# ==============================================================================
# build_ml_training_data.R — Multi-Season CFB Training Data Pull
# Standalone script — run once to build clean/ml_training_data_2013_2025.csv
#
# Data sources (all via CFBD API):
#   /ratings/sp?year=Y-1   — prior-season final SP+ as preseason proxy
#   /ratings/elo?year=Y    — in-season ELO (latest week per team)
#   /ppa/teams?year=Y      — efficiency: PPA, success rate, explosiveness, scheme splits
#   /stats/season?year=Y   — third-down rates, rush/pass attempts
#   /games?year=Y          — game results (regular + postseason)
#   /lines?year=Y          — posted spread + total (DK preferred)
#
# Coverage: 2013-2025 (PPA available from 2013). ~10 API calls/year × 13 years.
# Runtime: ~5-10 minutes (rate-limited to ~3 req/s).
#
# Output: clean/ml_training_data_2013_2025.csv
#   One row per completed FBS game with ratings, efficiency, context, and market data.
#   Used by ml_model_cfb.R to train XGBoost spread + total models.
# ==============================================================================

suppressMessages({
  library(tidyverse)
  library(httr)
  library(jsonlite)
})

setwd("G:/My Drive/Scripting Projects/cfb_project")
source("scripts/CONFIG.R")
source("scripts/TEAM_NAME_NORMALIZER_CFB.R")

TRAINING_YEARS  <- 2013:2025
API_SLEEP       <- 0.35     # seconds between requests (~3 req/s, well within CFBD limits)
OUTPUT_FILE     <- "clean/ml_training_data_2013_2025.csv"

master <- load_cfb_master()
creds  <- load_credentials()
api_key <- creds$cfbd_api_key
if (is.null(api_key) || nchar(api_key) < 10)
  stop("[ML DATA] cfbd_api_key missing in credentials.json")

cat(sprintf("\n========== CFB ML Training Data Builder | %d–%d ==========\n",
            min(TRAINING_YEARS), max(TRAINING_YEARS)))

# ── CFBD request helper ────────────────────────────────────────────────────────

cfbd_get <- function(endpoint, params = list()) {
  Sys.sleep(API_SLEEP)
  resp <- GET(
    paste0("https://api.collegefootballdata.com", endpoint),
    add_headers(Authorization = paste("Bearer", api_key)),
    query   = params,
    timeout(30)
  )
  if (http_error(resp))
    stop(sprintf("HTTP %d on %s", status_code(resp), endpoint))
  fromJSON(content(resp, "text", encoding = "UTF-8"), flatten = TRUE)
}

# ── Conference tier classification ─────────────────────────────────────────────

P4_CONFS <- c("SEC", "Big Ten", "Big 12", "ACC",
               "Pac-12", "Pac-10")   # Pac-12 was P5 through 2023

classify_conf_tier <- function(home_conf, away_conf) {
  home_p4 <- !is.na(home_conf) & home_conf %in% P4_CONFS
  away_p4 <- !is.na(away_conf) & away_conf %in% P4_CONFS
  case_when(
    home_p4 & away_p4   ~ 1L,   # P4 vs P4
    home_p4 | away_p4   ~ 0L,   # mixed
    TRUE                ~ 0L    # G5 vs G5
  )
}

# ── Scheme adjustment (mirrors get_scheme_adj() in GENERATE_PREDICTIONS_CFB.R) ─

compute_scheme_adj <- function(home_rush_rate, away_rush_rate,
                                home_def_rush_ppa, home_def_pass_ppa,
                                away_def_rush_ppa, away_def_pass_ppa,
                                scheme_w = 4.0, lg_rush = 0.0, lg_pass = 0.0,
                                lg_rr   = 0.42) {
  h_rr <- coalesce(home_rush_rate,   lg_rr)
  a_rr <- coalesce(away_rush_rate,   lg_rr)
  h_dr <- coalesce(home_def_rush_ppa, lg_rush)
  h_dp <- coalesce(home_def_pass_ppa, lg_pass)
  a_dr <- coalesce(away_def_rush_ppa, lg_rush)
  a_dp <- coalesce(away_def_pass_ppa, lg_pass)

  home_edge <- h_rr * (a_dr - lg_rush) + (1 - h_rr) * (a_dp - lg_pass)
  away_edge <- a_rr * (h_dr - lg_rush) + (1 - a_rr) * (h_dp - lg_pass)
  (home_edge - away_edge) * scheme_w
}

# ── FCS team filter — same list used in BACKTEST_2025.R ───────────────────────

FCS_FILTER_TERMS <- c(
  "nationalAverages", "Missouri State", "Delaware",
  "North Dakota State", "South Dakota State", "Montana",
  "Montana State", "Villanova", "Youngstown State",
  "Eastern Washington", "Sacramento State", "Northern Iowa",
  "James Madison", "Liberty", "Sam Houston State", "Jacksonville State",
  "Kennesaw State", "UAB"   # UAB left/re-joined FBS mid-period
)

# ── Per-year data pull ─────────────────────────────────────────────────────────

pull_season <- function(yr) {
  cat(sprintf("\n── Season %d ──\n", yr))
  sp_yr <- yr - 1L   # prior-year final SP+ as preseason proxy

  # 1. SP+ (prior year) --------------------------------------------------------
  sp <- tryCatch({
    raw <- cfbd_get("/ratings/sp", list(year = sp_yr))
    as_tibble(raw) %>%
      transmute(
        canonical_name = normalize_team_name(team, mappings = master,
                                              source_col    = "massey_name",
                                              unmatched_log = "logs/unmatched_teams.csv"),
        sp_overall     = as.numeric(rating),
        sp_offense     = as.numeric(offense.rating),
        sp_defense     = as.numeric(defense.rating)
      ) %>%
      filter(!is.na(canonical_name))
  }, error = function(e) {
    warning(sprintf("[%d] SP+ failed: %s", yr, e$message)); tibble()
  })
  cat(sprintf("  SP+ (%d): %d teams\n", sp_yr, nrow(sp)))

  # 2. ELO (current year, latest week) ----------------------------------------
  elo <- tryCatch({
    raw <- cfbd_get("/ratings/elo", list(year = yr))
    as_tibble(raw) %>%
      group_by(team) %>%
      slice_tail(n = 1) %>%
      ungroup() %>%
      transmute(
        canonical_name = normalize_team_name(team, mappings = master,
                                              source_col    = "massey_name",
                                              unmatched_log = "logs/unmatched_teams.csv"),
        elo_rating     = as.numeric(elo)
      ) %>%
      filter(!is.na(canonical_name))
  }, error = function(e) {
    warning(sprintf("[%d] ELO failed: %s", yr, e$message)); tibble()
  })
  cat(sprintf("  ELO: %d teams\n", nrow(elo)))

  # 3. PPA (current year) -------------------------------------------------------
  ppa <- tryCatch({
    raw <- cfbd_get("/ppa/teams", list(year = yr, excludeGarbageTime = "true"))
    tbl <- as_tibble(raw)
    get_col <- function(df, ...) {
      for (nm in c(...)) if (nm %in% names(df)) return(df[[nm]])
      NA_real_
    }
    tbl %>%
      transmute(
        canonical_name    = normalize_team_name(team, mappings = master,
                                                 source_col    = "massey_name",
                                                 unmatched_log = "logs/unmatched_teams.csv"),
        off_ppa           = as.numeric(get_col(tbl, "offense.overall",        "offenseOverall")),
        def_ppa           = as.numeric(get_col(tbl, "defense.overall",        "defenseOverall")),
        off_success_rate  = as.numeric(get_col(tbl, "offense.success",        "offenseSuccess")),
        def_success_rate  = as.numeric(get_col(tbl, "defense.success",        "defenseSuccess")),
        off_explosiveness = as.numeric(get_col(tbl, "offense.explosiveness",  "offenseExplosiveness")),
        off_rush_ppa      = as.numeric(get_col(tbl, "offense.rushing",        "offenseRushing")),
        off_pass_ppa      = as.numeric(get_col(tbl, "offense.passing",        "offensePassing")),
        def_rush_ppa      = as.numeric(get_col(tbl, "defense.rushing",        "defenseRushing")),
        def_pass_ppa      = as.numeric(get_col(tbl, "defense.passing",        "defensePassing"))
      ) %>%
      filter(!is.na(canonical_name))
  }, error = function(e) {
    warning(sprintf("[%d] PPA failed: %s", yr, e$message)); tibble()
  })
  cat(sprintf("  PPA: %d teams\n", nrow(ppa)))

  # 4. Season stats (third-down rate, rush rate) --------------------------------
  stats <- tryCatch({
    raw  <- cfbd_get("/stats/season", list(year = yr))
    tbl  <- as_tibble(raw)
    if (!all(c("statName", "statValue", "team") %in% names(tbl))) stop("unexpected format")
    tbl %>%
      filter(statName %in% c("thirdDownConversions", "thirdDowns",
                               "rushingAttempts",     "passAttempts")) %>%
      select(team, statName, statValue) %>%
      pivot_wider(names_from = statName, values_from = statValue, values_fn = first) %>%
      filter(!is.na(thirdDowns), as.numeric(thirdDowns) > 0) %>%
      mutate(
        canonical_name  = normalize_team_name(team, mappings = master,
                                               source_col    = "massey_name",
                                               unmatched_log = "logs/unmatched_teams.csv"),
        third_down_rate = as.numeric(thirdDownConversions) /
                            pmax(as.numeric(thirdDowns), 1L),
        rush_att        = suppressWarnings(as.numeric(rushingAttempts)),
        pass_att        = suppressWarnings(as.numeric(passAttempts)),
        rush_rate       = if_else(
          !is.na(rush_att) & !is.na(pass_att) & (rush_att + pass_att) > 0,
          rush_att / (rush_att + pass_att), NA_real_)
      ) %>%
      filter(!is.na(canonical_name)) %>%
      select(canonical_name, third_down_rate, rush_rate)
  }, error = function(e) {
    warning(sprintf("[%d] Stats failed: %s", yr, e$message)); tibble()
  })
  cat(sprintf("  Season stats: %d teams\n", nrow(stats)))

  # 5. Game results (regular + postseason) --------------------------------------
  pull_games_yr <- function(season_type) {
    tryCatch({
      raw <- cfbd_get("/games", list(year = yr, seasonType = season_type,
                                     division = "fbs"))
      if (length(raw) == 0) return(NULL)
      tbl <- as_tibble(raw)
      # Normalise column names across API versions
      rename_map <- c(homePoints    = "home_points",  awayPoints    = "away_points",
                      homeTeam      = "home_team",     awayTeam      = "away_team",
                      homeConference= "home_conference", awayConference= "away_conference",
                      neutralSite   = "neutral_site",  seasonType    = "season_type",
                      "home.points" = "home_points",   "away.points" = "away_points",
                      "home.team"   = "home_team",     "away.team"   = "away_team")
      for (old in names(rename_map)) {
        if (old %in% names(tbl)) names(tbl)[names(tbl) == old] <- rename_map[[old]]
      }
      tbl
    }, error = function(e) { warning(sprintf("[%d] %s games: %s", yr, season_type, e$message)); NULL })
  }

  games_raw <- bind_rows(pull_games_yr("regular"), pull_games_yr("postseason"))
  if (is.null(games_raw) || nrow(games_raw) == 0) {
    warning(sprintf("[%d] No game results — skipping year.", yr)); return(NULL)
  }

  games <- games_raw %>%
    filter(!is.na(home_points), !is.na(away_points)) %>%
    filter(!home_team %in% FCS_FILTER_TERMS, !away_team %in% FCS_FILTER_TERMS) %>%
    transmute(
      season         = yr,
      game_id        = as.character(id),
      week           = as.integer(week),
      season_type    = season_type,
      neutral_site   = as.integer(as.logical(neutral_site)),
      home_team_raw  = home_team,
      away_team_raw  = away_team,
      home_conf      = home_conference,
      away_conf      = away_conference,
      home_score     = as.integer(home_points),
      away_score     = as.integer(away_points),
      actual_margin  = home_score - away_score,
      actual_total   = home_score + away_score
    ) %>%
    mutate(
      canonical_home = normalize_team_name(home_team_raw, mappings = master,
                                            source_col    = "massey_name",
                                            unmatched_log = "logs/unmatched_teams.csv"),
      canonical_away = normalize_team_name(away_team_raw, mappings = master,
                                            source_col    = "massey_name",
                                            unmatched_log = "logs/unmatched_teams.csv"),
      is_postseason  = as.integer(season_type == "postseason"),
      conf_tier      = classify_conf_tier(home_conf, away_conf)
    ) %>%
    filter(!is.na(canonical_home), !is.na(canonical_away))

  cat(sprintf("  Games: %d completed FBS games\n", nrow(games)))

  # 6. Betting lines (posted spread + total) ------------------------------------
  lines <- tryCatch({
    raw  <- cfbd_get("/lines", list(year = yr))
    tbl  <- as_tibble(raw)
    extract_spread <- function(ll) {
      if (is.null(ll) || length(ll) == 0) return(NA_real_)
      if (!is.data.frame(ll)) return(NA_real_)
      for (prov in c("DraftKings", "Caesars", "consensus", "ESPN Bet")) {
        row <- ll[tolower(ll$provider) == tolower(prov), ]
        if (nrow(row) > 0 && !is.na(as.numeric(row$spread[1])))
          return(as.numeric(row$spread[1]))
      }
      non_na <- suppressWarnings(as.numeric(ll$spread[!is.na(ll$spread)]))
      if (length(non_na) > 0) non_na[1] else NA_real_
    }
    extract_total <- function(ll) {
      if (is.null(ll) || !is.data.frame(ll)) return(NA_real_)
      vals <- suppressWarnings(as.numeric(ll$overUnder))
      non_na <- vals[!is.na(vals)]
      if (length(non_na) > 0) non_na[1] else NA_real_
    }
    tbl %>%
      mutate(game_id      = as.character(id),
             posted_spread = map_dbl(lines, extract_spread),
             posted_total  = map_dbl(lines, extract_total)) %>%
      select(game_id, posted_spread, posted_total)
  }, error = function(e) {
    warning(sprintf("[%d] Lines failed: %s", yr, e$message))
    tibble(game_id = character(0), posted_spread = numeric(0), posted_total = numeric(0))
  })
  cat(sprintf("  Lines: %d games | %.0f%% have spread\n",
              nrow(lines), 100 * mean(!is.na(lines$posted_spread))))

  # 7. Join everything into one row per game ------------------------------------

  # HFA from MASTER
  hfa_lu <- master %>%
    select(canonical_name, hfa_pts) %>%
    filter(!is.na(hfa_pts))
  DEFAULT_HFA <- 2.5

  sp_sd  <- if (nrow(sp)  > 1) sd(sp$sp_overall,   na.rm = TRUE) else 10.0
  elo_sd <- if (nrow(elo) > 0) sd(elo$elo_rating,   na.rm = TRUE) else 100.0

  joined <- games %>%
    # SP+ ratings
    left_join(sp  %>% select(canonical_name, home_sp = sp_overall,
                               home_sp_off = sp_offense, home_sp_def = sp_defense),
              by = c("canonical_home" = "canonical_name")) %>%
    left_join(sp  %>% select(canonical_name, away_sp = sp_overall,
                               away_sp_off = sp_offense, away_sp_def = sp_defense),
              by = c("canonical_away" = "canonical_name")) %>%
    # ELO ratings
    left_join(elo %>% select(canonical_name, home_elo = elo_rating),
              by = c("canonical_home" = "canonical_name")) %>%
    left_join(elo %>% select(canonical_name, away_elo = elo_rating),
              by = c("canonical_away" = "canonical_name")) %>%
    # PPA / efficiency
    left_join(ppa %>% select(canonical_name,
                               home_off_ppa = off_ppa,       home_def_ppa = def_ppa,
                               home_off_succ = off_success_rate, home_def_succ = def_success_rate,
                               home_off_expl = off_explosiveness,
                               home_off_rush = off_rush_ppa, home_off_pass = off_pass_ppa,
                               home_def_rush = def_rush_ppa, home_def_pass = def_pass_ppa),
              by = c("canonical_home" = "canonical_name")) %>%
    left_join(ppa %>% select(canonical_name,
                               away_off_ppa = off_ppa,       away_def_ppa = def_ppa,
                               away_off_succ = off_success_rate, away_def_succ = def_success_rate,
                               away_off_expl = off_explosiveness,
                               away_off_rush = off_rush_ppa, away_off_pass = off_pass_ppa,
                               away_def_rush = def_rush_ppa, away_def_pass = def_pass_ppa),
              by = c("canonical_away" = "canonical_name")) %>%
    # Season stats
    left_join(stats %>% select(canonical_name, home_3d = third_down_rate,
                                 home_rush_rate = rush_rate),
              by = c("canonical_home" = "canonical_name")) %>%
    left_join(stats %>% select(canonical_name, away_3d = third_down_rate,
                                 away_rush_rate = rush_rate),
              by = c("canonical_away" = "canonical_name")) %>%
    # HFA
    left_join(hfa_lu %>% select(canonical_name, home_hfa = hfa_pts),
              by = c("canonical_home" = "canonical_name")) %>%
    # Lines
    left_join(lines, by = "game_id") %>%
    # Derived features
    mutate(
      sp_diff           = coalesce(home_sp - away_sp,    0),
      elo_diff          = coalesce(home_elo - away_elo,  0),
      elo_diff_scaled   = elo_diff / elo_sd * sp_sd,
      rating_diff_blend = WEIGHT_SP_PLUS / (WEIGHT_SP_PLUS + WEIGHT_ELO) * sp_diff +
                          WEIGHT_ELO    / (WEIGHT_SP_PLUS + WEIGHT_ELO) * elo_diff_scaled,
      ppa_diff          = (coalesce(home_off_ppa,  0) - coalesce(away_def_ppa,  0)) -
                          (coalesce(away_off_ppa,  0) - coalesce(home_def_ppa,  0)),
      success_rate_diff = (coalesce(home_off_succ, 0) - coalesce(away_def_succ, 0)) -
                          (coalesce(away_off_succ, 0) - coalesce(home_def_succ, 0)),
      expl_diff         = coalesce(home_off_expl - away_off_expl, 0),
      rush_rate_diff    = coalesce(home_rush_rate - away_rush_rate, 0),
      third_down_diff   = coalesce(home_3d - away_3d, 0),
      effective_hfa     = if_else(neutral_site == 1L, 0,
                                   coalesce(home_hfa, DEFAULT_HFA)),
      scheme_adj        = pmap_dbl(
        list(home_rush_rate, away_rush_rate,
             home_def_rush,  home_def_pass,
             away_def_rush,  away_def_pass),
        compute_scheme_adj
      )
    ) %>%
    # Keep only rows with ratings and a posted spread (ML needs a market prior)
    filter(!is.na(sp_diff), !is.na(posted_spread)) %>%
    select(
      season, game_id, week, is_postseason, neutral_site, conf_tier,
      canonical_home, canonical_away, home_conf, away_conf,
      home_score, away_score, actual_margin, actual_total,
      posted_spread, posted_total,
      sp_diff, elo_diff_scaled, rating_diff_blend,
      ppa_diff, success_rate_diff, expl_diff,
      rush_rate_diff, third_down_diff, scheme_adj,
      effective_hfa,
      home_sp, away_sp, home_elo, away_elo
    )

  cat(sprintf("  Final: %d rows with ratings + spread (%.0f%% of games)\n",
              nrow(joined),
              100 * nrow(joined) / max(nrow(games), 1)))
  joined
}

# ── Run all years ──────────────────────────────────────────────────────────────

all_seasons <- map(TRAINING_YEARS, function(yr) {
  tryCatch(pull_season(yr), error = function(e) {
    warning(sprintf("[%d] Season pull failed: %s", yr, e$message)); NULL
  })
}) %>%
  compact() %>%
  bind_rows()

cat(sprintf("\n\n=== COMPLETE ===\n"))
cat(sprintf("Total rows: %d games across %d seasons\n",
            nrow(all_seasons), n_distinct(all_seasons$season)))
cat(sprintf("Seasons: %s\n", paste(sort(unique(all_seasons$season)), collapse = ", ")))
cat(sprintf("Posted spread coverage: %.1f%%\n",
            100 * mean(!is.na(all_seasons$posted_spread))))
cat(sprintf("PPA coverage: %.1f%%\n",
            100 * mean(all_seasons$ppa_diff != 0, na.rm = TRUE)))

by_season <- all_seasons %>%
  group_by(season) %>%
  summarise(n = n(), pct_spread = round(100 * mean(!is.na(posted_spread)), 1),
            .groups = "drop")
print(by_season, n = 20)

# ── Write output ───────────────────────────────────────────────────────────────

dir.create("clean", showWarnings = FALSE)
write_csv(all_seasons, OUTPUT_FILE)
cat(sprintf("\nSaved → %s\n", OUTPUT_FILE))
