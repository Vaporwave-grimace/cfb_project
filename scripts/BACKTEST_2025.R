# ==============================================================================
# BACKTEST_2025.R — Model Validation Against 2025 CFB Historical Season
# Standalone script — does NOT require live pipeline to be running
#
# PURPOSE:
#   Validate the deterministic spread model before live deployment in Sep 2026.
#   Target: MAE <= 6.0 pts overall.  If MAE > 7.5, recalibrate blend weights
#   or HFA before going live.
#
# DATA SOURCES (all via CFBD API):
#   /games?year=2025          — final scores, neutral site flag
#   /ratings/sp?year=2025     — SP+ ratings (primary rating input)
#   /ppa/teams?year=2025      — per-play EPA: off/def PPA, success rate, explosiveness
#   /lines?year=2025          — opening + closing spread lines (DK preferred)
#
# MODEL USED:
#   Matches GENERATE_PREDICTIONS_CFB.R (deterministic linear):
#     proj_spread = -(rating_diff_blended * SP_SCALAR
#                     + ppa_adj              [ppa_diff × PPA_SPREAD_WEIGHT]
#                     + succ_adj             [success_rate_diff × SUCCESS_SPREAD_WEIGHT]
#                     + third_down_spread_adj [3d-rate diff × THIRD_DOWN_SPREAD_WEIGHT]
#                     + effective_hfa)
#
#   Factors INCLUDED in backtest (CFBD historical data available):
#     SP+    — /ratings/sp?year=2024  (prior-season final as preseason proxy)
#     ELO    — /ratings/elo?year=2025 (latest week per team; blended at WEIGHT_ELO)
#     PPA    — /ppa/teams?year=2025
#     3rd Dn — /stats/season?year=2025 (thirdDownConversions / thirdDowns)
#
#   Factors EXCLUDED (no CFBD historical data):
#     Sagarin/Massey — no historical weekly snapshots via CFBD API
#     Injury adj     — no historical injury status data
#     Motivational   — rivalry/trap/bowl-elig require per-game context not in API
#
#   Three-way comparison: SP-only → SP+ELO-blend → full model (PPA + 3d-rate)
#   ELO weight normalized to SP+: WEIGHT_SP_PLUS/(WEIGHT_SP_PLUS+WEIGHT_ELO)
#
# OUTPUTS:
#   clean/backtest_2025_results.csv   — one row per game, all metrics
#   clean/backtest_2025_summary.csv   — MAE + ATS by week / conf_tier / overall
#   Console summary report (SP-only MAE vs PPA-blended MAE side-by-side)
#
# RUN ANYTIME:
#   source("scripts/BACKTEST_2025.R")
#   OR from terminal: Rscript scripts/BACKTEST_2025.R
# ==============================================================================

suppressMessages(library(tidyverse))
suppressMessages(library(httr))
suppressMessages(library(jsonlite))

setwd("G:/My Drive/Scripting Projects/cfb_project")
source("scripts/CONFIG.R")
source("scripts/TEAM_NAME_NORMALIZER_CFB.R")

BACKTEST_YEAR      <- 2025   # game results year
SP_RATINGS_YEAR    <- 2024   # SP+ ratings year — use PRIOR season final as preseason proxy
                              # Rationale: live pipeline uses current-week SP+, not end-of-season.
                              # 2024 final SP+ = best available estimate before 2025 games were played.

cat(sprintf("\n========== mcFootball Backtest | Year: %d ==========\n", BACKTEST_YEAR))

# ------------------------------------------------------------------------------
# 0. Load MASTER + credentials
# ------------------------------------------------------------------------------
master <- load_cfb_master()
creds  <- load_credentials()
api_key <- creds$cfbd_api_key
if (is.null(api_key) || nchar(api_key) < 10) {
  stop("[BACKTEST] cfbd_api_key missing in credentials.json")
}

# ------------------------------------------------------------------------------
# 1. CFBD helper (mirrors SCRAPE_CFB_DATA.R)
# ------------------------------------------------------------------------------
cfbd_get <- function(endpoint, params = list()) {
  base_url <- "https://api.collegefootballdata.com"
  resp <- GET(
    paste0(base_url, endpoint),
    add_headers(Authorization = paste("Bearer", api_key)),
    query   = params,
    timeout(30)
  )
  if (http_error(resp)) {
    stop(sprintf("[BACKTEST] HTTP %d on %s", status_code(resp), endpoint))
  }
  fromJSON(content(resp, "text", encoding = "UTF-8"), flatten = TRUE)
}

# ------------------------------------------------------------------------------
# 2. Pull SP+ ratings for 2025
# ------------------------------------------------------------------------------
cat("\n[1/5] Fetching SP+ ratings...\n")
sp_raw <- cfbd_get("/ratings/sp", list(year = SP_RATINGS_YEAR))
cat(sprintf("[BACKTEST] Using SP+ ratings from %d (preseason proxy for %d).\n",
            SP_RATINGS_YEAR, BACKTEST_YEAR))

if (length(sp_raw) == 0) {
  stop("[BACKTEST] SP+ ratings returned empty for 2025 — check API key or season availability.")
}

sp_ratings <- as_tibble(sp_raw) %>%
  transmute(
    canonical_name = normalize_team_name(team, mappings = master,
                                          source_col = "massey_name",
                                          unmatched_log = "logs/unmatched_teams.csv"),
    sp_overall  = as.numeric(rating),
    sp_offense  = as.numeric(offense.rating),
    sp_defense  = as.numeric(defense.rating)
  ) %>%
  filter(!is.na(canonical_name))

cat(sprintf("[BACKTEST] SP+ ratings: %d teams loaded.\n", nrow(sp_ratings)))

# ------------------------------------------------------------------------------
# 2.1 Pull ELO ratings for 2025
# Endpoint: /ratings/elo?year=YEAR — per-team per-week ELO.
# Take latest week per team (highest week = most current rating).
# Blended with SP+ in the prediction step at normalized weight.
# ------------------------------------------------------------------------------
cat("\n[1.5/5] Fetching ELO ratings...\n")
elo_ratings <- tryCatch({
  raw_elo <- cfbd_get("/ratings/elo", list(year = BACKTEST_YEAR))
  if (length(raw_elo) == 0 || nrow(as.data.frame(raw_elo)) == 0) {
    warning("[BACKTEST] /ratings/elo returned empty — ELO blend disabled.")
    NULL
  } else {
    elo_tbl <- as_tibble(raw_elo) %>%
      group_by(team) %>%
      slice_max(order_by = as.integer(week), n = 1, with_ties = FALSE) %>%
      ungroup() %>%
      transmute(
        canonical_name = normalize_team_name(team, mappings = master,
                                              source_col    = "massey_name",
                                              unmatched_log = "logs/unmatched_teams.csv"),
        elo_rating = as.numeric(elo)
      ) %>%
      filter(!is.na(canonical_name))
    cat(sprintf("[BACKTEST] ELO ratings: %d teams loaded.\n", nrow(elo_tbl)))
    elo_tbl
  }
}, error = function(e) {
  warning(sprintf("[BACKTEST] ELO fetch failed (non-fatal): %s", e$message))
  NULL
})
ELO_AVAILABLE <- !is.null(elo_ratings) && nrow(elo_ratings) > 0

# ------------------------------------------------------------------------------
# 2.5 Pull PPA metrics for 2025 (off/def PPA, success rate, explosiveness)
# CFBD endpoint: /ppa/teams?year=YEAR&excludeGarbageTime=true
# Column map:
#   offense.overall      -> off_ppa
#   defense.overall      -> def_ppa        (negative = better defense)
#   offense.success      -> off_success_rate
#   defense.success      -> def_success_rate
#   offense.explosiveness-> off_explosiveness
# ------------------------------------------------------------------------------
cat("\n[2/5] Fetching PPA team metrics...\n")

ppa_ratings <- tryCatch({
  raw_ppa <- cfbd_get("/ppa/teams", list(year = BACKTEST_YEAR,
                                          excludeGarbageTime = "true"))
  if (length(raw_ppa) == 0 || nrow(as.data.frame(raw_ppa)) == 0) {
    warning("[BACKTEST] /ppa/teams returned empty — PPA adjustments will be skipped.")
    NULL
  } else {
    ppa_tbl <- as_tibble(raw_ppa)

    # CFBD returns nested objects for offense/defense when flatten=TRUE
    # Column names: offense.overall, offense.success, offense.explosiveness,
    #               defense.overall, defense.success
    # Fallback: also check non-nested names in case API version differs
    get_col <- function(df, ...) {
      for (nm in c(...)) {
        if (nm %in% names(df)) return(df[[nm]])
      }
      NA_real_
    }

    ppa_out <- ppa_tbl %>%
      transmute(
        canonical_name     = normalize_team_name(team, mappings = master,
                                                  source_col = "massey_name",
                                                  unmatched_log = "logs/unmatched_teams.csv"),
        off_ppa            = as.numeric(get_col(ppa_tbl, "offense.overall",   "offenseOverall")),
        def_ppa            = as.numeric(get_col(ppa_tbl, "defense.overall",   "defenseOverall")),
        off_success_rate   = as.numeric(get_col(ppa_tbl, "offense.success",   "offenseSuccess")),
        def_success_rate   = as.numeric(get_col(ppa_tbl, "defense.success",   "defenseSuccess")),
        off_explosiveness  = as.numeric(get_col(ppa_tbl, "offense.explosiveness",
                                                          "offenseExplosiveness"))
      ) %>%
      filter(!is.na(canonical_name))

    cat(sprintf("[BACKTEST] PPA metrics: %d teams loaded.\n", nrow(ppa_out)))
    ppa_out
  }
}, error = function(e) {
  warning(sprintf("[BACKTEST] PPA fetch failed (non-fatal): %s", e$message))
  NULL
})

PPA_AVAILABLE <- !is.null(ppa_ratings) && nrow(ppa_ratings) > 0

# ------------------------------------------------------------------------------
# 2.6 Pull season stats for 2025 — third-down conversion rate
# Endpoint: /stats/season?year=YEAR — returns long-format team season totals.
# We extract thirdDownConversions + thirdDowns and compute rate per team.
# Matches SCRAPE_CFB_DATA.R logic; applied in prediction step via
# THIRD_DOWN_SPREAD_WEIGHT and THIRD_DOWN_TOTAL_WEIGHT from CONFIG.R.
# ------------------------------------------------------------------------------
cat("\n[2.5/5] Fetching season stats (third-down rates)...\n")
season_stats <- tryCatch({
  raw_stats <- cfbd_get("/stats/season", list(year = BACKTEST_YEAR))
  if (length(raw_stats) == 0 || nrow(as.data.frame(raw_stats)) == 0) {
    warning("[BACKTEST] /stats/season returned empty — third-down adj disabled.")
    NULL
  } else {
    stats_tbl <- as_tibble(raw_stats)
    if (!all(c("statName", "statValue", "team") %in% names(stats_tbl))) {
      warning("[BACKTEST] /stats/season unexpected format — third-down adj disabled.")
      NULL
    } else {
      td_stats <- stats_tbl %>%
        filter(statName %in% c("thirdDownConversions", "thirdDowns")) %>%
        select(team, statName, statValue) %>%
        pivot_wider(names_from = statName, values_from = statValue,
                    values_fn = first) %>%
        filter(!is.na(thirdDowns), as.numeric(thirdDowns) > 0) %>%
        mutate(
          canonical_name  = normalize_team_name(team, mappings = master,
                                                 source_col    = "massey_name",
                                                 unmatched_log = "logs/unmatched_teams.csv"),
          third_down_rate = as.numeric(thirdDownConversions) /
                              pmax(as.numeric(thirdDowns), 1L)
        ) %>%
        filter(!is.na(canonical_name)) %>%
        select(canonical_name, third_down_rate)
      cat(sprintf("[BACKTEST] Third-down rates: %d teams loaded.\n", nrow(td_stats)))
      td_stats
    }
  }
}, error = function(e) {
  warning(sprintf("[BACKTEST] Season stats fetch failed (non-fatal): %s", e$message))
  NULL
})
TD_AVAILABLE <- !is.null(season_stats) && nrow(season_stats) > 0

# ------------------------------------------------------------------------------
# 3. Pull all 2025 game results (regular season + postseason)
# ------------------------------------------------------------------------------
cat("\n[3/5] Fetching 2025 game results...\n")

pull_games <- function(season_type) {
  tryCatch({
    raw <- cfbd_get("/games", list(year = BACKTEST_YEAR, seasonType = season_type,
                                   division = "fbs"))
    if (length(raw) == 0 || nrow(as.data.frame(raw)) == 0) return(NULL)
    tbl <- as_tibble(raw)

    # CFBD v2 API returns camelCase column names when processed via fromJSON(flatten=TRUE).
    # Normalize to snake_case so downstream code is stable across API versions.
    names(tbl) <- names(tbl) %>%
      str_replace("homePoints",    "home_points") %>%
      str_replace("awayPoints",    "away_points") %>%
      str_replace("homeTeam",      "home_team")   %>%
      str_replace("awayTeam",      "away_team")   %>%
      str_replace("homeConference","home_conference") %>%
      str_replace("awayConference","away_conference") %>%
      str_replace("neutralSite",   "neutral_site") %>%
      str_replace("seasonType",    "season_type")

    # Also handle dot-notation from flatten=TRUE (e.g., "home.points")
    names(tbl) <- names(tbl) %>%
      str_replace("^home\\.points$",      "home_points") %>%
      str_replace("^away\\.points$",      "away_points") %>%
      str_replace("^home\\.team$",        "home_team")   %>%
      str_replace("^away\\.team$",        "away_team")   %>%
      str_replace("^home\\.conference$",  "home_conference") %>%
      str_replace("^away\\.conference$",  "away_conference") %>%
      str_replace("^neutral\\.site$",     "neutral_site")

    # Diagnostic: print column names on first call so we can verify mapping
    if (season_type == "regular") {
      cat(sprintf("[BACKTEST] /games columns: %s\n",
                  paste(names(tbl), collapse = ", ")))
    }

    tbl
  }, error = function(e) {
    warning(sprintf("[BACKTEST] %s games fetch failed: %s", season_type, e$message))
    NULL
  })
}

games_reg  <- pull_games("regular")
games_post <- pull_games("postseason")
games_raw  <- bind_rows(games_reg, games_post)

if (is.null(games_raw) || nrow(games_raw) == 0) {
  stop("[BACKTEST] No game results found for 2025.")
}

# FCS / non-FBS team names that appear as spurious rows — filter before normalization
FCS_FILTER_TERMS <- c("nationalAverages", "Missouri State", "Delaware",
                       "North Dakota State", "South Dakota State", "Montana",
                       "Montana State", "Villanova", "Youngstown State",
                       "Eastern Washington", "Sacramento State", "Northern Iowa")

# Keep only completed FBS-vs-FBS games with scores
# home_points/away_points are normalized above; NA = game not yet played
games <- games_raw %>%
  filter(!is.na(home_points), !is.na(away_points)) %>%
  filter(!home_team %in% FCS_FILTER_TERMS,
         !away_team %in% FCS_FILTER_TERMS) %>%
  transmute(
    game_id        = as.character(id),
    week           = as.integer(week),
    season_type    = season_type,
    neutral_site   = as.logical(neutral_site),
    home_team_raw  = home_team,
    away_team_raw  = away_team,
    home_conf      = home_conference,
    away_conf      = away_conference,
    home_score     = as.integer(home_points),
    away_score     = as.integer(away_points),
    actual_margin  = home_score - away_score   # positive = home won
  ) %>%
  mutate(
    canonical_home = normalize_team_name(home_team_raw, mappings = master,
                                          source_col = "massey_name",
                                          unmatched_log = "logs/unmatched_teams.csv"),
    canonical_away = normalize_team_name(away_team_raw, mappings = master,
                                          source_col = "massey_name",
                                          unmatched_log = "logs/unmatched_teams.csv")
  ) %>%
  filter(!is.na(canonical_home), !is.na(canonical_away))

cat(sprintf("[BACKTEST] Game results: %d completed FBS games (%d regular + %d postseason).\n",
            nrow(games),
            sum(games$season_type == "regular",    na.rm = TRUE),
            sum(games$season_type == "postseason", na.rm = TRUE)))

# ------------------------------------------------------------------------------
# 4. Pull 2025 betting lines (opening + closing spread)
# ------------------------------------------------------------------------------
cat("\n[4/5] Fetching 2025 betting lines...\n")

lines_df <- tryCatch({
  raw <- cfbd_get("/lines", list(year = BACKTEST_YEAR))
  if (length(raw) == 0) stop("empty")

  lines_tbl <- as_tibble(raw)

  # The /lines endpoint returns a list-column `lines` per game
  # Each element has: provider, spread, formattedSpread, overUnder, etc.
  # We want opening DraftKings line; fall back to consensus/Caesars/any
  extract_line <- function(lines_list, prefer_providers = c("DraftKings", "Caesars",
                                                              "consensus", "ESPN Bet")) {
    if (is.null(lines_list) || length(lines_list) == 0) return(NA_real_)
    if (is.data.frame(lines_list)) {
      for (prov in prefer_providers) {
        row <- lines_list[tolower(lines_list$provider) == tolower(prov), ]
        if (nrow(row) > 0 && !is.na(row$spread[1])) return(as.numeric(row$spread[1]))
      }
      # Fallback: first non-NA spread
      non_na <- lines_list$spread[!is.na(lines_list$spread)]
      if (length(non_na) > 0) return(as.numeric(non_na[1]))
    }
    NA_real_
  }

  lines_out <- lines_tbl %>%
    mutate(
      game_id      = as.character(id),
      posted_spread = map_dbl(lines, extract_line),
      # posted_spread from CFBD is home-team perspective (negative = home favored)
      posted_total  = map_dbl(lines, function(l) {
        if (is.null(l) || !is.data.frame(l)) return(NA_real_)
        vals <- suppressWarnings(as.numeric(l$overUnder))
        non_na <- vals[!is.na(vals)]
        if (length(non_na) > 0) non_na[1] else NA_real_
      })
    ) %>%
    select(game_id, posted_spread, posted_total)

  cat(sprintf("[BACKTEST] Lines loaded: %d games | %.0f%% have posted spread.\n",
              nrow(lines_out),
              100 * mean(!is.na(lines_out$posted_spread))))
  lines_out

}, error = function(e) {
  warning(sprintf("[BACKTEST] Lines fetch failed (non-fatal): %s", e$message))
  tibble(game_id = character(0), posted_spread = numeric(0), posted_total = numeric(0))
})

# ------------------------------------------------------------------------------
# 5. Build model predictions for each game
# ------------------------------------------------------------------------------
cat("\n[5/5] Running model predictions...\n")

# Join SP+ ratings onto games
games_rated <- games %>%
  left_join(sp_ratings %>% select(canonical_name,
                                   home_sp = sp_overall,
                                   home_sp_off = sp_offense,
                                   home_sp_def = sp_defense),
            by = c("canonical_home" = "canonical_name")) %>%
  left_join(sp_ratings %>% select(canonical_name,
                                   away_sp = sp_overall,
                                   away_sp_off = sp_offense,
                                   away_sp_def = sp_defense),
            by = c("canonical_away" = "canonical_name")) %>%
  # Join MASTER metadata for HFA + conference
  left_join(master %>% select(canonical_name, home_hfa_pts = hfa_pts,
                               home_conf_weight = conf_weight),
            by = c("canonical_home" = "canonical_name")) %>%
  left_join(master %>% select(canonical_name, away_conf_weight = conf_weight),
            by = c("canonical_away" = "canonical_name")) %>%
  # Join posted lines
  left_join(lines_df, by = "game_id")

# Join ELO ratings onto games
if (ELO_AVAILABLE) {
  games_rated <- games_rated %>%
    left_join(elo_ratings %>% select(canonical_name, home_elo = elo_rating),
              by = c("canonical_home" = "canonical_name")) %>%
    left_join(elo_ratings %>% select(canonical_name, away_elo = elo_rating),
              by = c("canonical_away" = "canonical_name"))
} else {
  games_rated <- games_rated %>% mutate(home_elo = NA_real_, away_elo = NA_real_)
}

# Join third-down rates onto games
if (TD_AVAILABLE) {
  games_rated <- games_rated %>%
    left_join(season_stats %>% select(canonical_name, home_3d = third_down_rate),
              by = c("canonical_home" = "canonical_name")) %>%
    left_join(season_stats %>% select(canonical_name, away_3d = third_down_rate),
              by = c("canonical_away" = "canonical_name"))
} else {
  games_rated <- games_rated %>% mutate(home_3d = NA_real_, away_3d = NA_real_)
}

# Join PPA metrics onto games (non-fatal — remains NA if PPA unavailable)
if (PPA_AVAILABLE) {
  games_rated <- games_rated %>%
    left_join(ppa_ratings %>% select(canonical_name,
                                      home_off_ppa          = off_ppa,
                                      home_def_ppa          = def_ppa,
                                      home_off_success_rate = off_success_rate,
                                      home_def_success_rate = def_success_rate,
                                      home_off_explosiveness= off_explosiveness),
              by = c("canonical_home" = "canonical_name")) %>%
    left_join(ppa_ratings %>% select(canonical_name,
                                      away_off_ppa          = off_ppa,
                                      away_def_ppa          = def_ppa,
                                      away_off_success_rate = off_success_rate,
                                      away_def_success_rate = def_success_rate,
                                      away_off_explosiveness= off_explosiveness),
              by = c("canonical_away" = "canonical_name")) %>%
    mutate(
      # PPA differential (home perspective): net EPA/play advantage
      ppa_diff = coalesce(
        (home_off_ppa - away_def_ppa) - (away_off_ppa - home_def_ppa),
        NA_real_
      ),
      # Success rate differential: drive consistency signal
      success_rate_diff = coalesce(
        (home_off_success_rate - away_def_success_rate) -
        (away_off_success_rate - home_def_success_rate),
        NA_real_
      ),
      # Explosiveness differential: big-play upside vs total
      explosiveness_diff = coalesce(
        home_off_explosiveness - away_off_explosiveness,
        NA_real_
      )
    )
  n_ppa_games <- sum(!is.na(games_rated$ppa_diff))
  cat(sprintf("[BACKTEST] PPA diffs computed for %d / %d games.\n",
              n_ppa_games, nrow(games_rated)))
} else {
  games_rated <- games_rated %>%
    mutate(ppa_diff = NA_real_, success_rate_diff = NA_real_,
           explosiveness_diff = NA_real_)
  cat("[BACKTEST] PPA not available — SP+ only model.\n")
}

# Prediction (matches GENERATE_PREDICTIONS_CFB.R logic):
#
#   SP-only:  proj_spread_sp  = -(rating_diff * SP_SCALAR + effective_hfa)
#   PPA-blend:proj_spread     = -(rating_diff * SP_SCALAR
#                                 + ppa_adj    [ppa_diff × PPA_SPREAD_WEIGHT]
#                                 + succ_adj   [success_rate_diff × SUCCESS_SPREAD_WEIGHT]
#                                 + effective_hfa)
#
# rating_diff = home_sp - away_sp (positive = home better)
# proj_spread: negative = home favored (matches sportsbook convention)
#
# Both variants stored so the summary can show delta MAE from PPA layer.

# Resolve constants outside mutate
.max_edge   <- if (exists("MAX_EDGE_SPREAD"))             MAX_EDGE_SPREAD             else Inf
.ppa_w      <- if (exists("PPA_SPREAD_WEIGHT"))           PPA_SPREAD_WEIGHT           else 5.0
.succ_w     <- if (exists("SUCCESS_SPREAD_WEIGHT"))       SUCCESS_SPREAD_WEIGHT       else 2.0
.expl_w     <- if (exists("EXPL_TOTAL_WEIGHT"))           EXPL_TOTAL_WEIGHT           else 3.0
.scalar     <- if (exists("SP_SCALAR"))                   SP_SCALAR                   else 1.0
.td_sp_w    <- if (exists("THIRD_DOWN_SPREAD_WEIGHT"))    THIRD_DOWN_SPREAD_WEIGHT    else 3.0
.td_tot_w   <- if (exists("THIRD_DOWN_TOTAL_WEIGHT"))     THIRD_DOWN_TOTAL_WEIGHT     else 4.0
.avg_3d     <- if (exists("LEAGUE_AVG_3D_RATE"))          LEAGUE_AVG_3D_RATE          else 0.41
.elo_w_cfg  <- if (exists("WEIGHT_ELO"))                  WEIGHT_ELO                  else 0.10
.sp_w_cfg   <- if (exists("WEIGHT_SP_PLUS"))              WEIGHT_SP_PLUS              else 0.45

# ELO blend weights — normalized to SP+ + ELO only (Sagarin/Massey unavailable historically)
.sp_w_bt    <- .sp_w_cfg  / (.sp_w_cfg + .elo_w_cfg)   # 0.45/0.55 ≈ 0.818
.elo_w_bt   <- .elo_w_cfg / (.sp_w_cfg + .elo_w_cfg)   # 0.10/0.55 ≈ 0.182

# ELO z-score scale: convert ELO diff to SP+ units for blending
# SD(ELO per team) ≈ 150; SD(SP+ per team) ≈ 15 → scale_factor ≈ 0.1
.sp_sd      <- sd(sp_ratings$sp_overall,  na.rm = TRUE)
.elo_sd     <- if (ELO_AVAILABLE) sd(elo_ratings$elo_rating, na.rm = TRUE) else 1

games_pred <- games_rated %>%
  mutate(
    rating_diff   = home_sp - away_sp,
    effective_hfa = if_else(neutral_site, 0, coalesce(home_hfa_pts, 3.0)),

    # ELO differential scaled to SP+ units, then blended
    elo_diff_scaled = if_else(
      !is.na(home_elo) & !is.na(away_elo) & ELO_AVAILABLE,
      (home_elo - away_elo) / .elo_sd * .sp_sd,
      rating_diff   # fall back to SP+ diff when ELO unavailable
    ),
    # Blended rating: SP+ 82% + ELO 18% (weights normalized; see header)
    rating_diff_blended = rating_diff * .sp_w_bt + elo_diff_scaled * .elo_w_bt,

    # Third-down rate adjustment (same formula as live GENERATE_PREDICTIONS_CFB.R)
    home_3d_use          = coalesce(home_3d, .avg_3d),
    away_3d_use          = coalesce(away_3d, .avg_3d),
    third_down_spread_adj = (home_3d_use - away_3d_use) * .td_sp_w,
    third_down_total_adj  = (home_3d_use + away_3d_use - 2 * .avg_3d) * .td_tot_w,

    # PPA adjustment terms (0 when PPA unavailable)
    ppa_adj     = if_else(!is.na(ppa_diff),          ppa_diff          * .ppa_w, 0),
    success_adj = if_else(!is.na(success_rate_diff), success_rate_diff * .succ_w, 0),

    # --- Three variants for delta measurement ---
    # 1. SP-only baseline (original model, no ELO/PPA/3d)
    proj_spread_sp  = -(.scalar * rating_diff + effective_hfa),

    # 2. SP+ELO blend (rating improvement only)
    proj_spread_elo = -(.scalar * rating_diff_blended + effective_hfa),

    # 3. Full model: SP+ELO + PPA + third-down
    proj_spread     = -(.scalar * rating_diff_blended +
                        ppa_adj + success_adj +
                        third_down_spread_adj +
                        effective_hfa),

    # Flag which adjustments were active on this game
    ppa_active  = !is.na(ppa_diff) & PPA_AVAILABLE,
    elo_active  = !is.na(home_elo) & !is.na(away_elo) & ELO_AVAILABLE,
    td_active   = !is.na(home_3d)  & !is.na(away_3d)  & TD_AVAILABLE,

    # Win probability from spread
    win_prob_home = 1 / (1 + exp(proj_spread / 7.5)),

    # Predicted home margins for all three variants
    pred_home_margin     = -proj_spread,
    pred_home_margin_elo = -proj_spread_elo,
    pred_home_margin_sp  = -proj_spread_sp,

    # Errors for three-way MAE comparison
    pred_error    = pred_home_margin     - actual_margin,
    abs_error     = abs(pred_error),
    pred_error_elo= pred_home_margin_elo - actual_margin,
    abs_error_elo = abs(pred_error_elo),
    pred_error_sp = pred_home_margin_sp  - actual_margin,
    abs_error_sp  = abs(pred_error_sp),

    # ATS evaluation (requires posted_spread)
    # posted_spread < 0 → home is favorite
    # home covered if: actual_margin > -posted_spread
    home_covered  = case_when(
      is.na(posted_spread)                 ~ NA,
      actual_margin >  -posted_spread      ~ TRUE,
      actual_margin == -posted_spread      ~ NA,   # push
      TRUE                                 ~ FALSE
    ) %>% as.logical(),

    # Model edge vs market
    # edge > 0 = model projects home to cover
    # edge < 0 = model projects away to cover
    model_edge    = if_else(!is.na(posted_spread),
                             pred_home_margin - (-posted_spread),
                             NA_real_),

    # Did a qualifying bet (|edge| in [MIN_EDGE_SPREAD, MAX_EDGE_SPREAD]) cover?
    bet_qualifies = !is.na(model_edge) &
                    abs(model_edge) >= MIN_EDGE_SPREAD &
                    abs(model_edge) <= .max_edge,
    bet_side      = case_when(
      !bet_qualifies          ~ NA_character_,
      model_edge < 0          ~ "away",
      TRUE                    ~ "home"
    ),
    bet_covered   = case_when(
      !bet_qualifies          ~ NA,
      bet_side == "home"      ~ home_covered,
      bet_side == "away"      ~ !home_covered,
      TRUE                    ~ NA
    ),

    # Conference tier lookup
    conf_tier = coalesce(
      master$conf_tier[match(canonical_home, master$canonical_name)],
      2L
    ),
    conf_tier_label = case_when(
      conf_tier == 1 ~ "P4 (SEC/Big Ten/Big 12/ACC)",
      conf_tier == 2 ~ "G5",
      conf_tier == 3 ~ "Independent",
      TRUE           ~ "Unknown"
    )
  ) %>%
  filter(!is.na(home_sp), !is.na(away_sp))  # drop games missing SP+ for both teams

cat(sprintf("[BACKTEST] Predictions generated for %d games with complete SP+ data.\n",
            nrow(games_pred)))
cat(sprintf("[BACKTEST] Games dropped (missing SP+): %d\n",
            nrow(games) - nrow(games_pred)))

# ------------------------------------------------------------------------------
# 6. Compute summary statistics
# ------------------------------------------------------------------------------

# --- Overall ---
overall_mae     <- mean(games_pred$abs_error,     na.rm = TRUE)
overall_mae_elo <- mean(games_pred$abs_error_elo, na.rm = TRUE)
overall_mae_sp  <- mean(games_pred$abs_error_sp,  na.rm = TRUE)
overall_rmse    <- sqrt(mean(games_pred$pred_error^2, na.rm = TRUE))
n_games         <- nrow(games_pred)
n_ppa_active    <- sum(games_pred$ppa_active, na.rm = TRUE)
n_elo_active    <- sum(games_pred$elo_active, na.rm = TRUE)
n_td_active     <- sum(games_pred$td_active,  na.rm = TRUE)

# Direction accuracy: did model correctly predict which team would win?
direction_correct <- games_pred %>%
  filter(actual_margin != 0) %>%
  summarise(
    n = n(),
    correct = sum(sign(pred_home_margin) == sign(actual_margin)),
    pct = correct / n
  )

# ATS performance on qualifying bets
ats_summary <- games_pred %>%
  filter(bet_qualifies, !is.na(bet_covered)) %>%
  summarise(
    n_bets  = n(),
    n_win   = sum(bet_covered),
    n_loss  = sum(!bet_covered),
    win_pct = n_win / n_bets
  )

# --- By week ---
by_week <- games_pred %>%
  group_by(week) %>%
  summarise(
    n_games  = n(),
    mae      = round(mean(abs_error, na.rm = TRUE), 2),
    rmse     = round(sqrt(mean(pred_error^2, na.rm = TRUE)), 2),
    n_bets   = sum(bet_qualifies, na.rm = TRUE),
    ats_wins = sum(bet_covered, na.rm = TRUE),
    ats_win_pct = if_else(n_bets > 0, round(ats_wins / n_bets, 3), NA_real_),
    .groups = "drop"
  ) %>%
  arrange(week)

# --- By conference tier ---
by_conf <- games_pred %>%
  group_by(conf_tier, conf_tier_label) %>%
  summarise(
    n_games  = n(),
    mae      = round(mean(abs_error, na.rm = TRUE), 2),
    rmse     = round(sqrt(mean(pred_error^2, na.rm = TRUE)), 2),
    n_bets   = sum(bet_qualifies, na.rm = TRUE),
    ats_wins = sum(bet_covered, na.rm = TRUE),
    ats_win_pct = if_else(n_bets > 0, round(ats_wins / n_bets, 3), NA_real_),
    .groups = "drop"
  ) %>%
  arrange(conf_tier)

# --- Edge size buckets ---
by_edge <- games_pred %>%
  filter(bet_qualifies) %>%
  mutate(edge_bucket = cut(abs(model_edge),
                            breaks = c(3, 5, 7, 10, 15, Inf),
                            labels = c("3-5 pts", "5-7 pts", "7-10 pts",
                                       "10-15 pts", "15+ pts"),
                            right  = FALSE)) %>%
  group_by(edge_bucket) %>%
  summarise(
    n_bets      = n(),
    ats_wins    = sum(bet_covered, na.rm = TRUE),
    ats_win_pct = round(ats_wins / n_bets, 3),
    .groups = "drop"
  )

# --- Bias check: is the model systematically over/under-projecting? ---
mean_error <- mean(games_pred$pred_error, na.rm = TRUE)
# Positive mean_error = model over-projects home team (predicts too many home wins)
# Negative = under-projects home team

# ------------------------------------------------------------------------------
# 7. Console report
# ------------------------------------------------------------------------------
sep <- paste(rep("=", 60), collapse = "")
cat(sprintf("\n%s\n", sep))
cat(sprintf(" mcFootball 2025 BACKTEST RESULTS\n"))
cat(sprintf("%s\n\n", sep))

cat(sprintf(" Total games evaluated:  %d\n", n_games))
cat(sprintf(" ELO active:             %d / %d games  (blend: SP+%.0f%% + ELO%.0f%%)\n",
            n_elo_active, n_games, .sp_w_bt * 100, .elo_w_bt * 100))
cat(sprintf(" PPA active:             %d / %d games  (weights: spread=%.1f, succ=%.1f)\n",
            n_ppa_active, n_games, .ppa_w, .succ_w))
cat(sprintf(" 3rd-Down active:        %d / %d games  (spread=%.1f, total=%.1f)\n",
            n_td_active, n_games, .td_sp_w, .td_tot_w))

# Three-way MAE comparison: SP-only → SP+ELO → full model
delta_elo  <- overall_mae_sp  - overall_mae_elo
delta_full <- overall_mae_elo - overall_mae
cat(sprintf("\n --- MAE Comparison (three variants) ---\n"))
cat(sprintf(" 1. SP-only:            %.2f pts  (baseline)\n", overall_mae_sp))
cat(sprintf(" 2. SP+ELO blend:       %.2f pts  (delta vs SP-only:  %+.2f)\n",
            overall_mae_elo, delta_elo))
cat(sprintf(" 3. Full model (PPA+3d):%.2f pts  %s\n",
            overall_mae,
            ifelse(overall_mae <= 6.0, "✓ TARGET MET (≤ 6.0)",
                   ifelse(overall_mae <= 7.5, "⚠ MARGINAL (6-7.5)",
                                              "✗ RECALIBRATE (> 7.5)"))))
cat(sprintf("    ELO contribution:    %+.2f pts | PPA+3d contribution: %+.2f pts\n",
            delta_elo, delta_full))
mae_delta <- overall_mae_sp - overall_mae   # total improvement
if (mae_delta > 0.1) {
  cat(sprintf(" New factors IMPROVED model by %.2f pts MAE total.\n", mae_delta))
} else if (mae_delta < -0.1) {
  cat(sprintf(" New factors HURT model by %.2f pts — consider reducing weights.\n",
              abs(mae_delta)))
} else {
  cat(" Factor effect is negligible (< 0.1 pts). Weights may need tuning.\n")
}

cat(sprintf("\n Overall RMSE:           %.2f pts\n", overall_rmse))
cat(sprintf(" Direction accuracy:     %.1f%%  (%d / %d games)\n",
            direction_correct$pct * 100,
            direction_correct$correct,
            direction_correct$n))
cat(sprintf(" Model bias:             %+.2f pts  %s\n",
            mean_error,
            ifelse(abs(mean_error) < 0.5, "(well-calibrated)",
                   ifelse(mean_error > 0, "(over-projects home)", "(under-projects home)"))))

cat(sprintf("\n--- ATS Performance on Qualifying Bets (edge ≥ %.1f pts) ---\n",
            MIN_EDGE_SPREAD))
if (ats_summary$n_bets > 0) {
  cat(sprintf(" Qualifying bets:   %d\n", ats_summary$n_bets))
  cat(sprintf(" ATS record:        %d-%d  (%.1f%%)\n",
              ats_summary$n_win, ats_summary$n_loss,
              ats_summary$win_pct * 100))
  cat(sprintf(" Break-even needed: 52.4%%  %s\n",
              ifelse(ats_summary$win_pct >= 0.524, "✓ PROFITABLE",
                     ifelse(ats_summary$win_pct >= 0.50, "⚠ NEAR BREAK-EVEN",
                                                         "✗ BELOW BREAK-EVEN"))))
} else {
  cat(" No qualifying bets found at current edge threshold.\n")
  cat(sprintf(" Consider lowering MIN_EDGE_SPREAD (currently %.1f pts) for validation.\n",
              MIN_EDGE_SPREAD))
}

cat("\n--- MAE by Conference Tier ---\n")
by_conf %>%
  select(conf_tier_label, n_games, mae, rmse, n_bets, ats_win_pct) %>%
  as.data.frame() %>%
  print(row.names = FALSE)

cat("\n--- MAE by Week (first 5 and last 5) ---\n")
bind_rows(
  head(by_week, 5),
  if (nrow(by_week) > 10) tibble(week = NA, n_games = NA, mae = NA,
                                  rmse = NA, n_bets = NA,
                                  ats_wins = NA, ats_win_pct = NA),
  tail(by_week, 5)
) %>%
  mutate(week = if_else(is.na(week), "---", as.character(week))) %>%
  select(week, n_games, mae, rmse, n_bets, ats_win_pct) %>%
  as.data.frame() %>%
  print(row.names = FALSE)

cat("\n--- ATS Win Rate by Model Edge Size ---\n")
if (nrow(by_edge) > 0) {
  by_edge %>% as.data.frame() %>% print(row.names = FALSE)
} else {
  cat(" No qualifying bets to bucket.\n")
}

# ------------------------------------------------------------------------------
# 8. Save outputs
# ------------------------------------------------------------------------------
out_results <- "clean/backtest_2025_results.csv"
out_summary <- "clean/backtest_2025_summary.csv"

write_csv(
  games_pred %>%
    select(game_id, week, season_type, neutral_site,
           canonical_away, canonical_home,
           home_conf, away_conf, conf_tier, conf_tier_label,
           home_score, away_score, actual_margin,
           home_sp, away_sp, rating_diff,
           home_elo, away_elo, elo_diff_scaled, rating_diff_blended,
           home_3d, away_3d, third_down_spread_adj,
           effective_hfa,
           ppa_diff, success_rate_diff, ppa_adj, success_adj,
           ppa_active, elo_active, td_active,
           proj_spread_sp, proj_spread_elo, proj_spread,
           pred_home_margin_sp, pred_home_margin_elo, pred_home_margin,
           pred_error_sp, abs_error_sp,
           pred_error_elo, abs_error_elo,
           pred_error, abs_error,
           posted_spread, model_edge, bet_qualifies, bet_side, bet_covered),
  out_results
)

summary_rows <- bind_rows(
  tibble(group = "overall", label = "All games (PPA-blend)",
         n_games = n_games, mae = round(overall_mae, 3),
         mae_sp_only = round(overall_mae_sp, 3),
         mae_elo = round(overall_mae_elo, 3),
         mae_ppa_delta = round(mae_delta, 3),
         rmse = round(overall_rmse, 3),
         n_bets = ats_summary$n_bets,
         ats_win_pct = ats_summary$win_pct,
         model_bias = round(mean_error, 3)),
  by_conf %>%
    mutate(group = "conf_tier", label = conf_tier_label,
           mae_sp_only = NA_real_, mae_elo = NA_real_, mae_ppa_delta = NA_real_,
           model_bias = NA_real_) %>%
    select(group, label, n_games, mae, mae_sp_only, mae_elo, mae_ppa_delta,
           rmse, n_bets, ats_win_pct, model_bias),
  by_week %>%
    mutate(group = "week", label = as.character(week),
           mae_sp_only = NA_real_, mae_elo = NA_real_, mae_ppa_delta = NA_real_,
           model_bias = NA_real_) %>%
    select(group, label, n_games, mae, mae_sp_only, mae_elo, mae_ppa_delta,
           rmse, n_bets, ats_win_pct, model_bias)
)

write_csv(summary_rows, out_summary)

cat(sprintf("\n%s\n", sep))
cat(sprintf(" Results saved → %s\n", out_results))
cat(sprintf(" Summary saved → %s\n", out_summary))
cat(sprintf("%s\n\n", sep))

# ------------------------------------------------------------------------------
# 9. Recalibration guidance
# ------------------------------------------------------------------------------
if (overall_mae > 6.0) {
  cat("⚠  MAE EXCEEDS TARGET. Recalibration checklist:\n")
  cat("   1. Check HFA values in MASTER CSV — are dome/neutral sites zeroed?\n")
  cat("   2. SP+ preseason vs. mid-season timing — early-season SP+ is noisier\n")
  cat("      → try filtering to weeks 4-14 only and recheck MAE\n")
  cat("   3. Add Sagarin PREDICTOR to blend — should reduce MAE 0.5-1.0 pts\n")
  cat("   4. Conference tier weighting — G5 MAE typically higher; acceptable\n")
  cat("   5. Consider recency-weighting SP+ (recent weeks > early weeks)\n")

  # MAE by early vs late season
  early_late <- games_pred %>%
    mutate(period = if_else(week <= 4, "Early (wks 1-4)", "Mid/Late (wks 5+)")) %>%
    group_by(period) %>%
    summarise(n = n(), mae = round(mean(abs_error, na.rm = TRUE), 2), .groups = "drop")

  cat("\n   Early vs. Late season MAE:\n")
  print(as.data.frame(early_late), row.names = FALSE)
}

invisible(list(
  results  = games_pred,
  by_week  = by_week,
  by_conf  = by_conf,
  by_edge  = by_edge,
  mae      = overall_mae,
  rmse     = overall_rmse,
  ats      = ats_summary
))
