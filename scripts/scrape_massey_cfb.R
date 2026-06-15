# ==============================================================================
# scrape_massey_cfb.R — Massey Ratings CFB Scraper
# Pipeline Step 4 (non-fatal — wrapped in tryCatch by orchestrator)
#
# Source:  https://masseyratings.com/ranks
# Extracts: MAS column (rank 1-N) → inverted to massey_rating (higher = better)
#           → clean/massey_ratings_YYYYMMDD.csv
#
# Fetch strategy:
#   Primary  — Firecrawl REST API (handles JS rendering, no Chromote dependency)
#   Fallback — rvest::read_html_live() + Chromote (requires Chrome installed)
#
# MAS column is a ranking (1 = best). Inverted before saving so that
# higher massey_rating = better team, consistent with SP+ and Sagarin.
# MERGE_ALL_RATINGS_CFB.R z-scores all inputs, so absolute scale doesn't matter.
# ==============================================================================

suppressMessages(library(tidyverse))
suppressMessages(library(rvest))

source("scripts/TEAM_NAME_NORMALIZER_CFB.R")
source("scripts/firecrawl_utils.R")

MASSEY_CFB_URL    <- "https://masseyratings.com/ranks"
MASSEY_CACHE_HOURS <- 12

# ------------------------------------------------------------------------------
# 1a. Fetch via Firecrawl (primary — no Chrome dependency)
# ------------------------------------------------------------------------------
fetch_massey_firecrawl <- function(url = MASSEY_CFB_URL) {
  cat(sprintf("[MASSEY] Fetching via Firecrawl: %s\n", url))
  firecrawl_scrape(url, timeout_ms = 45000, wait_ms = 5000)
}

# ------------------------------------------------------------------------------
# 1b. Fetch via Chromote (fallback — requires Chrome installed)
#
# Reliability improvements over original:
#   - Full retry loop (max_attempts = 2): if #SHCtable is missing after the
#     first attempt, close the session and try again with a longer wait.
#   - Explicit post-render validation: stop() only after all retries exhausted,
#     so Saturday morning failures are caught early with a clear error message.
#   - Longer wait_for timeout on retry (45s vs 30s) + larger sleep buffer.
# ------------------------------------------------------------------------------
fetch_massey_chromote <- function(url = MASSEY_CFB_URL, max_attempts = 2L) {
  cat(sprintf("[MASSEY] Fetching via Chromote (fallback): %s\n", url))
  if (!requireNamespace("chromote", quietly = TRUE))
    stop("[MASSEY] chromote package required for fallback fetch.")
  chrome_path <- tryCatch(chromote::find_chrome(), error = function(e) NULL)
  if (is.null(chrome_path))
    stop("[MASSEY] Chrome not found for fallback fetch.")

  last_err <- NULL

  for (attempt in seq_len(max_attempts)) {
    if (attempt > 1L) {
      cat(sprintf("[MASSEY] Chromote retry %d / %d (sleeping 3s)...\n",
                  attempt, max_attempts))
      Sys.sleep(3)
    }

    wait_ms  <- if (attempt == 1L) 30000L else 45000L
    sleep_s  <- if (attempt == 1L) 1.5    else 2.5

    html_str <- tryCatch({
      page <- rvest::read_html_live(url)
      on.exit(try(page$session$close(), silent = TRUE), add = TRUE)

      tryCatch(
        page$wait_for("#SHCtable td", timeout = wait_ms),
        error = function(e)
          cat(sprintf("[MASSEY] wait_for timed out (attempt %d) — proceeding.\n",
                      attempt))
      )
      Sys.sleep(sleep_s)

      html <- page$session$Runtime$evaluate(
        "document.documentElement.outerHTML"
      )$result$value

      if (!grepl("SHCtable", html, fixed = TRUE))
        stop("#SHCtable not found in rendered page — table not loaded yet.")

      html
    }, error = function(e) {
      last_err <<- e$message
      cat(sprintf("[MASSEY] Chromote attempt %d failed: %s\n",
                  attempt, e$message))
      NULL
    })

    if (!is.null(html_str)) return(html_str)
  }

  stop(sprintf("[MASSEY] Chromote failed after %d attempt(s). Last error: %s",
               max_attempts, last_err))
}

# ------------------------------------------------------------------------------
# 2a. Parse markdown table from Firecrawl output
#
#    Header (confirmed 2026-06-04): Team | Conf | W-L | Δ | CMP | Sort | MAS | HOW
#    MAS column = Massey rank (integer, 1 = best).
#    Inverted to massey_rating = (n_teams + 1 - mas_rank).
# ------------------------------------------------------------------------------
parse_massey_markdown <- function(markdown) {
  rows <- parse_markdown_table(markdown)

  # Filter to data rows: MAS must be a positive integer, Team must be non-empty
  parsed <- map_dfr(rows, function(r) {
    team <- trimws(r$Team %||% "")
    mas  <- suppressWarnings(as.integer(r$MAS %||% ""))
    if (!nzchar(team) || is.na(mas) || mas <= 0L) return(NULL)
    tibble(team_raw = team, mas_rank = mas)
  })

  if (nrow(parsed) == 0)
    stop("[MASSEY] 0 valid rows parsed from Firecrawl markdown — table may have changed.")

  n_teams <- nrow(parsed)
  parsed  <- parsed %>%
    mutate(mas = n_teams + 1L - mas_rank)

  cat(sprintf("[MASSEY] Parsed %d teams via Firecrawl (MAS rank range: 1–%d).\n",
              n_teams, n_teams))
  parsed
}

# ------------------------------------------------------------------------------
# 2b. Parse HTML from Chromote fallback (original logic)
# ------------------------------------------------------------------------------
parse_massey_html <- function(html_str) {
  doc        <- rvest::read_html(html_str)
  table_node <- doc |> rvest::html_element("#SHCtable")
  if (is.na(table_node))
    stop("[MASSEY] #SHCtable not found in Chromote HTML.")

  rows   <- table_node |> rvest::html_elements("tr")
  parsed <- purrr::map_dfr(rows, function(row) {
    cells    <- row |> rvest::html_elements("td") |> rvest::html_text(trim = TRUE)
    if (length(cells) < 8) return(NULL)
    mas_rank <- suppressWarnings(as.integer(cells[8]))
    if (is.na(mas_rank)) return(NULL)
    tibble(team_raw = cells[1], mas_rank = mas_rank)
  })

  if (nrow(parsed) == 0)
    stop("[MASSEY] 0 rows from Chromote HTML.")

  n_teams <- nrow(parsed)
  parsed  <- parsed %>% mutate(mas = n_teams + 1L - mas_rank)
  cat(sprintf("[MASSEY] Parsed %d teams via Chromote.\n", n_teams))
  parsed
}

# ------------------------------------------------------------------------------
# 3. Main scraper — called by orchestrator
# ------------------------------------------------------------------------------
scrape_massey_cfb <- function(master = NULL, date = Sys.Date()) {

  if (is.null(master)) {
    master <- if (exists("master_cfb", envir = .GlobalEnv)) {
      get("master_cfb", envir = .GlobalEnv)
    } else {
      load_cfb_master()
    }
  }

  massey_cache_path <- sprintf("clean/massey_ratings_%s.csv", format(date, "%Y%m%d"))

  # Use local cache if fresh
  if (file.exists(massey_cache_path)) {
    age_hours <- as.numeric(difftime(Sys.time(),
                                     file.mtime(massey_cache_path), units = "hours"))
    if (age_hours < MASSEY_CACHE_HOURS) {
      cat(sprintf("[MASSEY] Using cached file (%.1f hours old): %s\n",
                  age_hours, massey_cache_path))
      massey_data <- read_csv(massey_cache_path, show_col_types = FALSE)
      assign("massey_ratings", massey_data, envir = .GlobalEnv)
      return(invisible(massey_data))
    }
  }

  # Fetch and parse — Firecrawl primary, Chromote fallback
  parsed <- tryCatch({
    md <- fetch_massey_firecrawl()
    if (is.null(md)) stop("Firecrawl returned NULL")
    parse_massey_markdown(md)
  }, error = function(e) {
    cat(sprintf("[MASSEY] Firecrawl failed (%s) — trying Chromote fallback.\n", e$message))
    html_str <- fetch_massey_chromote()
    parse_massey_html(html_str)
  })

  # Normalize team names using massey_name column of MASTER
  parsed <- parsed %>%
    mutate(
      canonical_name = normalize_team_name(
        team_raw, mappings = master,
        source_col    = "massey_name",
        unmatched_log = "logs/unmatched_teams.csv"
      ),
      scrape_date = date
    )

  n_matched   <- sum(!is.na(parsed$canonical_name))
  n_unmatched <- sum( is.na(parsed$canonical_name))
  cat(sprintf("[MASSEY] Matched: %d | Unmatched: %d\n", n_matched, n_unmatched))

  massey_out <- parsed %>%
    filter(!is.na(canonical_name)) %>%
    select(canonical_name, massey_rating = mas, scrape_date)

  write_csv(massey_out, massey_cache_path)
  cat(sprintf("[MASSEY] Saved %d teams → %s\n", nrow(massey_out), massey_cache_path))

  assign("massey_ratings", massey_out, envir = .GlobalEnv)
  invisible(massey_out)
}

# Run when sourced by pipeline
scrape_massey_cfb()

cat("[MASSEY] scrape_massey_cfb.R complete.\n")
