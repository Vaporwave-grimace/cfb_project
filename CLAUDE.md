# mcFootball CFB Pipeline — Session State
# Last updated: 2026-06-15 | Session 20

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
4. ✅ Sagarin SSL — `ssl_verifypeer=FALSE` added to `fetch_sagarin_direct()` (Session 20); fixes `SEC_E_UNTRUSTED_ROOT` in Task Scheduler sessions; Firecrawl path unaffected
5. ✅ Massey Chromote — full 2-attempt retry loop + `grepl("#SHCtable")` validation before returning; longer wait on retry (45s); clear error after all attempts exhausted (Session 20)
6. ✅ MASTER odds_names validated vs DK feed (2026-06-15) — 78/78 canonical matches, zero mismatches; `CFB_LineLogger_Hourly` enabled
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

## Task Scheduler (Windows) — CFB

Registered via `schedule_tasks_cfb.ps1` (run once as Administrator). Wrapper: `run_with_log_cfb.ps1` — logs to `log/{TaskName}_{date}.log`, 30-day retention.

| Task | Day | Time | Purpose |
|---|---|---|---|
| `CFB_Pipeline_Thu` | Thursday | 6:00 PM | Full pipeline — early line capture |
| `CFB_Pipeline_Fri` | Friday | 12:00 PM | Updated odds + injury check |
| `CFB_Pipeline_Sat` | Saturday | 8:00 AM | Final run before kickoffs |
| `CFB_LineLogger_Hourly` | Thu–Sat | 9 AM–8 PM hourly | Line movement logging — **CREATED DISABLED** |

Enable line logger in late August: `Enable-ScheduledTask -TaskName "CFB_LineLogger_Hourly"`

---

## Drop-in for Next Session

Continuing mcFootball CFB pipeline. Read `CFB_PROJECT_BIBLE.md` for full history. Session 20 complete — score fetcher (`fetch_cfb_scores.R`), Task Scheduler scripts (`run_with_log_cfb.ps1`, `schedule_tasks_cfb.ps1`), Sagarin SSL fix, Massey Chromote retry, and backtest ELO blend + third-down adjustments. **Before first live use, run `source("scripts/db_schema_init.R")`**. Enable `CFB_LineLogger_Hourly` task in late August. Next live action Sep 2026.

## Session 20 Summary (2026-06-15)

### Score Fetcher (`scripts/fetch_cfb_scores.R`) — New

- Solves Odds API hex `game_id` ↔ CFBD integer `game_id` mismatch by matching on canonical team name pair + game date (±1 day), then writing the Odds API `game_id` to the score CSV
- `SCORES_LOOKBACK = 21L` — covers Thursday pipeline catching prior Saturday results
- Output: `clean/cfb_scores_YYYYMMDD.csv` (cols: `game_id`, `home_team`, `away_team`, `home_score`, `away_score`, `game_date`)
- Sources `TEAM_NAME_NORMALIZER_CFB.R`; falls back to raw names if master unavailable

### `run_daily_football.R` — Score Fetch + 21-Day Settlement Window

- Step 1.5 added: calls `fetch_cfb_scores()` before settlement
- Step 2 rewritten: scans all `clean/cfb_scores_YYYYMMDD.csv` within 21-day window; deduplicates on `game_id`; covers multi-day settlement gaps (Sat games not yet in yesterday's file)

### Task Scheduler — New Scripts

- **`run_with_log_cfb.ps1`** — wrapper for all CFB tasks; logs stdout+stderr to `log/`; self-healing R path detection; 30-day log retention
- **`schedule_tasks_cfb.ps1`** — registers `CFB_Pipeline_Thu` (Thu 6 PM), `CFB_Pipeline_Fri` (Fri 12 PM), `CFB_Pipeline_Sat` (Sat 8 AM), and `CFB_LineLogger_Hourly` (Thu–Sat 9 AM–8 PM, **created disabled**)

### `scripts/scrape_sagarin.R` — SSL Fix

- `fetch_sagarin_direct()` now passes `httr::config(ssl_verifypeer = FALSE)` — fixes `SEC_E_UNTRUSTED_ROOT` that silently dropped Sagarin from the rating blend when running under Task Scheduler
- Firecrawl path (primary) unaffected

### `scripts/scrape_massey_cfb.R` — Chromote Retry

- `fetch_massey_chromote()` rewritten with 2-attempt retry loop
- Explicit `grepl("SHCtable", html, fixed = TRUE)` validation before returning — prevents returning incomplete HTML when table hasn't rendered
- Longer wait_for on retry (30s → 45s), larger sleep (1.5s → 2.5s), 3s between attempts

### `scripts/BACKTEST_2025.R` — ELO Blend + Third-Down Adjustments

- ELO fetch added (`[1.5/5]`): CFBD `/ratings/elo?year=2025`, latest week per team
- Season stats fetch added (`[2.5/5]`): CFBD `/stats/season?year=2025` for third-down rates
- **ELO blend**: SP+ weight 81.8% / ELO weight 18.2% (normalized from 0.45/0.10); ELO diff z-score scaled to SP+ units via `(elo_diff / sd_elo) * sd_sp`
- **Third-down adjustments**: `third_down_spread_adj` + `third_down_total_adj` matching live engine
- Three projection variants: `proj_spread_sp` (SP-only), `proj_spread_elo` (SP+ELO), `proj_spread` (full)
- Three-way MAE console report: SP-only → SP+ELO → full model
- New CSV output columns: `rating_diff_blended`, `elo_active`, `td_active`, `third_down_spread_adj`, `proj_spread_elo`, `abs_error_elo`; `summary_rows` includes `mae_elo`
