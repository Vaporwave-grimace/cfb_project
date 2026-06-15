# ==============================================================================
# MOTIVATIONAL_FACTORS_CFB.R — Situational / Motivational Spread Adjustments
# Pipeline Step 14.5 (non-fatal, runs after BYE_WEEK_TRACKER)
#
# Detects four situational edges that are well-documented in CFB ATS research
# but absent from pure ratings-based models:
#
#   1. REVENGE GAME (+1.5 pts for the avenging team)
#      Team that lost to this same opponent last season at the same venue.
#      Source: CFBD /games?year={year-1} — one API call for the full last season.
#
#   2. BOWL ELIGIBILITY SPOT (+1.0 pts)
#      Team sitting at 5 wins going for bowl eligibility (win #6).
#      Source: current season results from cfbd_schedule (home/away points cols).
#
#   3. TRAP GAME (-1.5 pts for the vulnerable team)
#      A ranked team faces an unranked opponent THIS week while a ranked opponent
#      awaits next week. The ranked team is prone to a letdown.
#      Source: CFBD /rankings?year={year}&week={week} + next week's schedule.
#
#   4. RIVALRY GAME (±0 pts on spread, but flags for broadcast)
#      Traditional rivals playing each other — models tend to overvalue the
#      better-rated team; rivalry games historically cover at ~50% regardless.
#      Effect: dampens any edge > 7 pts by 1.5 pts toward 0 (softens conviction).
#      Source: hardcoded list of annual CFB rivalry matchups.
#
# Output: motivational_factors (.GlobalEnv)
#   game_id, canonical_home, canonical_away,
#   net_motiv_spread_adj,   — home perspective: positive = home team advantaged
#   motiv_flags             — pipe-separated: "REVENGE_HOME|TRAP_AWAY" etc.
#
# Usage:
#   source("scripts/MOTIVATIONAL_FACTORS_CFB.R")
#   run_motivational_factors()
# ==============================================================================

suppressMessages({
  library(tidyverse)
  library(httr)
  library(jsonlite)
})

# --------------------------------------------------------------------------
# Constants (all tunable post-season)
# --------------------------------------------------------------------------
REVENGE_ADJ_PTS      <- 1.5   # pts for team that lost to this opp last season
BOWL_ELIG_ADJ_PTS    <- 1.0   # pts for team gunning for bowl eligibility (win 6)
TRAP_GAME_ADJ_PTS    <- -1.5  # pts AGAINST vulnerable team in trap game
RIVALRY_SOFTEN_PTS   <- 1.5   # pts soften toward 0 when rivalry game detected

# --------------------------------------------------------------------------
# Hardcoded rivalry pairs (canonical_name format, order-independent)
# Teams in each pair play annually — model edges are historically unreliable.
# Update names if canonical_name changes in MASTER_CFB.csv.
# --------------------------------------------------------------------------
CFB_RIVALRIES <- list(
  c("Alabama", "Auburn"),                      # Iron Bowl
  c("Michigan", "Ohio State"),                 # The Game
  c("Army", "Navy"),                           # Army-Navy
  c("Florida", "Florida State"),               # Sunshine Showdown
  c("Georgia", "Georgia Tech"),
  c("Clemson", "South Carolina"),
  c("Oklahoma", "Oklahoma State"),             # Bedlam
  c("Texas", "Texas A&M"),                     # Battle of the Brazos (when played)
  c("USC", "UCLA"),                            # LA Rivalry
  c("Stanford", "California"),                 # Big Game
  c("Oregon", "Oregon State"),                 # Civil War
  c("Washington", "Washington State"),         # Apple Cup
  c("Iowa", "Iowa State"),                     # Cy-Hawk
  c("Minnesota", "Wisconsin"),                 # Paul Bunyan's Axe
  c("Kansas", "Kansas State"),                 # Sunflower Showdown
  c("Pittsburgh", "West Virginia"),            # Backyard Brawl
  c("Mississippi", "Mississippi State"),       # Egg Bowl
  c("LSU", "Tulane"),
  c("Notre Dame", "USC"),                      # Classic rivalry (when scheduled)
  c("TCU", "Baylor"),                          # Revivalry
  c("Air Force", "Army"),
  c("Air Force", "Navy"),
  c("BYU", "Utah"),                            # Holy War
  c("Utah", "Utah State"),
  c("Colorado", "Colorado State"),             # Rocky Mountain Showdown
  c("Michigan State", "Penn State"),
  c("Cincinnati", "Miami (OH)"),               # Battle of the Bricks
  c("Georgia Southern", "Georgia State")
)

# --------------------------------------------------------------------------
# CFBD API helper (reuses same pattern as SCRAPE_CFB_DATA.R)
# --------------------------------------------------------------------------
.cfbd_get_motiv <- function(endpoint, params = list(), api_key) {
  url  <- paste0("https://api.collegefootballdata.com", endpoint)
  resp <- GET(url,
              add_headers(Authorization = paste("Bearer", api_key)),
              query   = params,
              timeout(20))
  if (http_error(resp)) return(NULL)
  tryCatch(fromJSON(content(resp, "text", encoding = "UTF-8"), flatten = TRUE),
           error = function(e) NULL)
}

# --------------------------------------------------------------------------
# 1. Detect revenge games
#    Returns a tibble: canonical_name, is_revenge (TRUE if team lost to this
#    same opponent last season at the SAME site — road revenge counts more,
#    but we apply +1.5 regardless of site for simplicity).
# --------------------------------------------------------------------------
.detect_revenge_games <- function(games_df, api_key, year) {
  prior_year <- year - 1L
  cat(sprintf("[MOTIV] Fetching %d season results for revenge detection...\n", prior_year))

  prior_raw <- tryCatch(
    .cfbd_get_motiv("/games",
                    params  = list(year = prior_year, seasonType = "regular"),
                    api_key = api_key),
    error = function(e) NULL
  )

  if (is.null(prior_raw) || length(prior_raw) == 0) {
    cat("[MOTIV] Prior season fetch failed — skipping revenge detection.\n")
    return(tibble(game_id = character(), revenge_team = character(),
                  revenge_adj = numeric()))
  }

  prior <- as_tibble(prior_raw) %>%
    filter(!is.na(home_points), !is.na(away_points)) %>%
    transmute(
      prior_home = home_team,
      prior_away = away_team,
      home_won   = home_points > away_points
    )

  revenge_rows <- list()

  for (i in seq_len(nrow(games_df))) {
    g <- games_df[i, ]
    home <- g$canonical_home
    away <- g$canonical_away

    # Did home team lose to this away team last season?
    prior_matchup <- prior %>%
      filter(
        (str_detect(prior_home, fixed(word(home, 1))) &
           str_detect(prior_away, fixed(word(away, 1)))) |
        (str_detect(prior_away, fixed(word(home, 1))) &
           str_detect(prior_home, fixed(word(away, 1))))
      )

    if (nrow(prior_matchup) == 0) next

    pm <- prior_matchup[1, ]
    home_was_home_last_yr <- str_detect(pm$prior_home, fixed(word(home, 1)))

    home_lost_last_yr <- (home_was_home_last_yr  & !pm$home_won) |
                         (!home_was_home_last_yr &  pm$home_won)
    away_lost_last_yr <- (home_was_home_last_yr  &  pm$home_won) |
                         (!home_was_home_last_yr & !pm$home_won)

    if (home_lost_last_yr) {
      revenge_rows[[length(revenge_rows) + 1]] <- list(
        game_id = g$game_id, revenge_team = home, side = "home",
        adj = REVENGE_ADJ_PTS    # home team gets revenge boost → positive home adj
      )
    } else if (away_lost_last_yr) {
      revenge_rows[[length(revenge_rows) + 1]] <- list(
        game_id = g$game_id, revenge_team = away, side = "away",
        adj = -REVENGE_ADJ_PTS   # away team revenge → negative (away favoured)
      )
    }
  }

  if (length(revenge_rows) == 0) return(tibble())
  map_dfr(revenge_rows, as_tibble)
}

# --------------------------------------------------------------------------
# 2. Detect bowl eligibility spots
#    Team at exactly 5-X wins playing for bowl eligibility.
#    Uses cfbd_schedule results already in memory.
# --------------------------------------------------------------------------
.detect_bowl_eligibility <- function(games_df) {
  sched <- if (exists("cfbd_schedule", envir = .GlobalEnv)) {
    get("cfbd_schedule", envir = .GlobalEnv)
  } else NULL

  if (is.null(sched)) return(tibble())

  # Compute current W/L record from completed games (those with scores)
  completed <- sched %>%
    filter(!is.na(home_points), !is.na(away_points))

  if (nrow(completed) == 0) return(tibble())

  home_records <- completed %>%
    transmute(team = canonical_home,
              win  = as.integer(home_points > away_points))
  away_records <- completed %>%
    transmute(team = canonical_away,
              win  = as.integer(away_points > home_points))

  records <- bind_rows(home_records, away_records) %>%
    group_by(team) %>%
    summarise(wins = sum(win, na.rm = TRUE), .groups = "drop")

  bowl_elig_rows <- list()

  for (i in seq_len(nrow(games_df))) {
    g <- games_df[i, ]

    home_wins <- records$wins[records$team == g$canonical_home]
    away_wins <- records$wins[records$team == g$canonical_away]

    if (length(home_wins) > 0 && home_wins == 5L) {
      bowl_elig_rows[[length(bowl_elig_rows) + 1]] <- list(
        game_id = g$game_id, team = g$canonical_home, side = "home",
        adj = BOWL_ELIG_ADJ_PTS
      )
    }
    if (length(away_wins) > 0 && away_wins == 5L) {
      bowl_elig_rows[[length(bowl_elig_rows) + 1]] <- list(
        game_id = g$game_id, team = g$canonical_away, side = "away",
        adj = -BOWL_ELIG_ADJ_PTS  # away bowl chase → away advantaged → neg home adj
      )
    }
  }

  if (length(bowl_elig_rows) == 0) return(tibble())
  map_dfr(bowl_elig_rows, as_tibble)
}

# --------------------------------------------------------------------------
# 3. Detect trap games
#    A ranked team this week faces an unranked opponent, but plays a ranked
#    opponent NEXT week. Historically these teams underperform the spread.
# --------------------------------------------------------------------------
.detect_trap_games <- function(games_df, api_key, year, week) {
  cat(sprintf("[MOTIV] Fetching rankings (week %d) for trap game detection...\n", week))

  rankings_raw <- tryCatch(
    .cfbd_get_motiv("/rankings",
                    params  = list(year = year, week = week,
                                   seasonType = "regular"),
                    api_key = api_key),
    error = function(e) NULL
  )

  if (is.null(rankings_raw) || length(rankings_raw) == 0) {
    cat("[MOTIV] Rankings fetch failed — skipping trap game detection.\n")
    return(tibble())
  }

  # Extract AP Top 25 teams
  ranked_teams <- tryCatch({
    rdf <- as_tibble(rankings_raw) %>%
      filter(str_detect(name, "AP") | str_detect(name, "Coaches"))
    if (nrow(rdf) == 0) return(character(0))
    if ("ranks" %in% names(rdf)) {
      ranks_unnested <- rdf %>%
        slice(1) %>%
        pull(ranks) %>%
        `[[`(1) %>%
        as_tibble()
      if ("school" %in% names(ranks_unnested)) ranks_unnested$school else character(0)
    } else character(0)
  }, error = function(e) character(0))

  if (length(ranked_teams) == 0) {
    cat("[MOTIV] Could not parse rankings — skipping trap game detection.\n")
    return(tibble())
  }

  # Fetch next week's schedule (non-fatal)
  next_week_raw <- tryCatch(
    .cfbd_get_motiv("/games",
                    params  = list(year = year, week = week + 1L,
                                   seasonType = "regular"),
                    api_key = api_key),
    error = function(e) NULL
  )

  next_opponents <- list()  # canonical_name → next opponent canonical_name
  if (!is.null(next_week_raw) && length(next_week_raw) > 0) {
    nw <- as_tibble(next_week_raw)
    if (all(c("home_team", "away_team") %in% names(nw))) {
      for (j in seq_len(nrow(nw))) {
        next_opponents[[nw$home_team[j]]] <- nw$away_team[j]
        next_opponents[[nw$away_team[j]]] <- nw$home_team[j]
      }
    }
  }

  is_ranked <- function(team_canonical) {
    any(str_detect(ranked_teams, fixed(word(team_canonical, 1))))
  }

  next_opp_is_ranked <- function(team_canonical) {
    next_opp <- next_opponents[[team_canonical]] %||%
                next_opponents[[word(team_canonical, 1)]]
    if (is.null(next_opp)) return(FALSE)
    is_ranked(next_opp)
  }

  trap_rows <- list()

  for (i in seq_len(nrow(games_df))) {
    g <- games_df[i, ]
    home <- g$canonical_home
    away <- g$canonical_away

    home_ranked <- is_ranked(home)
    away_ranked <- is_ranked(away)

    # Trap: ranked team facing unranked opp this week AND ranked opp next week
    if (home_ranked && !away_ranked && next_opp_is_ranked(home)) {
      trap_rows[[length(trap_rows) + 1]] <- list(
        game_id = g$game_id, trap_team = home, side = "home",
        adj = TRAP_GAME_ADJ_PTS   # home team in trap → shift against home
      )
    }
    if (away_ranked && !home_ranked && next_opp_is_ranked(away)) {
      trap_rows[[length(trap_rows) + 1]] <- list(
        game_id = g$game_id, trap_team = away, side = "away",
        adj = -TRAP_GAME_ADJ_PTS  # away team in trap → shift toward home
      )
    }
  }

  if (length(trap_rows) == 0) return(tibble())
  map_dfr(trap_rows, as_tibble)
}

# --------------------------------------------------------------------------
# 4. Detect rivalry games
#    Returns a logical per game_id — no spread adj, used to soften large edges.
# --------------------------------------------------------------------------
.detect_rivalry_games <- function(games_df) {
  rivalry_flags <- character(0)

  for (i in seq_len(nrow(games_df))) {
    g <- games_df[i, ]
    home <- g$canonical_home
    away <- g$canonical_away

    is_rival <- any(sapply(CFB_RIVALRIES, function(pair) {
      (home %in% pair && away %in% pair)
    }))

    if (is_rival) rivalry_flags <- c(rivalry_flags, g$game_id)
  }

  rivalry_flags
}

# --------------------------------------------------------------------------
# Main entry point
# --------------------------------------------------------------------------
run_motivational_factors <- function() {
  cat("[MOTIV] Computing motivational factors...\n")

  if (!exists("games_with_predictions", envir = .GlobalEnv) &&
      !exists("odds_data", envir = .GlobalEnv)) {
    cat("[MOTIV] No game data found — skipping.\n")
    return(invisible(NULL))
  }

  # Use odds_data (available at Step 14.5 — after BYE_WEEK_TRACKER)
  games_df <- if (exists("odds_data", envir = .GlobalEnv)) {
    get("odds_data", envir = .GlobalEnv)
  } else {
    get("games_with_predictions", envir = .GlobalEnv)
  }

  if (!all(c("canonical_home", "canonical_away", "game_id") %in% names(games_df))) {
    cat("[MOTIV] Games data missing required columns — skipping.\n")
    return(invisible(NULL))
  }

  # Load credentials + current year/week
  creds   <- tryCatch(load_credentials(), error = function(e) NULL)
  api_key <- creds$cfbd_api_key %||% NULL

  yr <- as.integer(format(Sys.Date(), "%Y"))
  mo <- as.integer(format(Sys.Date(), "%m"))
  year <- if (mo < 7) yr - 1L else yr

  # Infer current week — check multiple sources in order of availability.
  # games_with_predictions only exists AFTER Step 13; cfbd_schedule is set at
  # Step 4. Running at Step 12.5 means cfbd_schedule is the primary source.
  week <- tryCatch({
    gp <- if (exists("games_with_predictions", envir = .GlobalEnv))
            get("games_with_predictions", envir = .GlobalEnv)
          else NULL
    if (!is.null(gp) && "week_num" %in% names(gp)) {
      as.integer(gp$week_num[1])
    } else if (exists("cfbd_schedule", envir = .GlobalEnv)) {
      sched <- get("cfbd_schedule", envir = .GlobalEnv)
      if ("week" %in% names(sched) && nrow(sched) > 0) as.integer(sched$week[1])
      else 1L
    } else 1L
  }, error = function(e) 1L)

  # Initialise per-game adjustment accumulator
  game_adjs <- tibble(
    game_id              = games_df$game_id,
    canonical_home       = games_df$canonical_home,
    canonical_away       = games_df$canonical_away,
    net_motiv_spread_adj = 0,
    motiv_flags          = ""
  )

  add_adj <- function(acc, rows, flag_prefix) {
    if (nrow(rows) == 0) return(acc)
    for (i in seq_len(nrow(rows))) {
      r   <- rows[i, ]
      idx <- which(acc$game_id == r$game_id)
      if (length(idx) == 0) next
      acc$net_motiv_spread_adj[idx] <- acc$net_motiv_spread_adj[idx] + r$adj
      flag <- sprintf("%s_%s", flag_prefix, toupper(r$side))
      acc$motiv_flags[idx] <- paste(
        Filter(nzchar, c(acc$motiv_flags[idx], flag)), collapse = "|"
      )
    }
    acc
  }

  # --- Revenge games ---
  if (!is.null(api_key)) {
    revenge <- tryCatch(
      .detect_revenge_games(games_df, api_key, year),
      error = function(e) {
        cat(sprintf("[MOTIV] Revenge detection error: %s\n", e$message))
        tibble()
      }
    )
    if (nrow(revenge) > 0) {
      n_rev <- nrow(revenge)
      cat(sprintf("[MOTIV] Revenge games found: %d\n", n_rev))
      game_adjs <- add_adj(game_adjs, revenge, "REVENGE")
    }
  }

  # --- Bowl eligibility ---
  bowl <- tryCatch(
    .detect_bowl_eligibility(games_df),
    error = function(e) {
      cat(sprintf("[MOTIV] Bowl eligibility error: %s\n", e$message))
      tibble()
    }
  )
  if (nrow(bowl) > 0) {
    cat(sprintf("[MOTIV] Bowl eligibility spots: %d\n", nrow(bowl)))
    game_adjs <- add_adj(game_adjs, bowl, "BOWL_ELIG")
  }

  # --- Trap games ---
  if (!is.null(api_key)) {
    trap <- tryCatch(
      .detect_trap_games(games_df, api_key, year, week),
      error = function(e) {
        cat(sprintf("[MOTIV] Trap game error: %s\n", e$message))
        tibble()
      }
    )
    if (nrow(trap) > 0) {
      cat(sprintf("[MOTIV] Trap games detected: %d\n", nrow(trap)))
      game_adjs <- add_adj(game_adjs, trap, "TRAP")
    }
  }

  # --- Rivalry dampening (applies to spread conviction, not raw adj) ---
  rivalry_game_ids <- tryCatch(
    .detect_rivalry_games(games_df),
    error = function(e) character(0)
  )
  if (length(rivalry_game_ids) > 0) {
    cat(sprintf("[MOTIV] Rivalry games: %d\n", length(rivalry_game_ids)))
    for (gid in rivalry_game_ids) {
      idx <- which(game_adjs$game_id == gid)
      if (length(idx) == 0) next
      game_adjs$motiv_flags[idx] <- paste(
        Filter(nzchar, c(game_adjs$motiv_flags[idx], "RIVALRY")), collapse = "|"
      )
    }
  }

  # --- Summary ---
  n_adjusted <- sum(game_adjs$net_motiv_spread_adj != 0 | nzchar(game_adjs$motiv_flags))
  cat(sprintf("[MOTIV] %d / %d games with motivational factors.\n",
              n_adjusted, nrow(game_adjs)))

  active <- game_adjs %>%
    filter(net_motiv_spread_adj != 0 | nzchar(motiv_flags))
  if (nrow(active) > 0) {
    for (i in seq_len(nrow(active))) {
      cat(sprintf("  %s @ %s: %+.1f pts [%s]\n",
                  active$canonical_away[i], active$canonical_home[i],
                  active$net_motiv_spread_adj[i], active$motiv_flags[i]))
    }
  }

  assign("motivational_factors", game_adjs, envir = .GlobalEnv)

  # Store rivalry game IDs separately so CALCULATE_VALUE can soften large edges
  assign("rivalry_game_ids", rivalry_game_ids, envir = .GlobalEnv)

  invisible(game_adjs)
}

if (!exists(".motiv_sourced_by_orchestrator")) {
  run_motivational_factors()
}

cat("[MOTIV] MOTIVATIONAL_FACTORS_CFB.R loaded.\n")
