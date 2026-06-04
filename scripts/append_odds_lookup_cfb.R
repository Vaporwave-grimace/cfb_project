# ==============================================================================
# append_odds_lookup_cfb.R — Auto-Learn New DK Team Names
# Pipeline Step 10 (non-fatal)
#
# After normalize_team_name() runs, any unmatched names are in
# logs/unmatched_teams.csv. This script:
#   1. Reads unmatched log
#   2. Attempts fuzzy match against MASTER canonical names
#   3. If confident match found (score >= threshold), proposes the mapping
#   4. Appends to a pending_mappings.csv for manual review before MASTER update
#
# Does NOT auto-write to MASTER — that's a manual step to avoid silent errors.
# ==============================================================================

suppressMessages(library(tidyverse))

FUZZY_THRESHOLD <- 0.75   # minimum similarity score to propose a mapping

# Simple character-level similarity (Jaccard on bigrams)
bigram_similarity <- function(a, b) {
  bigrams <- function(s) {
    s <- tolower(s)
    if (nchar(s) < 2) return(character(0))
    substring(s, 1:(nchar(s)-1), 2:nchar(s))
  }
  bg_a <- bigrams(a); bg_b <- bigrams(b)
  if (length(bg_a) == 0 || length(bg_b) == 0) return(0)
  length(intersect(bg_a, bg_b)) / length(union(bg_a, bg_b))
}

append_odds_lookup <- function() {

  unmatched_log <- "logs/unmatched_teams.csv"
  pending_path  <- "logs/pending_mappings.csv"

  if (!file.exists(unmatched_log)) {
    cat("[LOOKUP] No unmatched teams log found — nothing to process.\n")
    return(invisible(NULL))
  }

  unmatched <- read_csv(unmatched_log, show_col_types = FALSE) %>%
    filter(!is.na(raw_name), nzchar(raw_name)) %>%
    # Only process DK/Odds API feed names — Massey/CFBD sources include
    # thousands of non-FBS schools (D2, D3, FCS) that will never match our
    # 134-team FBS master and just flood the output with garbage proposals.
    filter(source_col == "odds_name") %>%
    distinct(raw_name, .keep_all = TRUE)

  if (nrow(unmatched) == 0) {
    cat("[LOOKUP] No unmatched Odds API team names — MASTER coverage is complete.\n")
    return(invisible(NULL))
  }

  cat(sprintf("[LOOKUP] %d unmatched Odds API name(s) to process.\n", nrow(unmatched)))

  master <- if (exists("master_cfb", envir = .GlobalEnv)) {
    get("master_cfb", envir = .GlobalEnv)
  } else {
    load_cfb_master()
  }

  # Fuzzy match each unmatched name against all canonical names
  proposals <- map_dfr(seq_len(nrow(unmatched)), function(i) {
    raw   <- unmatched$raw_name[i]
    prep  <- unmatched$preprocessed[i]
    query <- if (!is.na(prep) && nchar(prep) > 0) prep else raw

    scores <- map_dbl(master$canonical_name,
                      ~ bigram_similarity(query, .x))
    best_idx   <- which.max(scores)
    best_score <- scores[best_idx]

    tibble(
      raw_name        = raw,
      preprocessed    = prep,
      proposed_match  = master$canonical_name[best_idx],
      similarity      = round(best_score, 3),
      confident       = best_score >= FUZZY_THRESHOLD,
      source_col      = unmatched$source_col[i]
    )
  })

  confident   <- proposals %>% filter(confident)
  unconfident <- proposals %>% filter(!confident)

  if (nrow(confident) > 0) {
    cat(sprintf("[LOOKUP] %d confident proposal(s):\n", nrow(confident)))
    walk(seq_len(nrow(confident)), function(i) {
      cat(sprintf("  %s → %s (score: %.2f)\n",
                  confident$raw_name[i],
                  confident$proposed_match[i],
                  confident$similarity[i]))
    })
  }

  if (nrow(unconfident) > 0) {
    cat(sprintf("[LOOKUP] %d low-confidence name(s) need manual review:\n",
                nrow(unconfident)))
    walk(seq_len(nrow(unconfident)), function(i) {
      cat(sprintf("  %s (best guess: %s, score: %.2f)\n",
                  unconfident$raw_name[i],
                  unconfident$proposed_match[i],
                  unconfident$similarity[i]))
    })
  }

  # Write to pending_mappings.csv for manual MASTER update
  proposals <- proposals %>% mutate(reviewed = FALSE, timestamp = Sys.time())
  if (file.exists(pending_path)) {
    existing <- read_csv(pending_path, show_col_types = FALSE)
    proposals <- proposals %>%
      filter(!raw_name %in% existing$raw_name) %>%
      bind_rows(existing, .)
  }
  write_csv(proposals, pending_path)
  cat(sprintf("[LOOKUP] Proposals saved → %s\n", pending_path))

  invisible(proposals)
}

append_odds_lookup()
cat("[LOOKUP] append_odds_lookup_cfb.R complete.\n")
