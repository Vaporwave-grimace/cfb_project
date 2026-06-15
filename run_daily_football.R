# ==============================================================================
# run_daily_football.R — mcFootball Master Pipeline Orchestrator
# Project: cfb_project | Path: G:/My Drive/Scripting Projects/cfb_project
# Philosophy: Edge + Positive EV + CLV across Spread, Total, and ML markets
# No player props (Colorado restriction)
#
# Run schedule (Windows Task Scheduler):
#   Thursday  6:00 PM  — early line capture
#   Friday   12:00 PM  — updated odds + injury check
#   Saturday  8:00 AM  — final run before kickoffs
#
# Markets: SPREAD | TOTAL | MONEYLINE (ML filtered: |spread| <= 10 pts only)
# ==============================================================================

# Capture DRY_RUN_MODE BEFORE rm() wipes the environment.
# Caller sets: DRY_RUN_MODE <- TRUE; source("run_daily_football.R")
.dry_run_saved <- if (exists("DRY_RUN_MODE")) DRY_RUN_MODE else FALSE
rm(list = ls())
setwd("G:/My Drive/Scripting Projects/cfb_project")
library(tidyverse)
library(lubridate)

# ------------------------------------------------------------------------------
# DRY_RUN_MODE — set TRUE to run full pipeline without writing to bet history
#                or broadcasting. Bets are printed to console only.
#                Set FALSE (or remove) for live production runs.
# ------------------------------------------------------------------------------
DRY_RUN_MODE <- .dry_run_saved
rm(.dry_run_saved)

pipeline_date <- Sys.Date()
pipeline_start <- Sys.time()
cat(sprintf("\n========== mcFootball Pipeline | %s%s ==========\n",
            pipeline_date,
            if (isTRUE(DRY_RUN_MODE)) " | DRY RUN — no writes, no broadcast" else ""))

# --- STEP 1: Load config ------------------------------------------------------
cat("\n[Step 1] Loading config...\n")
source("scripts/CONFIG.R")

# Flush stale unmatched-team log from prior runs.
# Step 10 auto-learn only needs names that genuinely fail the current normalizer.
if (file.exists("logs/unmatched_teams.csv")) file.remove("logs/unmatched_teams.csv")

# --- STEP 2: Settle previous bets ---------------------------------------------
cat("\n[Step 2] Settling previous bets...\n")
tryCatch({
  scores_file <- sprintf("clean/cfb_scores_%s.csv", format(pipeline_date - 1, "%Y%m%d"))
  if (file.exists(scores_file)) {
    scores <- read_csv(scores_file, show_col_types = FALSE)
    source("scripts/BET_SETTLEMENT.R")
    closing_lines <- tryCatch(
      load_closing_lines(),
      error = function(e) {
        cat(sprintf("[Step 2] Closing line load failed (non-fatal): %s\n", e$message))
        NULL
      }
    )
    settlement_results <- settle_bets(scores = scores, closing_lines = closing_lines)
    cat(sprintf("[Step 2] Settlement complete. Net P&L: $%.2f\n",
                coalesce(settlement_results$net_pl, 0)))
  } else {
    cat(sprintf("[Step 2] No scores file found for %s — skipping settlement.\n",
                pipeline_date - 1))
  }
}, error = function(e) cat(sprintf("[Step 2] Settlement error: %s\n", e$message)))

# --- STEP 3: Reload bankroll (may have been updated by settlement) ------------
BANKROLL <- as.numeric(readLines("outputs/bankroll.txt", warn = FALSE)[1])
cat(sprintf("[Step 3] Bankroll: $%.2f\n", BANKROLL))

# --- STEP 4: Scrape ratings (SP+, Sagarin, Massey) ----------------------------
cat("\n[Step 4] Scraping ratings...\n")
tryCatch({
  source("scripts/scrape_massey_cfb.R")
  source("scripts/scrape_sagarin.R")
  source("scripts/SCRAPE_CFB_DATA.R")   # SP+ + team stats via CFB Data API
}, error = function(e) cat(sprintf("[Step 4] Ratings error: %s\n", e$message)))

# --- STEP 5: Merge ratings ----------------------------------------------------
cat("\n[Step 5] Merging ratings...\n")
tryCatch({
  source("scripts/MERGE_ALL_RATINGS_CFB.R")
}, error = function(e) cat(sprintf("[Step 5] Merge error: %s\n", e$message)))

# --- STEP 6: Team metrics (off/def efficiency) --------------------------------
cat("\n[Step 6] Computing team metrics...\n")
tryCatch({
  source("scripts/TEAM_METRICS.R")
}, error = function(e) cat(sprintf("[Step 6] Team metrics error: %s\n", e$message)))

# --- STEP 7: Fetch odds (DraftKings primary) ----------------------------------
cat("\n[Step 7] Fetching odds...\n")
source("scripts/fetch_odds_football.R")   # fatal — no odds = no pipeline

# --- STEP 7.5: Injury reports (ESPN CFB) --------------------------------------
# Runs AFTER odds fetch so odds_data exists to scope to this week's teams only.
# Sets injury_adjustments in GlobalEnv; consumed by GENERATE_PREDICTIONS Step 13.
cat("\n[Step 7.5] Fetching CFB injury reports (ESPN)...\n")
tryCatch({
  .injury_sourced_by_orchestrator <- TRUE
  source("scripts/INJURY_SCRAPER_CFB.R")
  run_injury_scraper_cfb()
}, error = function(e) {
  cat(sprintf("[Step 7.5] Injury scraper error (non-fatal): %s\n", e$message))
  injury_adjustments <<- NULL
})

# --- STEP 8: Trend analysis (line movement) -----------------------------------
cat("\n[Step 8] Running trend analysis...\n")
tryCatch({
  source("scripts/TREND_ANALYSIS_CFB.R")
}, error = function(e) {
  cat(sprintf("[Step 8] Trend analysis error (non-fatal): %s\n", e$message))
  trend_signals <<- NULL
})

# --- STEP 8.5: Public betting % (Action Network via Firecrawl) ---------------
# Populates vsin_data with bets% vs money% per game — powers BOOST_PUBLIC_PCT
# (1.20x) in CALCULATE_VALUE_CFB.R. Non-fatal: boost simply won't fire if the
# scrape fails or Firecrawl is unavailable.
cat("\n[Step 8.5] Fetching public betting percentages...\n")
tryCatch({
  .public_bets_sourced_by_orchestrator <- TRUE
  source("scripts/FETCH_PUBLIC_BETS_CFB.R")
  fetch_public_bets_cfb()
}, error = function(e) {
  cat(sprintf("[Step 8.5] Public bets error (non-fatal): %s\n", e$message))
  vsin_data <<- NULL
})

# --- STEP 9: Patch commence times ---------------------------------------------
cat("\n[Step 9] Patching commence times...\n")
tryCatch({
  schedule_file <- sprintf("clean/cfb_schedule_%s.csv", format(pipeline_date, "%Y%m%d"))
  if (file.exists(schedule_file)) {
    cfb_schedule <- read_csv(schedule_file, show_col_types = FALSE)
    # Patch T00:00:00Z games from schedule CSV
    odds_data <- odds_data %>%
      left_join(cfb_schedule %>% select(game_id, scheduled_time), by = "game_id") %>%
      mutate(commence_time = if_else(
        str_detect(commence_time, "T00:00:00Z") & !is.na(scheduled_time),
        scheduled_time,
        commence_time
      )) %>%
      select(-scheduled_time)
  }
}, error = function(e) cat(sprintf("[Step 9] Commence time patch error (non-fatal): %s\n", e$message)))

# --- STEP 10: Append odds lookup (auto-learn new team names) ------------------
cat("\n[Step 10] Appending odds lookup...\n")
tryCatch({
  source("scripts/append_odds_lookup_cfb.R")
}, error = function(e) cat(sprintf("[Step 10] Odds lookup error (non-fatal): %s\n", e$message)))

# --- STEP 11: Normalize team names --------------------------------------------
cat("\n[Step 11] Normalizing team names...\n")
source("scripts/standardize_data_cfb.R")   # fatal — normalization must succeed
# load_cfb_master() is now available (defined by TEAM_NAME_NORMALIZER_CFB.R,
# sourced transitively by standardize_data_cfb.R). Populate master_cfb if not
# already present (some sub-scripts may have loaded it earlier).
if (!exists("master_cfb")) {
  master_cfb <- load_cfb_master("team_name_mappings_MASTER_CFB.csv")
  assign("master_cfb", master_cfb, envir = .GlobalEnv)
}
odds_data <- normalize_odds_data(odds_data, master_cfb)
validate_odds_data(odds_data)

# --- STEP 12: Merge games + ratings -------------------------------------------
cat("\n[Step 12] Merging games with ratings...\n")
source("scripts/MERGE_GAMES_RATINGS_CFB.R")

# --- STEP 12.5: Motivational factors ------------------------------------------
# Must run BEFORE Step 13 (predictions) so get_motiv_adj() finds the data.
# Uses odds_data (Step 7) for game list; cfbd_schedule (Step 4) for week number.
cat("\n[Step 12.5] Computing motivational factors...\n")
tryCatch({
  .motiv_sourced_by_orchestrator <- TRUE
  source("scripts/MOTIVATIONAL_FACTORS_CFB.R")
  run_motivational_factors()
}, error = function(e) {
  cat(sprintf("[Step 12.5] Motivational factors error (non-fatal): %s\n", e$message))
  motivational_factors <<- NULL
  rivalry_game_ids     <<- character(0)
})

# --- STEP 13: Generate predictions (spread + total + win prob) ----------------
cat("\n[Step 13] Generating predictions...\n")
source("scripts/GENERATE_PREDICTIONS_CFB.R")

# --- STEP 14: Bye week flags --------------------------------------------------
cat("\n[Step 14] Applying bye week flags...\n")
tryCatch({
  source("scripts/BYE_WEEK_TRACKER.R")
}, error = function(e) {
  cat(sprintf("[Step 14] Bye week tracker error (non-fatal): %s\n", e$message))
  bye_week_data <<- NULL
})

# --- STEP 15: Weather (skip if dome) ------------------------------------------
cat("\n[Step 15] Fetching weather...\n")
tryCatch({
  source("scripts/WEATHER_SCRAPER_CFB.R")
}, error = function(e) {
  cat(sprintf("[Step 15] Weather error (non-fatal): %s\n", e$message))
  weather_data <<- NULL
})

# --- STEP 16: Travel fatigue --------------------------------------------------
cat("\n[Step 16] Computing travel fatigue...\n")
tryCatch({
  source("scripts/TRAVEL_FATIGUE_CFB.R")
}, error = function(e) {
  cat(sprintf("[Step 16] Travel fatigue error (non-fatal): %s\n", e$message))
  travel_fatigue <<- NULL
})

# --- STEP 17: Weather adjustments (skip if dome) ------------------------------
cat("\n[Step 17] Applying weather adjustments...\n")
tryCatch({
  # Weather columns (wind_speed, precip_prob) only exist when Step 15 fetched data.
  # Pre-season runs and dome-only slates will have NULL weather_data — skip adjustment.
  has_weather <- !is.null(weather_data) &&
                 all(c("wind_speed", "precip_prob") %in% names(games_with_predictions))
  if (has_weather) {
    games_with_predictions <- games_with_predictions %>%
      mutate(
        weather_total_adj = case_when(
          home_dome == TRUE ~ 0,                          # dome: no adjustment
          !is.na(wind_speed) & wind_speed > 20 ~ -2.5,   # high wind: suppress totals
          !is.na(wind_speed) & wind_speed > 15 ~ -1.5,
          !is.na(precip_prob) & precip_prob > 0.6 ~ -1.0,
          TRUE ~ 0
        ),
        proj_total = proj_total + weather_total_adj
      )
  } else {
    games_with_predictions <- games_with_predictions %>%
      mutate(weather_total_adj = 0)
  }
}, error = function(e) cat(sprintf("[Step 17] Weather adj error (non-fatal): %s\n", e$message)))

# --- STEP 18: Calculate value (3-market +EV engine) --------------------------
cat("\n[Step 18] Calculating value (+EV: Spread / Total / ML)...\n")
source("scripts/CALCULATE_VALUE_CFB.R")   # fatal

# --- STEP 19: Filter bets -----------------------------------------------------
cat("\n[Step 19] Filtering bets...\n")
qualified_bets <- all_bets %>%
  filter(ev > 0, bet_amount >= MIN_BET)

cat(sprintf("[Step 19] %d bets qualified (spread: %d, total: %d, ml: %d)\n",
            nrow(qualified_bets),
            sum(qualified_bets$bet_type == "SPREAD"),
            sum(qualified_bets$bet_type == "TOTAL"),
            sum(qualified_bets$bet_type == "ML")))

# --- STEP 20: Portfolio limits ------------------------------------------------
cat("\n[Step 20] Applying portfolio limits...\n")
tryCatch({
  # Cap total weekly exposure
  total_exposure <- sum(qualified_bets$bet_amount)
  max_exposure   <- BANKROLL * MAX_EXPOSURE_PER_WEEK
  if (total_exposure > max_exposure) {
    scale_factor   <- max_exposure / total_exposure
    qualified_bets <- qualified_bets %>%
      mutate(bet_amount = round(bet_amount * scale_factor, 2))
    cat(sprintf("[Step 20] Scaled bets by %.2fx to stay within %.0f%% weekly exposure cap.\n",
                scale_factor, MAX_EXPOSURE_PER_WEEK * 100))
  }
  # Cap per-game correlated exposure (spread + ML on same game)
  qualified_bets <- qualified_bets %>%
    group_by(game_id) %>%
    mutate(game_exposure = sum(bet_amount),
           game_cap      = BANKROLL * MAX_SINGLE_GAME_EXPOSURE) %>%
    mutate(bet_amount = if_else(
      game_exposure > game_cap,
      round(bet_amount * (game_cap / game_exposure), 2),
      bet_amount
    )) %>%
    ungroup() %>%
    select(-game_exposure, -game_cap)
  # Hard cap on bet count
  if (nrow(qualified_bets) > MAX_BETS_PER_WEEK) {
    qualified_bets <- qualified_bets %>%
      arrange(desc(ev)) %>%
      slice_head(n = MAX_BETS_PER_WEEK)
    cat(sprintf("[Step 20] Trimmed to top %d bets by EV.\n", MAX_BETS_PER_WEEK))
  }
}, error = function(e) cat(sprintf("[Step 20] Portfolio limits error: %s\n", e$message)))

# --- STEP 21: Save outputs + broadcast ----------------------------------------
cat("\n[Step 21] Saving outputs and broadcasting...\n")
if (isTRUE(DRY_RUN_MODE)) {
  cat("[Step 21] DRY RUN — skipping finalize + broadcast. Qualified bets:\n")
  if (nrow(qualified_bets) > 0) {
    print(qualified_bets %>%
            select(canonical_away, canonical_home, bet_type, bet_side,
                   posted_line, edge, ev, bet_amount, boost_flags) %>%
            arrange(desc(ev)))
  } else {
    cat("  (no qualifying bets this run)\n")
  }
} else {
  source("scripts/FINALIZE_BETS_CFB.R")
  source("scripts/broadcast_football.R")
}

# --- DONE ---------------------------------------------------------------------
pipeline_end <- Sys.time()
cat(sprintf("\n========== Pipeline complete | %.1f seconds | %d bets | $%.2f total action ==========\n",
            as.numeric(pipeline_end - pipeline_start, units = "secs"),
            nrow(qualified_bets),
            sum(qualified_bets$bet_amount)))
