# ==============================================================================
# GENERATE_PREDICTIONS_CFB.R — Projected Spread, Total, Win Probability
# Pipeline Step 13
#
# Input:  games_with_ratings  (from MERGE_GAMES_RATINGS_CFB.R)
# Output: games_with_predictions  (.GlobalEnv)
#
# Model: deterministic linear — blended rating differential + adjustments
#
# Projected spread (home perspective, negative = home favored):
#   proj_spread = -(rating_diff + effective_hfa + bye_adj + travel_adj)
#
# Projected total:
#   proj_total  = league_avg_total + off_def_home + off_def_away + pace_adj
#
# Win probability (ML input):
#   win_prob_home = spread_to_win_prob(proj_spread)  [logistic sigmoid, CONFIG.R]
#
# ── PHASE 2 TODO: Monte Carlo Alternate Lines ──────────────────────────────────
# Monte Carlo is specifically valuable for evaluating alternate spread/total
# lines (alt -7, alt -14, alt -21 at varying juice prices). The base model
# gives a point estimate; alt lines require P(margin > X) from a full
# outcome distribution.
#
# Implementation plan (Phase 2):
#   1. Add simulate_game_outcomes(proj_spread, sigma, n_sims = 10000) function
#      sigma ≈ 16–18 pts (calibrate from 2025 CFB season residuals)
#   2. Return games_with_predictions with a `sim_margins` list-column
#   3. In CALCULATE_VALUE_CFB.R, add evaluate_alt_lines() that iterates
#      posted alt spread menu → P(cover) → EV → Kelly per line
#   4. Add "alternate_spreads,alternate_totals" to ODDS_MARKETS in
#      fetch_odds_football.R (Odds API v4 supports these markets)
#   5. Calibrate sigma by conference tier — P4 games have tighter distributions
#      than G5/Independent due to smaller talent variance within the group
#
# Prerequisite: validate base model MAE ≤ 6 pts against 2025 historical season
# data before trusting sigma estimates. Live deployment: Sep 2026.
# See PENDING ITEMS in CFB_PROJECT_BIBLE.md.
# ──────────────────────────────────────────────────────────────────────────────

suppressMessages(library(tidyverse))

# ------------------------------------------------------------------------------
# Talent composite decay schedule
#   In weeks 1-4, in-season SP+ hasn't fully stabilized. Talent composite
#   (247Sports blue-chip index via CFBD /teams/talent) fills the gap.
#   By Week 5, market efficiency on blended ratings is sufficient; decay = 0.
#
#   Week:    1      2      3      4      5+
#   Weight: 1.00   0.75   0.50   0.25   0.00
# ------------------------------------------------------------------------------
talent_decay <- function(week_num) {
  decay_vec <- c(1.00, 0.75, 0.50, 0.25, 0.00)
  if (is.na(week_num) || as.integer(week_num) >= 5L) return(0.0)
  decay_vec[pmax(1L, pmin(as.integer(week_num), 4L))]
}

# League-average total — calibrated from 2025 CFB historical data (CFBD historical endpoint)
# 2025 FBS average: ~48.5 pts/game. Update after each completed season.
# Live season: 2026. Validation year: 2025.
CFB_AVG_TOTAL <- 48.5

# ------------------------------------------------------------------------------
# Bye week adjustment
#   Teams off a bye week cover ATS at ~53-54% historically.
#   Applies +BYE_ADJ_PTS to the better-rated team's side when model agrees.
#   Non-fatal: if bye_week_data missing, adjustment = 0
# ------------------------------------------------------------------------------
get_bye_adj <- function(canonical_home, canonical_away, rating_diff) {
  if (!exists("bye_week_data", envir = .GlobalEnv)) return(0)
  bye_df <- get("bye_week_data", envir = .GlobalEnv)
  if (is.null(bye_df) || nrow(bye_df) == 0) return(0)

  BYE_ADJ_PTS <- 1.5   # conservative half of the bye boost

  home_on_bye <- canonical_home %in% bye_df$canonical_name
  away_on_bye <- canonical_away %in% bye_df$canonical_name

  case_when(
    # Home on bye AND model has home as the better team
    home_on_bye & !away_on_bye & rating_diff > 0  ~  BYE_ADJ_PTS,
    # Away on bye AND model has away as the better team
    away_on_bye & !home_on_bye & rating_diff < 0  ~ -BYE_ADJ_PTS,
    TRUE ~ 0
  )
}

# ------------------------------------------------------------------------------
# Travel fatigue adjustment
#   Non-fatal: if travel_fatigue missing, adjustment = 0
# ------------------------------------------------------------------------------
get_travel_adj <- function(canonical_home, canonical_away) {
  if (!exists("travel_fatigue", envir = .GlobalEnv)) return(0)
  tf <- get("travel_fatigue", envir = .GlobalEnv)
  if (is.null(tf) || nrow(tf) == 0) return(0)

  # travel_fatigue tibble expected: canonical_name, fatigue_pts (negative = disadvantage)
  home_fatigue <- coalesce(tf$fatigue_pts[tf$canonical_name == canonical_home][1], 0)
  away_fatigue <- coalesce(tf$fatigue_pts[tf$canonical_name == canonical_away][1], 0)

  # Net effect on home spread: home fatigue hurts home, away fatigue helps home
  home_fatigue - away_fatigue
}

# ------------------------------------------------------------------------------
# Pace adjustment for totals
#   Primary signal: plays_per_game (from CFBD /stats/season — added Session 18).
#   Fast teams (75+ plays/game) inflate totals; slow teams (<65) suppress.
#   Fallback: possessionTime when plays_per_game is unavailable.
#
#   CONFIG params: LEAGUE_AVG_PACE (70.0), TEMPO_TOTAL_WEIGHT (0.15 pts/play)
#   e.g., two fast teams both at +5 plays over avg → (5+5) × 0.15 = +1.5 pts
# ------------------------------------------------------------------------------
pace_adjustment <- function(home_plays_pg, away_plays_pg,
                             home_possession = NA_real_, away_possession = NA_real_) {
  # Primary: plays_per_game
  if (!is.na(home_plays_pg) || !is.na(away_plays_pg)) {
    avg_pace <- if (exists("LEAGUE_AVG_PACE"))    LEAGUE_AVG_PACE    else 70.0
    tempo_w  <- if (exists("TEMPO_TOTAL_WEIGHT")) TEMPO_TOTAL_WEIGHT else 0.15
    home_dev <- (coalesce(as.numeric(home_plays_pg), avg_pace) - avg_pace)
    away_dev <- (coalesce(as.numeric(away_plays_pg), avg_pace) - avg_pace)
    return((home_dev + away_dev) * tempo_w)
  }

  # Fallback: possessionTime (original signal)
  BASELINE_POSS <- 30.0
  PTS_PER_MIN   <- 0.8
  home_dev <- coalesce(as.numeric(home_possession), BASELINE_POSS) - BASELINE_POSS
  away_dev <- coalesce(as.numeric(away_possession), BASELINE_POSS) - BASELINE_POSS
  (home_dev + away_dev) * PTS_PER_MIN
}

# ------------------------------------------------------------------------------
# Core prediction engine — one row at a time (via pmap)
#
# Spread formula:
#   proj_spread = -(rating_diff * SP_SCALAR
#                   + ppa_adj          [PPA_SPREAD_WEIGHT × ppa_diff]
#                   + success_adj      [SUCCESS_SPREAD_WEIGHT × success_rate_diff]
#                   + effective_hfa
#                   + bye_adj
#                   + travel_adj)
#
# Total formula (PPA path when available):
#   proj_total = CFB_AVG_TOTAL + expl_adj [EXPL_TOTAL_WEIGHT × explosiveness_diff]
#              + pace_adj
#   Fallback (no PPA): CFB_AVG_TOTAL + off_def_home + off_def_away + pace_adj
#
# All PPA weights live in CONFIG.R — tune without touching this function.
# ------------------------------------------------------------------------------
predict_game <- function(game_row) {
  rd       <- coalesce(game_row$rating_diff,   0)
  hfa      <- coalesce(game_row$effective_hfa, 3.0)
  odh      <- coalesce(game_row$off_def_home,  0)
  oda      <- coalesce(game_row$off_def_away,  0)
  home     <- game_row$canonical_home
  away     <- game_row$canonical_away

  # --- Load weights from CONFIG (with safe fallbacks) ---
  scalar       <- if (exists("SP_SCALAR"))             SP_SCALAR             else 1.0
  ppa_w        <- if (exists("PPA_SPREAD_WEIGHT"))     PPA_SPREAD_WEIGHT     else 5.0
  expl_w       <- if (exists("EXPL_TOTAL_WEIGHT"))     EXPL_TOTAL_WEIGHT     else 3.0
  success_w    <- if (exists("SUCCESS_SPREAD_WEIGHT")) SUCCESS_SPREAD_WEIGHT else 2.0
  talent_w     <- if (exists("TALENT_WEIGHT"))         TALENT_WEIGHT         else 1.5

  # --- PPA signals (NA-safe; fall back to 0 when team_metrics not available) ---
  ppa_diff       <- coalesce(game_row$ppa_diff,          NA_real_)
  success_diff   <- coalesce(game_row$success_rate_diff, NA_real_)
  expl_diff      <- coalesce(game_row$explosiveness_diff, NA_real_)

  ppa_adj     <- if (!is.na(ppa_diff))     ppa_diff     * ppa_w     else 0
  success_adj <- if (!is.na(success_diff)) success_diff * success_w else 0
  expl_adj    <- if (!is.na(expl_diff))    expl_diff    * expl_w    else NA_real_

  # --- Talent adjustment (weeks 1-4 only; decays to 0 by Week 5) ---
  # talent_diff = home_talent_norm - away_talent_norm from MERGE_GAMES_RATINGS.
  # Positive talent_diff = home team has the talent edge → shifts spread toward home.
  # Decay: Week 1 = full weight, Week 5+ = 0 (in-season SP+ fully trusted by then).
  tdiff <- coalesce(game_row$talent_diff, 0)

  # Derive CFB week number from game date
  game_date  <- tryCatch(as.Date(game_row$commence_time), error = function(e) NA_real_)
  if (!is.na(game_date)) {
    season_yr  <- as.integer(format(game_date, "%Y"))
    sept1      <- as.Date(sprintf("%d-09-01", season_yr))
    week_num   <- as.integer(ceiling((as.numeric(game_date - sept1) + 1) / 7))
    week_num   <- pmax(week_num, 1L)   # negative values (late Aug games) → Week 1
  } else {
    week_num   <- 5L   # unknown date → no talent adjustment
  }

  talent_adj <- tdiff * talent_w * talent_decay(week_num)

  # --- Bye week + travel adjustments ---
  bye_adj    <- tryCatch(get_bye_adj(home, away, rd), error = function(e) 0)
  travel_adj <- tryCatch(get_travel_adj(home, away),  error = function(e) 0)

  # --- Projected spread (home perspective) ---
  # Negative = home favored (sportsbook convention)
  # talent_adj added as a positive term (same sign convention as rating_diff):
  #   +talent_adj = home talent advantage → spread moves in home team's favor
  proj_spread <- -(rd * scalar + ppa_adj + success_adj + talent_adj + hfa + bye_adj + travel_adj)

  # --- Projected total ---
  home_plays_pg <- if ("home_plays_per_game" %in% names(game_row))
                     game_row$home_plays_per_game else NA_real_
  away_plays_pg <- if ("away_plays_per_game" %in% names(game_row))
                     game_row$away_plays_per_game else NA_real_
  home_poss     <- if ("home_possessionTime" %in% names(game_row))
                     game_row$home_possessionTime else NA_real_
  away_poss     <- if ("away_possessionTime" %in% names(game_row))
                     game_row$away_possessionTime else NA_real_
  p_adj <- pace_adjustment(home_plays_pg, away_plays_pg, home_poss, away_poss)

  # Use explosiveness diff when PPA data available; fall back to SP+ off/def
  proj_total <- if (!is.na(expl_adj)) {
    CFB_AVG_TOTAL + expl_adj + p_adj
  } else {
    CFB_AVG_TOTAL + odh + oda + p_adj
  }

  # --- Win probability (logistic sigmoid) ---
  win_prob_home <- spread_to_win_prob(proj_spread)
  win_prob_away <- 1 - win_prob_home

  list(
    proj_spread    = round(proj_spread,    2),
    proj_total     = round(proj_total,     2),
    win_prob_home  = round(win_prob_home,  4),
    win_prob_away  = round(win_prob_away,  4),
    bye_adj        = round(bye_adj,        2),
    travel_adj     = round(travel_adj,     2),
    ppa_adj        = round(ppa_adj,        3),
    success_adj    = round(success_adj,    3),
    talent_adj     = round(talent_adj,     3),
    tempo_adj      = round(p_adj,          3),
    week_num       = as.integer(week_num),
    ppa_available  = !is.na(ppa_diff)
  )
}

# ------------------------------------------------------------------------------
# Main entry point
# ------------------------------------------------------------------------------
generate_predictions <- function() {

  if (!exists("games_with_ratings", envir = .GlobalEnv)) {
    stop("[PREDICT] games_with_ratings not found. Run MERGE_GAMES_RATINGS_CFB.R first.")
  }

  gwr <- get("games_with_ratings", envir = .GlobalEnv)

  # Only predict on games where both teams are rated
  predictable <- gwr %>%
    filter(!is.na(home_rating), !is.na(away_rating))

  unpredictable <- nrow(gwr) - nrow(predictable)
  if (unpredictable > 0) {
    warning(sprintf("[PREDICT] %d game(s) skipped — missing ratings.", unpredictable))
  }

  cat(sprintf("[PREDICT] Generating predictions for %d games...\n", nrow(predictable)))

  # Apply predict_game row-by-row
  preds <- predictable %>%
    mutate(pred = pmap(., function(...) {
      row <- list(...)
      tryCatch(predict_game(row), error = function(e) {
        warning(sprintf("[PREDICT] Error on game %s: %s",
                        row$game_id, e$message))
        list(proj_spread   = NA_real_, proj_total   = NA_real_,
             win_prob_home = NA_real_, win_prob_away = NA_real_,
             bye_adj = 0, travel_adj = 0)
      })
    })) %>%
    unnest_wider(pred)

  # Summary diagnostics
  n_ppa <- if ("ppa_available" %in% names(preds)) sum(preds$ppa_available, na.rm = TRUE) else 0
  cat(sprintf(
    "[PREDICT] Spread range: %.1f to %.1f | Total range: %.1f to %.1f\n",
    min(preds$proj_spread, na.rm = TRUE),
    max(preds$proj_spread, na.rm = TRUE),
    min(preds$proj_total,  na.rm = TRUE),
    max(preds$proj_total,  na.rm = TRUE)
  ))
  cat(sprintf(
    "[PREDICT] Win prob range: %.1f%% to %.1f%%\n",
    min(preds$win_prob_home, na.rm = TRUE) * 100,
    max(preds$win_prob_home, na.rm = TRUE) * 100
  ))
  cat(sprintf(
    "[PREDICT] PPA adjustment active: %d / %d games (weights: spread=%.1f, total=%.1f, succ=%.1f)\n",
    n_ppa, nrow(preds),
    if (exists("PPA_SPREAD_WEIGHT")) PPA_SPREAD_WEIGHT else 5.0,
    if (exists("EXPL_TOTAL_WEIGHT")) EXPL_TOTAL_WEIGHT else 3.0,
    if (exists("SUCCESS_SPREAD_WEIGHT")) SUCCESS_SPREAD_WEIGHT else 2.0
  ))

  # Talent adjustment diagnostics
  if ("talent_adj" %in% names(preds) && "week_num" %in% names(preds)) {
    n_talent_active <- sum(abs(preds$talent_adj) > 0, na.rm = TRUE)
    cur_week        <- if (nrow(preds) > 0) preds$week_num[1] else NA
    if (!is.na(cur_week) && cur_week < 5L) {
      cat(sprintf(
        "[PREDICT] Talent adj active (Week %d, decay=%.2f): %d / %d games | range [%.2f, %.2f] pts\n",
        cur_week, talent_decay(cur_week), n_talent_active, nrow(preds),
        min(preds$talent_adj, na.rm = TRUE),
        max(preds$talent_adj, na.rm = TRUE)
      ))
    } else {
      cat("[PREDICT] Talent adj inactive (Week 5+ — in-season SP+ fully trusted).\n")
    }
  }

  # Sanity checks — warn on extreme projections
  extreme_spread <- preds %>% filter(abs(proj_spread) > 35)
  if (nrow(extreme_spread) > 0) {
    warning(sprintf(
      "[PREDICT] %d game(s) with |proj_spread| > 35 pts — check ratings for: %s",
      nrow(extreme_spread),
      paste(paste(extreme_spread$canonical_away, "@", extreme_spread$canonical_home),
            collapse = "; ")
    ))
  }

  assign("games_with_predictions", preds, envir = .GlobalEnv)
  invisible(preds)
}

# Run when sourced
generate_predictions()

cat("[PREDICT] GENERATE_PREDICTIONS_CFB.R complete.\n")
