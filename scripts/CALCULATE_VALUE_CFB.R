# ==============================================================================
# CALCULATE_VALUE_CFB.R — 3-Market +EV Engine
# Pipeline Step 18 (FATAL)
#
# Input:  games_with_predictions (.GlobalEnv)
# Output: all_bets (.GlobalEnv) — long-format, one row per market per game
#
# Markets: SPREAD | TOTAL | ML (ML filtered: |posted_spread| <= ML_SPREAD_THRESHOLD)
#
# Internal steps:
#   1. Spread edge    → proj_spread vs dk_spread_home
#   2. Total edge     → proj_total  vs dk_total
#   3. ML edge        → win_prob    vs american_to_prob(dk_ml)
#   4a. Sharp boost   (1.15x) — line moved >= SHARP_MOVE_SPREAD or SHARP_MOVE_TOTAL
#   4b. Trend boost   (1.08x) — trend signal agrees with model pick
#   4c. Bye week boost(1.08x) — team off bye, model agrees on direction
#   4d. Public% boost (1.20x) — VSiN divergence >= PUBLIC_PCT_MIN_DIV
#   4e. Conference weight (0.58–1.00x) — avg of both teams' conf_weight
#   5. Kelly sizing   — 3 independent bet sizes max per game
#   6. Correlated cap — ALL markets (SPREAD + TOTAL + ML) per game capped at MAX_SINGLE_GAME_EXPOSURE combined
#   7. Long-format    — one row per qualified bet
#
# Max combined boost: 1.15 * 1.08 * 1.08 * 1.20 = 1.606x (all 4 fire)
# ==============================================================================

suppressMessages(library(tidyverse))

# ------------------------------------------------------------------------------
# 1. Spread edge
# ------------------------------------------------------------------------------
evaluate_spread <- function(game, bankroll) {

  posted   <- game$dk_spread_home
  proj     <- game$proj_spread
  juice_h  <- coalesce(game$dk_spread_juice_home, -110)
  juice_a  <- coalesce(game$dk_spread_juice_away, -110)

  if (is.na(posted) || is.na(proj)) return(NULL)

  edge  <- proj - posted   # negative proj vs positive posted = home edge
  max_e <- if (exists("MAX_EDGE_SPREAD")) MAX_EDGE_SPREAD else Inf

  # MAX_EDGE_SPREAD cap applied first — outliers are negative EV regardless of
  # line movement. 2025 backtest: 126 bets >12 pts at 43.7% ATS. Cap is hard.
  if (abs(edge) > max_e) return(NULL)

  # Determine bet side
  line_move <- abs(coalesce(game$open_spread_home, posted) - posted)
  sharp     <- line_move >= SHARP_MOVE_SPREAD

  if (edge <= -MIN_EDGE_SPREAD) {
    bet_side <- "home"; juice <- juice_h; edge_abs <- abs(edge)
  } else if (edge >= MIN_EDGE_SPREAD) {
    bet_side <- "away"; juice <- juice_a; edge_abs <- edge
  } else if (sharp && edge < -SHARP_EDGE_SPREAD) {
    # Sharp override: reduced threshold when line has moved — cap already cleared above
    bet_side <- "home"; juice <- juice_h; edge_abs <- abs(edge)
  } else if (sharp && edge > SHARP_EDGE_SPREAD) {
    bet_side <- "away"; juice <- juice_a; edge_abs <- edge
  } else {
    return(NULL)
  }

  # Rivalry dampener: traditional rivalry games cover at ~50% regardless of
  # ratings. Reduce effective edge by RIVALRY_SOFTEN_PTS (1.5 pts) so a
  # 5.0 pt raw edge needs to be 6.5 pts before it qualifies on a rivalry game.
  is_rivalry <- exists("rivalry_game_ids", envir = .GlobalEnv) &&
                !is.null(game$game_id) &&
                game$game_id %in% get("rivalry_game_ids", envir = .GlobalEnv)
  if (is_rivalry) {
    soften <- if (exists("RIVALRY_SOFTEN_PTS")) RIVALRY_SOFTEN_PTS else 1.5
    edge_abs <- edge_abs - soften
    if (edge_abs <= 0) return(NULL)
  }

  dec_odds  <- american_to_decimal(juice)
  imp_prob  <- american_to_prob(juice)
  win_prob  <- imp_prob + (edge_abs / 28)  # rough prob boost from edge
  win_prob  <- min(win_prob, 0.85)

  ev        <- (win_prob * (dec_odds - 1)) - (1 - win_prob)
  if (ev <= 0) return(NULL)

  kelly_raw <- kelly_bet(win_prob, dec_odds, bankroll = bankroll)

  tibble(
    game_id        = game$game_id,
    canonical_home = game$canonical_home,
    canonical_away = game$canonical_away,
    commence_time  = game$commence_time,
    bet_type       = "SPREAD",
    bet_side       = bet_side,
    posted_line    = if (bet_side == "home") posted else -posted,
    proj_line      = proj,
    edge           = edge_abs,
    juice          = juice,
    win_prob_raw   = win_prob,
    ev_raw         = ev,
    kelly_raw      = kelly_raw,
    line_move      = abs(coalesce(game$open_spread_home, posted) - posted),
    conf_weight_avg = game$conf_weight_avg
  )
}

# ------------------------------------------------------------------------------
# 2. Total edge
# ------------------------------------------------------------------------------
evaluate_total <- function(game, bankroll) {

  posted     <- game$dk_total
  proj       <- game$proj_total
  juice_over <- coalesce(game$dk_total_juice_over,  -110)
  juice_under<- coalesce(game$dk_total_juice_under, -110)

  if (is.na(posted) || is.na(proj)) return(NULL)

  edge <- proj - posted

  if (edge >= MIN_EDGE_TOTAL) {
    bet_side  <- "over";  juice <- juice_over;  edge_abs <- edge
  } else if (edge <= -MIN_EDGE_TOTAL) {
    bet_side  <- "under"; juice <- juice_under; edge_abs <- abs(edge)
  } else {
    line_move_tot <- abs(coalesce(game$open_total, posted) - posted)
    if (line_move_tot >= SHARP_MOVE_TOTAL) {
      if (edge > 0) {
        bet_side <- "over";  juice <- juice_over;  edge_abs <- edge
      } else {
        bet_side <- "under"; juice <- juice_under; edge_abs <- abs(edge)
      }
    } else {
      return(NULL)
    }
  }

  dec_odds  <- american_to_decimal(juice)
  imp_prob  <- american_to_prob(juice)
  win_prob  <- imp_prob + (edge_abs / 28)
  win_prob  <- min(win_prob, 0.82)

  ev <- (win_prob * (dec_odds - 1)) - (1 - win_prob)
  if (ev <= 0) return(NULL)

  kelly_raw <- kelly_bet(win_prob, dec_odds, bankroll = bankroll)

  tibble(
    game_id        = game$game_id,
    canonical_home = game$canonical_home,
    canonical_away = game$canonical_away,
    commence_time  = game$commence_time,
    bet_type       = "TOTAL",
    bet_side       = bet_side,
    posted_line    = posted,
    proj_line      = proj,
    edge           = edge_abs,
    juice          = juice,
    win_prob_raw   = win_prob,
    ev_raw         = ev,
    kelly_raw      = kelly_raw,
    line_move      = abs(coalesce(game$open_total, posted) - posted),
    conf_weight_avg = game$conf_weight_avg
  )
}

# ------------------------------------------------------------------------------
# 3. ML edge
# ------------------------------------------------------------------------------
evaluate_ml <- function(game, bankroll) {

  posted_spread <- game$dk_spread_home
  if (!is.na(posted_spread) && abs(posted_spread) > ML_SPREAD_THRESHOLD) return(NULL)

  ml_home <- game$dk_ml_home
  ml_away <- game$dk_ml_away
  wp_home <- game$win_prob_home
  wp_away <- game$win_prob_away

  if (is.na(ml_home) || is.na(ml_away) || is.na(wp_home)) return(NULL)

  imp_home <- american_to_prob(ml_home)
  imp_away <- american_to_prob(ml_away)
  edge_home <- wp_home - imp_home
  edge_away <- wp_away - imp_away

  # Pick better side, must clear MIN_EDGE_ML (or SHARP_EDGE_ML with movement)
  line_move <- abs(coalesce(game$open_spread_home, coalesce(posted_spread, 0)) -
                     coalesce(posted_spread, 0))
  threshold <- if (line_move >= SHARP_MOVE_SPREAD) SHARP_EDGE_ML else MIN_EDGE_ML

  if (edge_home >= threshold && edge_home >= edge_away) {
    bet_side <- "home"; win_prob <- wp_home; juice <- ml_home; edge_abs <- edge_home
  } else if (edge_away >= threshold) {
    bet_side <- "away"; win_prob <- wp_away; juice <- ml_away; edge_abs <- edge_away
  } else {
    return(NULL)
  }

  dec_odds  <- american_to_decimal(juice)
  ev        <- (win_prob * (dec_odds - 1)) - (1 - win_prob)
  if (ev <= 0) return(NULL)

  kelly_raw <- kelly_bet(win_prob, dec_odds, bankroll = bankroll)

  tibble(
    game_id        = game$game_id,
    canonical_home = game$canonical_home,
    canonical_away = game$canonical_away,
    commence_time  = game$commence_time,
    bet_type       = "ML",
    bet_side       = bet_side,
    posted_line    = if (bet_side == "home") ml_home else ml_away,
    proj_line      = NA_real_,
    edge           = edge_abs,
    juice          = if (bet_side == "home") ml_home else ml_away,
    win_prob_raw   = win_prob,
    ev_raw         = ev,
    kelly_raw      = kelly_raw,
    line_move      = line_move,
    conf_weight_avg = game$conf_weight_avg
  )
}

# ------------------------------------------------------------------------------
# 4. Apply boost multipliers
# ------------------------------------------------------------------------------
apply_boosts <- function(bet_row, game) {

  boost <- 1.0
  flags <- character(0)

  # 4a. Sharp boost — line movement exceeds threshold
  if (!is.na(bet_row$line_move) && bet_row$line_move >= SHARP_MOVE_SPREAD) {
    boost <- boost * BOOST_SHARP
    flags <- c(flags, "SHARP")
  }

  # 4b. Trend boost — trend signal agrees with pick
  if (exists("trend_signals", envir = .GlobalEnv)) {
    ts <- get("trend_signals", envir = .GlobalEnv)
    if (!is.null(ts) && nrow(ts) > 0 && "game_id" %in% names(ts)) {
      game_trend <- ts[ts$game_id == bet_row$game_id, ]
      if (nrow(game_trend) > 0) {
        trend_dir  <- game_trend$trend_direction[1]
        pick_dir   <- if (bet_row$bet_side %in% c("home", "over")) "home" else "away"
        if (!is.na(trend_dir) && trend_dir == pick_dir) {
          boost <- boost * BOOST_TREND
          flags <- c(flags, "TREND")
        }
      }
    }
  }

  # 4c. Bye week boost — betting team off a bye
  if (exists("bye_week_data", envir = .GlobalEnv)) {
    bwd <- get("bye_week_data", envir = .GlobalEnv)
    if (!is.null(bwd) && nrow(bwd) > 0) {
      favored_team <- if (bet_row$bet_side == "home") game$canonical_home else game$canonical_away
      if (favored_team %in% bwd$canonical_name) {
        boost <- boost * BOOST_BYE_WEEK
        flags <- c(flags, "BYE")
      }
    }
  }

  # 4d. Public% boost — VSiN sharp vs. public divergence
  # Source: vsin_data (.GlobalEnv) — assigned by PARSE_VSIN_CFB.R (Step 8.5b)
  # vsin_divergence = abs(home_ml_handle_pct - home_ml_bets_pct)
  # Fires when divergence >= PUBLIC_PCT_MIN_DIV (default: 0.15)
  if (exists("vsin_data", envir = .GlobalEnv)) {
    vd <- get("vsin_data", envir = .GlobalEnv)
    if (!is.null(vd) && "game_id" %in% names(vd)) {
      game_vsin <- vd[vd$game_id == bet_row$game_id, ]
      if (nrow(game_vsin) > 0 && !is.na(game_vsin$vsin_divergence[1])) {
        if (game_vsin$vsin_divergence[1] >= PUBLIC_PCT_MIN_DIV) {
          boost <- boost * BOOST_PUBLIC_PCT
          flags <- c(flags, "PUBLIC")
        }
      }
    }
  }

  # 4e. Conference weight — downweight thin G5/Independent markets
  cw <- coalesce(bet_row$conf_weight_avg, 1.0)
  boost <- boost * cw

  # 4f. BBOC confirmation — Stuckey/Collin Wilson (Action Network BBOC podcast)
  # pick aligns with model side. Fires only when bboc_picks is populated and
  # has a LOVE or LIKE tier pick for this game+market+side.
  # Market mapping: SPREAD bet_side "home"/"away" → pick direction "FOR"/"FOR"
  #   (team_mention = canonical_home or canonical_away)
  # TOTAL: bet_side "over"/"under" → pick direction "OVER"/"UNDER"
  if (exists("bboc_picks", envir = .GlobalEnv)) {
    bp <- get("bboc_picks", envir = .GlobalEnv)
    if (!is.null(bp) && nrow(bp) > 0) {
      bboc_market <- bet_row$bet_type   # "SPREAD", "TOTAL", "ML"
      bboc_team   <- if (bet_row$bet_side %in% c("home")) game$canonical_home
                     else if (bet_row$bet_side == "away") game$canonical_away
                     else NA_character_  # TOTAL handled by direction
      bboc_dir    <- if (bet_row$bet_side %in% c("over", "under"))
                       toupper(bet_row$bet_side) else "FOR"

      # Match: same game + same market + (same team_mention OR same direction for TOTAL)
      # Require LOVE or LIKE tier — LEAN is too soft to boost
      bboc_match <- bp %>%
        filter(
          coalesce(game_id, "") == coalesce(bet_row$game_id, "X"),
          market == bboc_market,
          confidence_tier %in% c("LOVE", "LIKE"),
          if (bboc_market == "TOTAL")
            direction == bboc_dir
          else
            coalesce(team_mention, "") == coalesce(bboc_team, "X")
        )

      if (nrow(bboc_match) > 0) {
        bboc_mult <- if (exists("BBOC_CONFIRM_BOOST")) BBOC_CONFIRM_BOOST else 1.12
        boost <- boost * bboc_mult
        flags <- c(flags, sprintf("BBOC_%s", bboc_match$confidence_tier[1]))
      }
    }
  }

  list(boost = round(boost, 4), flags = paste(flags, collapse = "|"))
}

# ------------------------------------------------------------------------------
# 5 + 6. Kelly sizing + correlated cap applied in main loop
# ------------------------------------------------------------------------------
calculate_value <- function() {

  if (!exists("games_with_predictions", envir = .GlobalEnv)) {
    stop("[CALC] games_with_predictions not found. Run GENERATE_PREDICTIONS_CFB.R first.")
  }

  gwp      <- get("games_with_predictions", envir = .GlobalEnv)
  bankroll <- as.numeric(readLines(BANKROLL_FILE, warn = FALSE)[1])

  cat(sprintf("[CALC] Evaluating %d games | Bankroll: $%.2f\n", nrow(gwp), bankroll))

  all_bets <- vector("list", nrow(gwp) * 3)
  idx <- 1

  for (i in seq_len(nrow(gwp))) {
    game <- as.list(gwp[i, ])

    for (eval_fn in list(evaluate_spread, evaluate_total, evaluate_ml)) {
      bet <- tryCatch(eval_fn(game, bankroll), error = function(e) NULL)
      if (is.null(bet)) next

      boost_result    <- apply_boosts(bet, game)
      bet$boost       <- boost_result$boost
      bet$boost_flags <- boost_result$flags
      bet$ev          <- bet$ev_raw  * bet$boost
      bet$bet_amount  <- min(
        round(bet$kelly_raw * bet$boost, 2),
        bankroll * MAX_SINGLE_GAME_EXPOSURE   # hard per-bet cap
      )
      bet$bet_amount  <- max(bet$bet_amount, 0)

      # --- Retention dampener (weeks 1-4 only; applied to bet sizing, NOT to EV) ---
      # Represents model uncertainty from roster turnover, not a market edge signal.
      # Scales Kelly down for low-retention teams; decays linearly to 1.0 by Week 5.
      #   decay_fac = (5 - week_num) / 4  → 1.0 at week1, 0.25 at week4, 0.0 at week5+
      #   ret_mult  = 1.0 - (1.0 - retention_score) * decay_fac
      # For TOTAL bets: use min(home, away) — both teams' uncertainty matters.
      # For SPREAD / ML: use the bet-side team's retention score.
      wn <- coalesce(as.integer(game$week_num), 5L)
      if (wn < 5L) {
        decay_fac <- (5L - wn) / 4L
        ret_score <- if (bet$bet_type == "TOTAL") {
          min(coalesce(game$home_retention_score, 1.0),
              coalesce(game$away_retention_score, 1.0))
        } else if (bet$bet_side == "home") {
          coalesce(game$home_retention_score, 1.0)
        } else {
          coalesce(game$away_retention_score, 1.0)
        }
        ret_mult       <- 1.0 - (1.0 - ret_score) * decay_fac
        bet$bet_amount <- round(bet$bet_amount * ret_mult, 2)
      } else {
        ret_mult <- 1.0
      }
      bet$retention_mult <- round(ret_mult, 4)

      all_bets[[idx]] <- bet
      idx <- idx + 1
    }
  }

  all_bets <- bind_rows(compact(all_bets))

  if (nrow(all_bets) == 0) {
    cat("[CALC] No bets qualified this run.\n")
    assign("all_bets", all_bets, envir = .GlobalEnv)
    assign("qualified_bets", all_bets, envir = .GlobalEnv)
    return(invisible(all_bets))
  }

  # --- Correlated bet cap: ALL markets on same game capped at MAX_SINGLE_GAME_EXPOSURE ---
  # Previously only capped SPREAD + ML. Extended to include TOTAL (2026-05-17):
  # Spread + Total on the same game are correlated when the model likes a big underdog
  # AND the Under — both win/lose together in a low-scoring defensive game. A full
  # Kelly on all three markets on a single game concentrates unacceptable correlated risk.
  # Fix: sum all three markets' exposure per game; scale all proportionally if over cap.
  all_bets <- all_bets %>%
    group_by(game_id) %>%
    mutate(
      game_exposure = sum(bet_amount),            # all markets, not just SPREAD+ML
      game_cap      = bankroll * MAX_SINGLE_GAME_EXPOSURE
    ) %>%
    mutate(
      bet_amount = if_else(
        game_exposure > game_cap,
        round(bet_amount * (game_cap / game_exposure), 2),
        bet_amount
      )
    ) %>%
    ungroup() %>%
    select(-game_exposure, -game_cap)

  # --- Weekly exposure cap: MAX_EXPOSURE_PER_WEEK ---
  # Sort by EV descending — trim lowest-EV bets if total action exceeds cap
  weekly_cap <- bankroll * MAX_EXPOSURE_PER_WEEK
  all_bets   <- all_bets %>% arrange(desc(ev))
  cum_action <- cumsum(all_bets$bet_amount)
  n_keep     <- max(which(cum_action <= weekly_cap), 1)   # keep at least 1

  if (n_keep < nrow(all_bets)) {
    n_trimmed <- nrow(all_bets) - n_keep
    cat(sprintf(
      "[CALC] Weekly exposure cap ($%.0f): trimmed %d lowest-EV bet(s).\n",
      weekly_cap, n_trimmed
    ))
    all_bets <- all_bets[seq_len(n_keep), ]
  }

  # --- MAX_BETS_PER_WEEK hard cap (already sorted by EV desc) ---
  if (nrow(all_bets) > MAX_BETS_PER_WEEK) {
    cat(sprintf(
      "[CALC] MAX_BETS_PER_WEEK cap (%d): dropping %d excess bet(s).\n",
      MAX_BETS_PER_WEEK, nrow(all_bets) - MAX_BETS_PER_WEEK
    ))
    all_bets <- all_bets[seq_len(MAX_BETS_PER_WEEK), ]
  }

  # --- Final sort: by commence_time then EV ---
  if ("commence_time" %in% names(all_bets)) {
    all_bets <- all_bets %>% arrange(commence_time, desc(ev))
  }

  # --- Summary ---
  cat(sprintf(
    "[CALC] Qualified bets: %d total (SPREAD: %d | TOTAL: %d | ML: %d)\n",
    nrow(all_bets),
    sum(all_bets$bet_type == "SPREAD"),
    sum(all_bets$bet_type == "TOTAL"),
    sum(all_bets$bet_type == "ML")
  ))
  cat(sprintf(
    "[CALC] Total action: $%.2f of $%.2f weekly cap (%.1f%%)\n",
    sum(all_bets$bet_amount), weekly_cap,
    100 * sum(all_bets$bet_amount) / weekly_cap
  ))
  cat(sprintf(
    "[CALC] Avg EV: %.3f | Avg edge: %.1f pts | Avg boost: %.3fx\n",
    mean(all_bets$ev),
    mean(all_bets$edge),
    mean(all_bets$boost)
  ))

  # Retention dampener summary — only meaningful in weeks 1-4
  if ("retention_mult" %in% names(all_bets)) {
    n_dampened <- sum(all_bets$retention_mult < 1.0, na.rm = TRUE)
    if (n_dampened > 0) {
      cat(sprintf(
        "[CALC] Retention dampener fired: %d bet(s) | avg mult %.3f (min %.3f)\n",
        n_dampened,
        mean(all_bets$retention_mult[all_bets$retention_mult < 1.0], na.rm = TRUE),
        min(all_bets$retention_mult, na.rm = TRUE)
      ))
    }
  }

  assign("all_bets",       all_bets, envir = .GlobalEnv)
  assign("qualified_bets", all_bets, envir = .GlobalEnv)   # alias for orchestrator summary
  invisible(all_bets)
}

# Run when sourced
calculate_value()

cat("[CALC] CALCULATE_VALUE_CFB.R complete.\n")
