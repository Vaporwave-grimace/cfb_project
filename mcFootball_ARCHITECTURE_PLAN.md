# mcFootball — CFB Pipeline Architecture Plan
# Port from mcBaseBall | Created: 2026-05-08

---

## OVERVIEW

Modular port of mcBaseBall to NCAA College Football. Same R stack, same
Kelly/Kelly-fractional bankroll model, same broadcast infrastructure.
Weekly cadence (Saturday-primary) vs baseball's daily cadence.

**Philosophy: Edge, +EV, and CLV.** Every bet must show positive expected value
vs the posted line. CLV is the primary performance metric — beating the closing
line over time is the proof that the model finds real edges, independent of W/L
variance.

**Markets: Spread + Total + Moneyline.** All three evaluated independently per game.
No player props (Colorado regulatory restriction).

**ML filter:** Only evaluate moneyline on games where the spread is ≤ 10 pts.
Beyond that, the juice on heavy favorites destroys EV even when the model agrees.

---

## +EV FRAMEWORK

Each market gets its own EV calculation before Kelly sizing:

### Spread +EV
```
spread_edge_pts = projected_spread - posted_spread
spread_ev = spread_edge_pts / total_point_estimate  # normalizes to probability scale
```
Qualifies when: `spread_edge_pts >= MIN_EDGE_SPREAD` (default: 3 pts)

### Total +EV
```
total_edge_pts = projected_total - posted_total
total_ev = |total_edge_pts| / posted_total
```
Qualifies when: `|total_edge_pts| >= MIN_EDGE_TOTAL` (default: 2.5 pts)

### Moneyline +EV
```
implied_prob = american_to_prob(dk_moneyline)
ml_ev = win_probability - implied_prob
```
Qualifies when: `ml_ev >= MIN_EDGE_ML` AND `abs(posted_spread) <= ML_SPREAD_THRESHOLD`
(defaults: 4%, 10 pts)

### Kelly sizing — all three markets
Same formula as mcBaseBall. Each market sized independently using its own EV.
Portfolio limit applies to total exposure across all three markets on a given game
(correlated bets — cap combined exposure per game).

---

## CLV AS PRIMARY PERFORMANCE METRIC

CLV tracks whether bets beat the closing line — the best long-run proof of edge,
independent of W/L noise.

**Three separate CLV streams:**
- `spread_clv_cents` — placement spread vs. closing spread
- `total_clv_cents` — placement total vs. closing total
- `ml_clv_cents` — placement ML odds vs. closing ML odds

**Interpretation:**
- Sustained positive CLV across markets = model finding real edges before market corrects
- Positive CLV on a losing bet is still a good bet (variance, not model failure)
- Negative CLV on a winning bet = got lucky, not a signal to repeat

**Target:** Track CLV by market separately. If spread CLV is positive but total CLV is flat,
the total signals need recalibration.

Closing line source: DraftKings (Pinnacle geo-blocked from US; same as mcBaseBall).

---

## WHAT PORTS DIRECTLY (minimal changes)

| Script | Change needed |
|--------|---------------|
| `CONFIG.R` | Rename constants; adjust MIN_EDGE thresholds for spread betting |
| `line_movement_logger.R` | None — same Odds API pattern |
| `TREND_ANALYSIS.R` | None — same line movement logic |
| `TEAM_NAME_NORMALIZER.R` | None — same architecture, new MASTER CSV |
| `TRAVEL_FATIGUE.R` | Recalibrate energy_rating weights for football |
| `FINALIZE_BETS.R` | Minor — adapt juice handling for spread markets |
| `broadcast_football.R` | Clone broadcast_baseball.R; remove pitcher fields, add spread/cover fields |
| `MERGE_GAMES_RATINGS.R` | Minor column renames |
| `standardize_data.R` | None |
| `append_odds_lookup.R` | None |

---

## WHAT CHANGES SIGNIFICANTLY

### CALCULATE_VALUE.R (complete rewrite of core logic)
Baseball: win probability → ML edge → Kelly size
Football: THREE independent +EV calculations per game → Kelly size each

**Step 1 — Spread edge:** `projected_spread - posted_spread`
**Step 2 — Total edge:** `projected_total - posted_total`
**Step 3 — ML edge:** `win_probability - implied_prob(dk_ml)` (only if |posted_spread| ≤ 10)
**Step 4 — Boosts** (multiplicative, same architecture as mcBaseBall):
  - `sharp_boost` 1.15x — line moved ≥ 2.5 pts (spread) or ≥ 0.5 (total)
  - `trend_boost` 1.08x — sharp line agrees with model pick
  - `bye_week_boost` 1.08x — team off bye, model agrees on direction
  - `conf_weight` 0.50–1.00x — same conference tier blending
  - Remove: `nolan_boost` (Warren Nolan is baseball only)
  - Keep: VSiN public % divergence → `ml_vsin_signal`
**Step 5 — Kelly sizing** per market (3 independent bet sizes per game max)
**Step 6 — Correlated bet cap:** if spread AND ML both qualify on same game,
  cap combined exposure at `MAX_SINGLE_GAME_EXPOSURE` (new CONFIG constant)
**Step 7 — Long-format bet card:** one row per market per game (spread/total/ML)

### BET_SETTLEMENT.R
- Spread settlement: did team cover? (final score + spread vs. line)
- ATS result replaces W/L
- Keep 5-field bet_idx key (game_id + away + home + bet_type + bet_side)
- Same CLV architecture (closing line value vs. placement line)

### MERGE_ALL_RATINGS.R
Remove: scrape_warren_nolan.R, scrape_boyds_isr.R
Keep: scrape_massey_ratings.R (has CFB)
Add: scrape_sagarin.R, scrape_sp_plus.R (or pull via CFB Data API)

### WEATHER_SCRAPER.R
Add `dome` column to MASTER CSV. Guard block:
```r
if (isTRUE(game$home_dome)) {
  # skip weather fetch; set wind=0, temp=72, precip=0
}
```
Domed FBS stadiums (partial list): AT&T (Dallas), Lucas Oil (Indy), Mercedes-Benz (ATL),
Allegiant (Las Vegas), Ford Field (Detroit), Caesars Superdome (NO), State Farm (Glendale),
Alamodome (UTSA), Carrier Dome/JMA Wireless (Syracuse), Hubert H. Humphrey (Minnesota).

---

## SCRIPTS TO DELETE (baseball-only)

```
scrape_fangraphs.R
scrape_boyds_isr.R
scrape_warren_nolan.R
SCRAPE_WARREN_NOLAN_GAMEDAY.R
SMART_STARTER_PICKER.R
UPDATE_PITCHER_TRACKING.R
AUTO_UPDATE_ROTATIONS_FROM_SCORES.R
ADVANCED_PITCHER_METRICS.R
PITCHER_ADJUSTMENTS.R
APPLY_PITCHER_SIGNALS.R
APPLY_STARTER_ADJUSTMENTS.R
BULLPEN_ANALYSIS.R
BASERUNS_METRICS.R
TEAM_BATTING_METRICS.R
```

---

## NEW SCRIPTS

### SCRAPE_CFB_DATA.R
Primary data source: **CollegeFootballData.com API** (free, requires key)
- Endpoints: `/ratings/sp` (SP+), `/ratings/elo`, `/games`, `/stats/season`, `/teams`
- Replaces FanGraphs + Boyd's + Warren Nolan combined
- SP+ is the gold-standard CFB rating (Bill Connelly / ESPN)
- Output: `clean/cfb_ratings_YYYY.csv`, `clean/cfb_team_stats_YYYY.csv`

### GENERATE_PREDICTIONS.R (CFB version)
Input: blended ratings (SP+, Sagarin, Massey) + HFA adjustment + travel fatigue
Output: `projected_spread` per game
Formula basis:
```
projected_spread = (home_rating - away_rating) + HFA_adjustment + fatigue_adjustment
```
HFA in CFB: ~3 pts average; SEC/Big Ten venues run 3.5–4.5 pts. Pull from SP+ HFA data.

### BYE_WEEK_TRACKER.R
- Reads `clean/cfb_schedule_YYYY.csv`
- Flags teams playing in week N whose last game was week N-2 or earlier (bye)
- Output column: `home_off_bye` (T/F), `away_off_bye` (T/F)
- Teams off bye historically cover at ~53–54% ATS — apply 1.08x boost when model agrees

### TEAM_METRICS.R
- Offensive efficiency (pts/drive, yards/play, success rate)
- Defensive efficiency (pts/drive allowed, EPA/play allowed)
- Source: CollegeFootballData.com API `/stats/season`
- Replaces pitcher metrics in signal chain

---

## PIPELINE STEPS (run_daily_football.R)

| Step | Name | Script | Status |
|------|------|--------|--------|
| 1 | load_config | CONFIG.R | ✅ Built |
| 2 | settle_bets | BET_SETTLEMENT.R | ✅ Built — SQLite closing lines |
| 3 | load_scores | — | CFB scores CSV (manual) |
| 4 | merge_ratings | MERGE_ALL_RATINGS.R | ✅ Built |
| 5 | fetch_cfb_stats | SCRAPE_CFB_DATA.R | ✅ Built |
| 6 | team_metrics | TEAM_METRICS.R | ✅ Built |
| 7 | fetch_odds | fetch_odds_football.R | ✅ Built — SQLite opening line write |
| 8 | trend_analysis | TREND_ANALYSIS_CFB.R | ✅ Built — SQLite reads |
| 8.5 | vsin_splits | SCRAPE_VSIN_CFB.R → PARSE_VSIN_CFB.R | ✅ Built — chromote scrape + normalize + vsin_data to .GlobalEnv |
| 9 | patch_commence_times | — | ✅ Built |
| 10 | append_odds_lookup | append_odds_lookup.R | ✅ Built |
| 11 | normalize_teams | standardize_data_cfb.R | ✅ Built |
| 12 | merge_games_ratings | MERGE_GAMES_RATINGS.R | ✅ Built |
| 13 | generate_predictions | GENERATE_PREDICTIONS_CFB.R | ✅ Built |
| 14 | bye_week_flags | BYE_WEEK_TRACKER.R | ✅ Built — non-fatal |
| 15 | add_weather | WEATHER_SCRAPER.R | ✅ Built — dome guard active |
| 16 | travel_fatigue | TRAVEL_FATIGUE.R | ✅ Built |
| 17 | weather_adjustments | — | ✅ Built |
| 18 | calculate_value | CALCULATE_VALUE_CFB.R | ✅ Built — Step 4d wired to vsin_data$vsin_divergence |
| 19 | filter_bets | — | ✅ Built |
| 20 | apply_portfolio_limits | — | ✅ Built |
| 21 | save_outputs_and_broadcast | FINALIZE_BETS.R + broadcast_football.R | ✅ Built |

**21 steps** (vs 26 in baseball — no pitcher chain)

**Orchestrator:** `scripts/run_daily_football.R` — sources all steps in order; fatal/non-fatal enforced via `step_run()` wrapper
**Run schedule:** Thursday 6pm + Friday 12pm + Saturday 8am via Task Scheduler
**Hourly standalone:** LINE_MOVEMENT_LOGGER_CFB.R — runs independently, writes to SQLite DB

---

## LINE MOVEMENT DATABASE

**File:** `outputs/cfb_line_movement.sqlite`
**Table:** `line_movement`

Two write sources share one table:

| Source | game_id | book columns |
|--------|---------|--------------|
| `fetch_odds_football.R` (Step 7, daily pipeline) | NULL — canonical names not yet resolved | DK only |
| `LINE_MOVEMENT_LOGGER_CFB.R` (hourly scheduler) | Canonical — full normalize applied | DK + FD + MGM + CZR + PIN |

**Full schema:**
```
logged_at | id | game_id | home_team | away_team | commence_time |
dk_spread_home | dk_total | dk_ml_home | dk_ml_away |
fd_spread_home | fd_total | fd_ml_home | fd_ml_away |
mgm_spread_home | mgm_total | mgm_ml_home | mgm_ml_away |
czr_spread_home | czr_total | czr_ml_home | czr_ml_away |
pin_spread_home | pin_total | pin_ml_home | pin_ml_away
```

**Key rules:**
- `logged_at` and `commence_time` stored as ISO8601 strings (`"%Y-%m-%d %H:%M:%S"`)
- CLV lookup in BET_SETTLEMENT.R uses only rows where `game_id IS NOT NULL`
- Closing line = `MAX(logged_at) WHERE logged_at <= commence_time` per game_id
- Purge: logger deletes rows older than `LOG_RETENTION_DAYS` (21) via SQL DELETE each run
- Schema mismatch guard: pipeline pads any logger-added columns with NA before INSERT

**Consumers:**
- `TREND_ANALYSIS_CFB.R` — MIN/MAX logged_at subqueries for open vs. current line diffs
- `BET_SETTLEMENT.R` — closing line CLV lookup (parameterized IN clause)
- `fetch_odds_football.R` — opening line read (MIN logged_at subquery per Odds API id)

---

## MASTER CSV — TEAM_NAME_MAPPINGS_MASTER_CFB.csv

136 teams (134 FBS + 2 FCS crossover opponents). New columns vs baseball MASTER:
- `dome` (TRUE/FALSE) — skip weather for home games
- `hfa_pts` — home field advantage in points (from SP+ or manual; default 3.0)

**Conference tiers:**
- Tier 1: Power 4 (SEC, Big Ten, Big 12, ACC)
- Tier 2: Group of 5 (AAC, Mountain West, MAC, CUSA, Sun Belt)
- Tier 3: Independents (Notre Dame, Army, Navy, Liberty, etc.)
- Tier 4: FCS opponents (added as needed when they appear in the Odds API feed)

**FCS entries (added when Odds API returns them as opponents):**
- `Sacramento State` — odds_name: "Sacramento State Hornets", FCS - Big Sky, weight 0.40
- `North Dakota State` — odds_name: "North Dakota State Bison", FCS - MVFC, weight 0.50, dome=TRUE (Fargodome)

**Conference structure post-2024 realignment:**
- Big Ten: 18 teams (added UCLA, USC, Oregon, Washington)
- SEC: 16 teams (added Texas, Oklahoma)
- Big 12: 16 teams (added Arizona, Arizona State, Colorado, Utah, UCF, etc.)
- ACC: 17 teams (added Cal, SMU, Stanford)
- Pac-12: DEFUNCT — remnants are Pac-2 (Oregon State, Washington State) as independents
- Independents: Notre Dame, Army, Navy, Liberty, UMass, New Mexico State

---

## KEY DECISIONS BEFORE BUILDING

1. **Markets: Spread + Total + ML** ✅ confirmed. ML filtered to games ≤ 10 pt spread.
   No player props (Colorado restriction).

2. **Rating blend for projected spread?**
   Recommendation: SP+ primary (most predictive), blend Sagarin + Massey as cross-checks.
   SP+ offensive/defensive ratings are available game-by-game from CFB Data API.

3. **CollegeFootballData.com API key**
   Free registration at collegefootballdata.com. Required before SCRAPE_CFB_DATA.R can run.
   Add to `credentials.json` as `cfbd_api_key`.

4. **HFA treatment**
   Option A: flat 3.0 pts for all home teams
   Option B: team-specific HFA from SP+ (recommended — some venues are +5 pts, some +1)

5. **Neutral site handling**
   Bowl games + playoffs + some early season games are neutral site. HFA = 0 for these.
   CollegeFootballData.com `neutral_site` field flags these automatically.

---

## BUILD ORDER (recommended)

1. **MASTER CSV** — 130 FBS teams, conference weights, dome flags, HFA pts. Everything depends on it.
2. **SCRAPE_CFB_DATA.R** — get SP+ ratings + team stats flowing. Register for CFB Data API key first.
3. **GENERATE_PREDICTIONS.R** — projected spread + projected total + win probability. Validate all three against historical lines before wiring into value engine.
4. **CALCULATE_VALUE.R** — three-market +EV engine. Port boost architecture. Add correlated bet cap.
5. **BET_SETTLEMENT.R** — ATS/total/ML settlement with full CLV tracking on all three markets.
6. **BYE_WEEK_TRACKER.R** — simple but high-signal; build early so it validates during preseason testing.
7. **Everything else** — weather (dome guard), travel fatigue, broadcast, line movement logger.

**Validate before going live:** Run GENERATE_PREDICTIONS.R against 2024 CFB season historical lines.
Measure projected spread accuracy (MAE), projected total accuracy (MAE), and win prob calibration.
Don't go live until spread MAE ≤ 6 pts on non-garbage-time games.

---

## HARD-LEARNED LESSONS FROM mcBASEBALL THAT APPLY HERE

- **Named args on normalize_team_name()** — always `mappings = master`, never positional
- **MASTER CSV as single source of truth** — no separate coord files, conf files, etc.
- **Brace balance before deploying any script** — depth-walking loop, not str_count
- **5-field bet_idx in settlement** — game_id + away + home + bet_type + bet_side
- **Non-fatal wrappers on all non-critical steps** — tryCatch on bye_week, weather, fatigue
- **`rm(list = ls())` before every settlement run** — stale function cache causes silent errors
- **Never settle same-day** — scores must be final before running settlement
- **FCS opponents drop unless in MASTER** — add to master with conf_tier 4 when Odds API returns them
- **SQLite schema mismatch guard** — pipeline pads logger-only columns with NA before INSERT; logger handles the reverse naturally via append=TRUE
- **chromote on Task Scheduler** — must patch `httpuv::randomPort` via netstat; libcurl/httr get empty body from Cloudflare TLS fingerprinting

---

## PENDING WORK (as of 2026-05-24)

### Immediate (next session)
- ✅ ~~SCRAPE_VSIN_CFB.R~~ — built; chromote scraper, `tr.sp-row` pairs, Telegram ping
- ✅ ~~PARSE_VSIN_CFB.R~~ — built; normalize + vsin_divergence + ml_vsin_signal → vsin_data
- ✅ ~~Step 8.5 in run_daily_football.R~~ — wired; run_daily_football.R created (was missing)
- ✅ ~~CALCULATE_VALUE_CFB.R Step 4d fix~~ — rewired to vsin_data$vsin_divergence

### Backlog
- **Massey scraper fix** — page is JS-rendered; needs chromote or alternative fetch
- **Score ingestion automation** — CFBD `/games` endpoint (issue #3)
- **Post-Week-4 calibration** — recalibrate TALENT_WEIGHT and RETENTION_SCALAR_MIN
- **Validate MASTER odds_names** vs DK feed on first live September odds fetch
- **TEAM_METRICS.R** — Step 6 is a no-op stub; PPA/efficiency currently flows through cfbd_team_stats directly in GENERATE_PREDICTIONS_CFB.R

---

## SESSION LOG

| Session | Date | Key Work |
|---------|------|----------|
| 1–3 | 2026-05-08 | Pipeline scaffold, CONFIG.R, MASTER CSV (130 teams), core scripts ported |
| 4–6 | 2026-05-10 | CALCULATE_VALUE_CFB.R (3-market +EV engine), BET_SETTLEMENT.R (ATS/CLV) |
| 7–8 | 2026-05-14 | GENERATE_PREDICTIONS_CFB.R, MERGE_GAMES_RATINGS.R, DRY_RUN_TEST.R (19.5s clean) |
| 9 | 2026-05-18 | LINE_MOVEMENT_LOGGER_CFB.R (hourly standalone, SQLite, Telegram), fetch_odds closing line fix, TREND_ANALYSIS schema fix, BET_SETTLEMENT CLV wiring |
| 10 | 2026-05-21 | VSiN scraper planning; identified 4 data gaps (#1 closing line, #2 VSiN splits, #3 score automation, #4 missing logger) |
| 11 | 2026-05-24 | SQLite migration (fetch_odds, TREND_ANALYSIS, BET_SETTLEMENT all off CSV); MASTER += Sacramento State + North Dakota State (FCS tier 4) |
| 12 | 2026-05-24 | VSiN scraper + parser built; run_daily_football.R orchestrator created; CALCULATE_VALUE Step 4d rewired to vsin_data |

---

## SESSION 11 DETAIL — 2026-05-24

### SQLite Migration — All Three Consumers Off CSV

`line_movement_log.csv` is fully retired. All three consumers now read from `outputs/cfb_line_movement.sqlite`.

**`fetch_odds_football.R`**
- `append_opening_lines()` INSERTs directly into SQLite.
- Pads logger-added book columns (`fd_*`, `mgm_*`, `czr_*`, `pin_*`) with `NA_real_` before each write so the two write sources never conflict on schema.
- Opening line lookup uses `MIN(logged_at)` subquery per Odds API `id`.

**`TREND_ANALYSIS_CFB.R`**
- `analyze_trends()` queries open vs. current lines via `MIN`/`MAX(logged_at)` subqueries.
- Backward-compat CSV rename block removed.

**`BET_SETTLEMENT.R`**
- `load_closing_lines()` parameter renamed to `db_path=`.
- Closing line is a single parameterized SQL query: `MAX(logged_at) WHERE logged_at <= commence_time`.

### MASTER CSV Updates
Two FCS opponents added (Odds API was returning them as live opponents):
- **Sacramento State** — tier 4, weight 0.40, Big Sky, dome=FALSE
- **North Dakota State** — tier 4, weight 0.50, MVFC, dome=TRUE (Fargodome)

### Resolved in Session 12
All four items above were completed in Session 12 (see SESSION 12 DETAIL below).

---

## SESSION 12 DETAIL — 2026-05-24

### SCRAPE_VSIN_CFB.R — Built
- Chromote headless scraper for `https://data.vsin.com/betting-splits/?source=DK&sport=CFB`
- Task Scheduler port patch: netstat-based free port detection → `--remote-debugging-port=N` via `options(chromote.chrome.args=)`
- Waits 7s for JS render; JS eval extracts all `tr.sp-row` cells as JSON array of arrays
- Parses pairs (odd index = away, even = home); cell map: [2]=team, [3]=spread_line, [4]=spread_handle, [5]=spread_bets, [6]=total_line, [7]=total_handle, [8]=total_bets, [9]=ml_odds, [10]=ml_handle, [11]=ml_bets
- Output: `clean/vsin_splits_YYYYMMDD_HHMM.csv`; Telegram ping on success
- Non-fatal: returns NULL silently on offseason / Cloudflare block

### PARSE_VSIN_CFB.R — Built
- Finds most recent `vsin_splits_*.csv` by mtime
- Normalizes raw VSiN team names via `normalize_team_name(mappings=master, source_col="odds_name")`
- Joins away/home pairs on `pair_idx`, then left-joins to `odds_data` on `canonical_home + canonical_away` to get `game_id`
- `vsin_divergence = abs(home_ml_handle_pct - home_ml_bets_pct)`
- `ml_vsin_signal`: `sharp_home` / `sharp_away` / `none` at `PUBLIC_PCT_MIN_DIV` (0.15)
- Output: `clean/vsin_matchups_LATEST.csv`; assigns `vsin_data` to `.GlobalEnv` (NULL if no data)

### run_daily_football.R — Created (was missing)
- Full 21-step orchestrator discovered missing; built from scratch
- `step_run(label, fatal, expr)` wrapper: fatal steps abort, non-fatal log and continue
- Fatal steps: 1 (config), 7 (odds fetch), 11 (normalize), 12 (merge ratings), 13 (predictions), 18 (calculate value)
- Step 8.5 wired as non-fatal: sources SCRAPE_VSIN_CFB.R then PARSE_VSIN_CFB.R in sequence
- Step 17 inline: merges weather_data cols onto games_with_predictions; wind > 15 mph → -2 pts proj_total, wind > 25 mph → -4 pts
- Step 6 (TEAM_METRICS.R) is a no-op stub — script not yet built
- Steps 19 + 20 (filter_bets, portfolio limits) confirmed inline inside `calculate_value()`

### CALCULATE_VALUE_CFB.R Step 4d — Rewired
- Old (broken): read `trend_signals$public_pct` — wrong tibble, wrong column
- New: reads `vsin_data$vsin_divergence` from `.GlobalEnv`; fires `BOOST_PUBLIC_PCT` (1.20x) when `vsin_divergence >= PUBLIC_PCT_MIN_DIV`
- Guard: `if (exists("vsin_data") && !is.null(vd) && "game_id" %in% names(vd))` — safe when VSiN scrape fails

### Still Pending (next session)
- **Massey scraper fix** — JS-rendered; needs chromote port
- **Score ingestion automation** — CFBD `/games` endpoint
- **Post-Week-4 calibration** — TALENT_WEIGHT + RETENTION_SCALAR_MIN
- **MASTER odds_names validation** — first live September DK feed
- **TEAM_METRICS.R** — Step 6 stub

---

## NEW-CHAT STATE SUMMARY — 2026-05-24 (after Session 12)

### What the pipeline does
mcFootball is a 21-step R pipeline that identifies +EV CFB bets across Spread, Total, and ML markets. Kelly sizing, CLV tracking, and SQLite line movement logging. Runs Thu/Fri/Sat via Task Scheduler. Hourly logger runs independently.

### Current state: fully wired, awaiting live season
All 21 steps are implemented. The orchestrator (`run_daily_football.R`) runs the full chain. The pipeline will return zero bets in the off-season (May–August) — that's expected. Step 7 (odds fetch) fails fast when no games are on slate.

### File locations (all relative to `G:/My Drive/Scripting Projects/cfb_project/`)
| File | Purpose |
|------|---------|
| `scripts/run_daily_football.R` | Master orchestrator — run this |
| `scripts/CONFIG.R` | All constants (Kelly, edges, boosts, paths) |
| `scripts/CALCULATE_VALUE_CFB.R` | 3-market +EV engine |
| `scripts/SCRAPE_VSIN_CFB.R` | VSiN chromote scraper (Step 8.5a) |
| `scripts/PARSE_VSIN_CFB.R` | VSiN normalizer → vsin_data (Step 8.5b) |
| `scripts/BET_SETTLEMENT.R` | CLV + ATS settlement (Step 2) |
| `scripts/LINE_MOVEMENT_LOGGER_CFB.R` | Hourly standalone SQLite logger |
| `outputs/cfb_line_movement.sqlite` | Shared line movement DB |
| `team_name_mappings_MASTER_CFB.csv` | 136-team canonical lookup |
| `mcFootball_ARCHITECTURE_PLAN.md` | This Bible |

### Key architecture decisions locked in
- SQLite for all line movement (no CSV)
- `game_id = coalesce(odds_api_id, paste(canonical_away, canonical_home, date))` — 5-field bet_idx for settlement
- VSiN divergence = `abs(home_ml_handle_pct - home_ml_bets_pct)` — threshold 0.15
- ML only evaluated when `|posted_spread| <= 7` (juice breaks EV above this)
- MIN_EDGE_SPREAD = 5.0 pts (raised from 3.0 after 2025 backtest: 3-5 pt bucket was -EV)
- MAX_EDGE_SPREAD = 12.0 pts cap (bets >12 pts were 43.7% ATS — model confidence outlier)

### Backlog (priority order)
1. Massey scraper fix (chromote — JS-rendered)
2. Score ingestion automation (CFBD /games)
3. Post-Week-4 calibration (TALENT_WEIGHT, RETENTION_SCALAR_MIN)
4. MASTER odds_names validation vs first live DK feed (September)
5. TEAM_METRICS.R (Step 6 stub)
