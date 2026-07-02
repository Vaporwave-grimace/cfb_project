# ==============================================================================
# TEAM_METRICS.R — Advanced Team Metrics (PPA, Success Rate, Explosiveness)
# Pipeline Step 6
#
# PURPOSE:
#   Fetch advanced efficiency metrics from CFBD /stats/season/advanced and join
#   with the basic team stats (third-down rate, red zone rate) already written
#   by SCRAPE_CFB_DATA.R (Step 4). Produces an enriched team_metrics tibble
#   used by GENERATE_PREDICTIONS_CFB.R and CALCULATE_VALUE_CFB.R.
#
# INPUTS:
#   CFBD API  /stats/season/advanced?year=YYYY&seasonType=regular
#   clean/cfb_team_stats_YYYY.csv  (written by SCRAPE_CFB_DATA.R Step 4)
#
# OUTPUT:
#   clean/cfb_team_stats_YYYY.csv  — overwritten; now includes PPA columns
#   team_metrics                   — tibble assigned to .GlobalEnv
#
# KEY COLUMNS:
#   canonical_name, off_ppa, def_ppa,
#   off_success_rate, def_success_rate,
#   off_explosiveness, def_explosiveness,
#   third_down_rate, red_zone_rate
#
# RUN:
#   Rscript scripts/TEAM_METRICS.R
#   — or source("scripts/TEAM_METRICS.R") after SCRAPE_CFB_DATA.R has run
#
# NOTES:
#   def_ppa sign convention: negative = good defense (opponent below avg EPA/play)
#   off_explosiveness: average PPA on successful plays (higher = more explosive)
#   Requires credentials.json with cfbd_api_key at project root.
# ==============================================================================

suppressMessages({
  library(tidyverse)
  library(httr)
  library(jsonlite)
})

# Working directory guard — RStudio vs. Rscript
if (!exists(".tm_wd_set")) {
  args <- commandArgs(trailingOnly = FALSE)
  script_path <- sub("--file=", "", args[grep("--file=", args)])
  if (length(script_path) > 0) {
    setwd(dirname(dirname(normalizePath(script_path))))
  }
  .tm_wd_set <- TRUE
}

source("scripts/CONFIG.R")
source("scripts/TEAM_NAME_NORMALIZER_CFB.R")

# ==============================================================================
# 1. CFBD API helper (mirrors SCRAPE_CFB_DATA.R — kept local to stay standalone)
# ==============================================================================

.cfbd_get <- function(endpoint, params = list(), api_key) {
  url  <- paste0("https://api.collegefootballdata.com", endpoint)
  resp <- GET(url,
              add_headers(Authorization = paste("Bearer", api_key)),
              query = params,
              timeout(30))

  if (http_error(resp)) {
    stop(sprintf("[TEAM_METRICS] HTTP %d on %s: %s",
                 status_code(resp), endpoint,
                 content(resp, "text", encoding = "UTF-8")))
  }
  fromJSON(content(resp, "text", encoding = "UTF-8"), flatten = TRUE)
}

# ==============================================================================
# 2. Fetch advanced stats from /stats/season/advanced
#    Returns a tidy tibble keyed on canonical_name.
#
#    CFBD response shape (after flatten = TRUE):
#      team, conference, season,
#      offense.ppa, offense.successRate, offense.explosiveness,
#      offense.powerSuccess, offense.stuffRate,
#      defense.ppa, defense.successRate, defense.explosiveness, ...
# ==============================================================================

fetch_advanced_stats <- function(api_key, year, master) {
  cat(sprintf("[TEAM_METRICS] Fetching /stats/season/advanced for %d...\n", year))

  raw <- .cfbd_get(
    "/stats/season/advanced",
    params  = list(year = year, seasonType = "regular"),
    api_key = api_key
  )

  if (length(raw) == 0 || nrow(as.data.frame(raw)) == 0) {
    warning("[TEAM_METRICS] /stats/season/advanced returned empty — check year or API key.")
    return(NULL)
  }

  df <- as_tibble(raw)

  # ── column existence guards ─────────────────────────────────────────────────
  # CFBD occasionally omits columns mid-season; coalesce to NA if absent.
  safe_col <- function(df, col) {
    if (col %in% names(df)) df[[col]] else rep(NA_real_, nrow(df))
  }

  df <- df %>%
    transmute(
      team_raw          = team,
      year              = as.integer(year),
      # Offense
      off_ppa           = as.numeric(safe_col(df, "offense.ppa")),
      off_success_rate  = as.numeric(safe_col(df, "offense.successRate")),
      off_explosiveness = as.numeric(safe_col(df, "offense.explosiveness")),
      off_power_success = as.numeric(safe_col(df, "offense.powerSuccess")),
      off_stuff_rate    = as.numeric(safe_col(df, "offense.stuffRate")),
      off_line_yards    = as.numeric(safe_col(df, "offense.lineYards")),
      # Defense (negative ppa = good defense)
      def_ppa              = as.numeric(safe_col(df, "defense.ppa")),
      def_success_rate     = as.numeric(safe_col(df, "defense.successRate")),
      def_explosiveness    = as.numeric(safe_col(df, "defense.explosiveness")),
      def_power_success    = as.numeric(safe_col(df, "defense.powerSuccess")),
      def_stuff_rate       = as.numeric(safe_col(df, "defense.stuffRate")),
      def_line_yards       = as.numeric(safe_col(df, "defense.lineYards")),
      # Havoc: sacks + TFLs + PBUs per total plays — disruptive D-line signal
      def_havoc_total      = as.numeric(safe_col(df, "defense.havoc.total")),
      def_havoc_front_seven = as.numeric(safe_col(df, "defense.havoc.frontSeven")),
      def_havoc_db         = as.numeric(safe_col(df, "defense.havoc.db"))
    ) %>%
    mutate(
      canonical_name = normalize_team_name(
        team_raw,
        mappings      = master,
        source_col    = "massey_name",
        unmatched_log = "logs/unmatched_teams.csv"
      )
    ) %>%
    filter(!is.na(canonical_name)) %>%
    select(-team_raw)

  cat(sprintf("[TEAM_METRICS] Advanced stats parsed: %d FBS teams.\n", nrow(df)))
  df
}

# ==============================================================================
# 3. Fetch talent composite from /teams/talent
#    Returns canonical_name + talent_score (raw) + talent_norm (normalized)
#
#    CFBD response: [ { team: "Alabama", year: 2025, talent: 1089.46 }, ... ]
#    Normalization: (raw - TALENT_NORM_BASE) / 100
#      Alabama (~1100) → +2.0 | avg P4 (~950) → +0.5 | avg G5 (~800) → -1.0
# ==============================================================================

fetch_talent <- function(api_key, year, master) {
  cat(sprintf("[TEAM_METRICS] Fetching /teams/talent for %d...\n", year))

  raw <- tryCatch(
    .cfbd_get("/teams/talent", params = list(year = year), api_key = api_key),
    error = function(e) {
      warning(sprintf("[TEAM_METRICS] /teams/talent fetch failed (non-fatal): %s", e$message))
      NULL
    }
  )

  if (is.null(raw) || length(raw) == 0) {
    warning("[TEAM_METRICS] /teams/talent returned empty — talent_norm will be NA.")
    return(NULL)
  }

  norm_base <- if (exists("TALENT_NORM_BASE")) TALENT_NORM_BASE else 900

  df <- as_tibble(raw) %>%
    transmute(
      team_raw     = team,
      talent_score = as.numeric(talent),
      talent_norm  = (talent_score - norm_base) / 100
    ) %>%
    mutate(
      canonical_name = normalize_team_name(
        team_raw,
        mappings      = master,
        source_col    = "massey_name",
        unmatched_log = "logs/unmatched_teams.csv"
      )
    ) %>%
    filter(!is.na(canonical_name)) %>%
    select(-team_raw)

  cat(sprintf("[TEAM_METRICS] Talent composite: %d teams | range [%.1f, %.1f] (raw)\n",
              nrow(df),
              min(df$talent_score, na.rm = TRUE),
              max(df$talent_score, na.rm = TRUE)))
  df
}

# ==============================================================================
# 4. Fetch returning production from /returning
#    Returns canonical_name + returning_pct + retention_score
#
#    CFBD response fields (after flatten):
#      team, conference, season, percentPPA, percentPassingPPA,
#      percentRushingPPA, percentReceivingPPA, usage, ...
#
#    retention_score tiers (from CONFIG.R thresholds):
#      percentPPA ≥ RETENTION_HIGH_PCT → 1.00
#      RETENTION_LOW_PCT ... HIGH       → linear interpolation
#      percentPPA < RETENTION_LOW_PCT  → RETENTION_SCALAR_MIN
# ==============================================================================

fetch_returning_production <- function(api_key, year, master) {
  cat(sprintf("[TEAM_METRICS] Fetching /returning for %d...\n", year))

  raw <- tryCatch(
    .cfbd_get("/returning", params = list(year = year), api_key = api_key),
    error = function(e) {
      warning(sprintf("[TEAM_METRICS] /returning fetch failed (non-fatal): %s", e$message))
      NULL
    }
  )

  if (is.null(raw) || length(raw) == 0) {
    warning("[TEAM_METRICS] /returning returned empty — retention_score will be NA.")
    return(NULL)
  }

  # Load retention thresholds from CONFIG (with safe fallbacks)
  ret_high  <- if (exists("RETENTION_HIGH_PCT"))   RETENTION_HIGH_PCT   else 0.65
  ret_low   <- if (exists("RETENTION_LOW_PCT"))    RETENTION_LOW_PCT    else 0.50
  ret_min   <- if (exists("RETENTION_SCALAR_MIN")) RETENTION_SCALAR_MIN else 0.80

  df <- as_tibble(raw) %>%
    mutate(
      # CFBD returns percentPPA as a decimal (0–1 scale) or percent (0–100).
      # Handle both: if max > 1, assume it's on a percent scale.
      pct_raw = as.numeric(percentPPA),
      returning_pct = if_else(max(pct_raw, na.rm = TRUE) > 1,
                               pct_raw / 100, pct_raw)
    ) %>%
    transmute(
      team_raw      = team,
      returning_pct = returning_pct,
      retention_score = case_when(
        is.na(returning_pct)           ~ 1.00,   # unknown → no penalty
        returning_pct >= ret_high      ~ 1.00,
        returning_pct >= ret_low       ~ ret_min + (returning_pct - ret_low) /
                                          (ret_high - ret_low) * (1.00 - ret_min),
        TRUE                           ~ ret_min
      )
    ) %>%
    mutate(
      canonical_name = normalize_team_name(
        team_raw,
        mappings      = master,
        source_col    = "massey_name",
        unmatched_log = "logs/unmatched_teams.csv"
      )
    ) %>%
    filter(!is.na(canonical_name)) %>%
    select(-team_raw)

  n_low <- sum(df$retention_score < 1.00, na.rm = TRUE)
  cat(sprintf("[TEAM_METRICS] Returning production: %d teams | %d flagged with retention_score < 1.0\n",
              nrow(df), n_low))
  df
}

# ==============================================================================
# 5. Fetch play-type PPA splits from /ppa/teams
#    Returns: canonical_name, off_rush_ppa, off_pass_ppa, def_rush_ppa, def_pass_ppa
#    Used by get_scheme_adj() in GENERATE_PREDICTIONS_CFB.R
#    Non-fatal: returns NULL on API error; columns will be NA in team_metrics
# ==============================================================================

fetch_ppa_teams <- function(api_key, year, master) {
  cat(sprintf("[TEAM_METRICS] Fetching /ppa/teams for %d...\n", year))

  raw <- tryCatch(
    .cfbd_get("/ppa/teams",
              params  = list(year = year, seasonType = "regular"),
              api_key = api_key),
    error = function(e) {
      warning(sprintf("[TEAM_METRICS] /ppa/teams fetch failed (non-fatal): %s", e$message))
      NULL
    }
  )

  if (is.null(raw) || length(raw) == 0) {
    warning("[TEAM_METRICS] /ppa/teams returned empty — scheme cols will be NA.")
    return(NULL)
  }

  df <- as_tibble(raw)

  # After flatten=TRUE: offense.rushing, offense.passing, defense.rushing, defense.passing
  safe_col <- function(df, col) if (col %in% names(df)) df[[col]] else rep(NA_real_, nrow(df))

  df <- df %>%
    transmute(
      team_raw     = team,
      off_rush_ppa = as.numeric(safe_col(df, "offense.rushing")),
      off_pass_ppa = as.numeric(safe_col(df, "offense.passing")),
      def_rush_ppa = as.numeric(safe_col(df, "defense.rushing")),
      def_pass_ppa = as.numeric(safe_col(df, "defense.passing"))
    ) %>%
    mutate(
      canonical_name = normalize_team_name(
        team_raw,
        mappings      = master,
        source_col    = "massey_name",
        unmatched_log = "logs/unmatched_teams.csv"
      )
    ) %>%
    filter(!is.na(canonical_name)) %>%
    select(-team_raw)

  cat(sprintf("[TEAM_METRICS] PPA play-type splits: %d teams | off_rush [%.3f,%.3f] | def_rush [%.3f,%.3f]\n",
              nrow(df),
              min(df$off_rush_ppa, na.rm = TRUE), max(df$off_rush_ppa, na.rm = TRUE),
              min(df$def_rush_ppa, na.rm = TRUE), max(df$def_rush_ppa, na.rm = TRUE)))
  df
}

# ==============================================================================
# 6. Load basic stats (third_down_rate + rush_rate) from SCRAPE_CFB_DATA.R
#    output. Falls back gracefully if file is missing.
# ==============================================================================

load_basic_stats <- function(year) {
  path <- sprintf("clean/cfb_team_stats_%d.csv", year)

  if (!file.exists(path)) {
    warning(sprintf("[TEAM_METRICS] %s not found — run SCRAPE_CFB_DATA.R first. ", path),
            "third_down_rate and rush_rate will be NA.")
    return(NULL)
  }

  df <- read_csv(path, show_col_types = FALSE)
  cat(sprintf("[TEAM_METRICS] Loaded basic stats: %d teams from %s.\n", nrow(df), path))

  # Keep only the columns we need for the join.
  # rushingAttempts + passAttempts → rush_rate (consumed by get_scheme_adj()).
  # red_zone_rate excluded — not available from CFBD /stats/season endpoint.
  keep <- intersect(
    c("canonical_name", "year", "third_down_rate",
      "pointsPerGame", "yardsPerPlay", "turnovers", "turnover_margin",
      "pass_completion_rate", "sacksOpponent",
      "rushingAttempts", "passAttempts"),
    names(df)
  )
  out <- select(df, all_of(keep))

  if (all(c("rushingAttempts", "passAttempts") %in% names(out))) {
    out <- out %>%
      mutate(
        rush_rate = as.numeric(rushingAttempts) /
                    (as.numeric(rushingAttempts) + as.numeric(passAttempts)),
        rush_rate = if_else(!is.finite(rush_rate), NA_real_, rush_rate)
      ) %>%
      select(-rushingAttempts, -passAttempts)
  }

  out
}

# ==============================================================================
# 4. Build team_metrics — joins advanced + basic, writes enriched CSV
# ==============================================================================

build_team_metrics <- function(year = NULL, master = NULL) {

  if (is.null(year)) {
    yr <- as.integer(format(Sys.Date(), "%Y"))
    mo <- as.integer(format(Sys.Date(), "%m"))
    year <- if (mo < 7) yr - 1L else yr
  }

  # ── credentials ─────────────────────────────────────────────────────────────
  creds   <- load_credentials()
  api_key <- creds$cfbd_api_key
  if (is.null(api_key) || nchar(api_key) < 10) {
    stop("[TEAM_METRICS] cfbd_api_key missing or too short in credentials.json")
  }

  # ── master team mappings ─────────────────────────────────────────────────────
  if (is.null(master)) {
    master <- if (exists("master_cfb", envir = .GlobalEnv)) {
      get("master_cfb", envir = .GlobalEnv)
    } else {
      load_cfb_master("team_name_mappings_MASTER_CFB.csv")
    }
  }

  # ── fetch advanced metrics ───────────────────────────────────────────────────
  adv <- fetch_advanced_stats(api_key = api_key, year = year, master = master)
  if (is.null(adv)) {
    stop("[TEAM_METRICS] Advanced stats fetch failed — cannot build team_metrics.")
  }

  # ── fetch talent composite (non-fatal) ──────────────────────────────────────
  talent_df <- tryCatch(
    fetch_talent(api_key = api_key, year = year, master = master),
    error = function(e) {
      warning(sprintf("[TEAM_METRICS] fetch_talent() error (non-fatal): %s", e$message))
      NULL
    }
  )

  # ── fetch returning production (non-fatal) ──────────────────────────────────
  returning_df <- tryCatch(
    fetch_returning_production(api_key = api_key, year = year, master = master),
    error = function(e) {
      warning(sprintf("[TEAM_METRICS] fetch_returning_production() error (non-fatal): %s", e$message))
      NULL
    }
  )

  # ── fetch play-type PPA splits (non-fatal) ───────────────────────────────────
  ppa_teams_df <- tryCatch(
    fetch_ppa_teams(api_key = api_key, year = year, master = master),
    error = function(e) {
      warning(sprintf("[TEAM_METRICS] fetch_ppa_teams() error (non-fatal): %s", e$message))
      NULL
    }
  )

  # ── load basic stats (third-down, rush_rate) ─────────────────────────────────
  basic <- load_basic_stats(year)

  # ── join: basic stats ────────────────────────────────────────────────────────
  if (!is.null(basic)) {
    # Basic stats file may have a year column — drop it before join to avoid .x/.y
    if ("year" %in% names(basic)) basic <- select(basic, -year)

    metrics <- adv %>%
      left_join(basic, by = "canonical_name")
  } else {
    metrics <- adv %>%
      mutate(third_down_rate = NA_real_,
             red_zone_rate   = NA_real_)
  }

  # ── join: talent composite (non-fatal left join) ─────────────────────────────
  if (!is.null(talent_df)) {
    metrics <- metrics %>% left_join(talent_df, by = "canonical_name")
  } else {
    metrics <- metrics %>%
      mutate(talent_score = NA_real_, talent_norm = NA_real_)
  }

  # ── join: returning production (non-fatal left join) ─────────────────────────
  if (!is.null(returning_df)) {
    metrics <- metrics %>% left_join(returning_df, by = "canonical_name")
  } else {
    metrics <- metrics %>%
      mutate(returning_pct = NA_real_, retention_score = NA_real_)
  }

  # ── join: play-type PPA splits (non-fatal left join) ─────────────────────────
  if (!is.null(ppa_teams_df)) {
    metrics <- metrics %>% left_join(ppa_teams_df, by = "canonical_name")
  } else {
    metrics <- metrics %>%
      mutate(off_rush_ppa = NA_real_, off_pass_ppa = NA_real_,
             def_rush_ppa = NA_real_, def_pass_ppa = NA_real_)
  }

  # ── column ordering: key columns first ──────────────────────────────────────
  priority_cols <- c(
    "year", "canonical_name",
    "off_ppa", "def_ppa",
    "off_rush_ppa", "off_pass_ppa",
    "def_rush_ppa", "def_pass_ppa",
    "rush_rate",
    "off_success_rate", "def_success_rate",
    "off_explosiveness", "def_explosiveness",
    "talent_score", "talent_norm",
    "returning_pct", "retention_score",
    "third_down_rate", "red_zone_rate",
    "off_power_success", "def_power_success",
    "off_stuff_rate", "def_stuff_rate",
    "off_line_yards", "def_line_yards",
    "def_havoc_total", "def_havoc_front_seven", "def_havoc_db",
    "pointsPerGame", "yardsPerPlay", "turnovers"
  )
  remaining <- setdiff(names(metrics), priority_cols)
  metrics   <- select(metrics, any_of(priority_cols), any_of(remaining))

  # ── validation report ────────────────────────────────────────────────────────
  # Core 5: from /stats/season/advanced — always populated when API responds
  # Supplemental 1: third_down_rate from /stats/season basic CSV
  #   red_zone_rate omitted — redZoneAttempts/redZoneScores absent from CFBD endpoint
  core_cols <- c("off_ppa", "def_ppa", "off_success_rate",
                 "def_success_rate", "off_explosiveness")
  supp_cols <- c("third_down_rate")

  n_core_complete <- sum(complete.cases(select(metrics, all_of(core_cols))))
  n_full_complete <- sum(complete.cases(select(metrics, all_of(c(core_cols, supp_cols)))))

  # Per-column NA counts for transparency
  na_counts <- metrics %>%
    select(all_of(c(core_cols, supp_cols))) %>%
    summarise(across(everything(), ~sum(is.na(.)))) %>%
    pivot_longer(everything(), names_to = "col", values_to = "n_NA")

  n_talent    <- sum(!is.na(metrics$talent_norm))
  n_retention <- sum(!is.na(metrics$retention_score))

  cat(sprintf("\n[TEAM_METRICS] === Build Summary (%d) ===\n", year))
  cat(sprintf("  Teams total                 : %d\n", nrow(metrics)))
  cat(sprintf("  Core complete (5 advanced)  : %d\n", n_core_complete))
  cat(sprintf("  Fully complete (+ 3rd/RZ)   : %d\n", n_full_complete))
  cat(sprintf("  Talent composite            : %d teams with talent_norm\n", n_talent))
  cat(sprintf("  Returning production        : %d teams with retention_score\n", n_retention))
  cat(sprintf("  off_ppa        range : [%.3f, %.3f]\n",
              min(metrics$off_ppa, na.rm = TRUE),
              max(metrics$off_ppa, na.rm = TRUE)))
  cat(sprintf("  def_ppa        range : [%.3f, %.3f]\n",
              min(metrics$def_ppa, na.rm = TRUE),
              max(metrics$def_ppa, na.rm = TRUE)))
  cat(sprintf("  off_succ_rate  range : [%.3f, %.3f]\n",
              min(metrics$off_success_rate, na.rm = TRUE),
              max(metrics$off_success_rate, na.rm = TRUE)))
  cat(sprintf("  def_succ_rate  range : [%.3f, %.3f]\n",
              min(metrics$def_success_rate, na.rm = TRUE),
              max(metrics$def_success_rate, na.rm = TRUE)))
  cat(sprintf("  off_explsv     range : [%.3f, %.3f]\n",
              min(metrics$off_explosiveness, na.rm = TRUE),
              max(metrics$off_explosiveness, na.rm = TRUE)))
  if (n_talent > 0) {
    cat(sprintf("  talent_norm    range : [%.2f, %.2f] (raw: %.0f–%.0f)\n",
                min(metrics$talent_norm, na.rm = TRUE),
                max(metrics$talent_norm, na.rm = TRUE),
                min(metrics$talent_score, na.rm = TRUE),
                max(metrics$talent_score, na.rm = TRUE)))
  }
  if (n_retention > 0) {
    n_low_ret <- sum(metrics$retention_score < 1.0, na.rm = TRUE)
    cat(sprintf("  retention_score range: [%.2f, %.2f] | %d teams with dampener < 1.0\n",
                min(metrics$retention_score, na.rm = TRUE),
                max(metrics$retention_score, na.rm = TRUE),
                n_low_ret))
  }

  # Report supplemental NA — informational, not fatal
  supp_na <- na_counts %>% filter(col %in% supp_cols)
  if (any(supp_na$n_NA > 0)) {
    cat(sprintf(
      "  [NOTE] Supplemental cols NA — fix in SCRAPE_CFB_DATA.R stat filter:\n"
    ))
    for (i in seq_len(nrow(supp_na))) {
      cat(sprintf("    %s: %d NA\n", supp_na$col[i], supp_na$n_NA[i]))
    }
  }

  if (n_core_complete < 50) {
    warning(sprintf(
      "[TEAM_METRICS] Only %d teams with core advanced metrics — verify CFBD API key + year.",
      n_core_complete
    ))
  }

  # ── write enriched CSV (overwrites basic stats file from Step 4) ─────────────
  out_path <- sprintf("clean/cfb_team_stats_%d.csv", year)
  write_csv(metrics, out_path)
  cat(sprintf("\n[TEAM_METRICS] Written: %s (%d teams, %d columns)\n",
              out_path, nrow(metrics), ncol(metrics)))

  # ── assign to GlobalEnv for downstream pipeline steps ────────────────────────
  assign("team_metrics", metrics, envir = .GlobalEnv)
  cat("[TEAM_METRICS] team_metrics assigned to .GlobalEnv\n")

  invisible(metrics)
}

# ==============================================================================
# 5. PFF grades loader (Option C stub — Phase 4)
#
# Reads a manually-placed PFF export CSV (not API-fetched — PFF requires
# Enterprise plan). If the file is absent, returns an empty tibble silently.
# When present, it enriches team_metrics with pff_off_grade / pff_def_grade
# before the pipeline's merge step.
#
# To activate: export grades from pff.com and save as clean/pff_grades_latest.csv
# Columns expected: team_name (raw), pff_off_grade (0–100), pff_def_grade (0–100)
# ==============================================================================

load_pff_grades <- function(master = NULL) {
  path <- "clean/pff_grades_latest.csv"
  if (!file.exists(path)) return(tibble())

  grades <- tryCatch(
    read_csv(path, col_types = cols(.default = "c"), show_col_types = FALSE) %>%
      mutate(
        pff_off_grade = suppressWarnings(as.numeric(pff_off_grade)),
        pff_def_grade = suppressWarnings(as.numeric(pff_def_grade))
      ),
    error = function(e) {
      warning("[PFF] Error reading pff_grades_latest.csv: ", e$message)
      return(tibble())
    }
  )

  if (nrow(grades) == 0) return(tibble())

  if (!is.null(master) && "team_name" %in% names(grades)) {
    grades <- grades %>%
      mutate(canonical_name = normalize_team_name(
        team_name, mappings = master,
        source_col = "massey_name",
        unmatched_log = "logs/unmatched_teams.csv"
      )) %>%
      filter(!is.na(canonical_name))
  }

  n <- sum(!is.na(grades$pff_off_grade) | !is.na(grades$pff_def_grade))
  cat(sprintf("[PFF] Loaded %d teams from pff_grades_latest.csv\n", n))
  grades
}

# ==============================================================================
# 6. Run when sourced directly (not when sourced by orchestrator with own logic)
# ==============================================================================

if (!exists(".team_metrics_sourced_by_orchestrator")) {
  build_team_metrics()
}

cat("[TEAM_METRICS] TEAM_METRICS.R loaded.\n")
