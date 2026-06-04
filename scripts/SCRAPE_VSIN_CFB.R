# ==============================================================================
# SCRAPE_VSIN_CFB.R — VSiN CFB Betting Splits Scraper
# Pipeline Step 8.5a (sourced before PARSE_VSIN_CFB.R)
# Also callable standalone.
#
# Source: https://data.vsin.com/betting-splits/?source=DK&sport=CFB
# Method: Firecrawl REST API (replaces chromote — Cloudflare bypass built in)
#
# Output: clean/vsin_splits_YYYYMMDD_HHMM.csv
#   Columns: scraped_at, row_type (away/home), raw_team,
#             spread_line, spread_handle_pct, spread_bets_pct,
#             total_line, total_handle_pct, total_bets_pct,
#             ml_odds, ml_handle_pct, ml_bets_pct,
#             pair_idx  (integer — each away/home pair shares an index)
#
# On success: Telegram ping with row count.
# On no games: silent return (offseason expected).
# On error:   warning + returns NULL (non-fatal wrapper in run_daily_football.R)
# ==============================================================================

suppressMessages(library(tidyverse))
suppressMessages(library(httr))

setwd("G:/My Drive/Scripting Projects/cfb_project")

source("scripts/CONFIG.R")
source("scripts/firecrawl_utils.R")

VSIN_URL     <- "https://data.vsin.com/betting-splits/?source=DK&sport=CFB"
VSIN_OUT_DIR <- "clean"

# ------------------------------------------------------------------------------
# Inline Telegram helper (standalone — not sourcing broadcast_football.R)
# ------------------------------------------------------------------------------
send_telegram_vsin <- function(message) {
  creds <- tryCatch(load_credentials(), error = function(e) NULL)
  if (is.null(creds) ||
      is.null(creds$telegram_bot_token) ||
      is.null(creds$telegram_chat_id)) return(invisible(NULL))
  tryCatch(
    httr::POST(
      sprintf("https://api.telegram.org/bot%s/sendMessage",
              creds$telegram_bot_token),
      body = list(chat_id = creds$telegram_chat_id,
                  text    = message,
                  parse_mode = "Markdown"),
      encode = "form"
    ),
    error = function(e) warning(sprintf("[VSIN SCRAPE] Telegram send failed: %s", e$message))
  )
  invisible(NULL)
}

# ------------------------------------------------------------------------------
# pct_val() — parse "54%" → 0.54; "—" or NA → NA_real_
# ------------------------------------------------------------------------------
pct_val <- function(x) {
  x <- trimws(x)
  if (is.na(x) || x %in% c("", "-", "—", "N/A")) return(NA_real_)
  as.numeric(gsub("%", "", x)) / 100
}

# ------------------------------------------------------------------------------
# parse_vsin_markdown() — extract split rows from Firecrawl markdown
#
# VSiN table structure (confirmed 2026-06-04):
#   Header row:  | date | SpreadSPR | HandleHND | BetsBET | TotalTOT | ... |
#   Separator:   | --- | --- | ... |
#   Data rows:   | steam | team+logo | spread | handle% | bets% | total | ... |
#
# Data rows are identified by: cell[3] is a non-header team name (after link
# extraction) and cell[5] matches a percentage.
# Away/home pairs alternate row-by-row.
# ------------------------------------------------------------------------------
parse_vsin_markdown <- function(markdown) {
  lines       <- strsplit(markdown, "\n")[[1]]
  table_lines <- grep("^\\|", lines, value = TRUE)
  if (length(table_lines) == 0) return(NULL)

  HEADER_PATTERN <- "SpreadSPR|HandleHND|BetsBET|TotalTOT|MoneyML|^---$"

  rows_list  <- list()
  pair_idx   <- 0L
  last_type  <- "home"

  for (line in table_lines) {
    cells <- strsplit(line, "\\|", fixed = TRUE)[[1]]
    cells <- trimws(cells)
    # Remove image markdown ![]()
    cells <- gsub("!\\[[^]]*\\]\\([^)]+\\)", "", cells)
    # Extract text from markdown links [text](url)
    cells <- gsub("\\[([^]]+)\\]\\([^)]+\\)", "\\1", cells)
    cells <- trimws(cells)

    if (length(cells) < 11) next
    if (any(grepl("^---$", cells))) next         # separator row
    if (grepl(HEADER_PATTERN, cells[3])) next     # column-header row

    team <- cells[3]
    if (!nzchar(team)) next

    row_type <- if (last_type == "home") { pair_idx <- pair_idx + 1L; "away" } else "home"
    last_type <- row_type

    safe <- function(i) if (length(cells) >= i) cells[i] else NA_character_

    rows_list[[length(rows_list) + 1]] <- tibble(
      scraped_at        = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
      pair_idx          = pair_idx,
      row_type          = row_type,
      raw_team          = team,
      spread_line       = safe(4),
      spread_handle_pct = pct_val(safe(5)),
      spread_bets_pct   = pct_val(safe(6)),
      total_line        = safe(7),
      total_handle_pct  = pct_val(safe(8)),
      total_bets_pct    = pct_val(safe(9)),
      ml_odds           = safe(10),
      ml_handle_pct     = pct_val(safe(11)),
      ml_bets_pct       = pct_val(safe(12))
    )
  }

  if (length(rows_list) == 0) return(NULL)
  bind_rows(rows_list)
}

# ------------------------------------------------------------------------------
# scrape_vsin_cfb() — main scrape function
# Returns a tibble of raw split rows, or NULL on failure.
# ------------------------------------------------------------------------------
scrape_vsin_cfb <- function() {
  cat(sprintf("[VSIN SCRAPE] Fetching via Firecrawl: %s\n", VSIN_URL))

  md <- firecrawl_scrape(VSIN_URL, timeout_ms = 45000, wait_ms = 8000)
  if (is.null(md)) {
    warning("[VSIN SCRAPE] Firecrawl returned NULL — no data.")
    return(NULL)
  }

  splits_df <- parse_vsin_markdown(md)

  if (is.null(splits_df) || nrow(splits_df) == 0) {
    cat("[VSIN SCRAPE] No data rows found — no CFB games on slate or offseason.\n")
    return(NULL)
  }

  splits_df <- splits_df %>% filter(nzchar(raw_team))

  cat(sprintf("[VSIN SCRAPE] Parsed %d rows (%d game pairs).\n",
              nrow(splits_df), max(splits_df$pair_idx, na.rm = TRUE)))
  splits_df
}

# ------------------------------------------------------------------------------
# Main entry point
# ------------------------------------------------------------------------------
run_vsin_scrape <- function() {

  splits_df <- tryCatch(
    scrape_vsin_cfb(),
    error = function(e) {
      warning(sprintf("[VSIN SCRAPE] Unhandled error: %s", e$message))
      NULL
    }
  )

  if (is.null(splits_df)) {
    cat("[VSIN SCRAPE] No data written.\n")
    return(invisible(NULL))
  }

  # Write to clean/
  if (!dir.exists(VSIN_OUT_DIR)) dir.create(VSIN_OUT_DIR, recursive = TRUE)
  ts_str  <- format(Sys.time(), "%Y%m%d_%H%M")
  outfile <- file.path(VSIN_OUT_DIR,
                       sprintf("vsin_splits_%s.csv", ts_str))
  write_csv(splits_df, outfile)

  n_games <- max(splits_df$pair_idx, na.rm = TRUE)
  cat(sprintf("[VSIN SCRAPE] Wrote %d rows (%d game pairs) → %s\n",
              nrow(splits_df), n_games, outfile))

  # Telegram ping
  msg <- sprintf(
    paste0("*CFB VSiN Splits scraped* ✅\n",
           "%d game pairs | %s\n",
           "`%s`"),
    n_games,
    format(Sys.time(), "%Y-%m-%d %H:%M"),
    basename(outfile)
  )
  send_telegram_vsin(msg)

  invisible(splits_df)
}

run_vsin_scrape()
