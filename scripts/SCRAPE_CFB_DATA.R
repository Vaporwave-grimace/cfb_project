# ==============================================================================
# SCRAPE_CFB_DATA.R — CollegeFootballData.com API Scraper
# Pipeline Step 4 (non-fatal — wrapped in tryCatch by orchestrator)
#
# Fetches three data sets and writes to clean/:
#   1. SP+ ratings        → clean/cfb_ratings_YYYY.csv
#   2. Team season stats  → clean/cfb_team_stats_YYYY.csv
#   3. Week schedule      → clean/cfb_schedule_YYYYMMDD.csv
#
# Auth: Bearer JWT from credentials.json ("cfbd_api_key")
# Base URL: https://api.collegefootballdata.com
# Docs: https://api.collegefootballdata.com/api/docs/
# ==============================================================================

suppressMessages(library(tidyverse))
suppressMessages(library(httr))
suppressMessages(library(jsonlite))

source("scripts/TEAM_NAME_NORMALIZER_CFB.R")

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

cfbd_get <- function(endpoint, params = list(), api_key) {
  base_url <- "https://api.collegefootballdata.com"
  url      <- paste0(base_url, endpoint)

  resp <- GET(
    url,
    add_headers(Authorization = paste("Bearer", api_key)),
    query   = params,
    timeout(30)
  )

  if (http_error(resp)) {
    stop(sprintf("[CFBD] HTTP %d on %s: %s",
                 status_code(resp), endpoint,
                 content(resp, "text", encoding = "UTF-8")))
  }

  raw <- content(resp, "text", encoding = "UTF-8")
  fromJSON(raw, flatten = TRUE)
}

# Determine current CFB season year (season runs Aug–Jan; Jan counts as prior year)
cfb_season_year <- function(date = Sys.Date()) {
  yr <- as.integer(format(date, "%Y"))
  mo <- as.integer(format(date, "%m"))
  if (mo < 7) yr - 1L else yr
}

# Determine current week from the CFBD calendar
cfbd_current_week <- function(api_key, year, date = Sys.Date()) {
  tryCatch({
    # Primary: cfbfastR (no manual auth headers)
    cal <- if (requireNamespace("cfbfastR", quietly = TRUE)) {
      tryCatch(
        cfbfastR::cfbd_calendar(year = year),
        error = function(e) { cat("[CFBD] cfbfastR calendar fallback to httr:", e$message, "\n"); NULL }
      )
    } else NULL

    if (!is.null(cal) && nrow(cal) > 0) {
      cal <- cal %>%
        mutate(
          first_game_start = as.Date(first_game_start),
          last_game_start  = as.Date(last_game_start)
        )
    } else {
      # httr fallback
      raw <- cfbd_get(sprintf("/calendar/%d", year), api_key = api_key)
      cal <- as_tibble(raw) %>%
        mutate(
          first_game_start = as.Date(firstGameStart),
          last_game_start  = as.Date(lastGameStart)
        )
    }

    upcoming <- cal %>%
      filter(last_game_start >= date) %>%
      arrange(week) %>%
      slice(1)
    if (nrow(upcoming) == 0) {
      cat("[CFBD] Season appears complete — defaulting to week 1 for off-season scrape.\n")
      return(1L)
    }
    as.integer(upcoming$week)
  }, error = function(e) {
    warning(sprintf("[CFBD] Could not determine current week: %s. Defaulting to week 1.", e$message))
    1L
  })
}

# ------------------------------------------------------------------------------
# 1. SP+ Ratings
#    Endpoint: GET /ratings/sp?year=YYYY
#    Returns overall SP+ rating + offense + defense sub-ratings per team
# ------------------------------------------------------------------------------
scrape_sp_plus <- function(api_key, year, master) {
  cat(sprintf("[CFBD] Fetching SP+ ratings for %d...\n", year))

  # Primary: cfbfastR (maintained wrapper, snake_case column names)
  raw_cfbfastr <- if (requireNamespace("cfbfastR", quietly = TRUE))
    tryCatch(cfbfastR::cfbd_ratings_sp(year = year),
             error = function(e) { cat("[CFBD] cfbfastR SP+ fallback to httr:", e$message, "\n"); NULL })
  else NULL

  df <- if (!is.null(raw_cfbfastr) && nrow(raw_cfbfastr) > 0) {
    raw_cfbfastr %>%
      transmute(
        year       = as.integer(year),
        team_raw   = team,
        conference = conference,
        sp_overall = as.numeric(rating),
        sp_offense = as.numeric(offense_rating),
        sp_defense = as.numeric(defense_rating),
        sp_st      = if ("special_teams_rating" %in% names(raw_cfbfastr))
                       as.numeric(special_teams_rating) else NA_real_
      )
  } else {
    # httr fallback
    raw <- cfbd_get("/ratings/sp", params = list(year = year), api_key = api_key)
    if (length(raw) == 0 || nrow(as.data.frame(raw)) == 0) {
      warning("[CFBD] SP+ ratings returned empty — off-season or pre-season scrape?")
      return(NULL)
    }
    as_tibble(raw) %>%
      transmute(
        year       = as.integer(year),
        team_raw   = team,
        conference = conference,
        sp_overall = as.numeric(rating),
        sp_offense = as.numeric(offense.rating),
        sp_defense = as.numeric(defense.rating),
        sp_st      = if ("specialTeams.rating" %in% names(.)) as.numeric(specialTeams.rating) else NA_real_
      )
  }

  if (is.null(df) || nrow(df) == 0) {
    warning("[CFBD] SP+ ratings returned empty — off-season or pre-season scrape?")
    return(NULL)
  }

  df <- df %>%
    mutate(
      canonical_name = normalize_team_name(team_raw, mappings = master,
                                            source_col = "massey_name",
                                            unmatched_log = "logs/unmatched_teams.csv")
    ) %>%
    filter(!is.na(canonical_name)) %>%
    select(year, canonical_name, conference, sp_overall, sp_offense, sp_defense, sp_st)

  out_path <- sprintf("clean/cfb_ratings_%d.csv", year)
  write_csv(df, out_path)
  cat(sprintf("[CFBD] SP+ ratings: %d teams → %s\n", nrow(df), out_path))
  df
}

# ------------------------------------------------------------------------------
# 2. Team Season Stats
#    Endpoint: GET /stats/season?year=YYYY&seasonType=regular
#    Returns per-team aggregated stats by category/statName
#    We pivot to wide format and keep the most pipeline-relevant columns
# ------------------------------------------------------------------------------
scrape_team_stats <- function(api_key, year, master) {
  cat(sprintf("[CFBD] Fetching team season stats for %d...\n", year))

  raw <- cfbd_get("/stats/season",
                  params = list(year = year, seasonType = "regular"),
                  api_key = api_key)

  if (length(raw) == 0) {
    warning("[CFBD] Team stats returned empty.")
    return(NULL)
  }

  df_long <- as_tibble(raw) %>%
    select(team, statName, statValue) %>%
    mutate(statValue = as.numeric(statValue))

  # Stats we care about for the prediction model
  # Verified against CFBD /stats/season statName values (2025-05-15):
  #   netPassingYards not passYards | rushingYards not rushYards
  #   redZoneAttempts/redZoneScores absent from this endpoint — omitted
  keep_stats <- c(
    "games",
    "pointsPerGame",
    "totalYards",
    "yardsPerPlay",
    "netPassingYards",
    "passAttempts",
    "passCompletions",
    "rushingYards",
    "rushingAttempts",
    "turnovers",
    "turnoversOpponent",      # enables turnover_margin without MERGE step
    "fumblesLost",
    "interceptions",          # thrown (offense)
    "interceptionYards",      # returned (defense)
    "sacks",
    "sacksOpponent",
    "tacklesForLoss",
    "firstDowns",
    "thirdDownConversions",
    "thirdDowns",
    "penalties",
    "penaltyYards",
    "possessionTime",
    "plays"          # raw play count; plays_per_game derived below
  )

  df_wide <- df_long %>%
    filter(statName %in% keep_stats) %>%
    pivot_wider(names_from = statName, values_from = statValue) %>%
    rename(team_raw = team)

  # Derived efficiency metrics
  # Check column existence OUTSIDE mutate — names(.) is unreliable inside mutate
  has_third_down    <- all(c("thirdDownConversions", "thirdDowns") %in% names(df_wide))
  has_turnover_opp  <- "turnoversOpponent" %in% names(df_wide)
  has_pass_eff      <- all(c("passCompletions", "passAttempts") %in% names(df_wide))
  has_plays_games   <- all(c("plays", "games") %in% names(df_wide))

  df_wide <- df_wide %>%
    mutate(
      third_down_rate      = if (has_third_down)    thirdDownConversions / pmax(thirdDowns, 1) else NA_real_,
      turnover_margin      = if (has_turnover_opp)  turnoversOpponent - turnovers              else NA_real_,
      pass_completion_rate = if (has_pass_eff)      passCompletions / pmax(passAttempts, 1)    else NA_real_,
      plays_per_game       = if (has_plays_games)   plays / pmax(games, 1)                     else NA_real_,
      year                 = as.integer(year)
    )

  df_wide <- df_wide %>%
    mutate(
      canonical_name = normalize_team_name(team_raw, mappings = master,
                                            source_col = "massey_name",
                                            unmatched_log = "logs/unmatched_teams.csv")
    ) %>%
    filter(!is.na(canonical_name)) %>%
    select(year, canonical_name, everything(), -team_raw)

  out_path <- sprintf("clean/cfb_team_stats_%d.csv", year)
  write_csv(df_wide, out_path)
  cat(sprintf("[CFBD] Team stats: %d teams, %d stat columns → %s\n",
              nrow(df_wide), ncol(df_wide) - 2, out_path))
  df_wide
}

# ------------------------------------------------------------------------------
# 3. Weekly Schedule
#    Endpoint: GET /games?year=YYYY&week=W&seasonType=regular
#    Also fetches postseason games when week == "postseason"
# ------------------------------------------------------------------------------
scrape_schedule <- function(api_key, year, week, master, date = Sys.Date()) {
  cat(sprintf("[CFBD] Fetching schedule for %d week %s...\n", year, week))

  # Primary: cfbfastR
  raw_cfbfastr <- if (requireNamespace("cfbfastR", quietly = TRUE))
    tryCatch(
      cfbfastR::cfbd_game_info(year = year, week = week, season_type = "regular",
                               division = "fbs"),
      error = function(e) { cat("[CFBD] cfbfastR schedule fallback to httr:", e$message, "\n"); NULL }
    )
  else NULL

  raw <- if (!is.null(raw_cfbfastr) && nrow(raw_cfbfastr) > 0) {
    raw_cfbfastr
  } else {
    raw_httr <- cfbd_get("/games",
                         params = list(year = year, week = week,
                                       seasonType = "regular", division = "fbs"),
                         api_key = api_key)
    if (length(raw_httr) == 0 || nrow(as.data.frame(raw_httr)) == 0) {
      warning(sprintf("[CFBD] No games found for year=%d week=%s.", year, week))
      return(NULL)
    }
    as_tibble(raw_httr)
  }

  if (is.null(raw) || nrow(raw) == 0) {
    warning(sprintf("[CFBD] No games found for year=%d week=%s.", year, week))
    return(NULL)
  }

  # Column names are consistent between cfbfastR and raw httr (both snake_case from CFBD)
  safe_col <- function(nm, default) if (nm %in% names(raw)) raw[[nm]] else default
  df <- raw %>%
    transmute(
      game_id         = as.character(id),
      season          = as.integer(season),
      week            = as.integer(week),
      season_type     = season_type,
      scheduled_time  = start_date,
      neutral_site    = as.logical(neutral_site),
      conference_game = as.logical(conference_game),
      home_team_raw   = home_team,
      away_team_raw   = away_team,
      home_conference = home_conference,
      away_conference = away_conference,
      venue           = if ("venue" %in% names(.)) venue else NA_character_,
      home_points     = if ("home_points" %in% names(.)) as.integer(home_points) else NA_integer_,
      away_points     = if ("away_points" %in% names(.)) as.integer(away_points) else NA_integer_
    ) %>%
    mutate(
      canonical_home = normalize_team_name(home_team_raw, mappings = master,
                                            source_col = "massey_name",
                                            unmatched_log = "logs/unmatched_teams.csv"),
      canonical_away = normalize_team_name(away_team_raw, mappings = master,
                                            source_col = "massey_name",
                                            unmatched_log = "logs/unmatched_teams.csv")
    ) %>%
    filter(!is.na(canonical_home), !is.na(canonical_away)) %>%
    select(game_id, season, week, season_type, scheduled_time, neutral_site,
           conference_game, canonical_home, canonical_away,
           home_conference, away_conference, venue,
           home_points, away_points)

  out_path <- sprintf("clean/cfb_schedule_%s.csv", format(date, "%Y%m%d"))
  write_csv(df, out_path)
  cat(sprintf("[CFBD] Schedule: %d FBS games → %s\n", nrow(df), out_path))
  df
}

# ------------------------------------------------------------------------------
# 4. ELO Ratings
#    Endpoint: GET /ratings/elo?year=YYYY
#    Returns per-team per-week ELO scores. We take the most recent week per team.
#    ELO is particularly valuable early-season before SP+ stabilizes (Weeks 1-4).
#    Saved to clean/cfb_elo_ratings_YYYY.csv for MERGE_ALL_RATINGS_CFB.R to blend.
# ------------------------------------------------------------------------------
scrape_elo_ratings <- function(api_key, year, master) {
  cat(sprintf("[CFBD] Fetching ELO ratings for %d...\n", year))

  # Primary: cfbfastR
  raw_cfbfastr <- if (requireNamespace("cfbfastR", quietly = TRUE))
    tryCatch(cfbfastR::cfbd_ratings_elo(year = year),
             error = function(e) { cat("[CFBD] cfbfastR ELO fallback to httr:", e$message, "\n"); NULL })
  else NULL

  raw <- if (!is.null(raw_cfbfastr) && nrow(raw_cfbfastr) > 0) {
    raw_cfbfastr
  } else {
    tryCatch(
      as_tibble(cfbd_get("/ratings/elo", params = list(year = year), api_key = api_key)),
      error = function(e) {
        warning(sprintf("[CFBD] ELO ratings failed (non-fatal): %s", e$message)); NULL
      }
    )
  }

  if (is.null(raw) || nrow(raw) == 0) {
    warning("[CFBD] ELO ratings returned empty — pre-season or no data yet.")
    return(NULL)
  }

  df <- raw %>%
    # Most recent week per team (highest week number = current rating)
    group_by(team) %>%
    slice_max(order_by = as.integer(week), n = 1, with_ties = FALSE) %>%
    ungroup() %>%
    transmute(
      year       = as.integer(year),
      team_raw   = team,
      elo_rating = as.numeric(elo)
    ) %>%
    mutate(
      canonical_name = normalize_team_name(team_raw, mappings = master,
                                            source_col = "massey_name",
                                            unmatched_log = "logs/unmatched_teams.csv")
    ) %>%
    filter(!is.na(canonical_name)) %>%
    select(year, canonical_name, elo_rating)

  out_path <- sprintf("clean/cfb_elo_ratings_%d.csv", year)
  write_csv(df, out_path)
  cat(sprintf("[CFBD] ELO ratings: %d teams | range [%.0f, %.0f] → %s\n",
              nrow(df),
              min(df$elo_rating, na.rm = TRUE),
              max(df$elo_rating, na.rm = TRUE),
              out_path))
  df
}

# ------------------------------------------------------------------------------
# 5. Recruiting composite — 247Sports 3-year average via cfbfastR
#    Talent proxy for early-season weeks before SP+ stabilizes.
#    Output: canonical_name, recruiting_composite, recruiting_year_range
# ------------------------------------------------------------------------------
scrape_recruiting <- function(api_key, year, master, n_years = 3L) {
  cat(sprintf("[CFBD] Fetching recruiting composites (%d–%d)...\n",
              year - n_years + 1L, year))

  years <- seq(year - n_years + 1L, year)
  raw_list <- lapply(years, function(yr) {
    tryCatch({
      if (requireNamespace("cfbfastR", quietly = TRUE)) {
        df <- cfbfastR::cfbd_recruiting_team(year = yr)
      } else {
        r <- cfbd_get(sprintf("/recruiting/teams?year=%d", yr), api_key = api_key)
        df <- as_tibble(do.call(rbind, lapply(r, as.data.frame)))
      }
      if (is.null(df) || nrow(df) == 0) return(NULL)
      df %>%
        select(team = any_of(c("team", "Team")),
               points = any_of(c("points", "Points"))) %>%
        mutate(yr = yr)
    }, error = function(e) {
      cat(sprintf("[CFBD] Recruiting %d failed: %s\n", yr, e$message)); NULL
    })
  })

  raw <- bind_rows(Filter(Negate(is.null), raw_list))
  if (nrow(raw) == 0) {
    warning("[CFBD] Recruiting: no data retrieved")
    return(NULL)
  }

  # Average composite points across available years per team
  df <- raw %>%
    group_by(team) %>%
    summarise(
      recruiting_composite = mean(as.numeric(points), na.rm = TRUE),
      recruiting_year_range = paste(range(yr), collapse = "–"),
      .groups = "drop"
    ) %>%
    mutate(
      canonical_name = normalize_team_name(team, mappings = master,
                                           source_col = "massey_name",
                                           unmatched_log = "logs/unmatched_teams.csv")
    ) %>%
    filter(!is.na(canonical_name)) %>%
    select(canonical_name, recruiting_composite, recruiting_year_range)

  out_path <- sprintf("clean/cfb_recruiting_%d.csv", year)
  write_csv(df, out_path)
  cat(sprintf("[CFBD] Recruiting: %d teams | composite range %.0f–%.0f → %s\n",
              nrow(df),
              min(df$recruiting_composite, na.rm = TRUE),
              max(df$recruiting_composite, na.rm = TRUE),
              out_path))
  df
}

# ------------------------------------------------------------------------------
# 6. Orchestrator — called by run_daily_football.R Step 4
# ------------------------------------------------------------------------------
run_cfbd_scrape <- function(master = NULL, date = Sys.Date()) {

  # Load credentials
  creds   <- load_credentials()
  api_key <- creds$cfbd_api_key
  if (is.null(api_key) || nchar(api_key) < 10) {
    stop("[CFBD] cfbd_api_key missing or too short in credentials.json")
  }

  # Make API key available to cfbfastR (reads CFBD_API_KEY env var)
  Sys.setenv(CFBD_API_KEY = api_key)

  # Load MASTER if not passed in
  if (is.null(master)) {
    if (exists("master_cfb", envir = .GlobalEnv)) {
      master <- get("master_cfb", envir = .GlobalEnv)
    } else {
      master <- load_cfb_master()
    }
  }

  year <- cfb_season_year(date)
  week <- cfbd_current_week(api_key = api_key, year = year, date = date)
  cat(sprintf("[CFBD] Season: %d | Week: %d\n", year, week))

  # Scrape all endpoints — each is independently non-fatal
  cfbd_sp_plus <- tryCatch(
    scrape_sp_plus(api_key = api_key, year = year, master = master),
    error = function(e) { warning(sprintf("[CFBD] SP+ failed: %s", e$message)); NULL }
  )

  cfbd_team_stats <- tryCatch(
    scrape_team_stats(api_key = api_key, year = year, master = master),
    error = function(e) { warning(sprintf("[CFBD] Team stats failed: %s", e$message)); NULL }
  )

  cfbd_schedule <- tryCatch(
    scrape_schedule(api_key = api_key, year = year, week = week,
                    master = master, date = date),
    error = function(e) { warning(sprintf("[CFBD] Schedule failed: %s", e$message)); NULL }
  )

  cfbd_elo_ratings <- tryCatch(
    scrape_elo_ratings(api_key = api_key, year = year, master = master),
    error = function(e) { warning(sprintf("[CFBD] ELO failed: %s", e$message)); NULL }
  )

  cfbd_recruiting <- tryCatch(
    scrape_recruiting(api_key = api_key, year = year, master = master),
    error = function(e) { warning(sprintf("[CFBD] Recruiting failed: %s", e$message)); NULL }
  )

  # Assign to global env for downstream pipeline steps
  if (!is.null(cfbd_sp_plus))     assign("cfbd_sp_plus",     cfbd_sp_plus,     envir = .GlobalEnv)
  if (!is.null(cfbd_team_stats))  assign("cfbd_team_stats",  cfbd_team_stats,  envir = .GlobalEnv)
  if (!is.null(cfbd_schedule))    assign("cfbd_schedule",    cfbd_schedule,    envir = .GlobalEnv)
  if (!is.null(cfbd_elo_ratings)) assign("cfbd_elo_ratings", cfbd_elo_ratings, envir = .GlobalEnv)
  if (!is.null(cfbd_recruiting))  assign("cfbd_recruiting",  cfbd_recruiting,  envir = .GlobalEnv)

  n_games <- if (!is.null(cfbd_schedule)) nrow(cfbd_schedule) else 0
  cat(sprintf(
    "[CFBD] Scrape complete — %d SP+ | %d stats | %d ELO | %d recruiting | %d games this week.\n",
    if (!is.null(cfbd_sp_plus))     nrow(cfbd_sp_plus)     else 0,
    if (!is.null(cfbd_team_stats))  nrow(cfbd_team_stats)  else 0,
    if (!is.null(cfbd_elo_ratings)) nrow(cfbd_elo_ratings) else 0,
    if (!is.null(cfbd_recruiting))  nrow(cfbd_recruiting)  else 0,
    n_games))

  invisible(list(sp_plus = cfbd_sp_plus, team_stats = cfbd_team_stats,
                 schedule = cfbd_schedule, elo_ratings = cfbd_elo_ratings,
                 recruiting = cfbd_recruiting))
}

# Run immediately when sourced by pipeline
run_cfbd_scrape()

cat("[CFBD] SCRAPE_CFB_DATA.R complete.\n")
