# mcFootball CFB Pipeline — Session State
# Last updated: 2026-06-04 | Session 19

## Project
Modular NCAA CFB sports betting pipeline in R. 21-step orchestrator (`run_daily_football.R`). Markets: SPREAD / TOTAL / ML. Kelly 0.5 fractional sizing. Telegram + Discord broadcast.

## Current State

**Last worked on (2026-06-01):**
- Session 18 (CLV tracking + tempo model — code written):
  - `scripts/db_schema_init.R` *(new)* — idempotent schema init for both SQLite DBs. Run once before first live use. Creates `cfb_bets` CLV columns and `line_movement` table.
  - `scripts/BET_SETTLEMENT.R` — full SQLite rewrite. Reads `cfb_bets WHERE settled=0`, fetches closing lines from `line_movement`, computes CLV by market (SPREAD/TOTAL/ML). Positive CLV = beat the close.
  - `scripts/LINE_MOVEMENT_LOGGER_CFB.R` — dead `LINE_MOVEMENT_CSV` reference replaced with `LM_DB <- "outputs/cfb_line_movement.sqlite"`. Writes via `dbWriteTable(..., append=TRUE)` with INSERT OR IGNORE on PK. 21-day purge via DELETE.
  - `scripts/SCRAPE_CFB_DATA.R` — `plays` and `games` added to `keep_stats`; `plays_per_game` derived and written to team stats CSV.
  - `scripts/GENERATE_PREDICTIONS_CFB.R` — `pace_adjustment()` rewritten to use `plays_per_game`. Fallback to `possessionTime` if plays data absent. `tempo_adj` column in output.
  - `scripts/CONFIG.R` — `LEAGUE_AVG_PACE <- 70.0`, `TEMPO_TOTAL_WEIGHT <- 0.15` added.
  - MASTER CSV: 138 rows. Delaware + Missouri State added. massey_name corrections: Missouri State → "Missouri State", Boise State → "Boise St".
  - Massey scraper: timeout 20s → 60s; one retry added on `Page.loadEventFired` timeout.

## Outstanding Before Sep 2026

0. **LINE_MOVEMENT_LOGGER_CFB.R Task Scheduler job — PAUSED** — running hourly in June burns Odds API quota with no actionable data (63 preseason lines unchanged all day). Resume during Week 1 prep week (late August). ~207/500 API calls used as of 2026-06-02.
1. **Run `source("scripts/db_schema_init.R")` once** — both SQLite tables must exist before first logger run or live bet. Script now exists (Session 19).
2. ✅ `plays_per_game` wired end-to-end (Session 19): SCRAPE adds `plays` → derives `plays_per_game`; MERGE passes it through; GENERATE uses it as primary pace signal (fallback: possessionTime).
3. Post-Week 4: calibrate `TEMPO_TOTAL_WEIGHT` (0.15 prior), `LEAGUE_AVG_PACE` (70.0 prior), `TALENT_WEIGHT` (1.5), `RETENTION_SCALAR_MIN` (0.80)
4. Sagarin SSL (`SEC_E_UNTRUSTED_ROOT`) — non-fatal fallback active, root cause unresolved
5. Massey chromote intermittent timeout — retry logic added, not yet confirmed stable under load
6. Validate MASTER odds_names vs DK feed on first live odds fetch
7. Monitor 10–15 pt edge bucket — 46.4% ATS on n=56, inconclusive

## Known Warnings (pre-season, non-fatal)
- Warnings 3–6: talent/returning production API calls return HTML instead of JSON — expected until season live
- Warning 7: 1–2 games with NA ratings when Massey/Sagarin doesn't cover both teams
- Warning 9: games with |proj_spread| > 35 pts — expected in pre-season schedule
- Warning 10: BYE_WEEK_TRACKER — no schedule found (pre-season)

## Key Architecture

- **Ledger:** `outputs/cfb_bets.sqlite` (WAL mode). `bet_history.csv` is archive only.
- **Bet schema:** `cfb_bets(bet_id PK, ..., closing_line, clv, clv_fetched_at, settled INTEGER)`
- **Line movement:** `outputs/cfb_line_movement.sqlite` — tables created by `db_schema_init.R`
- **MASTER:** `team_name_mappings_MASTER_CFB.csv` (138 rows — 134 FBS + FCS stragglers + Delaware + Missouri State)
- **Bankroll:** `outputs/bankroll.txt` ($500 starting)
- **Boosts:** SHARP=1.15x, TREND=1.08x, BYE=1.08x, PUBLIC=1.20x
- **CLV sign convention:** positive = beat the close = good process
- **Discord channels:** `discord_auto_bet_webhook` = #auto-bet-broadcast (primary bets); `discord_webhook_url` = general (secondary, optional)
- **Base44 exports:** `exports/BET_HISTORY_CFB_YYYYMMDD.csv` → `BetHistory` entity; `exports/MASTER_TICKET_CFB_YYYYMMDD.csv` → `Game` entity (same entities as MLB, `sport="CFB"` prevents Sep overlap collision)
  - Credentials needed: `base44_token` in `credentials.json` (same token as mlb_NRFI_YRFI; same APP_ID `69ce95e89103a042f4ca8797`)
  - `game_id` = Odds API event hex ID (same 32-char format as MLB); `game_label` = "Away @ Home" for display
  - MLB export.R also updated: `sport="MLB"` added to both BET_HISTORY and MASTER_TICKET exports
  - Sync: `node base44/sync.js YYYYMMDD` — auto-triggered by `finalize_bets()` after each live run

## Drop-in for Next Session

Continuing mcFootball CFB pipeline. Read `CFB_PROJECT_BIBLE.md` for full history. Session 18 complete — CLV tracking (db_schema_init.R, BET_SETTLEMENT.R SQLite rewrite, LINE_MOVEMENT_LOGGER_CFB.R fixed) and tempo model (plays_per_game in SCRAPE_CFB_DATA.R + GENERATE_PREDICTIONS_CFB.R) implemented. **Before first live use, run `source("scripts/db_schema_init.R")`**. Key pre-season check: verify `plays_per_game` flows through MERGE_GAMES_RATINGS_CFB.R. Next live action Sep 2026.
