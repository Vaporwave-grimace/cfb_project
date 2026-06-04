# ==============================================================================
# scrape_sagarin.R — Sagarin CFB Ratings Scraper
# Pipeline Step 4 (non-fatal — wrapped in tryCatch by orchestrator)
#
# TWO-PATH STRATEGY:
#   Path A (primary)  — read SAG column cached by scrape_massey_cfb.R
#                       clean/sagarin_ratings_YYYYMMDD.csv already exists
#   Path B (fallback) — fetch directly from sagarin.com/sports/cfsend.htm
#                       used when Massey fetch failed or SAG col was absent
#
# Output: clean/sagarin_ratings_YYYYMMDD.csv
# Global: assigns sagarin_ratings tibble to .GlobalEnv
#
# Column we want from Sagarin: PREDICTOR
#   Sagarin publishes three sub-ratings per team:
#     Rating     — blended recent + historical performance
#     Predictor  — pure scoring efficiency; best for point spread forecasts
#     Golden Mean— midpoint; less useful for us
#   We store all three but weight PREDICTOR in MERGE_ALL_RATINGS_CFB.R
# ==============================================================================

suppressMessages(library(tidyverse))
suppressMessages(library(httr))

source("scripts/TEAM_NAME_NORMALIZER_CFB.R")
source("scripts/firecrawl_utils.R")

SAGARIN_URL         <- "https://sagarin.com/sports/cfsend.htm"
SAGARIN_CACHE_HOURS <- 12

# ------------------------------------------------------------------------------
# Path A — read bonus cache written by scrape_massey_cfb.R
# ------------------------------------------------------------------------------
load_sagarin_from_massey_cache <- function(date = Sys.Date()) {
  cache_path <- sprintf("clean/sagarin_ratings_%s.csv", format(date, "%Y%m%d"))
  if (!file.exists(cache_path)) return(NULL)

  age_hours <- as.numeric(difftime(Sys.time(), file.mtime(cache_path), units = "hours"))
  if (age_hours >= SAGARIN_CACHE_HOURS) return(NULL)

  df <- read_csv(cache_path, show_col_types = FALSE)
  if (nrow(df) < 50 || !"sagarin_rating" %in% names(df)) return(NULL)

  cat(sprintf("[SAGARIN] Loaded from Massey cache (%.1f hrs old) — %d teams.\n",
              age_hours, nrow(df)))
  df
}

# ------------------------------------------------------------------------------
# Path B — fetch from sagarin.com
#
# Sagarin's CFB page is a <pre>-formatted block. Firecrawl renders it as
# bold markdown lines (each team row is wrapped in **...**):
#
#   **1  Indiana    A  = 100.06   16   0   ... | 97.74  1 | ...  BIG TEN  (A)**
#
# We extract: rank, team name (before division marker), main rating (= X.XX).
# PREDICTOR and GoldenMean sub-ratings are not labeled in current format → NA.
#
# Fallback: direct httr GET (fails with SEC_E_UNTRUSTED_ROOT on some machines).
# ------------------------------------------------------------------------------

# Primary: Firecrawl (handles SSL transparently)
fetch_sagarin_firecrawl <- function(url = SAGARIN_URL) {
  cat(sprintf("[SAGARIN] Fetching via Firecrawl: %s\n", url))
  firecrawl_scrape(url, timeout_ms = 30000, wait_ms = 1000)
}

# Fallback: direct httr (may hit SSL error on Windows Task Scheduler)
fetch_sagarin_direct <- function(url = SAGARIN_URL) {
  cat(sprintf("[SAGARIN] Fetching direct (fallback): %s\n", url))
  resp <- httr::GET(
    url,
    httr::add_headers(
      `User-Agent` = "Mozilla/5.0 (compatible; cfb-pipeline/1.0)",
      `Accept`     = "text/html,application/xhtml+xml"
    ),
    httr::timeout(45)
  )
  if (httr::http_error(resp))
    stop(sprintf("[SAGARIN] HTTP %d from direct fetch.", httr::status_code(resp)))
  httr::content(resp, "text", encoding = "UTF-8")
}

# Parse Firecrawl markdown — handles bold-wrapped rating lines
parse_sagarin_markdown <- function(markdown, master) {
  lines <- strsplit(markdown, "\n")[[1]]
  lines <- trimws(lines)

  # Strip bold markers
  lines <- gsub("^\\*\\*|\\*\\*$", "", lines)

  # Data lines: start with a rank number, then team name, then division letter, then "= X.XX"
  data_lines <- lines[grepl("^\\d+\\s+.+=\\s*\\d+\\.\\d+", lines)]

  if (length(data_lines) < 50)
    stop(sprintf("[SAGARIN] Only %d data lines — format may have changed.", length(data_lines)))

  parse_line <- function(line) {
    # Match: RANK  TEAM_NAME  DIV_LETTER  =  RATING
    # DIV_LETTER is a single uppercase letter (A, B, etc.) preceded by spaces
    m <- stringr::str_match(
      line,
      "^\\s*(\\d+)\\s+([A-Za-z][A-Za-z0-9 &'.()+\\-]+?)\\s+[A-Z]\\s*=\\s*(-?\\d+\\.\\d+)"
    )
    if (is.na(m[1, 1])) {
      # Fallback: no division letter (e.g. PREDICTOR= format)
      m <- stringr::str_match(
        line,
        "^\\s*(\\d+)\\s+([A-Za-z &'.()+\\-]+?)\\s*=\\s*(-?\\d+\\.\\d+)"
      )
    }
    if (is.na(m[1, 1])) return(NULL)
    tibble(
      team_raw       = trimws(m[1, 3]),
      sagarin_rating = as.numeric(m[1, 4]),
      sagarin_predictor   = NA_real_,
      sagarin_golden_mean = NA_real_
    )
  }

  parsed <- purrr::map_dfr(data_lines, function(line) {
    tryCatch(parse_line(line), error = function(e) NULL)
  })

  cat(sprintf("[SAGARIN] Parsed %d raw rows from Firecrawl markdown.\n", nrow(parsed)))

  parsed %>%
    filter(nzchar(team_raw), !is.na(sagarin_rating)) %>%
    mutate(
      canonical_name = normalize_team_name(
        team_raw, mappings = master,
        source_col    = "massey_name",
        unmatched_log = "logs/unmatched_teams.csv"
      )
    ) %>%
    filter(!is.na(canonical_name)) %>%
    select(canonical_name, sagarin_rating, sagarin_predictor, sagarin_golden_mean)
}

# Parse legacy HTML text format (direct fetch fallback)
parse_sagarin_html <- function(html_text, master) {
  raw <- gsub("<[^>]+>", "", html_text)
  raw <- gsub("&amp;", "&", raw); raw <- gsub("&nbsp;", " ", raw)
  raw <- gsub("&#39;", "'", raw)

  lines      <- trimws(strsplit(raw, "\n")[[1]])
  lines      <- lines[nzchar(lines)]
  data_lines <- lines[grepl("^\\s*\\d+\\s+.+=\\s*\\d", lines)]

  if (length(data_lines) < 50)
    stop(sprintf("[SAGARIN] Only %d data lines from HTML — format may have changed.", length(data_lines)))

  parse_line <- function(line) {
    m <- stringr::str_match(
      line, "^\\s*\\d+\\s+([A-Za-z &'.()+\\-]+?)\\s*=\\s*(-?\\d+\\.\\d+)")
    if (is.na(m[1, 1])) return(NULL)
    team_raw <- trimws(m[1, 2])
    rating   <- as.numeric(m[1, 3])
    pred_m <- stringr::str_match(line, "PREDICTOR\\s*=\\s*(-?\\d+\\.\\d+)")
    gm_m   <- stringr::str_match(line, "Golden\\s*Mean\\s*=\\s*(-?\\d+\\.\\d+)")
    tibble(
      team_raw            = team_raw,
      sagarin_rating      = rating,
      sagarin_predictor   = if (!is.na(pred_m[1,1])) as.numeric(pred_m[1,2]) else NA_real_,
      sagarin_golden_mean = if (!is.na(gm_m[1,1]))  as.numeric(gm_m[1,2])  else NA_real_
    )
  }

  parsed <- purrr::map_dfr(data_lines, function(line) {
    tryCatch(parse_line(line), error = function(e) NULL)
  })

  cat(sprintf("[SAGARIN] Parsed %d raw rows from HTML.\n", nrow(parsed)))

  parsed %>%
    filter(nzchar(team_raw), !is.na(sagarin_rating)) %>%
    mutate(
      canonical_name = normalize_team_name(
        team_raw, mappings = master,
        source_col    = "massey_name",
        unmatched_log = "logs/unmatched_teams.csv"
      )
    ) %>%
    filter(!is.na(canonical_name)) %>%
    select(canonical_name, sagarin_rating, sagarin_predictor, sagarin_golden_mean)
}

# ------------------------------------------------------------------------------
# Main entry point
# ------------------------------------------------------------------------------
scrape_sagarin <- function(master = NULL, date = Sys.Date()) {

  if (is.null(master)) {
    master <- if (exists("master_cfb", envir = .GlobalEnv)) {
      get("master_cfb", envir = .GlobalEnv)
    } else {
      load_cfb_master()
    }
  }

  out_path <- sprintf("clean/sagarin_ratings_%s.csv", format(date, "%Y%m%d"))

  # --- Path A: Massey bonus cache ---
  sag_df <- load_sagarin_from_massey_cache(date)

  # --- Path B: Firecrawl primary, direct httr fallback ---
  if (is.null(sag_df)) {
    cat("[SAGARIN] No fresh Massey cache — fetching from sagarin.com.\n")
    sag_df <- tryCatch({
      md <- fetch_sagarin_firecrawl()
      if (is.null(md)) stop("Firecrawl returned NULL")
      parse_sagarin_markdown(md, master)
    }, error = function(e) {
      cat(sprintf("[SAGARIN] Firecrawl failed (%s) — trying direct fetch.\n", e$message))
      html_text <- fetch_sagarin_direct()
      parse_sagarin_html(html_text, master)
    })
    sag_df <- sag_df %>% mutate(scrape_date = date)
    write_csv(sag_df, out_path)
    cat(sprintf("[SAGARIN] Fetched: %d teams → %s\n", nrow(sag_df), out_path))

  } else {
    # Massey cache only has sagarin_rating (no predictor/golden_mean sub-columns)
    # Add NA placeholders so downstream merge doesn't break
    if (!"sagarin_predictor" %in% names(sag_df)) {
      sag_df <- sag_df %>%
        mutate(sagarin_predictor    = NA_real_,
               sagarin_golden_mean  = NA_real_)
    }
    if (!"scrape_date" %in% names(sag_df)) {
      sag_df <- sag_df %>% mutate(scrape_date = date)
    }
    # Re-save with complete column set
    write_csv(sag_df, out_path)
  }

  n_matched <- sum(!is.na(sag_df$canonical_name))
  cat(sprintf("[SAGARIN] Final: %d teams with Sagarin ratings.\n", n_matched))

  assign("sagarin_ratings", sag_df, envir = .GlobalEnv)
  invisible(sag_df)
}

# Run when sourced by pipeline
scrape_sagarin()

cat("[SAGARIN] scrape_sagarin.R complete.\n")
