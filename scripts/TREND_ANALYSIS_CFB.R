# ==============================================================================
# TREND_ANALYSIS_CFB.R — Line Movement Trend Signals
# Pipeline Step 8 (non-fatal)
#
# Reads line_movement_log.csv (written/appended by fetch_odds_football.R).
# Computes:
#   trend_direction — "home" | "away" | "over" | "under" | NA (no clear move)
#   move_magnitude  — total points moved from open to current
#   sharp_flag      — TRUE if move >= SHARP_MOVE_SPREAD threshold
#   reverse_line    — TRUE if public % and line moved opposite directions
#                     (classic sharp money signal)
#
# Output: trend_signals tibble → .GlobalEnv
# ==============================================================================

suppressMessages(library(tidyverse))
suppressMessages(library(DBI))
suppressMessages(library(RSQLite))

analyze_trends <- function() {

  db_path <- "outputs/cfb_line_movement.sqlite"

  if (!file.exists(db_path)) {
    cat("[TREND] No line movement DB found — trend signals unavailable.\n")
    assign("trend_signals", NULL, envir = .GlobalEnv)
    return(invisible(NULL))
  }

  con <- dbConnect(RSQLite::SQLite(), db_path)
  on.exit(dbDisconnect(con), add = TRUE)

  if (!dbExistsTable(con, "line_movement")) {
    cat("[TREND] line_movement table not yet created — trend signals unavailable.\n")
    assign("trend_signals", NULL, envir = .GlobalEnv)
    return(invisible(NULL))
  }

  n_rows <- dbGetQuery(con, "SELECT COUNT(*) AS n FROM line_movement")$n
  if (n_rows < 2) {
    cat("[TREND] Insufficient movement history (need 2+ snapshots).\n")
    assign("trend_signals", NULL, envir = .GlobalEnv)
    return(invisible(NULL))
  }

  # Opening line per game = values at the earliest logged_at snapshot
  opens <- dbGetQuery(con,
    "SELECT l.id,
            l.dk_spread_home AS open_spread,
            l.dk_total       AS open_total,
            l.dk_ml_home     AS open_ml_home,
            l.dk_ml_away     AS open_ml_away
     FROM   line_movement l
     INNER JOIN (
       SELECT id, MIN(logged_at) AS first_seen
       FROM   line_movement
       GROUP  BY id
     ) m ON l.id = m.id AND l.logged_at = m.first_seen")

  # Current line per game = values at the latest logged_at snapshot
  currents <- dbGetQuery(con,
    "SELECT l.id,
            l.dk_spread_home AS curr_spread,
            l.dk_total       AS curr_total,
            l.dk_ml_home     AS curr_ml_home,
            l.dk_ml_away     AS curr_ml_away
     FROM   line_movement l
     INNER JOIN (
       SELECT id, MAX(logged_at) AS last_seen
       FROM   line_movement
       GROUP  BY id
     ) m ON l.id = m.id AND l.logged_at = m.last_seen")

  trends <- left_join(opens, currents, by = "id") %>%
    mutate(
      spread_move = curr_spread - open_spread,
      total_move  = curr_total  - open_total,

      # Spread direction: negative move = line moved toward home (home getting
      # cheaper = sharp money on home)
      trend_direction = case_when(
        abs(spread_move) >= SHARP_MOVE_SPREAD & spread_move < 0 ~ "home",
        abs(spread_move) >= SHARP_MOVE_SPREAD & spread_move > 0 ~ "away",
        abs(total_move)  >= SHARP_MOVE_TOTAL  & total_move  > 0 ~ "over",
        abs(total_move)  >= SHARP_MOVE_TOTAL  & total_move  < 0 ~ "under",
        TRUE ~ NA_character_
      ),

      move_magnitude = pmax(abs(spread_move), abs(total_move), na.rm = TRUE),
      sharp_flag     = move_magnitude >= SHARP_MOVE_SPREAD,

      # Reverse line movement: if spread moved toward home but ML moved against
      # home (implies public on home but sharp $ on away)
      ml_move_home   = coalesce(curr_ml_home, open_ml_home) -
                         coalesce(open_ml_home, curr_ml_home),
      reverse_line   = case_when(
        trend_direction == "home" & ml_move_home > 5  ~ TRUE,
        trend_direction == "away" & ml_move_home < -5 ~ TRUE,
        TRUE ~ FALSE
      )
    )

  # Map Odds API id → canonical game_id via odds_data (Step 7 output)
  # odds_data has both `id` and `game_id` after Step 11 normalization.
  if (exists("odds_data", envir = .GlobalEnv)) {
    od <- get("odds_data", envir = .GlobalEnv)
    if ("game_id" %in% names(od) && "id" %in% names(od)) {
      id_map <- od %>% select(id, game_id) %>% filter(!is.na(game_id))
      trends <- trends %>%
        left_join(id_map, by = "id") %>%
        filter(!is.na(game_id)) %>%
        select(-id)
    } else {
      trends <- trends %>% rename(game_id = id)
    }
  } else {
    trends <- trends %>% rename(game_id = id)
  }

  trends <- trends %>%
    select(game_id, trend_direction, move_magnitude, sharp_flag, reverse_line,
           spread_move, total_move)

  n_sharp <- sum(trends$sharp_flag, na.rm = TRUE)
  n_reverse <- sum(trends$reverse_line, na.rm = TRUE)
  cat(sprintf("[TREND] %d games | %d sharp moves | %d reverse line signals.\n",
              nrow(trends), n_sharp, n_reverse))

  assign("trend_signals", trends, envir = .GlobalEnv)
  invisible(trends)
}

analyze_trends()
cat("[TREND] TREND_ANALYSIS_CFB.R complete.\n")
