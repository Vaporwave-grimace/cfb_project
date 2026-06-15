# ==============================================================================
# INJURY_SCRAPER_CFB.R — ESPN CFB Injury Status
# Pipeline Step 6.5 (non-fatal)
#
# Fetches current injury/availability status for all teams playing this week
# via ESPN's unofficial site API. Only polls teams on the current slate (from
# odds_data) — avoids iterating all 130 FBS teams (saves ~90 seconds).
#
# Adjustments applied (net from home perspective, passed to GENERATE_PREDICTIONS):
#   QB Out / Out For Season : spread -7.0 pts, total -3.0 pts
#   QB Doubtful             : spread -3.5 pts, total -1.5 pts
#   QB Questionable         : spread -1.5 pts, total -0.8 pts
#   Skill (RB/WR/TE) Out   : spread -0.5 pts each (capped at -2.0 pts)
#
# Output: injury_adjustments (.GlobalEnv)
#   canonical_name, spread_adj, total_adj, injury_flags
#
# Usage:
#   source("scripts/INJURY_SCRAPER_CFB.R")
#   run_injury_scraper_cfb()
# ==============================================================================

suppressMessages({
  library(tidyverse)
  library(httr2)
})

ESPN_CFB_BASE <- "https://site.api.espn.com/apis/site/v2/sports/football/college-football"

# --------------------------------------------------------------------------
# ESPN API helpers
# --------------------------------------------------------------------------
.espn_get <- function(path, params = list()) {
  resp <- tryCatch(
    request(ESPN_CFB_BASE) |>
      req_url_path_append(path) |>
      req_url_query(!!!params) |>
      req_headers(
        "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)",
        "Accept"     = "application/json"
      ) |>
      req_timeout(15) |>
      req_retry(max_tries = 2, backoff = \(i) 2^i) |>
      req_perform(),
    error = function(e) NULL
  )
  if (is.null(resp) || resp_status(resp) >= 400) return(NULL)
  tryCatch(resp_body_json(resp, simplifyVector = FALSE), error = function(e) NULL)
}

# Fetch all FBS teams from ESPN (group 80 = FBS)
.fetch_espn_cfb_teams <- function() {
  body <- .espn_get("teams", params = list(limit = 300, groups = 80))
  if (is.null(body)) return(NULL)

  teams_list <- tryCatch(
    body$sports[[1]]$leagues[[1]]$teams,
    error = function(e) NULL
  )
  if (is.null(teams_list) || length(teams_list) == 0) return(NULL)

  map_dfr(teams_list, \(t) tibble(
    espn_id   = t$team$id  %||% NA_character_,
    team_name = t$team$displayName %||% NA_character_,
    team_abbr = t$team$abbreviation %||% NA_character_
  ))
}

# Fetch roster + injury status for a single ESPN team ID
.fetch_team_injuries <- function(espn_id) {
  body <- .espn_get(paste0("teams/", espn_id, "/roster"))
  if (is.null(body)) return(tibble())

  athletes <- body$athletes
  if (is.null(athletes) || length(athletes) == 0) return(tibble())

  # ESPN returns athletes as grouped (has $items) or flat list
  first <- athletes[[1]]
  player_list <- if (!is.null(first$items)) {
    unlist(lapply(athletes, \(g) g$items %||% list()), recursive = FALSE)
  } else {
    athletes
  }
  if (length(player_list) == 0) return(tibble())

  map_dfr(player_list, function(a) {
    # Status: new format = plain character; old = nested list
    p_status <- tryCatch({
      s <- a$status
      if (is.character(s))       s
      else if (!is.null(s$type)) s$type$description %||% "Active"
      else "Active"
    }, error = function(e) "Active")

    pos <- tryCatch(
      a$position$abbreviation %||% NA_character_,
      error = function(e) NA_character_
    )
    injury_type <- tryCatch(
      a$injuries[[1]]$type$description %||% NA_character_,
      error = function(e) NA_character_
    )

    tibble(
      espn_id     = as.character(espn_id),
      player_name = a$fullName %||% NA_character_,
      position    = pos,
      status      = p_status,
      injury_type = injury_type
    )
  }) |>
    filter(!is.na(status), status != "Active")
}

# --------------------------------------------------------------------------
# Compute per-team spread/total adjustments from injury list
# --------------------------------------------------------------------------
.compute_team_adj <- function(team_injuries) {
  if (nrow(team_injuries) == 0) {
    return(tibble(spread_adj = 0, total_adj = 0, injury_flags = ""))
  }

  spread_adj <- 0
  total_adj  <- 0
  flags      <- character(0)

  qb_rows   <- team_injuries |> filter(position == "QB")
  skill_rows <- team_injuries |> filter(position %in% c("RB", "WR", "TE"),
                                         status %in% c("Out", "Out For Season"))

  # QB adjustments (only most-impactful status counts)
  if (nrow(qb_rows) > 0) {
    for (i in seq_len(nrow(qb_rows))) {
      s <- qb_rows$status[i]
      adj_sp <- case_when(
        s %in% c("Out", "Out For Season") ~ -7.0,
        s == "Doubtful"                   ~ -3.5,
        s == "Questionable"               ~ -1.5,
        TRUE                              ~ 0
      )
      adj_tot <- case_when(
        s %in% c("Out", "Out For Season") ~ -3.0,
        s == "Doubtful"                   ~ -1.5,
        s == "Questionable"               ~ -0.8,
        TRUE                              ~ 0
      )
      if (adj_sp != 0) {
        spread_adj <- spread_adj + adj_sp
        total_adj  <- total_adj  + adj_tot
        flags <- c(flags, sprintf("QB_%s(%s)", s, qb_rows$player_name[i]))
      }
    }
  }

  # Skill position Out adjustments — capped at -2.0 pts combined
  if (nrow(skill_rows) > 0) {
    skill_adj <- max(-2.0, nrow(skill_rows) * -0.5)
    spread_adj <- spread_adj + skill_adj
    flags <- c(flags, sprintf("%d_SKILL_OUT", nrow(skill_rows)))
  }

  tibble(
    spread_adj   = round(spread_adj, 2),
    total_adj    = round(total_adj,  2),
    injury_flags = paste(flags, collapse = "|")
  )
}

# --------------------------------------------------------------------------
# Main entry point
# --------------------------------------------------------------------------
run_injury_scraper_cfb <- function(master = NULL) {
  cat("[INJURY] Fetching ESPN CFB injury reports...\n")

  # Only poll teams on THIS WEEK'S slate — avoids iterating all 130 FBS teams
  if (!exists("odds_data", envir = .GlobalEnv)) {
    cat("[INJURY] odds_data not found — run fetch_odds_football.R first. Skipping.\n")
    return(invisible(NULL))
  }
  odds <- get("odds_data", envir = .GlobalEnv)
  active_teams <- unique(c(odds$canonical_home, odds$canonical_away))
  cat(sprintf("[INJURY] Active teams this week: %d\n", length(active_teams)))

  if (is.null(master)) {
    master <- if (exists("master_cfb", envir = .GlobalEnv)) {
      get("master_cfb", envir = .GlobalEnv)
    } else {
      tryCatch(load_cfb_master("team_name_mappings_MASTER_CFB.csv"),
               error = function(e) NULL)
    }
  }

  # Fetch ESPN team ID lookup (once per run, cached in session)
  espn_teams <- tryCatch(.fetch_espn_cfb_teams(), error = function(e) NULL)
  if (is.null(espn_teams) || nrow(espn_teams) == 0) {
    cat("[INJURY] ESPN team list fetch failed — skipping injury adjustments.\n")
    return(invisible(NULL))
  }

  # Match active canonical names → ESPN team IDs via fuzzy name match
  results <- map_dfr(active_teams, function(canonical) {
    # Try to find ESPN team by matching canonical name against ESPN display names
    match_idx <- which(
      str_detect(
        str_to_lower(espn_teams$team_name),
        str_to_lower(word(canonical, -1))   # last word of canonical (e.g. "Crimson Tide" → "Tide")
      )
    )
    # Prefer exact match if multiple hits
    exact_idx <- which(str_to_lower(espn_teams$team_name) == str_to_lower(canonical))
    idx <- if (length(exact_idx) > 0) exact_idx[1] else if (length(match_idx) > 0) match_idx[1] else NA_integer_

    if (is.na(idx)) {
      cat(sprintf("[INJURY] No ESPN match for: %s\n", canonical))
      return(tibble(canonical_name = canonical, spread_adj = 0,
                    total_adj = 0, injury_flags = "NO_ESPN_MATCH"))
    }

    espn_id   <- espn_teams$espn_id[idx]
    Sys.sleep(0.3)   # polite rate limit
    injuries <- tryCatch(.fetch_team_injuries(espn_id), error = function(e) tibble())
    adj <- .compute_team_adj(injuries)

    bind_cols(tibble(canonical_name = canonical), adj)
  })

  n_impacted <- sum(results$spread_adj != 0)
  cat(sprintf("[INJURY] %d / %d teams with injury adjustments.\n",
              n_impacted, length(active_teams)))
  if (n_impacted > 0) {
    impacted <- results |> filter(spread_adj != 0)
    for (i in seq_len(nrow(impacted))) {
      cat(sprintf("  %s: spread %+.1f | total %+.1f | %s\n",
                  impacted$canonical_name[i],
                  impacted$spread_adj[i],
                  impacted$total_adj[i],
                  impacted$injury_flags[i]))
    }
  }

  assign("injury_adjustments", results, envir = .GlobalEnv)
  invisible(results)
}

if (!exists(".injury_sourced_by_orchestrator")) {
  run_injury_scraper_cfb()
}

cat("[INJURY] INJURY_SCRAPER_CFB.R loaded.\n")
