# ==============================================================================
# db_schema_init.R — Initialize both CFB SQLite databases (idempotent)
# Run ONCE before first live use. Safe to re-run — all operations are IF NOT EXISTS.
#
# Handles:
#   1. outputs/cfb_bets.sqlite       — via db_init_bets.R (bet ledger + CLV cols)
#   2. outputs/cfb_line_movement.sqlite — line_movement table with schema + dedup index
#
# Why separate from db_init_bets.R:
#   db_init_bets.R handles the bet ledger (Session 14).
#   This script ensures BOTH DBs are fully initialized so BET_SETTLEMENT.R and
#   LINE_MOVEMENT_LOGGER_CFB.R can run without hitting missing-table errors.
# ==============================================================================

suppressMessages(library(DBI))
suppressMessages(library(RSQLite))

setwd("G:/My Drive/Scripting Projects/cfb_project")
source("scripts/CONFIG.R")

cat("[SCHEMA_INIT] Initializing CFB SQLite databases...\n")

# ------------------------------------------------------------------------------
# 1. cfb_bets.sqlite — delegate to db_init_bets.R
# ------------------------------------------------------------------------------
cat("[SCHEMA_INIT] Step 1: cfb_bets.sqlite\n")
source("scripts/db_init_bets.R")

# ------------------------------------------------------------------------------
# 2. cfb_line_movement.sqlite — line_movement table
#
# Schema mirrors LINE_MOVEMENT_LOGGER_CFB.R snapshot columns.
# Unique index on (id, logged_at) prevents duplicate hourly snapshots.
# ------------------------------------------------------------------------------
cat("[SCHEMA_INIT] Step 2: cfb_line_movement.sqlite\n")

LM_DB <- "outputs/cfb_line_movement.sqlite"

if (!dir.exists("outputs")) dir.create("outputs", recursive = TRUE)

con_lm <- dbConnect(RSQLite::SQLite(), LM_DB)
dbExecute(con_lm, "PRAGMA journal_mode=WAL")

dbExecute(con_lm, "
  CREATE TABLE IF NOT EXISTS line_movement (
    logged_at        TEXT NOT NULL,
    id               TEXT,
    game_id          TEXT,
    home_team        TEXT,
    away_team        TEXT,
    commence_time    TEXT,
    dk_spread_home   REAL,
    dk_total         REAL,
    dk_ml_home       REAL,
    dk_ml_away       REAL,
    fd_spread_home   REAL,
    fd_total         REAL,
    fd_ml_home       REAL,
    fd_ml_away       REAL,
    mgm_spread_home  REAL,
    mgm_total        REAL,
    mgm_ml_home      REAL,
    mgm_ml_away      REAL,
    czr_spread_home  REAL,
    czr_total        REAL,
    czr_ml_home      REAL,
    czr_ml_away      REAL,
    pin_spread_home  REAL,
    pin_total        REAL,
    pin_ml_home      REAL,
    pin_ml_away      REAL
  )
")

# Dedup guard: same Odds API event at the same logged_at timestamp
dbExecute(con_lm, "
  CREATE UNIQUE INDEX IF NOT EXISTS idx_lm_id_time
  ON line_movement(id, logged_at)
")

# Index to speed up BET_SETTLEMENT.R closing-line queries (game_id + time range)
dbExecute(con_lm, "
  CREATE INDEX IF NOT EXISTS idx_lm_game_time
  ON line_movement(game_id, logged_at)
")

n_rows <- dbGetQuery(con_lm, "SELECT COUNT(*) AS n FROM line_movement")$n
cat(sprintf("[SCHEMA_INIT] line_movement table ready — %d existing row(s).\n", n_rows))

dbDisconnect(con_lm)

cat("[SCHEMA_INIT] All schemas initialized. Pipeline is ready for first live run.\n")
