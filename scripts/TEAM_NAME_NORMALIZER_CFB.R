# ==============================================================================
# TEAM_NAME_NORMALIZER_CFB.R
# Port of mcBaseBall normalize_team_name() adapted for FBS teams
#
# SINGLE SOURCE OF TRUTH: team_name_mappings_MASTER_CFB.csv
#   canonical_name  — primary key used throughout pipeline
#   odds_name       — DraftKings / Odds API feed name
#   massey_name     — masseyratings.com scraped name
#
# LOOKUP STRATEGY (4-pass):
#   1. primary source exact match  (odds_name / massey_name / canonical_name)
#   2. canonical_name exact match  (fallback — raw name already canonical)
#   3. massey_name exact match     (tertiary — catches Massey full-form names)
#   4. odds_lu fallback            (only when source_col="massey_name" —
#                                   catches CFBD names that match odds_name form
#                                   e.g. "App State", "ULM", "Miami OH")
#   → NA + warning if all four fail
#
# preprocess_team_name() handles only genuinely ambiguous cases and acronyms.
# It does NOT normalize abbreviations (St./State) — the 4-pass lookup covers that.
# ==============================================================================

suppressMessages(library(tidyverse))

# ------------------------------------------------------------------------------
# 1. Load MASTER lookup table
# ------------------------------------------------------------------------------
load_cfb_master <- function(path = "team_name_mappings_MASTER_CFB.csv") {
  if (!file.exists(path)) {
    stop(sprintf("[NORMALIZER] MASTER CSV not found: %s", path))
  }
  master <- read_csv(path, show_col_types = FALSE)
  required_cols <- c("canonical_name", "odds_name", "massey_name",
                     "conference", "conf_weight", "dome", "hfa_pts",
                     "latitude", "longitude")
  missing <- setdiff(required_cols, names(master))
  if (length(missing) > 0) {
    stop(sprintf("[NORMALIZER] MASTER CSV missing columns: %s",
                 paste(missing, collapse = ", ")))
  }
  cat(sprintf("[NORMALIZER] MASTER loaded — %d teams.\n", nrow(master)))
  master
}

# ------------------------------------------------------------------------------
# 2. Pre-process raw name string
#
#    SCOPE: Only handle cases that are GENUINELY AMBIGUOUS or require expansion
#    (Miami disambiguation, Ole Miss, acronyms, common full-name feed variants).
#    Do NOT strip abbreviation periods — "Ohio St." must stay "Ohio St." so the
#    odds_name lookup works.  Full-name variants like "Ohio State" resolve via
#    canonical or massey fallback passes without preprocessing.
# ------------------------------------------------------------------------------
preprocess_team_name <- function(name) {
  name %>%
    str_trim() %>%

    # ---- Miami disambiguation (must precede all other Miami rules) ------------
    str_replace_all("^Miami \\(Ohio\\)$",    "Miami OH") %>%
    str_replace_all("^Miami Ohio$",           "Miami OH") %>%
    str_replace_all("^Miami, OH$",            "Miami OH") %>%
    str_replace_all("^Miami \\(OH\\)$",       "Miami OH") %>%
    str_replace_all("^Miami \\(FL\\)$",       "Miami") %>%
    str_replace_all("^Miami FL$",             "Miami") %>%

    # ---- Ole Miss — Massey calls it "Mississippi"; odds feed uses "Ole Miss" --
    str_replace_all("^Mississippi$",          "Ole Miss") %>%

    # ---- Unicode / accent normalization (CFBD occasionally returns accented) --
    str_replace_all("Hawaiʻi",           "Hawaii") %>%   # ʻokina apostrophe
    str_replace_all("Hawai'i",                "Hawaii") %>%   # straight apostrophe
    str_replace_all("é|è",          "e")    %>%     # é/è → e (San José)
    str_replace_all("ó",                 "o")    %>%     # ó → o

    # ---- Full-name → MASTER form (where massey_name / odds_name ≠ full name) ---
    str_replace_all("^Connecticut$",          "UConn") %>%
    str_replace_all("^Massachusetts$",        "UMass") %>%
    # California: MASTER canonical="Cal", odds_name="California", massey_name="Cal"
    # CFBD SP+ endpoint returns "California" — preprocess to massey_name="Cal" so
    # Pass 1 hits massey_lu directly. Pass 2 (canonical) also catches "Cal".
    str_replace_all("^California$",           "Cal") %>%
    str_replace_all("^Appalachian State$",    "App State") %>%
    str_replace_all("^Appalachian St\\.?$",   "App State") %>%
    str_replace_all("^Louisiana-Monroe$",     "ULM") %>%
    str_replace_all("^UL Monroe$",            "ULM") %>%
    str_replace_all("^Louisiana-Lafayette$",  "Louisiana") %>%
    str_replace_all("^UL Lafayette$",         "Louisiana") %>%
    str_replace_all("^ULL$",                  "Louisiana") %>%
    str_replace_all("^Sam Houston State$",    "Sam Houston") %>%
    str_replace_all("^Sam Houston St\\.?$",   "Sam Houston") %>%
    str_replace_all("^SFA$",                  "Sam Houston") %>%
    str_replace_all("^Southern Methodist$",   "SMU") %>%
    str_replace_all("^Brigham Young$",        "BYU") %>%
    str_replace_all("^Army West Point$",      "Army") %>%
    str_replace_all("^USMA$",                 "Army") %>%
    str_replace_all("^Florida International$","FIU") %>%
    str_replace_all("^Florida Intl$",         "FIU") %>%
    str_replace_all("^Tex A&M$",              "Texas A&M") %>%
    str_replace_all("^Texas A & M$",          "Texas A&M") %>%

    # ---- Common short-form / nickname variants --------------------------------
    str_replace_all("^Pitt$",                 "Pittsburgh") %>%
    str_replace_all("^USF$",                  "South Florida") %>%
    str_replace_all("^N\\.C\\. State$",       "NC State") %>%
    str_replace_all("^Va Tech$",              "Virginia Tech") %>%
    str_replace_all("^VT$",                   "Virginia Tech") %>%
    str_replace_all("^BC$",                   "Boston College") %>%
    str_replace_all("^ND$",                   "Notre Dame") %>%
    str_replace_all("^Ga Tech$",              "Georgia Tech") %>%

    # ---- UL / Louisiana variants ---------------------------------------------
    str_replace_all("^UL Monroe.*$",           "Louisiana Monroe") %>%
    str_replace_all("^ULM$",                   "Louisiana Monroe") %>%
    str_replace_all("^Louisiana Monroe.*$",    "Louisiana Monroe") %>%

    # ---- Acronyms ------------------------------------------------------------
    str_replace_all("^WKU$",                  "Western Kentucky") %>%
    str_replace_all("^NIU$",                  "Northern Illinois") %>%
    str_replace_all("^CMU$",                  "Central Michigan") %>%
    str_replace_all("^EMU$",                  "Eastern Michigan") %>%
    str_replace_all("^WMU$",                  "Western Michigan") %>%
    str_replace_all("^BGSU$",                 "Bowling Green")
}

# ------------------------------------------------------------------------------
# 3. Core normalizer — 4-pass lookup
#    Pass 1: primary source  (odds_name / massey_name / canonical_name)
#    Pass 2: canonical       (e.g. "Ohio State", "Cal", "UConn")
#    Pass 3: massey          (catches Massey full-form names; skipped if source=massey)
#    Pass 4: odds_lu         (only when source_col="massey_name" — catches CFBD names
#                             that match odds_name form: "App State", "ULM", "Miami OH")
# ------------------------------------------------------------------------------
normalize_team_name <- function(names_vec,
                                 mappings,
                                 source_col    = "odds_name",
                                 unmatched_log = NULL) {

  stopifnot(source_col %in% c("odds_name", "massey_name", "canonical_name"))

  preprocessed <- preprocess_team_name(names_vec)

  # Build lookup tables (named vectors: source → canonical)
  odds_lu      <- setNames(mappings$canonical_name, mappings$odds_name)
  canonical_lu <- setNames(mappings$canonical_name, mappings$canonical_name)
  massey_lu    <- setNames(mappings$canonical_name, mappings$massey_name)

  # Select primary lookup
  primary_lu <- switch(source_col,
    odds_name      = odds_lu,
    canonical_name = canonical_lu,
    massey_name    = massey_lu
  )

  result <- unname(primary_lu[preprocessed])

  # Pass 2: canonical fallback
  still_na <- is.na(result)
  if (any(still_na)) {
    result[still_na] <- unname(canonical_lu[preprocessed[still_na]])
  }

  # Pass 3: massey fallback (skip if source_col was already massey)
  if (source_col != "massey_name") {
    still_na <- is.na(result)
    if (any(still_na)) {
      result[still_na] <- unname(massey_lu[preprocessed[still_na]])
    }
  }

  # Pass 4: odds_lu fallback when source_col is massey_name.
  # Handles cases where CFBD or SP+ returns the odds_name form directly:
  #   "App State" → odds_lu → "Appalachian State"
  #   "ULM"       → odds_lu → "Louisiana Monroe"   (after preprocess "UL Monroe"→"ULM")
  #   "Miami OH"  → odds_lu → "Miami (OH)"          (after preprocess "Miami (OH)"→"Miami OH")
  # This exhausts all three MASTER name columns before declaring a miss.
  if (source_col == "massey_name") {
    still_na <- is.na(result)
    if (any(still_na)) {
      result[still_na] <- unname(odds_lu[preprocessed[still_na]])
    }
  }

  # Pass 5 (odds_name only): strip last word (mascot) and retry.
  # DraftKings sometimes sends full names with mascots, e.g.:
  #   "Ohio State Buckeyes" → strip "Buckeyes" → "Ohio State" → canonical ✓
  #   "Iowa State Cyclones" → strip "Cyclones"  → "Iowa State" → canonical ✓
  #   "NC State Wolfpack"   → strip "Wolfpack"   → "NC State"   → odds_lu  ✓
  if (source_col == "odds_name") {
    still_na <- is.na(result)
    if (any(still_na)) {
      stripped1 <- sub("\\s+\\S+$", "", preprocessed[still_na])
      result[still_na] <- coalesce(
        unname(odds_lu[stripped1]),
        unname(canonical_lu[stripped1])
      )
    }
  }

  # Pass 6 (odds_name only): strip last two words (two-word mascots) and retry.
  #   "Notre Dame Fighting Irish" → strip "Fighting Irish" → "Notre Dame" ✓
  #   "North Carolina Tar Heels" → strip "Tar Heels"       → "North Carolina" ✓
  if (source_col == "odds_name") {
    still_na <- is.na(result)
    if (any(still_na)) {
      stripped2 <- sub("\\s+\\S+\\s+\\S+$", "", preprocessed[still_na])
      result[still_na] <- coalesce(
        unname(odds_lu[stripped2]),
        unname(canonical_lu[stripped2])
      )
    }
  }

  # Log unmatched
  unmatched <- unique(names_vec[is.na(result)])
  if (length(unmatched) > 0) {
    warning(sprintf(
      "[NORMALIZER] %d unmatched team name(s) [source: %s]: %s",
      length(unmatched), source_col,
      paste(unmatched, collapse = " | ")
    ))
    if (!is.null(unmatched_log)) {
      log_entry <- tibble(
        timestamp    = Sys.time(),
        raw_name     = unmatched,
        source_col   = source_col,
        preprocessed = preprocess_team_name(unmatched)
      )
      if (file.exists(unmatched_log)) {
        existing    <- read_csv(unmatched_log, show_col_types = FALSE)
        new_entries <- log_entry %>% filter(!raw_name %in% existing$raw_name)
        if (nrow(new_entries) > 0) bind_rows(existing, new_entries) %>% write_csv(unmatched_log)
      } else {
        write_csv(log_entry, unmatched_log)
      }
    }
  }

  result
}

# ------------------------------------------------------------------------------
# 4. Game-level convenience wrapper
# ------------------------------------------------------------------------------
normalize_game_teams <- function(df,
                                  mappings,
                                  away_col      = "away_team",
                                  home_col      = "home_team",
                                  source_col    = "odds_name",
                                  unmatched_log = "logs/unmatched_teams.csv") {
  df %>%
    mutate(
      canonical_away = normalize_team_name(
        .data[[away_col]], mappings = mappings,
        source_col = source_col, unmatched_log = unmatched_log
      ),
      canonical_home = normalize_team_name(
        .data[[home_col]], mappings = mappings,
        source_col = source_col, unmatched_log = unmatched_log
      )
    )
}

# ------------------------------------------------------------------------------
# 5. Metadata getters
# ------------------------------------------------------------------------------
get_team_meta   <- function(canonical, mappings, col) {
  unname(setNames(mappings[[col]], mappings$canonical_name)[canonical])
}
get_conf_weight <- function(canonical, mappings) get_team_meta(canonical, mappings, "conf_weight")
get_hfa_pts     <- function(canonical, mappings) get_team_meta(canonical, mappings, "hfa_pts")
get_dome        <- function(canonical, mappings) get_team_meta(canonical, mappings, "dome")
get_latitude    <- function(canonical, mappings) get_team_meta(canonical, mappings, "latitude")
get_longitude   <- function(canonical, mappings) get_team_meta(canonical, mappings, "longitude")
get_conference  <- function(canonical, mappings) get_team_meta(canonical, mappings, "conference")

# ------------------------------------------------------------------------------
# 6. Round-trip validation
# ------------------------------------------------------------------------------
validate_master_roundtrip <- function(mappings) {
  results    <- normalize_team_name(mappings$odds_name, mappings = mappings,
                                    source_col = "odds_name")
  mismatches <- mappings$canonical_name[results != mappings$canonical_name | is.na(results)]
  if (length(mismatches) == 0) {
    cat(sprintf("[NORMALIZER] Round-trip PASSED — all %d odds_names resolve correctly.\n",
                nrow(mappings)))
    invisible(TRUE)
  } else {
    warning(sprintf("[NORMALIZER] Round-trip FAILURES (%d): %s",
                    length(mismatches), paste(mismatches, collapse = " | ")))
    invisible(FALSE)
  }
}

cat("[NORMALIZER] TEAM_NAME_NORMALIZER_CFB.R loaded.\n")
