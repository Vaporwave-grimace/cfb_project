# ==============================================================================
# standardize_data_cfb.R — Odds Data Normalization Wrapper
# Pipeline Step 11 (FATAL)
#
# Consumes: odds_data (tibble from fetch_odds_football.R)
# Produces: odds_data (same tibble, team names normalized to canonical_name,
#           metadata columns joined from MASTER)
#
# Expected input columns from Odds API (DraftKings):
#   id, sport_key, sport_title, commence_time,
#   home_team, away_team,
#   bookmakers (list-col, will have already been unnested by fetch_odds_football.R)
#   dk_spread_home, dk_spread_away, dk_total, dk_ml_home, dk_ml_away
# ==============================================================================

library(tidyverse)

# Source normalizer (idempotent — safe to source multiple times)
source("scripts/TEAM_NAME_NORMALIZER_CFB.R")

# ------------------------------------------------------------------------------
# normalize_odds_data()
#
# Main function called by run_daily_football.R Step 11
# Mutates odds_data in the pipeline's global environment
# ------------------------------------------------------------------------------
normalize_odds_data <- function(odds_df, mappings) {

  if (!exists("master_cfb") && missing(mappings)) {
    stop("[STANDARDIZE] Call load_cfb_master() first, or pass mappings= explicitly.")
  }
  if (missing(mappings)) mappings <- master_cfb

  required <- c("home_team", "away_team")
  missing_cols <- setdiff(required, names(odds_df))
  if (length(missing_cols) > 0) {
    stop(sprintf("[STANDARDIZE] odds_data missing required columns: %s",
                 paste(missing_cols, collapse = ", ")))
  }

  cat(sprintf("[STANDARDIZE] Normalizing %d games from Odds API...\n", nrow(odds_df)))

  # Drop any stale canonical columns from a prior run (prevent join collisions)
  odds_df <- odds_df %>%
    select(-any_of(c("canonical_home", "canonical_away",
                     "home_conference", "away_conference",
                     "home_conf_weight", "away_conf_weight",
                     "home_dome", "away_dome",
                     "home_hfa_pts",
                     "home_latitude", "home_longitude",
                     "away_latitude", "away_longitude")))

  # Normalize team names (source_col = "odds_name" — DK feed default)
  odds_df <- normalize_game_teams(
    odds_df,
    mappings      = mappings,
    away_col      = "away_team",
    home_col      = "home_team",
    source_col    = "odds_name",
    unmatched_log = "logs/unmatched_teams.csv"
  )

  # Count and report any unmatched
  n_unmatched_away <- sum(is.na(odds_df$canonical_away))
  n_unmatched_home <- sum(is.na(odds_df$canonical_home))
  if (n_unmatched_away + n_unmatched_home > 0) {
    warning(sprintf(
      "[STANDARDIZE] %d away + %d home team names could not be resolved. Check logs/unmatched_teams.csv.",
      n_unmatched_away, n_unmatched_home
    ))
  }

  # Drop rows where either team is unresolved — can't compute predictions.
  # Common cause: FCS opponents in Week 1 cupcake games (not in FBS master).
  n_before <- nrow(odds_df)
  dropped_games <- odds_df %>%
    filter(is.na(canonical_away) | is.na(canonical_home)) %>%
    mutate(drop_reason = case_when(
      is.na(canonical_away) ~ paste0("unresolved away: ", away_team),
      is.na(canonical_home) ~ paste0("unresolved home: ", home_team),
      TRUE ~ "both unresolved"
    ))
  odds_df <- odds_df %>% filter(!is.na(canonical_away), !is.na(canonical_home))
  n_dropped <- n_before - nrow(odds_df)
  if (n_dropped > 0) {
    cat(sprintf("[STANDARDIZE] Dropped %d game(s) — likely FCS opponents not in FBS master:\n",
                n_dropped))
    walk(dropped_games$drop_reason, ~ cat(sprintf("  ✗ %s\n", .x)))
  }

  # Join home team metadata from MASTER
  home_meta <- mappings %>%
    select(canonical_name,
           home_conference  = conference,
           home_conf_weight = conf_weight,
           home_dome        = dome,
           home_hfa_pts     = hfa_pts,
           home_latitude    = latitude,
           home_longitude   = longitude)

  away_meta <- mappings %>%
    select(canonical_name,
           away_conference  = conference,
           away_conf_weight = conf_weight,
           away_latitude    = latitude,
           away_longitude   = longitude)

  odds_df <- odds_df %>%
    left_join(home_meta, by = c("canonical_home" = "canonical_name")) %>%
    left_join(away_meta, by = c("canonical_away" = "canonical_name"))

  # Composite conference weight: average of both teams
  # Used later by CALCULATE_VALUE_CFB as EV multiplier
  odds_df <- odds_df %>%
    mutate(
      conf_weight_avg = (home_conf_weight + away_conf_weight) / 2,
      game_id         = coalesce(id, paste(canonical_away, canonical_home,
                                           format(as.Date(commence_time), "%Y%m%d"),
                                           sep = "_"))
    )

  # Standardize commence_time to POSIXct UTC
  # Using if/else on the column type (scalar check) rather than case_when(),
  # which deprecated scalar LHS inputs in dplyr 1.2.0.
  odds_df <- odds_df %>%
    mutate(commence_time = {
      if (inherits(commence_time, "POSIXct")) {
        commence_time
      } else if (is.character(commence_time)) {
        as.POSIXct(commence_time, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
      } else {
        as.POSIXct(NA_real_, origin = "1970-01-01", tz = "UTC")
      }
    })

  cat(sprintf("[STANDARDIZE] Done — %d games normalized and ready for pipeline.\n",
              nrow(odds_df)))

  odds_df
}

# ------------------------------------------------------------------------------
# validate_odds_data()
#
# Called after normalize_odds_data() as a sanity gate.
# Stops pipeline if critical columns are missing or all spreads are NA.
# ------------------------------------------------------------------------------
validate_odds_data <- function(odds_df) {

  # Required columns post-normalization
  required <- c("game_id", "canonical_home", "canonical_away",
                "commence_time", "home_conf_weight", "away_conf_weight",
                "home_dome", "home_hfa_pts",
                "home_latitude", "home_longitude")

  missing_cols <- setdiff(required, names(odds_df))
  if (length(missing_cols) > 0) {
    stop(sprintf("[STANDARDIZE] Validation FAILED — missing columns after normalization: %s",
                 paste(missing_cols, collapse = ", ")))
  }

  if (nrow(odds_df) == 0) {
    stop("[STANDARDIZE] Validation FAILED — 0 games remain after normalization.")
  }

  # Warn if spread columns exist but are all NA (data source issue, not fatal)
  if ("dk_spread_home" %in% names(odds_df) && all(is.na(odds_df$dk_spread_home))) {
    warning("[STANDARDIZE] dk_spread_home is all NA — spread bets will be skipped.")
  }
  if ("dk_total" %in% names(odds_df) && all(is.na(odds_df$dk_total))) {
    warning("[STANDARDIZE] dk_total is all NA — total bets will be skipped.")
  }
  if ("dk_ml_home" %in% names(odds_df) && all(is.na(odds_df$dk_ml_home))) {
    warning("[STANDARDIZE] dk_ml_home is all NA — ML bets will be skipped.")
  }

  cat(sprintf("[STANDARDIZE] Validation PASSED — %d games, %d columns.\n",
              nrow(odds_df), ncol(odds_df)))
  invisible(TRUE)
}

cat("[STANDARDIZE] standardize_data_cfb.R loaded.\n")
