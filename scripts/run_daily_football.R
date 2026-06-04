# ==============================================================================
# run_daily_football.R — mcFootball Daily Pipeline Orchestrator
# Project: cfb_project
#
# EXECUTION ORDER (logical dependency, not step labels):
#   Phase 1  Settlement       BET_SETTLEMENT.R          (non-fatal)
#   Phase 2  Data collection  SCRAPE_CFB_DATA.R         (non-fatal)
#                             scrape_massey_cfb.R        (non-fatal)
#                             scrape_sagarin.R           (non-fatal)
#                             TEAM_METRICS.R             (non-fatal)
#   Phase 3  Ratings blend    MERGE_ALL_RATINGS_CFB.R   (non-fatal)
#   Phase 4  Context signals  BYE_WEEK_TRACKER.R        (non-fatal)
#                             TRAVEL_FATIGUE_CFB.R       (non-fatal)
#                             WEATHER_SCRAPER_CFB.R      (non-fatal)
#                             TREND_ANALYSIS_CFB.R       (non-fatal)
#   Phase 5  Market data      fetch_odds_football.R      (FATAL)
#                             append_odds_lookup_cfb.R   (non-fatal)
#                             standardize_data_cfb.R     (FATAL)
#   Phase 6  Merge + predict  MERGE_GAMES_RATINGS_CFB.R (FATAL)
#                             GENERATE_PREDICTIONS_CFB.R (FATAL)
#   Phase 7  Value + output   CALCULATE_VALUE_CFB.R     (FATAL)
#                             FINALIZE_BETS_CFB.R        (FATAL)
#                             broadcast_football.R        (non-fatal)
#
# RUN:
#   Rscript scripts/run_daily_football.R
#   — or source("scripts/run_daily_football.R") from RStudio project root
#
# LOGS:
#   logs/run_YYYYMMDD_HHMM.log  — full timestamped run log
#
# FATAL steps abort the pipeline if they fail.
# Non-fatal steps log a warning and continue.
# ==============================================================================

suppressMessages({
  library(tidyverse)
})

# Working directory guard
if (!exists(".orchestrator_wd_set")) {
  args <- commandArgs(trailingOnly = FALSE)
  script_path <- sub("--file=", "", args[grep("--file=", args)])
  if (length(script_path) > 0) {
    setwd(dirname(dirname(normalizePath(script_path))))
  }
  .orchestrator_wd_set <- TRUE
}

source("scripts/CONFIG.R")
source("scripts/TEAM_NAME_NORMALIZER_CFB.R")

# ==============================================================================
# Logging setup
# ==============================================================================

LOG_FILE <- sprintf("logs/run_%s.log", format(Sys.time(), "%Y%m%d_%H%M"))
dir.create("logs", showWarnings = FALSE)

log_msg <- function(...) {
  msg <- paste0("[", format(Sys.time(), "%H:%M:%S"), "] ", sprintf(...))
  cat(msg, "\n")
  cat(msg, "\n", file = LOG_FILE, append = TRUE)
}

# ==============================================================================
# Step runner
# ==============================================================================

pipeline_log <- list()   # collects per-step result for final summary

run_step <- function(label, script, fatal = FALSE) {
  log_msg("── %s", label)
  t0 <- proc.time()["elapsed"]

  result <- tryCatch({
    source(paste0("scripts/", script))
    elapsed <- round(proc.time()["elapsed"] - t0, 1)
    log_msg("   ✓ %s — %.1f sec", label, elapsed)
    list(label = label, status = "ok", elapsed = elapsed, error = NULL)
  }, error = function(e) {
    elapsed <- round(proc.time()["elapsed"] - t0, 1)
    msg <- conditionMessage(e)
    if (fatal) {
      log_msg("   ✗ FATAL — %s: %s", label, msg)
    } else {
      log_msg("   ⚠ non-fatal — %s: %s", label, msg)
    }
    list(label = label, status = "error", elapsed = elapsed, error = msg)
  })

  pipeline_log[[length(pipeline_log) + 1]] <<- result

  if (fatal && result$status == "error") {
    stop(sprintf("[ORCHESTRATOR] Fatal step failed: %s\n  → %s", label, result$error))
  }

  invisible(result$status == "ok")
}

# ==============================================================================
# Flag: prevents TEAM_METRICS.R from auto-running build_team_metrics() on source
# (orchestrator calls build_team_metrics() after SCRAPE_CFB_DATA.R completes)
# ==============================================================================
.team_metrics_sourced_by_orchestrator <- TRUE

# ==============================================================================
# MASTER — load team name mappings once, pass via GlobalEnv
# ==============================================================================
master_cfb <- load_cfb_master("team_name_mappings_MASTER_CFB.csv")
assign("master_cfb", master_cfb, envir = .GlobalEnv)

RUN_DATE <- Sys.Date()
log_msg("============================================================")
log_msg("mcFootball Daily Pipeline — %s", format(RUN_DATE, "%Y-%m-%d"))
log_msg("============================================================")

# ==============================================================================
# PHASE 1 — Settlement (settle prior week results if scores available)
# ==============================================================================
log_msg("")
log_msg("PHASE 1: Settlement")
run_step("Bet settlement",      "BET_SETTLEMENT.R",    fatal = FALSE)

# ==============================================================================
# PHASE 2 — Data collection
# ==============================================================================
log_msg("")
log_msg("PHASE 2: Data collection")
run_step("CFBD scrape (SP+, stats, schedule)", "SCRAPE_CFB_DATA.R",   fatal = FALSE)
run_step("Massey ratings",                     "scrape_massey_cfb.R", fatal = FALSE)
run_step("Sagarin ratings",                    "scrape_sagarin.R",    fatal = FALSE)

# TEAM_METRICS.R is sourced for function definitions only (flag set above);
# build_team_metrics() is called directly so we can pass master from GlobalEnv.
tryCatch({
  source("scripts/TEAM_METRICS.R")
  build_team_metrics(master = master_cfb)
  elapsed_tm <- NA
  log_msg("   ✓ Advanced team metrics (PPA, success rate, explosiveness)")
  pipeline_log[[length(pipeline_log) + 1]] <<-
    list(label = "Advanced team metrics", status = "ok", elapsed = NA, error = NULL)
}, error = function(e) {
  log_msg("   ⚠ non-fatal — Advanced team metrics: %s", conditionMessage(e))
  pipeline_log[[length(pipeline_log) + 1]] <<-
    list(label = "Advanced team metrics", status = "error",
         elapsed = NA, error = conditionMessage(e))
})

# ==============================================================================
# PHASE 3 — Ratings blend
# ==============================================================================
log_msg("")
log_msg("PHASE 3: Ratings blend")
run_step("Blend SP+ / Sagarin / Massey", "MERGE_ALL_RATINGS_CFB.R", fatal = FALSE)

# ==============================================================================
# PHASE 4 — Context signals (must be in GlobalEnv before GENERATE_PREDICTIONS)
# ==============================================================================
log_msg("")
log_msg("PHASE 4: Context signals")
run_step("Bye week tracker",   "BYE_WEEK_TRACKER.R",   fatal = FALSE)
run_step("Travel fatigue",     "TRAVEL_FATIGUE_CFB.R", fatal = FALSE)
run_step("Weather data",       "WEATHER_SCRAPER_CFB.R",fatal = FALSE)
run_step("Trend signals",      "TREND_ANALYSIS_CFB.R", fatal = FALSE)

# ==============================================================================
# PHASE 5 — Market data (odds lines)
# ==============================================================================
log_msg("")
log_msg("PHASE 5: Market data")
run_step("Fetch odds (Odds API)",    "fetch_odds_football.R",    fatal = TRUE)
run_step("Odds lookup append",       "append_odds_lookup_cfb.R", fatal = FALSE)
run_step("Standardize odds data",    "standardize_data_cfb.R",   fatal = TRUE)

# ==============================================================================
# PHASE 6 — Merge + predict
# ==============================================================================
log_msg("")
log_msg("PHASE 6: Merge + predict")
run_step("Merge games + ratings",    "MERGE_GAMES_RATINGS_CFB.R",  fatal = TRUE)
run_step("Generate predictions",     "GENERATE_PREDICTIONS_CFB.R", fatal = TRUE)

# ==============================================================================
# PHASE 7 — Value calculation + output
# ==============================================================================
log_msg("")
log_msg("PHASE 7: Value + output")
run_step("Calculate EV + Kelly",     "CALCULATE_VALUE_CFB.R",  fatal = TRUE)
run_step("Finalize bet ticket",      "FINALIZE_BETS_CFB.R",    fatal = TRUE)
run_step("Broadcast / notify",       "broadcast_football.R",   fatal = FALSE)

# ==============================================================================
# Run summary
# ==============================================================================
log_msg("")
log_msg("============================================================")
log_msg("Pipeline complete — %s", format(Sys.time(), "%H:%M:%S"))
log_msg("============================================================")

results_df <- map_dfr(pipeline_log, ~tibble(
  step    = .x$label,
  status  = .x$status,
  elapsed = coalesce(as.numeric(.x$elapsed), NA_real_),
  error   = if (is.null(.x$error)) NA_character_ else .x$error
))

n_ok  <- sum(results_df$status == "ok")
n_err <- sum(results_df$status == "error")
total_sec <- sum(results_df$elapsed, na.rm = TRUE)

log_msg("Steps OK: %d | Errors: %d | Total time: %.0f sec", n_ok, n_err, total_sec)
log_msg("")

if (n_err > 0) {
  log_msg("Failed steps:")
  results_df %>%
    filter(status == "error") %>%
    pwalk(function(step, error, ...) log_msg("  ✗ %s: %s", step, error))
}

# Print qualified bets summary if pipeline ran to completion
if (exists("qualified_bets", envir = .GlobalEnv)) {
  qb <- get("qualified_bets", envir = .GlobalEnv)
  if (!is.null(qb) && nrow(qb) > 0) {
    log_msg("")
    log_msg("Qualified bets this run: %d", nrow(qb))
    markets <- table(qb$market)
    for (m in names(markets)) {
      log_msg("  %s: %d bet(s)", m, markets[[m]])
    }
  } else {
    log_msg("No qualified bets this run.")
  }
}

log_msg("Log written: %s", LOG_FILE)

# Clean up orchestrator flag
rm(.team_metrics_sourced_by_orchestrator, envir = .GlobalEnv)

invisible(results_df)
