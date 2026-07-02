# ==============================================================================
# QA_portal_crosscheck.R — On3 vs 247Sports Portal Data Cross-Check (Phase 5)
#
# STANDALONE only — not part of the daily pipeline.
# Run manually before the season to validate portal data quality.
#
# Compares team-level portal data from two sources:
#   1. On3 team portal rankings (scrape_portal_on3.R via Firecrawl)
#   2. 247Sports team recruiting portal rankings (via cfbfastR or Firecrawl)
#
# Outputs:
#   - Console report: teams with large On3 vs 247 ranking discrepancies
#   - clean/qa_portal_crosscheck_YYYY.csv — full comparison table
#
# Usage:
#   setwd("G:/My Drive/Scripting Projects/cfb_project")
#   source("scripts/QA_portal_crosscheck.R")
#   portal_qa_run()          # current year
#   portal_qa_run(year=2025) # historical
# ==============================================================================

suppressMessages({
  library(tidyverse)
  library(httr)
  library(jsonlite)
})

source("scripts/CONFIG.R")
source("scripts/TEAM_NAME_NORMALIZER_CFB.R")
source("scripts/scrape_portal_on3.R")
source("scripts/TRANSFER_PORTAL_CFB.R")

DISCREPANCY_THRESHOLD <- 15  # On3 rank vs 247 rank difference flagged as conflict

# ==============================================================================
# 1. Fetch 247Sports portal team rankings via cfbfastR
#    cfbfastR wraps 247's public recruiting data; team-level portal rankings
#    differ from individual recruit ratings.
# ==============================================================================

.fetch_247_portal_teams <- function(year, master) {
  if (!requireNamespace("cfbfastR", quietly = TRUE)) {
    message("[QA] cfbfastR not installed — 247 cross-check unavailable")
    return(tibble())
  }

  raw <- tryCatch(
    cfbfastR::cfbd_recruiting_transfer_portal(year = year),
    error = function(e) {
      message("[QA] cfbd_recruiting_transfer_portal() failed: ", e$message)
      tibble()
    }
  )
  if (nrow(raw) == 0) return(tibble())

  # Derive destination column
  dest_col <- intersect(c("destination", "transfer_destination", "school"), names(raw))[1]
  rating_col <- intersect(c("rating", "composite_rating"), names(raw))[1]
  if (is.na(dest_col) || is.na(rating_col)) return(tibble())

  raw %>%
    rename(dest_team = !!dest_col, rating_val = !!rating_col) %>%
    filter(!is.na(rating_val)) %>%
    mutate(
      rating_val = as.numeric(rating_val),
      canonical_name = normalize_team_name(
        dest_team, mappings = master,
        source_col = "massey_name",
        unmatched_log = "logs/unmatched_teams.csv"
      )
    ) %>%
    filter(!is.na(canonical_name)) %>%
    group_by(canonical_name) %>%
    summarise(
      s247_in_n       = n(),
      s247_avg_rating = round(mean(rating_val, na.rm = TRUE), 3),
      s247_total_pts  = round(sum(rating_val, na.rm = TRUE), 2),
      .groups = "drop"
    ) %>%
    arrange(desc(s247_total_pts)) %>%
    mutate(rank_247 = row_number())
}

# ==============================================================================
# 2. Main QA runner
# ==============================================================================

portal_qa_run <- function(year = as.integer(format(Sys.Date(), "%Y"))) {
  cat(sprintf("\n[QA PORTAL] Cross-check %d — On3 vs 247Sports\n", year))
  cat(strrep("=", 55), "\n")

  master <- tryCatch(
    load_cfb_master("team_name_mappings_MASTER_CFB.csv"),
    error = function(e) { stop("[QA] Could not load master CFB mappings: ", e$message) }
  )

  # On3 data
  cat("[QA] Fetching On3 team portal rankings...\n")
  on3_raw <- tryCatch(scrape_portal_on3(year),
                      error = function(e) { message(e$message); tibble() })

  if (nrow(on3_raw) == 0) {
    cat("[QA] On3 returned no data — aborting cross-check.\n")
    return(invisible(NULL))
  }

  on3 <- on3_raw %>%
    mutate(
      canonical_name = normalize_team_name(
        team_name_raw, mappings = master,
        source_col = "massey_name",
        unmatched_log = "logs/unmatched_teams.csv"
      )
    ) %>%
    filter(!is.na(canonical_name)) %>%
    arrange(rank) %>%
    rename(rank_on3 = rank,
           on3_in_n = portal_in_n,
           on3_out_n = portal_out_n,
           on3_index = portal_index_score)

  cat(sprintf("[QA] On3 teams parsed: %d\n", nrow(on3)))

  # 247 data (individual → aggregate)
  cat("[QA] Fetching 247Sports individual portal transfers...\n")
  s247 <- .fetch_247_portal_teams(year, master)
  cat(sprintf("[QA] 247 teams aggregated: %d\n", nrow(s247)))

  if (nrow(s247) == 0) {
    cat("[QA] 247Sports data unavailable — printing On3 only.\n")
    print(select(on3, rank_on3, canonical_name, on3_in_n, on3_out_n, on3_index))
    return(invisible(on3))
  }

  # Merge
  combined <- full_join(
    select(on3, canonical_name, rank_on3, on3_in_n, on3_out_n, on3_index),
    select(s247, canonical_name, rank_247, s247_in_n, s247_avg_rating, s247_total_pts),
    by = "canonical_name"
  ) %>%
    mutate(
      rank_diff      = abs(coalesce(rank_on3, 999L) - coalesce(rank_247, 999L)),
      in_n_diff      = coalesce(on3_in_n, 0L) - coalesce(s247_in_n, 0L),
      flagged        = rank_diff >= DISCREPANCY_THRESHOLD,
      in_on3_only    = !is.na(rank_on3)  & is.na(rank_247),
      in_247_only    = is.na(rank_on3)   & !is.na(rank_247)
    ) %>%
    arrange(coalesce(rank_on3, rank_247))

  # Report
  n_both    <- sum(!combined$in_on3_only & !combined$in_247_only, na.rm = TRUE)
  n_flagged <- sum(combined$flagged, na.rm = TRUE)
  n_on3_only <- sum(combined$in_on3_only, na.rm = TRUE)
  n_247_only <- sum(combined$in_247_only, na.rm = TRUE)

  cat(sprintf("\n  Teams in both sources : %d\n", n_both))
  cat(sprintf("  On3 only             : %d\n", n_on3_only))
  cat(sprintf("  247 only             : %d\n", n_247_only))
  cat(sprintf("  Rank discrepancy ≥%d  : %d (investigate)\n\n",
              DISCREPANCY_THRESHOLD, n_flagged))

  if (n_flagged > 0) {
    cat("  Top discrepancies:\n")
    combined %>%
      filter(flagged) %>%
      arrange(desc(rank_diff)) %>%
      head(10) %>%
      select(canonical_name, rank_on3, rank_247, rank_diff, on3_in_n, s247_in_n) %>%
      pwalk(function(canonical_name, rank_on3, rank_247, rank_diff,
                     on3_in_n, s247_in_n, ...) {
        cat(sprintf("    %-28s  On3:#%2d  247:#%2d  diff:%2d  in_n: %d vs %d\n",
                    canonical_name,
                    coalesce(rank_on3, 999L), coalesce(rank_247, 999L),
                    rank_diff,
                    coalesce(on3_in_n, 0L), coalesce(s247_in_n, 0L)))
      })
  }

  # Write CSV
  out_path <- sprintf("clean/qa_portal_crosscheck_%d.csv", year)
  write_csv(combined, out_path)
  cat(sprintf("\n[QA] Written: %s (%d rows)\n", out_path, nrow(combined)))

  invisible(combined)
}
