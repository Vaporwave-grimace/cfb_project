# ==============================================================================
# MERGE_GAMES_RATINGS_CFB.R — Join Ratings + Stats onto Game Slate
# Pipeline Step 12 (FATAL)
#
# Inputs (from .GlobalEnv):
#   odds_data       — normalized game slate from standardize_data_cfb.R
#                     must have: canonical_home, canonical_away, game_id,
#                                home_dome, home_hfa_pts, commence_time,
#                                dk_spread_home, dk_total, dk_ml_home/away
#   blended_ratings — from MERGE_ALL_RATINGS_CFB.R
#                     must have: canonical_name, blended_rating,
#                                sp_offense, sp_defense
#   cfbd_team_stats — from SCRAPE_CFB_DATA.R (optional — non-fatal if missing)
#
# Output (to .GlobalEnv): games_with_ratings
#   One row per game. All columns needed by GENERATE_PREDICTIONS_CFB.R present.
# ==============================================================================

suppressMessages(library(tidyverse))

# ------------------------------------------------------------------------------
# Helper: join ratings for home + away side with clear column prefixes
# ------------------------------------------------------------------------------
join_ratings_side <- function(games_df, ratings_df, side = "home") {
  col <- if (side == "home") "canonical_home" else "canonical_away"
  prefix <- side

  # Select rating columns to join
  ratings_join <- ratings_df %>%
    select(
      canonical_name,
      !!paste0(prefix, "_rating")         := blended_rating,
      !!paste0(prefix, "_sp_offense")     := any_of("sp_offense"),
      !!paste0(prefix, "_sp_defense")     := any_of("sp_defense"),
      !!paste0(prefix, "_n_sources")      := any_of("n_sources")
    )

  left_join(games_df, ratings_join, by = setNames("canonical_name", col))
}

# ------------------------------------------------------------------------------
# Helper: join basic team stats for home + away
# Columns sourced from clean/cfb_team_stats_YYYY.csv (SCRAPE_CFB_DATA.R Step 4)
# ------------------------------------------------------------------------------
join_stats_side <- function(games_df, stats_df, side = "home") {
  col    <- if (side == "home") "canonical_home" else "canonical_away"
  prefix <- side

  keep_stats <- c("yardsPerPlay", "pointsPerGame", "turnovers",
                  "turnover_margin", "third_down_rate",
                  "pass_completion_rate", "possessionTime", "plays_per_game")

  available <- intersect(keep_stats, names(stats_df))
  if (length(available) == 0) return(games_df)

  stats_join <- stats_df %>%
    select(canonical_name, all_of(available)) %>%
    rename_with(~ paste0(prefix, "_", .), .cols = -canonical_name)

  left_join(games_df, stats_join, by = setNames("canonical_name", col))
}

# ------------------------------------------------------------------------------
# Helper: join advanced efficiency metrics for home + away
# Columns sourced from team_metrics (TEAM_METRICS.R Step 6)
# Core: off/def PPA, success rate, explosiveness
# ------------------------------------------------------------------------------
join_metrics_side <- function(games_df, metrics_df, side = "home") {
  col    <- if (side == "home") "canonical_home" else "canonical_away"
  prefix <- side

  keep_metrics <- c("off_ppa", "def_ppa",
                    "off_rush_ppa", "off_pass_ppa",
                    "def_rush_ppa", "def_pass_ppa",
                    "rush_rate",
                    "off_success_rate", "def_success_rate",
                    "off_explosiveness", "def_explosiveness",
                    "off_power_success", "off_stuff_rate")

  available <- intersect(keep_metrics, names(metrics_df))
  if (length(available) == 0) return(games_df)

  metrics_join <- metrics_df %>%
    select(canonical_name, all_of(available)) %>%
    rename_with(~ paste0(prefix, "_", .), .cols = -canonical_name)

  left_join(games_df, metrics_join, by = setNames("canonical_name", col))
}

# ------------------------------------------------------------------------------
# Helper: join talent composite + retention score for home + away
# Columns sourced from team_metrics (TEAM_METRICS.R Step 6, fetch_talent +
# fetch_returning_production). Non-fatal — returns games_df unchanged when
# talent_norm / retention_score are absent from metrics_df.
# ------------------------------------------------------------------------------
join_talent_side <- function(games_df, metrics_df, side = "home") {
  col    <- if (side == "home") "canonical_home" else "canonical_away"
  prefix <- side

  keep_cols <- c("talent_norm", "retention_score")
  available <- intersect(keep_cols, names(metrics_df))
  if (length(available) == 0) return(games_df)

  talent_join <- metrics_df %>%
    select(canonical_name, all_of(available)) %>%
    rename_with(~ paste0(prefix, "_", .), .cols = -canonical_name)

  left_join(games_df, talent_join, by = setNames("canonical_name", col))
}

# ------------------------------------------------------------------------------
# Helper: join defensive havoc rates for home + away
# Columns sourced from team_metrics (TEAM_METRICS.R fetch_advanced_stats —
# defense.havoc.* via CFBD /stats/season/advanced). Non-fatal — returns
# games_df unchanged when havoc cols are absent from metrics_df.
# ------------------------------------------------------------------------------
join_havoc_side <- function(games_df, metrics_df, side = "home") {
  col    <- if (side == "home") "canonical_home" else "canonical_away"
  prefix <- side

  keep_cols <- c("def_havoc_total", "def_havoc_front_seven", "def_havoc_db")
  available <- intersect(keep_cols, names(metrics_df))
  if (length(available) == 0) return(games_df)

  havoc_join <- metrics_df %>%
    select(canonical_name, all_of(available)) %>%
    rename_with(~ paste0(prefix, "_", .), .cols = -canonical_name)

  left_join(games_df, havoc_join, by = setNames("canonical_name", col))
}

# ------------------------------------------------------------------------------
# Main merge
# ------------------------------------------------------------------------------
merge_games_ratings <- function() {

  # --- Validate required inputs ---
  if (!exists("odds_data", envir = .GlobalEnv)) {
    stop("[MERGE_GR] odds_data not found. Run fetch_odds_football.R + standardize_data_cfb.R first.")
  }
  if (!exists("blended_ratings", envir = .GlobalEnv)) {
    # Try loading from most recent CSV
    candidates <- list.files("clean", pattern = "^cfb_ratings_blended_",
                             full.names = TRUE)
    if (length(candidates) == 0) {
      stop("[MERGE_GR] blended_ratings not found and no clean/cfb_ratings_blended_*.csv exists.")
    }
    most_recent <- candidates[order(file.mtime(candidates), decreasing = TRUE)][1]
    cat(sprintf("[MERGE_GR] Loading blended_ratings from %s\n", most_recent))
    assign("blended_ratings", read_csv(most_recent, show_col_types = FALSE),
           envir = .GlobalEnv)
  }

  games    <- get("odds_data",       envir = .GlobalEnv)
  ratings  <- get("blended_ratings", envir = .GlobalEnv)

  # Basic stats (Step 4) — non-fatal
  stats <- if (exists("cfbd_team_stats", envir = .GlobalEnv)) {
    get("cfbd_team_stats", envir = .GlobalEnv)
  } else {
    candidates <- list.files("clean", pattern = "^cfb_team_stats_\\d{4}\\.csv$",
                             full.names = TRUE)
    if (length(candidates) > 0) {
      most_recent <- candidates[order(file.mtime(candidates), decreasing = TRUE)][1]
      cat(sprintf("[MERGE_GR] Loading team stats from %s\n", most_recent))
      read_csv(most_recent, show_col_types = FALSE)
    } else NULL
  }

  # Advanced metrics (Step 6) — non-fatal; fall back to stats if team_metrics absent
  metrics <- if (exists("team_metrics", envir = .GlobalEnv)) {
    get("team_metrics", envir = .GlobalEnv)
  } else if (!is.null(stats) &&
             all(c("off_ppa", "def_ppa") %in% names(stats))) {
    cat("[MERGE_GR] team_metrics not in GlobalEnv — using PPA cols from cfbd_team_stats.\n")
    stats
  } else {
    cat("[MERGE_GR] team_metrics not available — PPA columns will be NA.\n")
    NULL
  }

  cat(sprintf("[MERGE_GR] Merging: %d games | %d rated teams | %s stats | %s metrics\n",
              nrow(games), nrow(ratings),
              if (!is.null(stats))   sprintf("%d teams", nrow(stats))   else "none",
              if (!is.null(metrics)) sprintf("%d teams", nrow(metrics)) else "none"))

  # --- Drop stale columns to prevent join collisions ---
  stale_pattern <- paste0(
    "^(home|away)_(",
    "rating|sp_offense|sp_defense|n_sources|",
    "yardsPerPlay|pointsPerGame|turnovers|turnover_margin|",
    "third_down_rate|pass_completion_rate|possessionTime|plays_per_game|",
    "off_ppa|def_ppa|off_rush_ppa|off_pass_ppa|def_rush_ppa|def_pass_ppa|rush_rate|",
    "off_success_rate|def_success_rate|",
    "off_explosiveness|def_explosiveness|off_power_success|off_stuff_rate|",
    "talent_norm|retention_score|",
    "def_havoc_total|def_havoc_front_seven|def_havoc_db|",
    "portal_net_score",
    ")"
  )
  stale_cols <- names(games)[str_detect(names(games), stale_pattern)]
  if (length(stale_cols) > 0) {
    games <- games %>% select(-any_of(stale_cols))
  }

  # --- Join ratings ---
  gwr <- games %>%
    join_ratings_side(ratings, "home") %>%
    join_ratings_side(ratings, "away")

  # --- Join basic stats (non-fatal) ---
  if (!is.null(stats)) {
    gwr <- gwr %>%
      join_stats_side(stats, "home") %>%
      join_stats_side(stats, "away")
  }

  # --- Join advanced metrics (non-fatal) ---
  if (!is.null(metrics)) {
    gwr <- gwr %>%
      join_metrics_side(metrics, "home") %>%
      join_metrics_side(metrics, "away")
  }

  # --- Join talent + retention (non-fatal) ---
  # talent_norm and retention_score are written by TEAM_METRICS.R (Step 6).
  # If columns are absent (pre-season API not yet populated), the helper returns
  # games_df unchanged and downstream scripts see NA for both fields.
  if (!is.null(metrics) &&
      any(c("talent_norm", "retention_score") %in% names(metrics))) {
    gwr <- gwr %>%
      join_talent_side(metrics, "home") %>%
      join_talent_side(metrics, "away")
  }

  # --- Join defensive havoc rates (non-fatal) ---
  # def_havoc_* cols added to team_metrics by TEAM_METRICS.R Phase 1.
  # Returns games_df unchanged when columns are absent (pre-2026 data or API gap).
  if (!is.null(metrics) &&
      any(c("def_havoc_total", "def_havoc_front_seven", "def_havoc_db") %in% names(metrics))) {
    gwr <- gwr %>%
      join_havoc_side(metrics, "home") %>%
      join_havoc_side(metrics, "away")
  }

  # --- Join portal net score (non-fatal) ---
  # portal_net_score written by TRANSFER_PORTAL_CFB.R (Phase 2).
  # Assign to GlobalEnv as team_portal_scores before this step if available.
  portal_scores <- if (exists("team_portal_scores", envir = .GlobalEnv)) {
    get("team_portal_scores", envir = .GlobalEnv)
  } else NULL

  if (!is.null(portal_scores) && "portal_net_score" %in% names(portal_scores)) {
    for (side in c("home", "away")) {
      col <- if (side == "home") "canonical_home" else "canonical_away"
      p_join <- portal_scores %>%
        select(canonical_name, portal_net_score) %>%
        rename_with(~ paste0(side, "_", .), .cols = -canonical_name)
      gwr <- left_join(gwr, p_join, by = setNames("canonical_name", col))
    }
  }

  # --- Rating differential (home perspective) ---
  # Positive = home team is better rated

  # neutral_site is not returned by the Odds API — default FALSE when absent.
  # (A future schedule-join step can overwrite it for bowl/title games.)
  if (!"neutral_site" %in% names(gwr)) {
    gwr <- gwr %>% mutate(neutral_site = FALSE)
  }

  gwr <- gwr %>%
    mutate(
      rating_diff = home_rating - away_rating,

      # Effective HFA: zero out for neutral site games
      effective_hfa = if_else(
        neutral_site == TRUE,
        0,
        coalesce(home_hfa_pts, 3.0)   # default 3 pts if somehow missing
      ),

      # Offense/defense differential (used by GENERATE_PREDICTIONS for total)
      # Positive = home offense better than away defense (and vice versa)
      off_def_home = coalesce(home_sp_offense, 0) - coalesce(away_sp_defense, 0),
      off_def_away = coalesce(away_sp_offense, 0) - coalesce(home_sp_defense, 0),

      # PPA differential (home perspective) — primary signal when available
      # Composite: off advantage vs opponent def, minus own def disadvantage
      # Higher = home team expected to generate more EPA/play net
      ppa_diff = coalesce(
        (home_off_ppa - away_def_ppa) - (away_off_ppa - home_def_ppa),
        NA_real_
      ),

      # Success rate differential — drives vs spread; higher = more consistent offense
      success_rate_diff = coalesce(
        (home_off_success_rate - away_def_success_rate) -
        (away_off_success_rate - home_def_success_rate),
        NA_real_
      ),

      # Explosiveness differential — drives vs total; higher = more big-play upside
      explosiveness_diff = coalesce(
        home_off_explosiveness - away_off_explosiveness,
        NA_real_
      ),

      # Talent differential (home - away normalized composite)
      # Used in GENERATE_PREDICTIONS weeks 1-4 talent_adj; decays to 0 by Week 5.
      # +2.0 = home team is roughly ~200 composite pts better (e.g., Alabama vs G5)
      # Coalesced to 0 so prediction formula degrades gracefully when talent unavailable.
      talent_diff = coalesce(home_talent_norm, 0) - coalesce(away_talent_norm, 0),

      # Havoc differential (home def minus away def front-seven disruption rate)
      # Positive = home D-line creates more disruption vs away offense.
      # NA when CFBD /stats/season/advanced doesn't return havoc columns.
      havoc_diff = coalesce(
        home_def_havoc_front_seven - away_def_havoc_front_seven,
        NA_real_
      ),

      # Portal net score differential (home minus away portal talent delta)
      # Written by TRANSFER_PORTAL_CFB.R; NA when portal step hasn't run.
      portal_diff = coalesce(
        home_portal_net_score - away_portal_net_score,
        NA_real_
      ),

      # Conference weight — downweights thin G5/FCS-adjacent markets in CALCULATE_VALUE
      # Scale: P4 conf = 1.00 | G5 = 0.80 | Independent = 0.70 | mixed = avg
      # Derived from home/away conference columns when available; defaults to 0.90
      conf_weight_home = case_when(
        home_conference %in% c("SEC","Big Ten","Big 12","ACC","Pac-12") ~ 1.00,
        home_conference %in% c("American Athletic","Mountain West",
                               "Conference USA","MAC","Sun Belt")      ~ 0.80,
        home_conference == "FBS Independents"                          ~ 0.70,
        TRUE                                                           ~ 0.90
      ),
      conf_weight_away = case_when(
        away_conference %in% c("SEC","Big Ten","Big 12","ACC","Pac-12") ~ 1.00,
        away_conference %in% c("American Athletic","Mountain West",
                               "Conference USA","MAC","Sun Belt")      ~ 0.80,
        away_conference == "FBS Independents"                          ~ 0.70,
        TRUE                                                           ~ 0.90
      ),
      conf_weight_avg = (conf_weight_home + conf_weight_away) / 2,

      # Data quality flag
      n_sources_min = pmin(
        coalesce(home_n_sources, 0L),
        coalesce(away_n_sources, 0L)
      )
    )

  # --- Coverage check ---
  n_missing_home <- sum(is.na(gwr$home_rating))
  n_missing_away <- sum(is.na(gwr$away_rating))
  if (n_missing_home + n_missing_away > 0) {
    warning(sprintf(
      "[MERGE_GR] %d home + %d away ratings are NA. Affected games will have no predictions.",
      n_missing_home, n_missing_away
    ))
  }

  n_complete <- sum(!is.na(gwr$home_rating) & !is.na(gwr$away_rating))
  cat(sprintf("[MERGE_GR] Complete (both teams rated): %d / %d games.\n",
              n_complete, nrow(gwr)))

  assign("games_with_ratings", gwr, envir = .GlobalEnv)
  invisible(gwr)
}

# Run when sourced
merge_games_ratings()

cat("[MERGE_GR] MERGE_GAMES_RATINGS_CFB.R complete.\n")
