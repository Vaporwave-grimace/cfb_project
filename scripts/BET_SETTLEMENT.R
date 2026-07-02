# ==============================================================================
# BET_SETTLEMENT.R — ATS / Total / ML Settlement + 3-Stream CLV
# Pipeline Step 2 (non-fatal — skipped if no scores file)
#
# Inputs:
#   scores CSV  — clean/cfb_scores_YYYYMMDD.csv (manual or API pull)
#     required cols: game_id, home_score, away_score
#   bet ledger  — outputs/cfb_bets.sqlite (cfb_bets table)
#
# Settlement logic:
#   SPREAD: home_score - away_score vs posted_line (covers/pushes/losses)
#   TOTAL:  home_score + away_score vs posted_line (over/under/push)
#   ML:     winner vs bet_side
#
# CLV (Closing Line Value):
#   spread_clv_cents = (closing_spread - placement_spread) * 10
#   total_clv_cents  = (closing_total  - placement_total)  * 10
#   ml_clv_cents     = closing_ml_prob - placement_ml_prob (in cents/dollar)
#   Positive CLV = beat the closing line = good bet regardless of outcome
#
# Session 14: migrated from full CSV rewrite → atomic row-level UPDATEs.
# Pending query:  SELECT * FROM cfb_bets WHERE settled = 0
# Settlement:     UPDATE cfb_bets SET result=?, pl=?, ...clv...?, settled=1
#                 WHERE bet_id=?
# ==============================================================================

suppressMessages(library(tidyverse))
suppressMessages(library(DBI))
suppressMessages(library(RSQLite))

# ------------------------------------------------------------------------------
# load_closing_lines()
#
# Queries outputs/cfb_line_movement.sqlite and returns the last DK snapshot
# captured at or before each pending bet's commence_time. Used as the
# `closing_lines` argument to settle_bets() for CLV calculation.
#
# Requires: LINE_MOVEMENT_LOGGER_CFB.R must have run at least once with
#           canonical game_id populated (i.e., hourly scheduler is active).
#           Returns NULL gracefully if DB is absent or has no canonical ids.
# ------------------------------------------------------------------------------
load_closing_lines <- function(db_path = "C:/Users/Mike/sports_data/cfb_line_movement.sqlite") {

  if (!file.exists(db_path)) {
    cat("[SETTLE] No line movement DB — CLV will be NA.\n")
    return(NULL)
  }

  con <- dbConnect(RSQLite::SQLite(), db_path)
  on.exit(dbDisconnect(con), add = TRUE)

  if (!dbExistsTable(con, "line_movement")) {
    cat("[SETTLE] line_movement table not yet created — CLV will be NA.\n")
    return(NULL)
  }

  n_canonical <- dbGetQuery(con,
    "SELECT COUNT(*) AS n FROM line_movement WHERE game_id IS NOT NULL")$n
  if (n_canonical == 0) {
    cat("[SETTLE] Log has no canonical game_id entries yet — CLV will be NA.\n")
    return(NULL)
  }

  # Scope to pending bet game_ids from cfb_bets.sqlite
  if (!file.exists(CFB_BETS_DB)) return(NULL)
  con_bets <- dbConnect(RSQLite::SQLite(), CFB_BETS_DB)
  pending_ids <- dbGetQuery(con_bets,
    "SELECT DISTINCT game_id FROM cfb_bets WHERE settled = 0")$game_id
  dbDisconnect(con_bets)

  if (length(pending_ids) == 0) return(NULL)

  ids_sql <- paste0("'", paste(pending_ids, collapse = "','"), "'")

  # Closing line = last snapshot per game captured at or before commence_time
  closing <- dbGetQuery(con, sprintf(
    "SELECT l.game_id,
            l.dk_spread_home,
            l.dk_total,
            l.dk_ml_home,
            l.dk_ml_away,
            l.logged_at AS closing_captured_at
     FROM   line_movement l
     INNER JOIN (
       SELECT game_id, MAX(logged_at) AS last_before_start
       FROM   line_movement
       WHERE  game_id IN (%s)
         AND  game_id IS NOT NULL
         AND  logged_at <= commence_time
       GROUP  BY game_id
     ) m ON l.game_id = m.game_id AND l.logged_at = m.last_before_start",
    ids_sql
  ))

  if (nrow(closing) == 0) {
    cat("[SETTLE] No closing line snapshots for pending bets — CLV will be NA.\n")
    return(NULL)
  }

  cat(sprintf("[SETTLE] Closing lines found for %d / %d pending game(s).\n",
              nrow(closing), length(pending_ids)))

  closing
}

settle_bets <- function(scores, closing_lines = NULL) {

  if (!file.exists(CFB_BETS_DB)) {
    cat("[SETTLE] cfb_bets.sqlite not found — run db_init_bets.R first.\n")
    return(invisible(list(net_pl = 0, n_settled = 0)))
  }

  con <- dbConnect(RSQLite::SQLite(), CFB_BETS_DB)
  on.exit(dbDisconnect(con), add = TRUE)

  # Only fetch unsettled bets — no full-table read
  unsettled <- dbGetQuery(con, "SELECT * FROM cfb_bets WHERE settled = 0")

  if (nrow(unsettled) == 0) {
    cat("[SETTLE] No unsettled bets.\n")
    return(invisible(list(net_pl = 0, n_settled = 0)))
  }

  cat(sprintf("[SETTLE] Settling %d bet(s)...\n", nrow(unsettled)))

  # Join scores onto unsettled bets by game_id
  to_settle <- unsettled %>%
    left_join(
      scores %>% select(game_id, home_score, away_score),
      by = "game_id"
    ) %>%
    filter(!is.na(home_score), !is.na(away_score))

  if (nrow(to_settle) == 0) {
    cat("[SETTLE] No matching scores found for unsettled bets.\n")
    return(invisible(list(net_pl = 0, n_settled = 0)))
  }

  # --- Settlement by market ---
  to_settle <- to_settle %>%
    mutate(
      actual_margin = home_score - away_score,
      actual_total  = home_score + away_score,

      result = case_when(
        # SPREAD
        bet_type == "SPREAD" & bet_side == "home" &
          actual_margin > -posted_line          ~ "win",
        bet_type == "SPREAD" & bet_side == "home" &
          actual_margin == -posted_line         ~ "push",
        bet_type == "SPREAD" & bet_side == "home" ~ "loss",

        # Away bet: posted_line = +dk_away_spread (positive, e.g. +7 for underdog)
        # Away covers if home margin is LESS than posted_line (not -posted_line!)
        bet_type == "SPREAD" & bet_side == "away" &
          actual_margin < posted_line           ~ "win",
        bet_type == "SPREAD" & bet_side == "away" &
          actual_margin == posted_line          ~ "push",
        bet_type == "SPREAD" & bet_side == "away" ~ "loss",

        # TOTAL
        bet_type == "TOTAL" & bet_side == "over"  &
          actual_total > posted_line            ~ "win",
        bet_type == "TOTAL" & bet_side == "over"  &
          actual_total == posted_line           ~ "push",
        bet_type == "TOTAL" & bet_side == "over"  ~ "loss",

        bet_type == "TOTAL" & bet_side == "under" &
          actual_total < posted_line            ~ "win",
        bet_type == "TOTAL" & bet_side == "under" &
          actual_total == posted_line           ~ "push",
        bet_type == "TOTAL" & bet_side == "under" ~ "loss",

        # ML
        bet_type == "ML" & bet_side == "home" &
          actual_margin > 0                     ~ "win",
        bet_type == "ML" & bet_side == "home"   ~ "loss",
        bet_type == "ML" & bet_side == "away" &
          actual_margin < 0                     ~ "win",
        bet_type == "ML" & bet_side == "away"   ~ "loss",

        TRUE ~ "pending"
      ),

      # P&L
      pl = case_when(
        result == "win"  ~ bet_amount * (american_to_decimal(juice) - 1),
        result == "push" ~ 0,
        result == "loss" ~ -bet_amount,
        TRUE             ~ NA_real_
      )
    )

  # --- CLV calculation ---
  if (!is.null(closing_lines)) {
    to_settle <- to_settle %>%
      left_join(
        closing_lines %>%
          select(game_id,
                 closing_spread  = dk_spread_home,
                 closing_total   = dk_total,
                 closing_ml_home = dk_ml_home,
                 closing_ml_away = dk_ml_away),
        by = "game_id"
      ) %>%
      mutate(
        spread_clv_cents = case_when(
          # Home bet: posted_line < 0 (home perspective), closing_spread < 0.
          # Beat close = posted_line is smaller (less negative) than closing_spread.
          # Example: posted -3, close -7 → (-3 - (-7)) * 10 = +40 cents ✓
          bet_type == "SPREAD" & bet_side == "home" ~
            (posted_line - closing_spread) * 10,
          # Away bet: posted_line > 0 (away perspective, e.g. +7).
          # closing_spread is in home perspective (negative, e.g. -6 = away +6).
          # CLV = (posted_line + closing_spread) * 10
          # Example: posted +7, close home -6 (away +6) → (7 + (-6)) * 10 = +10 cents ✓
          bet_type == "SPREAD" & bet_side == "away" ~
            (posted_line + closing_spread) * 10,
          TRUE ~ NA_real_
        ),
        total_clv_cents = case_when(
          bet_type == "TOTAL" & bet_side == "over"  ~
            (closing_total - posted_line) * 10,
          bet_type == "TOTAL" & bet_side == "under" ~
            (posted_line - closing_total) * 10,
          TRUE ~ NA_real_
        ),
        ml_clv_cents = case_when(
          bet_type == "ML" & bet_side == "home" ~
            (american_to_prob(posted_line) -
               american_to_prob(closing_ml_home)) * 100,
          bet_type == "ML" & bet_side == "away" ~
            (american_to_prob(posted_line) -
               american_to_prob(closing_ml_away)) * 100,
          TRUE ~ NA_real_
        )
      )
  } else {
    to_settle <- to_settle %>%
      mutate(spread_clv_cents = NA_real_,
             total_clv_cents  = NA_real_,
             ml_clv_cents     = NA_real_)
  }

  # --- Atomic row-level UPDATE for each settled bet ---
  settled_rows <- to_settle %>% filter(result != "pending")

  if (nrow(settled_rows) > 0) {
    purrr::pwalk(
      settled_rows %>%
        select(bet_id, result, pl,
               spread_clv_cents, total_clv_cents, ml_clv_cents),
      function(bet_id, result, pl,
               spread_clv_cents, total_clv_cents, ml_clv_cents) {
        dbExecute(con,
          "UPDATE cfb_bets
              SET result           = ?,
                  pl               = ?,
                  spread_clv_cents = ?,
                  total_clv_cents  = ?,
                  ml_clv_cents     = ?,
                  settled          = 1
            WHERE bet_id = ?",
          params = list(result, pl,
                        spread_clv_cents, total_clv_cents, ml_clv_cents,
                        bet_id)
        )
      }
    )
    cat(sprintf("[SETTLE] Updated %d row(s) in cfb_bets.sqlite\n",
                nrow(settled_rows)))
  }

  # --- Update bankroll ---
  net_pl   <- sum(settled_rows$pl, na.rm = TRUE)
  n_wins   <- sum(settled_rows$result == "win",  na.rm = TRUE)
  n_losses <- sum(settled_rows$result == "loss", na.rm = TRUE)
  n_pushes <- sum(settled_rows$result == "push", na.rm = TRUE)

  bankroll <- as.numeric(readLines(BANKROLL_FILE, warn = FALSE)[1])
  writeLines(as.character(round(bankroll + net_pl, 2)), BANKROLL_FILE)

  cat(sprintf("[SETTLE] W:%d L:%d P:%d | Net P&L: $%.2f | New bankroll: $%.2f\n",
              n_wins, n_losses, n_pushes, net_pl, bankroll + net_pl))

  # CLV summary
  if (nrow(settled_rows %>% filter(!is.na(spread_clv_cents) |
                                    !is.na(total_clv_cents))) > 0) {
    cat(sprintf("[SETTLE] CLV — Spread: %.1f¢ | Total: %.1f¢ | ML: %.1f¢\n",
                mean(settled_rows$spread_clv_cents, na.rm = TRUE),
                mean(settled_rows$total_clv_cents,  na.rm = TRUE),
                mean(settled_rows$ml_clv_cents,     na.rm = TRUE)))
  }

  invisible(list(net_pl = net_pl, n_settled = nrow(settled_rows),
                 n_wins = n_wins, n_losses = n_losses, n_pushes = n_pushes))
}
cat("[SETTLE] BET_SETTLEMENT.R loaded.\n")
