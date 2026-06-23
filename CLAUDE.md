# mcFootball CFB Pipeline — Session State
# Last updated: 2026-06-23 | Session 23

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
7. ✅ 10–15 pt edge bucket validated — 63.5% ATS (40/63) with ELO active; was 46% without ELO (ELO filters spurious large edges)

## Known Warnings (pre-season, non-fatal)
- Warnings 3–6: talent/returning production via Firecrawl/player/usage; 50 P4 teams for talent, 130-138 for returning — G5 vs G5 matchups default to NA → median imputed → 0 diff
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

Continuing mcFootball CFB pipeline. Read `CFB_PROJECT_BIBLE.md` for full history. Session 23 complete — ML v4 training data rebuilt (9443 rows / 13 seasons) with 247Sports talent, returning production, turnover margin, SP+ special teams, and On3 portal index. Models retrained; spread MAE 10.46, total MAE 12.48. **Before first live use, run `source("scripts/db_schema_init.R")`**. Enable `CFB_LineLogger_Hourly` task in late August. Next live action Sep 2026.

## Session 23 Summary (2026-06-23)

### ML Training Data v4 — 5 New Features + Bug Fixes

**New scraper: `scripts/scrape_talent_247.R`**
- Firecrawl scrape of `247sports.com/season/{year}-football/CompositeTeamRankings/`
- Returns `talent_score` (composite total, e.g. 317.19 for Georgia 2024) + avg rating + commits
- 49-50 teams/year (P4 heavy — page lazy-loads; G5 coverage via median imputation)
- Key fix: `perl=TRUE` required in `sub("^\\[([^\\]]+)\\].*", "\\1", line, perl=TRUE)` — without it POSIX ERE treats `[^\]]` as "not-backslash" and sub() returns the full markdown link unchanged

**Bug fixes in `scripts/build_ml_training_data.R`**
- `return()` inside `tryCatch({...})` exits the *enclosing function* (`pull_season()`), not the tryCatch — was silently dropping 2013 season (and any year where usage/talent data unavailable). Fixed throughout: bare `tibble()` as last expression in `if/else` block
- Returning production `else {` block was missing closing `}` — causing parse error at the `}, error=` boundary
- 247Sports talent `tryCatch` had same `return(tibble())` pattern — changed to `if/else`

**New ML features (all as `home - away` diffs):**
| Feature | Source | Coverage | Importance (total model) |
|---|---|---|---|
| `returning_pct_diff` | CFBD `/player/usage` year-over-year | 130-138 teams (2014+) | **#3 (0.0181)** |
| `talent_diff` | 247Sports composite via Firecrawl | 49-50 teams/year | #8 (0.00846) |
| `portal_index_diff` | On3 portal via Firecrawl | 50 teams (2022+) | ~0 |
| `turnover_margin_diff` | CFBD `/stats/season` | 127-138 teams | #4 in both models |
| `sp_st_diff` | CFBD `/ratings/sp` special teams | 123-134 teams | #9 spread |

**Returning production computation** — CFBD `/returning` is Patreon-gated (returns `"\n"`). Instead: `fetch_usage(yr-1)` + `fetch_usage(yr)`, intersect on `(player_id, team)`, compute `ret_usage/total_usage` per team. ~2 API calls/year.

**247Sports talent** — CFBD `/teams/talent` is 404 on current API path. Scrape directly. Prior-year class (yr-1) used as preseason talent proxy (same philosophy as SP+).

**Training data v4 results:**
- **9,443 rows / 13 seasons (2013–2025)** — previously 8,720 rows / 12 seasons (2013 was silently dropped)
- All 13 seasons present; returning_pct has 0 coverage for 2013 (no 2012 usage data) — median imputed

**Model v4 results (2025 holdout, train 2013-2024):**
| Model | MAE | vs v1 baseline |
|---|---|---|
| Spread | **10.46 pts** | v1: 10.45 — flat |
| Total | **12.48 pts** | v1: 12.43 — flat |

- `returning_pct_diff` now #3 feature in total model — signal confirmed present, will strengthen with more seasons
- `turnover_margin_diff` is #4 in both spread and total models; `talent_diff` #8 in total
- Spread model still dominated by `elo_diff_scaled` (93% importance) — new features provide marginal signal on totals

**`scripts/ml_model_cfb.R` — predictor lists updated:**
```r
SPREAD_PREDICTORS: added sp_st_diff, turnover_margin_diff, returning_pct_diff, talent_diff, portal_index_diff
TOTAL_PREDICTORS:  added turnover_margin_diff, returning_pct_diff, talent_diff, portal_index_diff
```

---

## Session 22 Summary (2026-06-15)

### 2025 Backtest — Full Validation Run

Backtest complete with all factors active (ELO fixed, scheme added). Results on 784 FBS games (740 regular + 44 postseason):

**MAE four-way comparison:**
| Variant | MAE | Delta |
|---|---|---|
| SP-only (2024 preseason proxy) | 14.32 pts | baseline |
| SP + ELO blend (82/18) | 13.23 pts | **+1.09** |
| SP+ELO + PPA + 3d-rate | 13.26 pts | -0.02 (negligible) |
| Full model + scheme matchup | **13.17 pts** | +0.09 |

**Key findings:**
- **ELO is the dominant factor (+1.09 pts)** — captures actual 2025 in-season performance vs. stale 2024 SP+. In live mode, gap is smaller because SP+ is also current-week.
- **PPA/3d-rate: negligible (±0.02)** — full-season averages are slightly post-hoc here; directionally correct in live sequential mode. No weight changes needed.
- **Scheme: +0.09 pts** — `SCHEME_SPREAD_WEIGHT=4.0` validated. Keep.
- **ELO critical for large edges**: 10-15 pt bucket was 46% ATS without ELO → **63.5% ATS** with ELO (40/63). ELO correctly filters spurious large edges where SP+ (stale) and ELO (current) disagree.

**ATS performance (full model):**
- Overall: **59.5%** on 311 qualifying bets (edge ≥ 5 pts)
- 5-7 pt edge: 56.9% (109 bets)
- 7-10 pt edge: 57.6% (144 bets)
- 10-15 pt edge: **63.5%** (63 bets) ← sweet spot
- Direction accuracy: 69.5% (545/784 games)
- Model bias: -0.48 pts (well-calibrated)

**By conference tier:**
- P4: 12.47 MAE, 60.1% ATS (168 bets)
- G5: 13.87 MAE, 57.2% ATS (138 bets)

**Floor MAE context:** 13.17 pts uses year-stale SP+. Live pipeline adds current Sagarin + Massey + fresh weekly SP+ → expect 10-11 pts MAE in-season.

### `scripts/BACKTEST_2025.R` — Scheme Matchup + ELO Fix

- `/ppa/teams` response extended: `off_rush_ppa`, `off_pass_ppa`, `def_rush_ppa`, `def_pass_ppa` extracted per team
- `/stats/season` response extended: `rushingAttempts` + `passAttempts` → `rush_rate` per team
- Both joined as `home_*` / `away_*` onto games
- `scheme_adj` computed using identical formula to `get_scheme_adj()` in live model
- Four-way MAE comparison (SP → SP+ELO → +PPA+3d → +scheme)
- `proj_spread_no_scheme` + `abs_error_no_scheme` written to CSV for scheme delta analysis
- **ELO fix**: `slice_max(order_by = as.integer(week))` failed on CFBD list-column → replaced with `slice_tail(n = 1)` per team (API returns weeks ascending; last row = latest)

## Session 21 Summary (2026-06-15)

### `scripts/WEATHER_SCRAPER_CFB.R` — Full Rewrite

Previous version had three structural bugs: (1) used `/data/2.5/weather` (current conditions) instead of `/data/2.5/forecast` (5-day forecast needed for Thursday-fetched Saturday games); (2) expected `home_latitude`/`home_longitude`/`home_dome` already in `odds_data` — those columns don't exist; (3) joined results onto `odds_data` but Step 17 checks `games_with_predictions` — so Step 17 always saw `has_weather = FALSE`.

Rewritten to:
- Fetch stadium coordinates + dome flag from CFBD `/teams?division=fbs` (via `.cfb_team_locations()`)
- Use `/data/2.5/forecast` (3-hr slots, 5 days) — pick slot closest to `commence_time` UTC
- Use forecast `pop` field for `precip_prob` (0–1 probability vs. binary rain detection)
- Join `wind_speed`, `precip_prob`, `temp_f`, `home_dome` directly onto `games_with_predictions` at end of run so Step 17's `!is.null(weather_data) && all(c("wind_speed","precip_prob") %in% names(gwp))` check passes
- Dome/retractable-roof parks logged explicitly; `Sys.sleep(0.15)` between forecast calls to respect OWM rate limit

### `scripts/TEAM_METRICS.R` — Scheme Matchup Data

- New `fetch_ppa_teams()` function: calls CFBD `/ppa/teams?year=YYYY&seasonType=regular`; extracts `off_rush_ppa`, `off_pass_ppa`, `def_rush_ppa`, `def_pass_ppa` per team (after `flatten=TRUE`: `offense.rushing`, `offense.passing`, `defense.rushing`, `defense.passing`)
- `load_basic_stats()` updated: adds `rushingAttempts` + `passAttempts` to keep list; derives `rush_rate = rushingAttempts / (rushingAttempts + passAttempts)` in-function; drops raw attempt columns before returning
- `build_team_metrics()` updated: calls `fetch_ppa_teams()` (non-fatal, like talent/returning); left-joins play-type PPA + rush_rate into `team_metrics`; `priority_cols` updated to place new scheme cols near top
- New columns flow to `games_with_predictions` via MERGE step as `home_off_rush_ppa`, `home_def_rush_ppa`, `home_rush_rate`, `away_*` etc.

### `scripts/GENERATE_PREDICTIONS_CFB.R` — Scheme + Injury Total Adj

- New `get_scheme_adj(game_row)`: pulls `home_rush_rate`, `home_def_rush_ppa`, `home_def_pass_ppa`, `away_*` from game_row; computes net home scheme edge (home offense vs. away defense scheme, minus away offense vs. home defense scheme); returns `net × SCHEME_SPREAD_WEIGHT`; returns 0 cleanly when columns absent
- New `get_injury_total_adj(home, away)`: reads `total_adj` from `injury_adjustments` (INJURY_SCRAPER_CFB.R); both teams' totals added (missing scorer suppresses total); was computed by injury scraper but never wired into `proj_total`
- `predict_game()` spread formula now includes `+ scheme_adj`
- `predict_game()` total formula now includes `+ injury_total_adj` on both PPA and fallback paths
- Output list adds `scheme_adj` and `injury_total_adj` columns

### `scripts/CONFIG.R` — Scheme Constants

- `SCHEME_SPREAD_WEIGHT <- 4.0` — pts per net EPA/play edge (conservative prior; tune 2.0–8.0)
- `LG_AVG_DEF_RUSH_PPA <- 0.0` — FBS avg EPA/play allowed on rushes (≈ 0, zero-centered)
- `LG_AVG_DEF_PASS_PPA <- 0.0` — FBS avg EPA/play allowed on passes (≈ 0)
- `LG_AVG_RUSH_RATE <- 0.42` — FBS avg rush-play fraction (default when team data absent)

### Calibration notes

- `SCHEME_SPREAD_WEIGHT = 4.0` is validated — 2025 backtest confirms +0.09 pts MAE improvement. Keep at 4.0; re-evaluate after live 2026 season accumulates 100+ settled games.
- Weather: wind + cold + precip are additive suppression signals; Step 17 already has the application logic — no code change needed there.
- `injury_total_adj` from INJURY_SCRAPER is negative for key injuries (e.g., QB Out → -3.0 spread / -1.5 total per team). Total adj now fires correctly alongside spread adj.

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
