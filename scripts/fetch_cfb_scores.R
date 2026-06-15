# ==============================================================================
# fetch_cfb_scores.R — CFBD Score Fetcher for Settlement
# Pipeline Step 1.5 (non-fatal, runs before Step 2 settlement)
#
# Fetches completed CFB game results from CFBD API and writes per-date score
# CSVs consumed by BET_SETTLEMENT.R.
#
# ID MAPPING:
#   cfb_bets.sqlite stores Odds API hex game_ids (e.g. "abc123...32chars").
#   CFBD uses integer IDs. This script joins CFBD scores to pending bets by
#   canonical_home + canonical_away + game_date (±1 day tolerance for timezone
#   edge cases), then writes the Odds API game_id so settle_bets() can join.
#
# WHY MULTI-FILE / LOOKBACK:
#   CFB games are Saturday; pipeline runs Thu/Fri/Sat. A Thursday settlement
#   needs scores from the prior Saturday (6+ days ago). SCORES_LOOKBACK=21
#   covers a full bye-week cycle and is consistent with LINE_MOVEMENT_LOGGER's
#   21-day retention window.
#
# Output: clean/cfb_scores_YYYYMMDD.csv per game date
#   cols: game_id (Odds API hex), home_team, away_team, home_score, away_score
#
# Usage:
#   source("scripts/fetch_cfb_scores.R")
#   fetch_cfb_scores()   # called from run_daily_football.R Step 1.5
# ==============================================================================

suppressMessages({
  library(tidyverse)
  library(httr)
  library(jsonlite)
  library(DBI)
  library(RSQLite)
})

CFBD_SCORES_BASE <- "https://api.collegefootballdata.com"
SCORES_LOOKBACK  <- 21L   # days; matches LINE_MOVEMENT_LOGGER retention

# CFBD API helper — same pattern as SCRAPE_CFB_DATA.R / MOTIVATIONAL_FACTORS_CFB.R
.cfbd_get_scores <- function(endpoint, params = list(), api_key) {
  url  <- paste0(CFBD_SCORES_BASE, endpoint)
  resp <- tryCatch(
    GET(url,
        add_headers(Authorization = paste("Bearer", api_key)),
        query   = params,
        timeout(20)),
    error = function(e) NULL
  )
  if (is.null(resp) || http_error(resp)) return(NULL)
  tryCatch(
    fromJSON(content(resp, "text", encoding = "UTF-8"), flatten = TRUE),
    error = function(e) NULL
  )
}

# Fetch all completed CFBD games for a year, returning rows in the lookback window
.fetch_cfbd_results <- function(api_key, year, lookback_date) {
  cat(sprintf("[SCORES] Fetching %d results from CFBD (since %s)...\n",
              year, lookback_date))

  raw <- .cfbd_get_scores(
    "/games",
    params  = list(year = year, seasonType = "regular"),
    api_key = api_key
  )

  if (is.null(raw) || length(raw) == 0 || !is.data.frame(raw)) {
    cat("[SCORES] CFBD /games returned no data.\n")
    return(tibble())
  }

  required <- c("id", "home_team", "away_team",
                 "home_points", "away_points", "start_date")
  missing <- setdiff(required, names(raw))
  if (length(missing) > 0) {
    cat(sprintf("[SCORES] CFBD /games missing cols: %s\n",
                paste(missing, collapse = ", ")))
    return(tibble())
  }

  df <- as_tibble(raw) %>%
    filter(!is.na(home_points), !is.na(away_points)) %>%
    transmute(
      cfbd_id    = as.character(id),
      home_raw   = as.character(home_team),
      away_raw   = as.character(away_team),
      home_score = as.integer(home_points),
      away_score = as.integer(away_points),
      game_date  = as.Date(substr(as.character(start_date), 1, 10))
    ) %>%
    filter(game_date >= lookback_date)

  cat(sprintf("[SCORES] %d completed games within lookback window.\n", nrow(df)))
  df
}

# Main entry point
fetch_cfb_scores <- function(lookback_days = SCORES_LOOKBACK,
                              date          = Sys.Date()) {

  lookback_date <- date - lookback_days

  creds   <- tryCatch(load_credentials(), error = function(e) NULL)
  api_key <- creds$cfbd_api_key %||% NULL

  if (is.null(api_key) || !nzchar(api_key)) {
    cat("[SCORES] No CFBD API key in credentials — skipping score fetch.\n")
    return(invisible(NULL))
  }

  # Load pending bets — need Odds API game_id + canonical team names
  if (!file.exists(CFB_BETS_DB)) {
    cat("[SCORES] cfb_bets.sqlite not found — skipping score fetch.\n")
    return(invisible(NULL))
  }

  con <- dbConnect(RSQLite::SQLite(), CFB_BETS_DB)
  pending <- tryCatch(
    dbGetQuery(con,
      "SELECT DISTINCT game_id, home_team, away_team, commence_time
       FROM cfb_bets WHERE settled = 0"),
    error = function(e) NULL,
    finally = dbDisconnect(con)
  )

  if (is.null(pending) || nrow(pending) == 0) {
    cat("[SCORES] No unsettled bets — nothing to match scores against.\n")
    return(invisible(NULL))
  }

  pending <- pending %>%
    mutate(game_date = as.Date(substr(commence_time, 1, 10)))

  cat(sprintf("[SCORES] %d unsettled bet(s) across %d game(s).\n",
              nrow(pending),
              n_distinct(pending$game_id)))

  # Determine season year
  yr   <- as.integer(format(date, "%Y"))
  mo   <- as.integer(format(date, "%m"))
  year <- if (mo < 7L) yr - 1L else yr

  # Fetch CFBD results
  cfbd_games <- tryCatch(
    .fetch_cfbd_results(api_key, year, lookback_date),
    error = function(e) {
      cat(sprintf("[SCORES] CFBD fetch error: %s\n", e$message))
      tibble()
    }
  )

  if (nrow(cfbd_games) == 0) {
    cat("[SCORES] No CFBD results to process.\n")
    return(invisible(NULL))
  }

  # Normalize CFBD team names to canonical_name for matching.
  # Source TEAM_NAME_NORMALIZER_CFB.R if not yet loaded (Step 1.5 runs before
  # Step 11 which normally loads it via standardize_data_cfb.R).
  if (!exists("load_cfb_master", mode = "function")) {
    source("scripts/TEAM_NAME_NORMALIZER_CFB.R")
  }
  master <- tryCatch(
    if (exists("master_cfb", envir = .GlobalEnv)) {
      get("master_cfb", envir = .GlobalEnv)
    } else {
      load_cfb_master("team_name_mappings_MASTER_CFB.csv")
    },
    error = function(e) NULL
  )

  if (!is.null(master) && exists("normalize_team_name", mode = "function")) {
    cfbd_games <- cfbd_games %>%
      mutate(
        canonical_home = map_chr(home_raw, function(n)
          tryCatch(
            normalize_team_name(n, mappings = master,
                                source_col    = "massey_name",
                                unmatched_log = "logs/unmatched_teams.csv"),
            error = function(e) NA_character_
          )
        ),
        canonical_away = map_chr(away_raw, function(n)
          tryCatch(
            normalize_team_name(n, mappings = master,
                                source_col    = "massey_name",
                                unmatched_log = "logs/unmatched_teams.csv"),
            error = function(e) NA_character_
          )
        )
      ) %>%
      filter(!is.na(canonical_home), !is.na(canonical_away))
  } else {
    # Fallback: treat CFBD raw names as canonical (may miss some matches)
    cfbd_games <- cfbd_games %>%
      mutate(canonical_home = home_raw, canonical_away = away_raw)
    cat("[SCORES] Warning: team normalizer unavailable — using raw CFBD names.\n")
  }

  # Match CFBD results to pending bets by canonical name pair + date (±1 day)
  matched <- purrr::map_dfr(seq_len(nrow(cfbd_games)), function(i) {
    g   <- cfbd_games[i, ]
    hit <- pending %>%
      filter(
        home_team == g$canonical_home,
        away_team == g$canonical_away,
        abs(as.integer(game_date - g$game_date)) <= 1L
      )
    if (nrow(hit) == 0) return(NULL)
    tibble(
      game_id    = hit$game_id[1],   # Odds API hex ID from pending bets
      home_team  = g$canonical_home,
      away_team  = g$canonical_away,
      home_score = g$home_score,
      away_score = g$away_score,
      game_date  = g$game_date
    )
  })

  if (nrow(matched) == 0) {
    cat("[SCORES] No CFBD results matched any unsettled bets.\n")
    return(invisible(NULL))
  }

  cat(sprintf("[SCORES] Matched %d / %d unsettled game(s).\n",
              n_distinct(matched$game_id),
              n_distinct(pending$game_id)))

  # Write one CSV per game_date
  if (!dir.exists("clean")) dir.create("clean", recursive = TRUE)
  written <- character(0)

  for (gd in sort(unique(matched$game_date))) {
    rows <- matched %>% filter(game_date == gd)
    out  <- sprintf("clean/cfb_scores_%s.csv", format(gd, "%Y%m%d"))
    write_csv(rows, out)
    cat(sprintf("[SCORES] → %s (%d game(s))\n", out, nrow(rows)))
    written <- c(written, out)
  }

  invisible(written)
}

if (!exists(".cfb_scores_sourced_by_orchestrator")) {
  fetch_cfb_scores()
}

cat("[SCORES] fetch_cfb_scores.R loaded.\n")
