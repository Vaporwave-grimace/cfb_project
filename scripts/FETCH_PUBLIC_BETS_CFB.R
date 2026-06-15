# ==============================================================================
# FETCH_PUBLIC_BETS_CFB.R — Public Betting % via Action Network
# Pipeline Step 8.5 (non-fatal)
#
# Scrapes Action Network's NCAAF public betting page using Firecrawl.
# Extracts both ticket % (bets) and money % (handle) per side per game.
#
# The BOOST_PUBLIC_PCT (1.20x) in CALCULATE_VALUE_CFB.R fires when:
#   vsin_divergence = abs(bets_pct - money_pct) >= PUBLIC_PCT_MIN_DIV (0.15)
#
# This captures the sharp-vs-public signal:
#   When 65% of tickets are on Team A but only 40% of money → sharps on Team B.
#   That's a 25pp divergence (0.25) — well above the 0.15 threshold.
#
# If Firecrawl is unavailable or parsing fails, vsin_data stays NULL and the
# 1.20x boost simply doesn't fire — the pipeline continues without it.
#
# Output: vsin_data (.GlobalEnv)
#   game_id, canonical_home, canonical_away,
#   public_home_bets_pct, public_home_money_pct, vsin_divergence
#
# Usage:
#   source("scripts/FETCH_PUBLIC_BETS_CFB.R")
#   fetch_public_bets_cfb()
# ==============================================================================

suppressMessages({
  library(tidyverse)
  library(stringr)
})

PUBLIC_BETS_URL <- "https://www.actionnetwork.com/ncaaf/public-betting"

# --------------------------------------------------------------------------
# Parse Action Network markdown output from Firecrawl
# Looks for team names + % values near them in the rendered markdown.
# Returns a list of rows: list(home, away, bets_pct_home, money_pct_home)
# --------------------------------------------------------------------------
.parse_action_network <- function(md, odds_df) {
  if (is.null(md) || !nzchar(md)) return(list())

  lines <- strsplit(md, "\n")[[1]]
  lines <- trimws(lines)
  lines <- lines[nzchar(lines)]

  # Collect all canonical team names from the current slate for matching
  all_home <- odds_df$canonical_home
  all_away <- odds_df$canonical_away

  # Build a lookup: last word of canonical name → canonical name
  # e.g., "Ohio State" → "State", "Notre Dame" → "Dame"
  # We also try full name match
  make_last_word <- function(s) str_to_lower(word(s, -1))
  home_lw <- setNames(make_last_word(all_home), all_home)
  away_lw <- setNames(make_last_word(all_away), all_away)
  all_teams <- c(all_home, all_away)
  all_lw    <- setNames(make_last_word(all_teams), all_teams)

  # Extract percentage values from a line (returns numeric 0-1 or NA)
  extract_pcts <- function(line) {
    pct_strings <- str_extract_all(line, "\\d{1,3}%")[[1]]
    as.numeric(gsub("%", "", pct_strings)) / 100
  }

  # Find team name in a line (returns canonical name or NA)
  find_team <- function(line) {
    line_lower <- str_to_lower(line)
    # Try full canonical name first
    for (team in all_teams) {
      if (str_detect(line_lower, fixed(str_to_lower(team)))) return(team)
    }
    # Fall back to last-word match
    for (team in all_teams) {
      lw <- make_last_word(team)
      if (nchar(lw) >= 4 && str_detect(line_lower, paste0("\\b", lw, "\\b"))) {
        return(team)
      }
    }
    NA_character_
  }

  rows <- list()
  i <- 1

  while (i <= length(lines)) {
    line <- lines[i]

    # Look for lines that contain both a team name and percentage values
    pcts <- extract_pcts(line)
    team <- find_team(line)

    # Pattern: a line with a matchup "Away @ Home" and percentages nearby
    if (!is.na(team) && length(pcts) >= 2) {
      # Attempt to extract both bets% and money% from same line
      # Action Network typically shows: "35% Bets  65% Money" or similar
      rows[[length(rows) + 1]] <- list(
        team       = team,
        bets_pct   = pcts[1],
        money_pct  = pcts[2]
      )
      i <- i + 1
      next
    }

    # Alternative: matchup line followed by two separate pct lines
    if (str_detect(line, "@") || str_detect(line, " vs ")) {
      # Try to extract teams from "Away @ Home" format
      parts <- str_split(line, "@|\\svs\\.?\\s")[[1]]
      if (length(parts) == 2) {
        team_a <- find_team(trimws(parts[1]))
        team_h <- find_team(trimws(parts[2]))

        # Scan next ~6 lines for percentages
        window <- lines[seq(i + 1, min(i + 6, length(lines)))]
        all_pcts <- unlist(lapply(window, extract_pcts))

        if (!is.na(team_a) && !is.na(team_h) && length(all_pcts) >= 2) {
          rows[[length(rows) + 1]] <- list(
            away       = team_a,
            home       = team_h,
            bets_pct   = all_pcts[1],
            money_pct  = if (length(all_pcts) >= 2) all_pcts[2] else all_pcts[1]
          )
          i <- i + 7
          next
        }
      }
    }

    i <- i + 1
  }

  rows
}

# --------------------------------------------------------------------------
# Match parsed rows to odds_data game_ids and compute vsin_divergence
# --------------------------------------------------------------------------
.build_vsin_data <- function(parsed_rows, odds_df) {
  if (length(parsed_rows) == 0) return(NULL)

  result_rows <- list()

  for (row in parsed_rows) {
    home <- row$home %||% NA_character_
    away <- row$away %||% NA_character_

    if (is.na(home) || is.na(away)) next

    # Find matching game in odds_data
    game_match <- odds_df |>
      filter(canonical_home == home, canonical_away == away)

    if (nrow(game_match) == 0) next

    bets_pct  <- coalesce(as.numeric(row$bets_pct),  0.5)
    money_pct <- coalesce(as.numeric(row$money_pct), bets_pct)

    # Clamp to valid range
    bets_pct  <- max(0, min(1, bets_pct))
    money_pct <- max(0, min(1, money_pct))

    # Sharp signal: divergence between money % and ticket %
    # High divergence = sharp bettors on one side, public on the other
    divergence <- abs(bets_pct - money_pct)

    result_rows[[length(result_rows) + 1]] <- tibble(
      game_id              = game_match$game_id[1],
      canonical_home       = home,
      canonical_away       = away,
      public_home_bets_pct  = round(bets_pct,  3),
      public_home_money_pct = round(money_pct, 3),
      vsin_divergence      = round(divergence, 3)
    )
  }

  if (length(result_rows) == 0) return(NULL)
  bind_rows(result_rows)
}

# --------------------------------------------------------------------------
# Main entry point
# --------------------------------------------------------------------------
fetch_public_bets_cfb <- function() {
  cat("[PUBLIC] Fetching NCAAF public betting data (Action Network)...\n")

  if (!exists("odds_data", envir = .GlobalEnv)) {
    cat("[PUBLIC] odds_data not found — skipping public bets.\n")
    return(invisible(NULL))
  }
  odds_df <- get("odds_data", envir = .GlobalEnv)

  if (!exists("firecrawl_scrape", mode = "function")) {
    source("scripts/firecrawl_utils.R")
  }

  if (!firecrawl_available()) {
    cat("[PUBLIC] Firecrawl not available — BOOST_PUBLIC_PCT will not fire.\n")
    return(invisible(NULL))
  }

  md <- tryCatch(
    firecrawl_scrape(PUBLIC_BETS_URL, timeout_ms = 30000, wait_ms = 4000),
    error = function(e) {
      cat(sprintf("[PUBLIC] Firecrawl scrape failed: %s\n", e$message))
      NULL
    }
  )

  if (is.null(md) || !nzchar(md)) {
    cat("[PUBLIC] No markdown returned — BOOST_PUBLIC_PCT inactive this run.\n")
    return(invisible(NULL))
  }

  parsed  <- .parse_action_network(md, odds_df)
  vsin_df <- .build_vsin_data(parsed, odds_df)

  if (is.null(vsin_df) || nrow(vsin_df) == 0) {
    cat("[PUBLIC] Parsing produced 0 matched games — BOOST_PUBLIC_PCT inactive.\n")
    return(invisible(NULL))
  }

  n_boosted <- sum(vsin_df$vsin_divergence >= PUBLIC_PCT_MIN_DIV, na.rm = TRUE)
  cat(sprintf(
    "[PUBLIC] Matched %d games | %d eligible for BOOST_PUBLIC_PCT (divergence >= %.0f%%)\n",
    nrow(vsin_df), n_boosted, PUBLIC_PCT_MIN_DIV * 100
  ))
  if (n_boosted > 0) {
    vsin_df |>
      filter(vsin_divergence >= PUBLIC_PCT_MIN_DIV) |>
      arrange(desc(vsin_divergence)) |>
      mutate(label = sprintf("  %s @ %s: bets=%.0f%% money=%.0f%% div=%.0f%%",
                             canonical_away, canonical_home,
                             public_home_bets_pct * 100,
                             public_home_money_pct * 100,
                             vsin_divergence * 100)) |>
      pull(label) |>
      cat(sep = "\n")
    cat("\n")
  }

  assign("vsin_data", vsin_df, envir = .GlobalEnv)
  invisible(vsin_df)
}

if (!exists(".public_bets_sourced_by_orchestrator")) {
  fetch_public_bets_cfb()
}

cat("[PUBLIC] FETCH_PUBLIC_BETS_CFB.R loaded.\n")
