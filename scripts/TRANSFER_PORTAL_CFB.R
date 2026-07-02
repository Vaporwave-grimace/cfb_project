# ==============================================================================
# TRANSFER_PORTAL_CFB.R — Transfer Portal Talent Delta (Phase 2)
# Pipeline Phase 2 (between TEAM_METRICS and PHASE 3)
#
# Combines two portal data sources:
#   1. On3 team portal rankings (scrape_portal_on3.R via Firecrawl)
#      → team-level net talent index score
#   2. cfbfastR::cfbd_recruiting_transfer_portal()
#      → individual transfers with position + rating (for difference-makers)
#
# OUTPUT: team_portal_scores — tibble assigned to .GlobalEnv
#   canonical_name, portal_in_n, portal_out_n, portal_index_score,
#   portal_net_score (normalized), n_difference_makers, has_qb_upgrade
#
# portal_net_score is normalized relative to FBS median portal_index_score so
# it's on the same ≈ [-2, +2] scale as talent_norm for GENERATE_PREDICTIONS.
#
# Consumed by: MERGE_GAMES_RATINGS_CFB.R (portal_diff → GENERATE_PREDICTIONS)
#              broadcast_football.R (has_qb_upgrade + n_difference_makers flags)
# ==============================================================================

suppressMessages({
  library(tidyverse)
  library(httr)
  library(jsonlite)
})

if (!exists("PORTAL_MIN_RATING")) source("scripts/CONFIG.R")
if (!exists("normalize_team_name")) source("scripts/TEAM_NAME_NORMALIZER_CFB.R")
if (!exists("scrape_portal_on3")) source("scripts/scrape_portal_on3.R")

PORTAL_NORM_BASE <- 0    # On3 portal_index_score median ≈ 0 (net-zero teams)
PORTAL_NORM_DIV  <- 200  # scale: +200 points = +1.0 normalized unit

# ==============================================================================
# 1. Individual player data (cfbfastR) — for difference-maker flagging
# ==============================================================================

.fetch_cfbfastr_portal <- function(year) {
  if (!requireNamespace("cfbfastR", quietly = TRUE)) {
    message("[PORTAL] cfbfastR not installed — difference-maker flags unavailable")
    return(tibble())
  }
  tryCatch(
    cfbfastR::cfbd_recruiting_transfer_portal(year = year),
    error = function(e) {
      message("[PORTAL] cfbd_recruiting_transfer_portal() failed: ", e$message)
      tibble()
    }
  )
}

# ==============================================================================
# 2. Flag difference-makers: high-rating transfers at impact positions
#    Returns tibble with canonical_name, n_difference_makers, has_qb_upgrade,
#    has_edge_upgrade, difference_maker_names
# ==============================================================================

flag_difference_makers <- function(indiv, master) {
  if (is.null(indiv) || nrow(indiv) == 0) {
    return(tibble(
      canonical_name       = character(),
      n_difference_makers  = integer(),
      has_qb_upgrade       = logical(),
      has_edge_upgrade     = logical(),
      difference_maker_names = character()
    ))
  }

  # Load position impact weights
  weights_path <- "data/position_impact_weights_CFB.csv"
  if (file.exists(weights_path)) {
    pos_weights <- read_csv(weights_path, col_types = cols(.default = "c"),
                            show_col_types = FALSE) %>%
      mutate(impact_weight = as.numeric(impact_weight))
  } else {
    pos_weights <- tibble(
      position      = c("QB","WR","CB","EDGE","OT","RB","LB","S","DL","TE"),
      impact_weight = c(2.5, 1.2, 1.3, 1.5, 1.3, 0.8, 1.0, 1.0, 1.2, 0.9)
    )
  }
  impact_positions <- pos_weights %>%
    filter(impact_weight >= 1.3) %>%
    pull(position)

  # cfbfastR column names may vary; detect rating col
  rating_col <- intersect(c("rating", "stars", "composite_rating"), names(indiv))[1]
  if (is.na(rating_col)) {
    message("[PORTAL] No rating column found in cfbfastR portal data — skipping flags")
    return(tibble(
      canonical_name = character(), n_difference_makers = integer(),
      has_qb_upgrade = logical(), has_edge_upgrade = logical(),
      difference_maker_names = character()
    ))
  }

  dest_col <- intersect(c("destination", "transfer_destination", "school"), names(indiv))[1]
  if (is.na(dest_col)) {
    message("[PORTAL] No destination column found — skipping flags")
    return(tibble(
      canonical_name = character(), n_difference_makers = integer(),
      has_qb_upgrade = logical(), has_edge_upgrade = logical(),
      difference_maker_names = character()
    ))
  }
  pos_col <- intersect(c("position", "pos"), names(indiv))[1]

  filtered <- indiv %>%
    rename(rating_val = !!rating_col, dest_team = !!dest_col) %>%
    filter(!is.na(rating_val), as.numeric(rating_val) >= PORTAL_MIN_RATING) %>%
    mutate(
      rating_val = as.numeric(rating_val),
      position_val = if (!is.na(pos_col)) .data[[pos_col]] else NA_character_,
      is_impact_pos = position_val %in% impact_positions,
      canonical_name = normalize_team_name(
        dest_team, mappings = master,
        source_col = "massey_name",
        unmatched_log = "logs/unmatched_teams.csv"
      )
    ) %>%
    filter(!is.na(canonical_name), is_impact_pos)

  if (nrow(filtered) == 0) {
    return(tibble(
      canonical_name = character(), n_difference_makers = integer(),
      has_qb_upgrade = logical(), has_edge_upgrade = logical(),
      difference_maker_names = character()
    ))
  }

  player_name_col <- intersect(c("full_name", "name", "athlete_name"), names(indiv))[1]

  filtered %>%
    mutate(player_name = if (!is.na(player_name_col)) .data[[player_name_col]] else "Unknown") %>%
    group_by(canonical_name) %>%
    summarise(
      n_difference_makers    = n(),
      has_qb_upgrade         = any(position_val == "QB",   na.rm = TRUE),
      has_edge_upgrade       = any(position_val == "EDGE", na.rm = TRUE),
      difference_maker_names = paste(player_name, collapse = ", "),
      .groups = "drop"
    )
}

# ==============================================================================
# 3. Compute team-level portal scores (On3 team index + normalization)
# ==============================================================================

compute_team_portal_scores <- function(on3_data, master) {
  if (is.null(on3_data) || nrow(on3_data) == 0) {
    cat("[PORTAL] No On3 data — portal_net_score will be 0 for all teams.\n")
    return(tibble())
  }

  scores <- on3_data %>%
    mutate(
      canonical_name = normalize_team_name(
        team_name_raw, mappings = master,
        source_col = "massey_name",
        unmatched_log = "logs/unmatched_teams.csv"
      ),
      portal_index_score = as.numeric(portal_index_score),
      portal_net_score   = (portal_index_score - PORTAL_NORM_BASE) / PORTAL_NORM_DIV
    ) %>%
    filter(!is.na(canonical_name)) %>%
    select(canonical_name, portal_in_n, portal_out_n,
           portal_index_score, portal_net_score)

  cat(sprintf("[PORTAL] On3 data: %d teams normalized | score range [%.2f, %.2f]\n",
              nrow(scores),
              min(scores$portal_net_score, na.rm = TRUE),
              max(scores$portal_net_score, na.rm = TRUE)))
  scores
}

# ==============================================================================
# 4. Main entry point
# ==============================================================================

fetch_portal_data <- function(year = as.integer(format(Sys.Date(), "%Y")),
                              master = NULL) {
  if (is.null(master)) {
    if (exists("master_cfb", envir = .GlobalEnv)) {
      master <- get("master_cfb", envir = .GlobalEnv)
    } else {
      master <- tryCatch(load_cfb_master("team_name_mappings_MASTER_CFB.csv"),
                         error = function(e) NULL)
    }
  }
  if (is.null(master)) {
    warning("[PORTAL] master_cfb not available — portal team names won't be normalized")
    return(invisible(NULL))
  }

  cat(sprintf("[PORTAL] Fetching portal data for %d...\n", year))

  # On3 team-level index
  on3 <- tryCatch(
    scrape_portal_on3(year),
    error = function(e) { message("[PORTAL] On3 scrape failed: ", e$message); tibble() }
  )

  # Individual transfers (cfbfastR)
  indiv <- .fetch_cfbfastr_portal(year)

  # Compute team scores
  scores <- compute_team_portal_scores(on3, master)

  # Flag difference-makers and merge
  if (nrow(indiv) > 0) {
    dm <- tryCatch(
      flag_difference_makers(indiv, master),
      error = function(e) {
        message("[PORTAL] flag_difference_makers() failed: ", e$message)
        tibble()
      }
    )
    if (nrow(dm) > 0 && nrow(scores) > 0) {
      scores <- left_join(scores, dm, by = "canonical_name")
    } else if (nrow(dm) > 0) {
      scores <- dm
    }
  }

  # Fill missing flag cols
  if (nrow(scores) > 0) {
    if (!"n_difference_makers"  %in% names(scores))
      scores$n_difference_makers  <- 0L
    if (!"has_qb_upgrade"       %in% names(scores))
      scores$has_qb_upgrade       <- FALSE
    if (!"has_edge_upgrade"     %in% names(scores))
      scores$has_edge_upgrade     <- FALSE
    if (!"difference_maker_names" %in% names(scores))
      scores$difference_maker_names <- NA_character_

    n_dm <- sum(scores$n_difference_makers > 0, na.rm = TRUE)
    n_qb <- sum(isTRUE(scores$has_qb_upgrade), na.rm = TRUE)
    cat(sprintf("[PORTAL] %d teams with difference-makers | %d with QB upgrades\n",
                n_dm, n_qb))
  }

  assign("team_portal_scores", scores, envir = .GlobalEnv)
  cat("[PORTAL] team_portal_scores assigned to .GlobalEnv\n")
  invisible(scores)
}

# ==============================================================================
# CLI guard
# ==============================================================================
if (!exists(".portal_sourced_by_orchestrator")) {
  if (!interactive()) fetch_portal_data()
}
cat("[PORTAL] TRANSFER_PORTAL_CFB.R loaded.\n")
