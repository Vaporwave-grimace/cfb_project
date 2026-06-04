# ==============================================================================
# PARSE_VSIN_CFB.R — VSiN CFB Splits Normalizer + Divergence Calculator
# Pipeline Step 8.5b (sourced after SCRAPE_VSIN_CFB.R in run_daily_football.R)
#
# Input:  clean/vsin_splits_*.csv  (most recent file by mtime)
#         odds_data (.GlobalEnv)   — needs canonical_home, canonical_away, game_id
#
# Output: clean/vsin_matchups_LATEST.csv
#         vsin_data (.GlobalEnv) — one row per game pair, keyed by game_id
#
# Columns in vsin_data:
#   game_id, canonical_home, canonical_away,
#   home_spread_handle_pct, home_spread_bets_pct,
#   home_total_handle_pct,  home_total_bets_pct,
#   home_ml_handle_pct,     home_ml_bets_pct,
#   away_ml_handle_pct,     away_ml_bets_pct,
#   vsin_divergence    — abs(home_ml_handle_pct - home_ml_bets_pct)
#   ml_vsin_signal     — "sharp_home" / "sharp_away" / "none"
#
# Divergence logic:
#   sharp_home: home_ml_handle_pct - home_ml_bets_pct >= PUBLIC_PCT_MIN_DIV
#   sharp_away: home_ml_bets_pct  - home_ml_handle_pct >= PUBLIC_PCT_MIN_DIV
#   none:       |divergence| < PUBLIC_PCT_MIN_DIV
#
# Non-fatal: if no CSV found or odds_data missing, warns and assigns NULL.
# ==============================================================================

suppressMessages(library(tidyverse))

source("scripts/CONFIG.R")
source("scripts/TEAM_NAME_NORMALIZER_CFB.R")

VSIN_CLEAN_DIR <- "clean"
VSIN_LATEST    <- file.path(VSIN_CLEAN_DIR, "vsin_matchups_LATEST.csv")

# ------------------------------------------------------------------------------
# find_latest_vsin_csv() — returns path to most recent vsin_splits_*.csv
# ------------------------------------------------------------------------------
find_latest_vsin_csv <- function(dir = VSIN_CLEAN_DIR) {
  files <- list.files(dir, pattern = "^vsin_splits_\\d{8}_\\d{4}\\.csv$",
                      full.names = TRUE)
  if (length(files) == 0) return(NULL)
  files[order(file.mtime(files), decreasing = TRUE)][1]
}

# ------------------------------------------------------------------------------
# parse_ml_odds() — coerce VSiN ML string to numeric American odds
#   handles "+150", "-110", "EV", "PK", blanks → NA_real_
# ------------------------------------------------------------------------------
parse_ml_odds <- function(x) {
  x <- trimws(x)
  if (is.na(x) || x %in% c("", "-", "—", "N/A", "EV", "PK")) return(NA_real_)
  suppressWarnings(as.numeric(x))
}

# ------------------------------------------------------------------------------
# parse_vsin_cfb() — main parse function
# Returns vsin_data tibble or NULL.
# ------------------------------------------------------------------------------
parse_vsin_cfb <- function() {

  # 1. Find latest CSV --------------------------------------------------------
  csv_path <- find_latest_vsin_csv()
  if (is.null(csv_path)) {
    warning("[VSIN PARSE] No vsin_splits_*.csv found in clean/ — skipping.")
    return(NULL)
  }
  cat(sprintf("[VSIN PARSE] Reading: %s\n", csv_path))
  splits_raw <- read_csv(csv_path, show_col_types = FALSE)

  # 2. Need odds_data for game_id join ----------------------------------------
  if (!exists("odds_data", envir = .GlobalEnv)) {
    warning("[VSIN PARSE] odds_data not found in .GlobalEnv — cannot assign game_id. Skipping.")
    return(NULL)
  }
  odds_df <- get("odds_data", envir = .GlobalEnv)

  required_odds <- c("game_id", "canonical_home", "canonical_away")
  missing_odds  <- setdiff(required_odds, names(odds_df))
  if (length(missing_odds) > 0) {
    warning(sprintf("[VSIN PARSE] odds_data missing columns: %s — skipping.",
                    paste(missing_odds, collapse = ", ")))
    return(NULL)
  }

  # 3. Load MASTER for normalization ------------------------------------------
  master <- tryCatch(
    load_cfb_master(),
    error = function(e) {
      warning(sprintf("[VSIN PARSE] Could not load MASTER CSV: %s", e$message))
      return(NULL)
    }
  )
  if (is.null(master)) return(NULL)

  # 4. Separate into away / home rows, normalize team names -------------------
  away_rows <- splits_raw %>% filter(row_type == "away")
  home_rows <- splits_raw %>% filter(row_type == "home")

  # Both must have same pair_idx set
  if (!setequal(away_rows$pair_idx, home_rows$pair_idx)) {
    warning("[VSIN PARSE] Mismatched away/home pair counts — page may have partially loaded.")
  }

  normalize_safe <- function(name) {
    tryCatch(
      normalize_team_name(name, mappings = master, source_col = "odds_name"),
      error = function(e) NA_character_
    )
  }

  away_rows <- away_rows %>%
    mutate(canonical = map_chr(raw_team, normalize_safe))

  home_rows <- home_rows %>%
    mutate(canonical = map_chr(raw_team, normalize_safe))

  n_away_unmatched <- sum(is.na(away_rows$canonical))
  n_home_unmatched <- sum(is.na(home_rows$canonical))
  if (n_away_unmatched + n_home_unmatched > 0) {
    warning(sprintf("[VSIN PARSE] %d away + %d home team(s) failed normalization.",
                    n_away_unmatched, n_home_unmatched))
  }

  # 5. Join pairs into one row per game ---------------------------------------
  pairs <- inner_join(
    away_rows %>% select(
      pair_idx,
      canonical_away     = canonical,
      away_spread_handle = spread_handle_pct,
      away_spread_bets   = spread_bets_pct,
      away_total_handle  = total_handle_pct,
      away_total_bets    = total_bets_pct,
      away_ml_handle_pct = ml_handle_pct,
      away_ml_bets_pct   = ml_bets_pct
    ),
    home_rows %>% select(
      pair_idx,
      canonical_home          = canonical,
      home_spread_handle_pct  = spread_handle_pct,
      home_spread_bets_pct    = spread_bets_pct,
      home_total_handle_pct   = total_handle_pct,
      home_total_bets_pct     = total_bets_pct,
      home_ml_handle_pct      = ml_handle_pct,
      home_ml_bets_pct        = ml_bets_pct
    ),
    by = "pair_idx"
  )

  if (nrow(pairs) == 0) {
    warning("[VSIN PARSE] No complete away/home pairs after join — no output.")
    return(NULL)
  }

  # Drop pairs where either canonical is NA
  pairs <- pairs %>%
    filter(!is.na(canonical_away), !is.na(canonical_home))

  # 6. Join to odds_data to get game_id ---------------------------------------
  pairs <- pairs %>%
    left_join(
      odds_df %>% select(game_id, canonical_home, canonical_away),
      by = c("canonical_home", "canonical_away")
    )

  n_no_id <- sum(is.na(pairs$game_id))
  if (n_no_id > 0) {
    warning(sprintf(
      "[VSIN PARSE] %d pair(s) could not be matched to odds_data — game_id will be NA.",
      n_no_id
    ))
  }

  # 7. Compute divergence + signal --------------------------------------------
  pairs <- pairs %>%
    mutate(
      vsin_divergence = abs(home_ml_handle_pct - home_ml_bets_pct),
      ml_vsin_signal  = case_when(
        is.na(home_ml_handle_pct) | is.na(home_ml_bets_pct) ~ "none",
        (home_ml_handle_pct - home_ml_bets_pct) >= PUBLIC_PCT_MIN_DIV  ~ "sharp_home",
        (home_ml_bets_pct   - home_ml_handle_pct) >= PUBLIC_PCT_MIN_DIV ~ "sharp_away",
        TRUE ~ "none"
      )
    )

  # 8. Final column order -----------------------------------------------------
  vsin_data <- pairs %>%
    select(
      game_id,
      canonical_home,
      canonical_away,
      home_spread_handle_pct,
      home_spread_bets_pct,
      home_total_handle_pct,
      home_total_bets_pct,
      home_ml_handle_pct,
      home_ml_bets_pct,
      away_ml_handle_pct,
      away_ml_bets_pct,
      vsin_divergence,
      ml_vsin_signal
    )

  vsin_data
}

# ------------------------------------------------------------------------------
# Main entry point
# ------------------------------------------------------------------------------
run_vsin_parse <- function() {

  vsin_data <- tryCatch(
    parse_vsin_cfb(),
    error = function(e) {
      warning(sprintf("[VSIN PARSE] Unhandled error: %s", e$message))
      NULL
    }
  )

  # Always assign — NULL is a valid "no data" signal for CALCULATE_VALUE_CFB.R
  assign("vsin_data", vsin_data, envir = .GlobalEnv)

  if (is.null(vsin_data)) {
    cat("[VSIN PARSE] vsin_data = NULL assigned to .GlobalEnv (no data / skipped).\n")
    return(invisible(NULL))
  }

  # Write LATEST CSV
  if (!dir.exists(VSIN_CLEAN_DIR)) dir.create(VSIN_CLEAN_DIR, recursive = TRUE)
  write_csv(vsin_data, VSIN_LATEST)

  n_sharp <- sum(vsin_data$ml_vsin_signal != "none", na.rm = TRUE)
  cat(sprintf(
    "[VSIN PARSE] %d game(s) parsed | %d sharp signal(s) | → %s\n",
    nrow(vsin_data), n_sharp, VSIN_LATEST
  ))

  # Summary to console
  if (n_sharp > 0) {
    sharp_games <- vsin_data %>%
      filter(ml_vsin_signal != "none") %>%
      mutate(label = sprintf("%s vs %s → %s (div=%.1f%%)",
                             canonical_away, canonical_home,
                             ml_vsin_signal,
                             vsin_divergence * 100))
    cat("[VSIN PARSE] Sharp signals:\n")
    walk(sharp_games$label, ~ cat(sprintf("  %s\n", .x)))
  }

  invisible(vsin_data)
}

run_vsin_parse()
