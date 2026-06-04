# ==============================================================================
# db_init_bets.R — Initialize cfb_bets.sqlite + backfill from bet_history.csv
# Run ONCE (Session 14 migration). Safe to re-run — idempotent.
#
# Creates: outputs/cfb_bets.sqlite  (table: cfb_bets)
# Schema:  bet_id TEXT PK | all FINALIZE_BETS_CFB columns | settled INTEGER
#
# If outputs/bet_history.csv exists, existing rows are imported.
# Duplicate bet_id values are silently skipped (INSERT OR IGNORE).
# ==============================================================================

suppressMessages(library(tidyverse))
suppressMessages(library(DBI))
suppressMessages(library(RSQLite))

source("scripts/CONFIG.R")

# ------------------------------------------------------------------------------
# 1. Open / create database
# ------------------------------------------------------------------------------
con <- dbConnect(RSQLite::SQLite(), CFB_BETS_DB)
cat(sprintf("[DB_INIT] Connected to %s\n", CFB_BETS_DB))

# Enable WAL for safer concurrent access
dbExecute(con, "PRAGMA journal_mode=WAL")

# ------------------------------------------------------------------------------
# 2. Create table (idempotent)
# ------------------------------------------------------------------------------
dbExecute(con, "
  CREATE TABLE IF NOT EXISTS cfb_bets (
    bet_id             TEXT PRIMARY KEY,
    game_id            TEXT,
    canonical_away     TEXT,
    canonical_home     TEXT,
    bet_type           TEXT,
    bet_side           TEXT,
    posted_line        REAL,
    juice              REAL,
    bet_amount         REAL,
    win_prob_raw       REAL,
    proj_line          REAL,
    edge               REAL,
    ev                 REAL,
    boost              REAL,
    boost_flags        TEXT,
    commence_time      TEXT,
    placed_at          TEXT,
    result             TEXT    DEFAULT 'pending',
    pl                 REAL,
    spread_clv_cents   REAL,
    total_clv_cents    REAL,
    ml_clv_cents       REAL,
    settled            INTEGER DEFAULT 0
  )
")
cat("[DB_INIT] Table cfb_bets ready.\n")

# Unique index as safety net (PK already enforces, but belt-and-suspenders)
dbExecute(con, "
  CREATE UNIQUE INDEX IF NOT EXISTS idx_bet_id ON cfb_bets(bet_id)
")

# ------------------------------------------------------------------------------
# 3. Backfill from legacy CSV (if it exists)
# ------------------------------------------------------------------------------
if (file.exists(BET_HISTORY_CSV)) {

  legacy <- read_csv(BET_HISTORY_CSV, show_col_types = FALSE)

  if (nrow(legacy) == 0) {
    cat("[DB_INIT] bet_history.csv is empty — nothing to backfill.\n")
  } else {

    # Normalise: rename bet_idx -> bet_id; add settled flag derived from result
    legacy_clean <- legacy %>%
      rename(bet_id = bet_idx) %>%
      mutate(
        settled = as.integer(!is.na(result) & result != "pending"),
        placed_at = as.character(placed_at),
        commence_time = as.character(commence_time)
      ) %>%
      # Keep only columns that exist in the DB schema
      select(any_of(c(
        "bet_id", "game_id", "canonical_away", "canonical_home",
        "bet_type", "bet_side", "posted_line", "juice", "bet_amount",
        "win_prob_raw", "proj_line", "edge", "ev", "boost", "boost_flags",
        "commence_time", "placed_at", "result", "pl",
        "spread_clv_cents", "total_clv_cents", "ml_clv_cents", "settled"
      )))

    # Fetch already-loaded IDs to skip duplicates
    existing_ids <- dbGetQuery(con, "SELECT bet_id FROM cfb_bets")$bet_id
    to_insert    <- legacy_clean %>% filter(!bet_id %in% existing_ids)

    if (nrow(to_insert) == 0) {
      cat("[DB_INIT] All CSV rows already present in DB — no backfill needed.\n")
    } else {
      dbWriteTable(con, "cfb_bets", to_insert, append = TRUE, row.names = FALSE)
      cat(sprintf("[DB_INIT] Backfilled %d row(s) from bet_history.csv\n",
                  nrow(to_insert)))
    }
  }

} else {
  cat("[DB_INIT] No bet_history.csv found — starting fresh.\n")
}

# ------------------------------------------------------------------------------
# 4. Summary
# ------------------------------------------------------------------------------
n_total    <- dbGetQuery(con, "SELECT COUNT(*)   FROM cfb_bets")[[1]]
n_settled  <- dbGetQuery(con, "SELECT COUNT(*)   FROM cfb_bets WHERE settled = 1")[[1]]
n_pending  <- dbGetQuery(con, "SELECT COUNT(*)   FROM cfb_bets WHERE settled = 0")[[1]]

cat(sprintf("[DB_INIT] cfb_bets: %d total | %d settled | %d pending\n",
            n_total, n_settled, n_pending))

dbDisconnect(con)
cat("[DB_INIT] db_init_bets.R complete. Run this script ONCE, then use\n")
cat("[DB_INIT] FINALIZE_BETS_CFB.R and BET_SETTLEMENT.R normally.\n")
