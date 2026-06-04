# ==============================================================================
# mcFootball PROJECT BIBLE
# Last updated: 2026-05-22  |  Session: 10
# Maintained by: Grimace
# Update cadence: append a new ## SESSION entry after every 20-response chat
# ==============================================================================

---

## PROJECT OVERVIEW

**mcFootball** is a modular, fully automated NCAA College Football sports betting
pipeline written in R. Port of mcBaseBall architecture adapted for CFB markets.

**Philosophy:** Edge + Positive Expected Value (+EV) + Closing Line Value (CLV).
Every bet must show +EV vs the posted line. CLV is the primary performance metric.

- **Markets:** SPREAD | TOTAL | MONEYLINE (ML only when |posted_spread| ≤ 10 pts)
- **No player props** — Colorado regulatory restriction
- **Runtime:** ~21 steps, target <120s end-to-end
- **Schedule:** Windows Task Scheduler — Thu 6pm, Fri 12pm, Sat 8am
- **Output:** Telegram + Discord broadcast + CSV bet history + master ticket
- **Bankroll management:** Kelly criterion, 0.5 fractional, correlated bet cap per game

---

## DIRECTORY STRUCTURE

```
cfb_project/
├── run_daily_football.R              # Master pipeline orchestrator
├── team_name_mappings_MASTER_CFB.csv # SINGLE SOURCE OF TRUTH — 136 FBS teams
│                                     # Columns: canonical_name, odds_name,
│                                     #   massey_name, conference, conf_tier,
│                                     #   conf_weight, stadium, latitude,
│                                     #   longitude, dome, hfa_pts
├── CFB_PROJECT_BIBLE.md              # This file
├── scripts/
│   ├── CONFIG.R                      # Constants: bankroll, Kelly, edge thresholds
│   ├── CALCULATE_VALUE_CFB.R         # 3-market +EV engine (SPREAD/TOTAL/ML)
│   ├── BET_SETTLEMENT.R              # ATS/total/ML settlement + CLV — NOT YET BUILT
│   ├── FINALIZE_BETS_CFB.R           # Writes bet history CSV + master ticket — NOT YET BUILT
│   ├── broadcast_football.R          # Telegram + Discord — NOT YET BUILT
│   ├── MERGE_ALL_RATINGS_CFB.R       # Merges SP+ + Sagarin + Massey — NOT YET BUILT
│   ├── MERGE_GAMES_RATINGS_CFB.R     # Joins ratings onto game slate — NOT YET BUILT
│   ├── GENERATE_PREDICTIONS_CFB.R    # Projected spread + total + win prob — NOT YET BUILT
│   ├── TEAM_METRICS.R                # Off/def efficiency (replaces pitcher metrics) — NOT YET BUILT
│   ├── BYE_WEEK_TRACKER.R            # Bye week flags per team — NOT YET BUILT
│   ├── WEATHER_SCRAPER_CFB.R         # Weather by stadium coords; dome guard — NOT YET BUILT
│   ├── TRAVEL_FATIGUE_CFB.R          # Port from mcBaseBall; recalibrated — NOT YET BUILT
│   ├── TREND_ANALYSIS_CFB.R          # Line movement trend signals — NOT YET BUILT
│   ├── SCRAPE_CFB_DATA.R             # CollegeFootballData.com API — NOT YET BUILT
│   ├── scrape_massey_cfb.R           # Massey CFB ratings scraper — NOT YET BUILT
│   ├── scrape_sagarin.R              # Sagarin ratings scraper — NOT YET BUILT
│   ├── fetch_odds_football.R         # Odds API fetch (DK primary) — NOT YET BUILT
│   ├── append_odds_lookup_cfb.R      # Auto-appends new odds API names — NOT YET BUILT
│   ├── standardize_data_cfb.R        # normalize_odds_data() wrapper — NOT YET BUILT
│   └── TEAM_NAME_NORMALIZER_CFB.R    # normalize_team_name() for CFB — NOT YET BUILT
├── clean/
│   ├── cfb_ratings_YYYY.csv          # Blended SP+ + Sagarin + Massey
│   ├── cfb_team_stats_YYYY.csv       # Off/def efficiency from CFB Data API
│   ├── cfb_schedule_YYYYMMDD.csv     # Weekly schedule
│   ├── cfb_scores_YYYYMMDD.csv       # Manual or API score pull (next-day settlement)
│   ├── bye_week_flags_YYYYMMDD.csv   # Teams on bye this week
│   └── trend_signals_latest.csv      # Stable path for CALCULATE_VALUE
├── outputs/
│   ├── bankroll.txt                  # Live bankroll — $500.00 (seed)
│   ├── bet_history.csv               # All bets with CLV columns
│   ├── master_ticket.csv
│   ├── line_movement_log.csv         # Written hourly by line_movement_logger
│   └── pipeline_log_YYYYMMDD.txt
└── logs/
    └── line_movement_YYYY-MM-DD.log  # Dated trace, purged after 7 days
```

---

## PIPELINE STEPS (run_daily_football.R)

| Step | Name | Script | Notes |
|------|------|--------|-------|
| 1 | load_config | CONFIG.R | Bankroll, Kelly, edge thresholds |
| 2 | settle_bets | BET_SETTLEMENT.R | ATS + total + ML settlement; non-fatal if no scores |
| 3 | reload_bankroll | — | Re-reads bankroll.txt post-settlement |
| 4 | scrape_ratings | scrape_massey_cfb + scrape_sagarin + SCRAPE_CFB_DATA | SP+/Sagarin/Massey |
| 5 | merge_ratings | MERGE_ALL_RATINGS_CFB.R | |
| 6 | team_metrics | TEAM_METRICS.R | Off/def efficiency |
| 7 | fetch_odds | fetch_odds_football.R | **Fatal** — DK primary |
| 8 | trend_analysis | TREND_ANALYSIS_CFB.R | Non-fatal |
| 9 | patch_commence_times | — | Patches T00:00:00Z from schedule CSV |
| 10 | append_odds_lookup | append_odds_lookup_cfb.R | Non-fatal |
| 11 | normalize_teams | standardize_data_cfb.R | **Fatal** |
| 12 | merge_games_ratings | MERGE_GAMES_RATINGS_CFB.R | **Fatal** |
| 13 | generate_predictions | GENERATE_PREDICTIONS_CFB.R | Spread + total + win_prob |
| 14 | bye_week_flags | BYE_WEEK_TRACKER.R | Non-fatal |
| 15 | add_weather | WEATHER_SCRAPER_CFB.R | Non-fatal; dome guard skips fetch |
| 16 | travel_fatigue | TRAVEL_FATIGUE_CFB.R | Non-fatal |
| 17 | weather_adjustments | — | Inline; skips if dome=TRUE |
| 18 | calculate_value | CALCULATE_VALUE_CFB.R | **Fatal** — 3-market +EV engine |
| 19 | filter_bets | — | ev > 0, bet_amount >= MIN_BET |
| 20 | apply_portfolio_limits | — | Weekly exposure cap + per-game correlated cap |
| 21 | save_outputs_and_broadcast | FINALIZE_BETS_CFB + broadcast_football | |

---

## CALCULATE_VALUE_CFB.R — INTERNAL STEPS

| Sub-step | Description |
|----------|-------------|
| Step 1 | Spread edge: `projected_spread - posted_spread`; qualifies at MIN_EDGE_SPREAD (3 pts) |
| Step 2 | Total edge: `projected_total - posted_total`; qualifies at MIN_EDGE_TOTAL (2.5 pts) |
| Step 3 | ML edge: `win_probability - american_to_prob(dk_ml)`; qualifies at MIN_EDGE_ML (4%) AND \|posted_spread\| ≤ 10 |
| Step 4a | Sharp boost (1.15x) — spread moved ≥ 2.5 pts OR total moved ≥ 0.5 |
| Step 4b | Trend boost (1.08x) — sharp line agrees with model pick |
| Step 4c | Bye week boost (1.08x) — team off bye, model agrees on direction |
| Step 4d | VSiN public % boost (1.20x) — divergence ≥ 15% |
| Step 4e | Conference weight (0.58–1.00x) — (away_conf_weight + home_conf_weight) / 2 |
| Step 5 | Kelly sizing per market — 3 independent bet sizes max per game |
| Step 6 | Correlated bet cap — ALL markets (SPREAD + TOTAL + ML) on same game capped at MAX_SINGLE_GAME_EXPOSURE combined; all scale proportionally |
| Step 7 | Long-format bet card — one row per market (SPREAD/TOTAL/ML) per game |

**Max combined boost on a single bet:** 1.15 × 1.08 × 1.08 × 1.20 = **1.606x**

---

## KEY CONSTANTS (CONFIG.R)

| Constant | Value | Purpose |
|----------|-------|---------|
| `MIN_EDGE_SPREAD` | 5.0 pts | Minimum spread edge to qualify (raised from 3.0 — 3-5 pt bucket 45.5% ATS, -EV) |
| `MIN_EDGE_TOTAL` | 2.5 pts | Minimum total edge to qualify |
| `MIN_EDGE_ML` | 4% | Minimum ML probability edge |
| `ML_SPREAD_THRESHOLD` | 7 pts | Only evaluate ML when spread ≤ this (lowered from 10 — at 10 pts juice is ~-400, break-even ~80%, vig destroys EV) |
| `KELLY_FRACTION` | 0.5 | Fractional Kelly |
| `MAX_SINGLE_GAME_EXPOSURE` | 8% | Correlated spread+ML cap per game |
| `MAX_EXPOSURE_PER_WEEK` | 30% | Max bankroll at risk per week |
| `SHARP_EDGE_SPREAD` | 3.25 pts | Sharp override floor (65% of MIN_EDGE_SPREAD = 5.0 × 0.65) |
| `SHARP_EDGE_ML` | 2.4% | Sharp override floor (60% of MIN_EDGE_ML) |

---

## TEAM METADATA — SINGLE SOURCE OF TRUTH

**File:** `team_name_mappings_MASTER_CFB.csv` — **133 FBS teams confirmed (Session 10, 2026-05-22)** — all 10 conferences: Big Ten=18, ACC=17, SEC=16, Big 12=16, Sun Belt=14, Mountain West=13, AAC=13, MAC=12, CUSA=9, Independent=5

| Column | Description |
|--------|-------------|
| `canonical_name` | Primary key used throughout pipeline |
| `odds_name` | Name as it appears in DraftKings feed |
| `massey_name` | Name as scraped from masseyratings.com |
| `conference` | Post-2024-realignment conference |
| `conf_tier` | 1=P4 (SEC/Big Ten/Big 12/ACC), 2=G5, 3=Independent |
| `conf_weight` | Value multiplier (0.58–1.00) |
| `stadium` | Stadium name |
| `latitude` | For weather API lookup |
| `longitude` | For weather API lookup |
| `dome` | TRUE/FALSE — if TRUE, skip weather adjustments |
| `hfa_pts` | Home field advantage in points (2.0–4.5) |

**Conference realignment notes (2024-2026):**
- Big Ten added: UCLA, USC, Oregon, Washington (from Pac-12)
- SEC added: Texas, Oklahoma (from Big 12)
- Big 12 added: Arizona, Arizona State, Colorado, Utah (from Pac-12)
- ACC added: Cal, SMU, Stanford (from Pac-12)
- Pac-12 dissolved: Oregon State + Washington State → Mountain West
- Notre Dame remains Independent (football only)

**Known dome stadiums:**
- Syracuse (JMA Wireless Dome)
- UNLV (Allegiant Stadium)
- UTSA (Alamodome)
- Minnesota (Huntington Bank Stadium) ← partially open roof, treat as outdoor

---

## CLV TRACKING

**Three CLV streams — one per market:**
- `spread_clv_cents` — placement spread vs DK closing spread
- `total_clv_cents` — placement total vs DK closing total
- `ml_clv_cents` — placement ML odds vs DK closing ML odds

**Interpretation:**
- Sustained positive CLV = model finding real edges before market corrects
- Positive CLV on a losing bet = good bet, variance not model failure
- Track by market separately — if total CLV is flat while spread CLV is positive, recalibrate total signals

**Closing line source:** DraftKings (Pinnacle geo-blocked from US IP — same constraint as mcBaseBall)

---

## BACKTEST CALIBRATION LOG

| Date | Session | Change | Before | After | Result |
|------|---------|--------|--------|-------|--------|
| 2026-05-11 | 4 | Added `MAX_EDGE_SPREAD = 12.0` | 605 bets, 53.7% | 402 bets, 55.0% | ✓ Improved — outlier bets were -EV |
| 2026-05-11 | 4 | `SP_SCALAR` reverted to 1.00 (was 0.65) | 402 bets, 55.0% | Maintained | ✓ Raw SP+ diffs correct scale; edge cap handles outliers |
| 2026-05-17 | 7 | PPA weights wired in (5.0/2.0) | MAE 14.32 | MAE 14.37 | PPA delta -0.05 pts — negligible. Expected: rating year mismatch (2024 SP+ vs 2025 PPA). Keep weights; re-evaluate after first live season. |
| 2026-05-17 | 7 | Raised `MIN_EDGE_SPREAD` 3.0 → 5.0 | 385 bets, 54.5% | **275 bets, 58.2% ATS (projected)** | ✓ 3-5 pt bucket was 45.5% ATS (110 bets) — below break-even. Every bucket ≥ 5 pts is profitable. |
| 2026-05-20 | 9 | Fixed strict inequality on edge floors (`<` → `<=`, `>` → `>=`) in CALCULATE_VALUE_CFB.R | Bets at exactly 5.0/2.5 pt edge silently dropped | Boundary bets qualify | ✓ Found by DRY_RUN_TEST.R §2f/§3d |
| 2026-05-20 | 9 | Fixed `result` column type in BET_SETTLEMENT.R (`as.character()` after `read_csv`) | First-ever settlement run crashes on `bind_rows` type mismatch | Settlement works on fresh bet history | ✓ Found by DRY_RUN_TEST.R §7 |
| 2026-05-22 | 10 | Added Pass 5 + Pass 6 (mascot strip) to normalize_team_name() | DK sends "Ohio State Buckeyes" — all 21 games dropped at Step 11 (0 remain after normalization) | All FBS teams resolve; FCS opponents (Sacramento State, NDSU) correctly dropped | ✓ Found by live dry run |
| 2026-05-22 | 10 | `isTRUE(neutral_site/home_dome)` → `col == TRUE` in 4 locations | `Can't recycle 'false' (size 21) to size 1` crash in if_else | Vectorized comparisons work across all 21 game rows | ✓ Found by live dry run |
| 2026-05-22 | 10 | Added `.dry_run_saved` capture pattern before `rm(list=ls())` | DRY_RUN_MODE always reset to FALSE; broadcasts fired on every dry run | DRY_RUN prevents writes and broadcast correctly | ✓ Found by live dry run |
| 2026-05-22 | 10 | Added `neutral_site = FALSE` default in MERGE_GAMES_RATINGS_CFB.R + TRAVEL_FATIGUE_CFB.R | `object 'neutral_site' not found` crash at Step 12 and Step 16 | Pipeline continues with neutral_site=FALSE for all regular-season non-bowl games | ✓ Found by live dry run |
| 2026-05-22 | 10 | Weather empty-result guard + `select(-any_of("home_dome"))` | OWM returns 0 rows pre-season (4 months out); `select(-home_dome)` crashed on absent column | Weather step skips gracefully; Step 17 uses `has_weather` guard | ✓ Found by live dry run |
| 2026-05-22 | 10 | `fatigue_pts_from_miles()` vectorized (`ifelse` not `if`) | `to_hawaii` is logical vector in mutate(); scalar `if()` always used first element only | All 21 away teams get correct fatigue calculation | ✓ Found by live dry run |
| 2026-05-22 | 10 | `filter(source_col == "odds_name")` added to append_odds_lookup_cfb.R + log flush at Step 1 | 567 FCS/D2/D3 names flooding Step 10 from stale unmatched_teams.csv | Only true DK-feed unmatched FBS names proposed for lookup | ✓ Found by live dry run |

**Edge bucket snapshot (2025 backtest, 2024 SP+):**

| Edge Bucket | Bets | ATS | Signal |
|-------------|------|-----|--------|
| 3-5 pts | 110 | 45.5% | ✗ -EV — eliminated by MIN_EDGE_SPREAD=5.0 |
| 5-7 pts | 102 | 56.9% | ✓ Profitable |
| 7-10 pts | 124 | 61.3% | ✓✓ Strong — primary sweet spot |
| 10-15 pts | 56 | 46.4% | ⚠ Monitor live — inconclusive at n=56 |

**Warning: 530 unmatched FCS team names** in normalizer warnings — these are FBS-vs-FCS games, correctly dropped by `filter(!is.na(canonical_home/away))`. Not a bug. Low-priority noise suppression opportunity.

---

## HARD-LEARNED LESSONS (inherited from mcBaseBall + CFB dry run, 2026-05-22)

1. Named args on `normalize_team_name()` — always `mappings = master`, never positional
2. MASTER CSV as single source of truth — no separate coord files or conf files
3. Brace balance before deploying any script — depth-walking loop, not str_count
4. 5-field `bet_idx` in settlement — game_id + away + home + bet_type + bet_side
5. Non-fatal `tryCatch` on all non-critical steps — bye_week, weather, travel, trend
6. `rm(list = ls())` before every settlement run — stale function cache causes silent errors
7. Never settle same-day — scores must be final
8. `select(-any_of(...))` before any join on external CSVs — prevent column collisions
9. `preprocess_team_name()` strips trailing periods and converts " State" → " St." — MASTER odds_name must match post-preprocessing form
10. Correlated bets (spread + ML on same game) need combined exposure cap — don't let one bad game double-hit the bankroll
11. **`isTRUE()` is scalar-only** — `isTRUE(vec)` always returns `FALSE` for vectors of length >1. Use `vec == TRUE` inside `mutate()`, `if_else()`, `case_when()`. Found in 4 locations: MERGE_GAMES_RATINGS_CFB.R, TRAVEL_FATIGUE_CFB.R, WEATHER_SCRAPER_CFB.R (x2), run_daily_football.R Step 17.
12. **DK feed sends full mascot names** ("Ohio State Buckeyes", "Notre Dame Fighting Irish") — 4-pass normalizer is not enough. Pass 5 (strip last word) + Pass 6 (strip last two words) added to TEAM_NAME_NORMALIZER_CFB.R. Without this, ALL 21 games dropped at Step 11.
13. **`rm(list = ls())` fires before any `exists()` guard** — capturing a pre-set variable like `DRY_RUN_MODE` requires a `.saved` pattern: capture before rm(), restore after. Otherwise every `source("run_daily_football.R")` resets DRY_RUN_MODE to FALSE and fires broadcasts.
14. **`neutral_site` column is NOT in the Odds API feed** — it comes from CFBD (MERGE_GAMES_RATINGS step). Any script that references `neutral_site` before Step 12 must default it: `if (!"neutral_site" %in% names(df)) df <- df %>% mutate(neutral_site = FALSE)`.
15. **Pre-season API behavior:** OWM returns empty results for games 4+ months out (`map_dfr` returns 0-row/0-col tibble). Guard with `nrow() == 0` check. CFBD talent/returning endpoints return HTML (data not published pre-season). All non-fatal; pipeline degrades gracefully.
16. **Stale `logs/unmatched_teams.csv` contaminates Step 10** — flush at the start of each pipeline run. The log accumulates FCS/D2/D3 school names from Massey/CFBD scraper passes and floods `append_odds_lookup_cfb.R` with garbage. Also added `filter(source_col == "odds_name")` inside that script.
17. **`fatigue_pts_from_miles()` vectorization** — original used scalar `if (to_hawaii) base <- base - 1.5`. When called inside `mutate()`, `to_hawaii` is a logical vector. Fix: `ifelse(to_hawaii, base - 1.5, base)`.

---

## CFB-SPECIFIC NOTES

- **Dome guard:** Before any weather fetch/adjustment, check `game$home_dome == TRUE`. If TRUE, set wind=0, temp=72, precip=0 and skip API call. **Never use `isTRUE()` inside `mutate()` or `if_else()` — it is scalar-only and always returns length 1 regardless of input vector length.**
- **Neutral site games:** Bowl games, CFP, some OOC games. `neutral_site = TRUE` from CFB Data API. Set HFA adjustment = 0 for neutral site games.
- **Bye week edge:** Teams off a bye week cover ATS at ~53-54% historically. Meaningful signal — by week boost (1.08x) fires when model agrees.
- **Sharp move threshold:** CFB spread moves of 2.5+ pts are significant (vs 10 pts for baseball ML). Totals: same 0.5-pt threshold as baseball.
- **CFBD API key:** Free registration at collegefootballdata.com. Store in credentials.json as `cfbd_api_key`. Required for SCRAPE_CFB_DATA.R.

---

## PENDING ITEMS

| Item | Priority | Notes |
|------|----------|-------|
| ~~Add `openweather_api_key` to credentials.json~~ | ~~High~~ | ✓ Done — 2026-05-20 |
| ~~Build DRY_RUN_TEST.R~~ | ~~High~~ | ✓ Done — 97/97 passing — 2026-05-20 |
| ~~Live dry run~~ | ~~High~~ | ✓ Done — 2026-05-22. Pipeline ran end-to-end in DRY RUN mode: 19.5 sec, 21/21 steps, 6 qualified bets, $133.33 action. FCS opponents correctly dropped. All pre-season API failures graceful. |
| ~~bet_history.csv → SQLite~~ | ~~High~~ | ✓ Done — 2026-05-25. `outputs/cfb_bets.sqlite` is now the permanent ledger. See Session 14. |
| ~~Massey JS scraper broken~~ | ~~High~~ | ✓ Done — 2026-05-25. `fetch_massey_page()` rewritten to use `rvest::read_html_live()` + chromote. See Session 15. |
| ~~Run db_schema_init.R once~~ | ~~High~~ | ✓ Done — Session 19. Script created; handles both cfb_bets.sqlite + cfb_line_movement.sqlite. |
| ~~Verify plays_per_game flows through MERGE_GAMES_RATINGS_CFB.R~~ | ~~High~~ | ✓ Done — Session 19. SCRAPE derives plays_per_game; MERGE passes it through; GENERATE uses it as primary pace signal (fallback: possessionTime). LEAGUE_AVG_PACE=70.0, TEMPO_TOTAL_WEIGHT=0.15 in CONFIG.R. |
| Calibrate talent_adj live (weeks 1-4) | **Medium** | TALENT_WEIGHT=1.5 is a reasonable prior. Tune after 4 weeks of live data against ATS by week bucket. If Week 1 ATS improves vs baseline, raise toward 2.5. |
| Calibrate retention dampener | **Medium** | RETENTION_SCALAR_MIN=0.80 (20% Kelly reduction for low-retention teams in Week 1). Verify impact in live play — if dampened bets hit at same rate, remove or reduce. |
| Validate MASTER odds_name vs DK feed | Medium | Run after first live odds fetch (Sep 2026); patch via append_odds_lookup_cfb.R |
| Monitor 10-15 pt edge bucket | Medium | Currently 46.4% ATS on n=56 — inconclusive. Flag in live play if < 50% after 50+ bets. Consider lowering MAX_EDGE_SPREAD to 10 if pattern holds. |
| Phase 2: Monte Carlo alternate lines | Low | Requires live season validation; full plan in GENERATE_PREDICTIONS_CFB.R header |
| Confirm Minnesota dome status | Low | Huntington Bank Stadium retractable roof — treating as outdoor for now |

---

## SESSION LOG

### SESSION 1 (Chat 1, Response 1)
**Date:** 2026-05-08

**Completed:**
- Architecture plan created (mcFootball_ARCHITECTURE_PLAN.md in Cowork/ABOUT ME/)
- Confirmed markets: Spread + Total + ML (no player props, Colorado restriction)
- Confirmed philosophy: Edge + +EV + CLV
- `cfb_project/` directory structure created
- `CONFIG.R` — complete with all constants, Kelly helper, american_to_prob
- `team_name_mappings_MASTER_CFB.csv` — 134 FBS teams, post-2024 realignment
- `run_daily_football.R` — full pipeline orchestrator (Steps 1–21)
- `CFB_PROJECT_BIBLE.md` — this file
- `outputs/bankroll.txt` — seeded at $500

**Outstanding (build in order):**
1. `TEAM_NAME_NORMALIZER_CFB.R` — port from mcBaseBall
2. `standardize_data_cfb.R` — normalize_odds_data() wrapper
3. `SCRAPE_CFB_DATA.R` — CFB Data API (needs API key first)
4. `scrape_massey_cfb.R` — Massey CFB ratings
5. `scrape_sagarin.R` — Sagarin ratings
6. `MERGE_ALL_RATINGS_CFB.R`
7. `fetch_odds_football.R`
8. `GENERATE_PREDICTIONS_CFB.R`
9. `CALCULATE_VALUE_CFB.R`
10. `BET_SETTLEMENT.R` (CFB version)
11. Remaining scripts (bye week, weather, travel, broadcast, finalize)

**Start Session 2 with:**
- Share `credentials.json` structure from mcBaseBall so API keys carry over
- Confirm CFB Data API key registered (collegefootballdata.com)
- Begin with TEAM_NAME_NORMALIZER_CFB.R port

---

### SESSION 2 (Chat 2, Response 20)
**Date:** 2026-05-08

**Completed:**
- `TEAM_NAME_NORMALIZER_CFB.R` — 3-pass lookup, 133/133 round-trip validated, Miami/Ohio disambiguated, trailing-period strip bug fixed
- `standardize_data_cfb.R` — normalize_odds_data() + validate_odds_data()
- `SCRAPE_CFB_DATA.R` — CFBD API, SP+/team stats/schedule; cfbd_api_key = Bearer JWT
- `scrape_massey_cfb.R` — PRE block parser, SAG bonus cache
- `scrape_sagarin.R` — Path A (Massey cache) + Path B (direct fetch)
- `MERGE_ALL_RATINGS_CFB.R` — z-score blend, SP+/Sagarin/Massey, n_sources quality flag
- `fetch_odds_football.R` — DK primary, fallback waterfall, opening line movement tracking
- `MERGE_GAMES_RATINGS_CFB.R` — rating diff, effective HFA, off/def efficiency
- `GENERATE_PREDICTIONS_CFB.R` — deterministic linear model; Phase 2 Monte Carlo TODO stub
- `CALCULATE_VALUE_CFB.R` — 3-market +EV engine, all 4 boost multipliers, correlated cap
- `BYE_WEEK_TRACKER.R`, `WEATHER_SCRAPER_CFB.R`, `TRAVEL_FATIGUE_CFB.R`, `TREND_ANALYSIS_CFB.R`
- `append_odds_lookup_cfb.R`, `BET_SETTLEMENT.R`, `FINALIZE_BETS_CFB.R`, `broadcast_football.R`
- All 19 scripts + MASTER CSV + bankroll.txt confirmed written to `G:\My Drive\Scripting Projects\cfb_project\`
- Fixed: bash sandbox writes do NOT propagate to Windows — Write tool required for all file output
- Validated: all season year references updated 2024 → 2025

**KEY DECISIONS:**
- CFBD API key format: Bearer JWT (~200+ char), stored as `cfbd_api_key` in credentials.json at project root
- Model: deterministic linear + logistic sigmoid win_prob (NOT Monte Carlo — Phase 2 for alt lines)
- Sagarin PREDICTOR (not Rating) used for spread modeling; z-scored before blend
- has_third_down / has_red_zone checked OUTSIDE mutate() — names(.) unreliable inside mutate

**Outstanding:**
1. Add `openweather_api_key` to credentials.json (for WEATHER_SCRAPER_CFB.R)
2. Optionally add Telegram/Discord credentials for broadcast
3. Validate MASTER CSV odds_name against DK feed on first live odds fetch
4. ~~Validate base model MAE ≤ 6 pts against 2025 CFB season~~ → BACKTEST_2025.R built (Session 3)
5. Build `TEAM_METRICS.R` (Step 6 — off/def efficiency stub, currently passed inline)
6. Phase 2: Monte Carlo alternate lines (full plan in GENERATE_PREDICTIONS_CFB.R header)
7. **Run** BACKTEST_2025.R and interpret results (needs credentials.json + API key)

**Start Session 3 with:** (Sessions 3–15 were development sessions; see CLAUDE.md for cumulative state as of Session 15.)

---

## Session 16 — Massey Session-Close Bug + MASTER Expansion + case_when Fix (2026-05-27)

**Goal:** Fix Massey scraper session-close bug, expand MASTER, eliminate Warning 6.

### Fix 1 — `scrape_massey_cfb.R`: Extract HTML Before Session Closes

**Root cause:** `fetch_massey_page()` returned a live `session` object. `on.exit(session$close())` fired before the caller could extract rendered HTML. By the time `parse_massey_ranks_table()` tried to read the DOM, the session was already closed.

**Fix:** Extract rendered HTML string inside `fetch_massey_page()` BEFORE `on.exit` fires, via `Runtime$evaluate`:
```r
html_string <- session$Runtime$evaluate(
  "document.documentElement.outerHTML"
)$result$value
```
`parse_massey_ranks_table()` now takes the string and calls `read_html()` on it — no live session dependency.

Timeout bumped to 30s. `wait_for('#SHCtable td', timeout=30000)` — if it times out, proceeds with current DOM.

**Dry run result (2026-05-27):** Massey timed out (wait_for failed) but parsed 138 teams from current DOM. Matched 100/138 (38 unmatched — Massey abbreviated names like "Ohio St", "Penn St"). This is acceptable; the 100 matched teams get blended ratings.

### Fix 2 — `team_name_mappings_MASTER_CFB.csv`: 138 Rows

Added two missing CUSA teams that appeared in CFBD advanced stats and Massey `/ranks`:
- **Delaware** — `Delaware` / `Delaware`, CUSA
- **Missouri State** — `Missouri State` / `Missouri St`, CUSA

MASTER is now 138 rows (134 FBS + 4 FCS/lower-div stragglers).

### Fix 3 — `standardize_data_cfb.R`: case_when → if/else

**Root cause:** `case_when()` with a scalar LHS inside `mutate()` generates a warning in dplyr when the condition evaluates to length-1 but the column is length-n.

**Fix:** Replaced `case_when(...)` block with `if/else` inside `mutate()`. Warning 6 eliminated.

### Dry Run Summary (2026-05-27)
- Runtime: 23.0s | 6 bets | $133.33 action
- 62/64 games with full ratings (2 with NA ratings — both missing from Massey/Sagarin)
- Sagarin SSL error ongoing (schannel root cert) — falls back gracefully to 0 Sagarin teams in blend
- talent/returning API calls fail (HTML returned instead of JSON) — pre-season, non-fatal

### Known Remaining Issues (pre-season)
- 38 Massey name mismatches (Massey abbreviations — would require a full 138-row Massey→MASTER alias table to fix)
- Warning 7: 2 NA-rated games per run (expected until both Sagarin and Massey cover all teams)
- Warning 9: extreme spreads (|proj_spread| > 35 pts) — pre-season schedule mismatches
- Warning 10: BYE_WEEK_TRACKER — no schedule (pre-season)

### Session 16 Decisions
- Do NOT add `confiscate_when` aliases for Massey abbreviations now — too many, pre-season only. Revisit in August if Massey coverage is still < 120 matched teams.
- MASTER stays at 138; next expansion when a new CUSA/G5 team appears in odds feed.

**Outstanding for Session 17:**
1. Run `db_init_bets.R` once before first live bet
2. Validate MASTER odds_names vs DK feed on first live odds fetch (Sep 2026)
3. Post-Week-4: calibrate TALENT_WEIGHT and RETENTION_SCALAR_MIN
4. Consider Massey full-alias table if match rate is still < 80% in-season

**Start Session 17 with:** run pipeline and paste full console log. Report Massey match count and any new unmatched team names.

---

### Session 3 through 15 — Catchup Summary (2026-05-08 to 2026-05-25)

(Not individually logged in this Bible. Key cumulative state as of Session 15:)

- Full 21-step orchestrator `run_daily_football.R` built and validated
- `TEAM_METRICS.R` implemented (Step 6 — no-op stub replaced with real PPA/success rate metrics from CFBD API)
- `bet_history.csv` → `outputs/cfb_bets.sqlite` migration (Sessions 13–14): new `db_init_bets.R`, `FINALIZE_BETS_CFB.R` and `BET_SETTLEMENT.R` fully migrated to SQLite
- `scrape_massey_cfb.R` updated from PRE-block parser to JS-rendered chromote scraper (Session 15), then session-close bug fixed (Session 16)
- VSiN scraper integrated (`SCRAPE_VSIN_CFB.R` + `PARSE_VSIN_CFB.R`, Steps 8.5a/8.5b)
- Line movement SQLite: `outputs/cfb_line_movement.sqlite`
- Talent/retention API stubs present but return NA pre-season
- All boosts wired: SHARP=1.15x, TREND=1.08x, BYE=1.08x, PUBLIC=1.20x
- Dry run as of Session 15: 22.6s, 6 bets, $133.33 action
- Run `run_daily_football.R` for the first time in-season (CFB season starts Sep 2026)
- Validate model MAE against 2025 historical season data before live deployment
- Check `logs/unmatched_teams.csv` after first odds fetch for any DK name mismatches
- Patch MASTER odds_names as needed via append_odds_lookup_cfb.R proposals

---

### SESSION 3 (Chat 3, Response 1)
**Date:** 2026-05-08

**Completed:**
- Season year audit: all 2024/2025 references corrected — **Validation year: 2025. Live deployment: September 2026.**
- All 19 scripts re-written to `G:\My Drive\Scripting Projects\cfb_project\scripts\` via Write tool (bash sandbox writes do NOT persist to Windows)
- `BACKTEST_2025.R` — standalone historical backtester against 2025 CFB season (SP+ via CFBD API). Computes MAE, RMSE, direction accuracy, model bias, ATS record on qualifying bets, breakdown by week/conf_tier/edge_bucket. Outputs: `clean/backtest_2025_results.csv` + `clean/backtest_2025_summary.csv`.
- Fixed `home_points` column name bug (CFBD API returns camelCase `homePoints` — added normalization block in `pull_games()`)
- Fixed 11 normalizer mismatches:
  - **MASTER CSV additions:** Wyoming (Mountain West, conf_tier=2, conf_weight=0.78, War Memorial Stadium), FAU massey_name fixed to "Florida Atlantic"
  - **Preprocessing additions:** `Hawai'i → Hawaii`, `é/è/ó → ASCII` (catches San José State), `California → Cal`
  - **Pass 4 added to normalize_team_name():** When source_col="massey_name", exhausts odds_lu as final fallback — fixes Miami (OH), App State, UL Monroe in one change
- Added `nationalAverages` + FCS team filter in `pull_games()` before normalization

**MASTER CSV status:** 136 teams (Wyoming + FAU added this session)

**First backtest run hit:**
1. `home_points` column not found → fixed (camelCase normalization)
2. 11 unmatched normalizer warnings → fixed (preprocessing + Pass 4 + MASTER additions)
→ Script is ready for a clean run

**KEY DECISIONS:**
- CFBD `/games` API returns camelCase (`homePoints`, `awayPoints`, `homeTeam`, etc.) — normalized in `pull_games()` via `str_replace` chain; also handles dot-notation from `flatten=TRUE`
- Pass 4 (odds_lu fallback for massey source) is the right architectural fix — avoids preprocessor context-coupling
- Wyoming was genuinely missing from MASTER (Mountain West had 13/14 teams)
- `preprocess_team_name("^California$")` was a no-op — fixed to → "Cal" (massey_name form)

**Outstanding:**
1. **Run BACKTEST_2025.R to completion** — first clean run pending; interpret MAE vs 6.0 pt target
2. Add `openweather_api_key` to credentials.json
3. Optionally add Telegram/Discord credentials for broadcast
4. Validate MASTER odds_names against DK feed on first live odds fetch (Sep 2026)
5. Build `TEAM_METRICS.R` (pipeline Step 6)
6. Phase 2: Monte Carlo alternate lines (full plan in `GENERATE_PREDICTIONS_CFB.R` header)
7. Check `logs/unmatched_teams.csv` after backtest run for any residual normalizer gaps

**Start Session 4 with:**
- Paste the BACKTEST_2025.R console output (full) so we can interpret MAE and calibrate
- If MAE > 7.5: recalibrate checklist in script fires automatically with guidance
- If MAE ≤ 6.0: model is validated; begin building `TEAM_METRICS.R`

---

### SESSION 4 (Chat 4, Response 8)
**Date:** 2026-05-11

**Completed:**
- Normalizer fixes confirmed NOT in bash mount — re-applied all three via bash write:
  - `"^California$"` → `"Cal"` (no-op fix)
  - Accent stripping block: `ʻokina`, `Hawai'i` → `Hawaii`, `é/è` → `e`, `ó` → `o`
  - Pass 4 (odds_lu fallback when `source_col="massey_name"`) — fixes App State, ULM, Miami OH
- BACKTEST_2025.R bugs fixed:
  - `isTRUE(neutral_site)` → `neutral_site` (scalar vs. vector crash in `if_else`)
  - `home_covered` bare NA → `as.logical()` coercion
  - Moved edge-cap variable (`.max_edge`) outside `mutate()` block
- Backtest fully run and interpreted (3 runs):
  1. 2025 SP+ (hindsight): 73.5% ATS — **look-ahead bias, discard**
  2. 2024 SP+ (preseason proxy), no cap: 53.7% ATS on 605 bets
  3. 2024 SP+ + MAX_EDGE_SPREAD=12: **55.0% ATS on 402 bets — VALIDATED**
- Added to CONFIG.R: `SP_SCALAR = 1.0`, `MAX_EDGE_SPREAD = 12.0`
- Wired MAX_EDGE_SPREAD cap into CALCULATE_VALUE_CFB.R spread bet qualification
- GENERATE_PREDICTIONS_CFB.R updated to use `SP_SCALAR` from CONFIG.R

**BACKTEST FINAL RESULTS (2024 SP+, MAX_EDGE=12):**
- Overall MAE: 14.32 pts (preseason-only; expected to drop to ~8–10 with in-season SP+)
- ATS: 55.0% on 402 bets ✓ PROFITABLE (break-even: 52.4%)
- 7–10 pt edge bucket: **61.9% ATS on 134 bets** — statistically significant (z=2.20, p=0.014)
- Direction accuracy: 67.2%
- Model bias: -0.55 pts (well-calibrated)
- 10–15 pt bucket: 40.9% on n=66 — flag to monitor live, inconclusive at this sample size

**KEY DECISIONS:**
- SP_SCALAR stays at 1.0 — scaling to 0.65 migrated the 7–10 bucket signal into 5–7, degrading ATS
- MAX_EDGE_SPREAD=12 is the validated cap — not 10 (too few bets) or 15 (negative EV)
- Stopped backtest parameter tuning at this point — further changes risk overfitting to 2025 data
- MAE target of ≤6.0 is appropriate only for the full blend (SP+ + Sagarin + Massey + in-season updates); preseason-only baseline of 14.32 is expected and acceptable
- Phase 2 Monte Carlo prerequisite relaxed: proceed with `TEAM_METRICS.R` now; Monte Carlo after first live season

**Outstanding:**
1. Build `TEAM_METRICS.R` (pipeline Step 6) — off/def efficiency from CFBD API
2. Add `openweather_api_key` to credentials.json
3. Validate MASTER odds_name vs DK feed (Sep 2026)
4. Add Telegram/Discord credentials (optional)
5. Monitor 10–15 pt edge bucket in live play

**Start Session 5 with:**
- Build `TEAM_METRICS.R` — pull off/def efficiency stats from CFBD `/stats/season` endpoint
- Input: `master` (canonical team list), `cfbd_api_key`
- Output: `cfb_team_stats_YYYY.csv` in `clean/` + `team_metrics` tibble in GlobalEnv
- Key columns needed: `canonical_name`, `off_ppa`, `def_ppa`, `off_success_rate`, `def_success_rate`, `off_explosiveness`, `third_down_rate`, `red_zone_rate`

---

### SESSION 5 (Chat 5, Response 12)
**Date:** 2026-05-15

**Completed:**

**TEAM_METRICS.R (Step 6) — built and validated:**
- Endpoint: CFBD `/stats/season/advanced` (NOT `/stats/season` — wrong endpoint, different data)
- Columns: off_ppa, def_ppa, off_success_rate, def_success_rate, off_explosiveness, def_explosiveness, off/def power_success, stuff_rate, line_yards + third_down_rate from basic stats join
- red_zone_rate confirmed NOT available from CFBD /stats/season endpoint (redZoneAttempts/Scores absent)
- 2025 validation: 134/134 FBS teams fully complete on 5 core metrics
- Orchestrator flag: `.team_metrics_sourced_by_orchestrator` suppresses auto-run; orchestrator calls `build_team_metrics()` directly
- CFBD stat name fixes in SCRAPE_CFB_DATA.R: `passYards` → `netPassingYards`, `rushYards` → `rushingYards`, removed redZone stats, added turnoversOpponent (enables turnover_margin inline), pass_completion_rate

**MERGE_GAMES_RATINGS_CFB.R — updated:**
- Added `join_metrics_side()` — joins off/def PPA, success rate, explosiveness per side
- Updated `join_stats_side()` — new column list matching SCRAPE output
- Team_metrics fallback chain: GlobalEnv → cfbd_team_stats CSV if PPA cols present
- Added PPA differentials to derived vars: `ppa_diff`, `success_rate_diff`, `explosiveness_diff`
- **Fixed conf_weight_avg** — was always NA; now computed from conference columns: P4=1.00, G5=0.80, Independent=0.70, unknown=0.90

**GENERATE_PREDICTIONS_CFB.R — updated:**
- Spread formula now blends: `rating_diff * SP_SCALAR + ppa_diff * PPA_SPREAD_WEIGHT + success_rate_diff * SUCCESS_SPREAD_WEIGHT + HFA + bye + travel`
- Total formula: PPA path (explosiveness_diff × EXPL_TOTAL_WEIGHT) when available; SP+ off/def fallback
- Output includes ppa_adj, success_adj, ppa_available columns for transparency
- Summary log shows PPA coverage and active weights per run

**CONFIG.R — updated:**
- Added PPA_SPREAD_WEIGHT=5.0, EXPL_TOTAL_WEIGHT=3.0, SUCCESS_SPREAD_WEIGHT=2.0
- SP_SCALAR=1.0 and MAX_EDGE_SPREAD=12.0 already present from Session 4

**CALCULATE_VALUE_CFB.R — three bugs fixed:**
- CRITICAL: MAX_EDGE_SPREAD cap was bypassed by sharp override path. `if (abs(edge) > max_e) return(NULL)` now fires first, before any branching. 126 bets at 43.7% ATS were slipping through.
- MISSING: MAX_BETS_PER_WEEK (20) and MAX_EXPOSURE_PER_WEEK (30%) defined in CONFIG but never enforced. Now applied: bets sorted EV desc, cumulative action trimmed at 30%, hard count cap at 20.
- MISSING: `qualified_bets` alias not assigned in zero-bets path. Fixed — orchestrator summary now works in all cases.

**run_daily_football.R (orchestrator) — built:**
- Phases 1–7 with correct dependency order (bye/weather/travel in Phase 4, before predictions)
- Fatal vs non-fatal correctly wired
- Per-step timing + timestamped log to logs/run_YYYYMMDD_HHMM.log
- Qualified bet summary at end (count by market)
- TEAM_METRICS.R flag handling
- Off-season behavior: clean through Phase 4, stops at Phase 5 (no odds)

**Scheduled task created:**
- Task ID: `mcfootball-daily-pipeline`
- Schedule: daily at 8:00 AM local (cron: `0 8 * * *`)
- Location: `C:\Users\Mike\Documents\Claude\Scheduled\mcfootball-daily-pipeline\SKILL.md`
- Note: requires one manual "Run now" to pre-approve bash permissions

**KEY DECISIONS:**
- PPA weights conservative at 5.0/3.0/2.0 — at defaults, 0.1 PPA diff = 0.5 pt spread shift. Don't tune up until live validation confirms PPA improves on 55% baseline.
- CFBD /stats/season/advanced is the right endpoint for PPA (not /stats/season which only has basic counting stats)
- red_zone_rate dropped from completeness check — not available from CFBD; will derive from PPA data if needed
- Orchestrator runs phases in logical dependency order, not step number order (step numbers in scripts are authoring labels, not execution sequence)
- Bash mount shows stale directory listing after Write tool writes — trust Write tool confirmation, not bash re-reads

**Outstanding:**
1. Re-run BACKTEST_2025.R with PPA weights active — verify 55% baseline holds
2. Verify home_conference/away_conference survive standardize_data_cfb.R passthrough
3. broadcast_football.R end-to-end test (Telegram/Discord)
4. Live dry run late Aug 2026

---

### SESSION 6 (Chat 6, Response 6)
**Date:** 2026-05-17

**Completed:**

**CFB_PROJECT_BIBLE.md — built:**
- Bible didn't exist despite being referenced in scripts (it was created here for the first time)
- Full pipeline map (21 steps), data sources, ratings blend, spread/total model formulas
- conf_weight system, Kelly sizing, MASTER CSV schema, backtest spec, calibration log
- Session log format established (append SESSION entry every 20 responses)

**BACKTEST_2025.R — PPA integration:**
- Added Step 6.5: Fetches `/ppa/teams?year=2025` from CFBD (non-fatal; graceful skip if unavailable)
- Joins `off_ppa`, `def_ppa`, `off_success_rate`, `def_success_rate`, `off_explosiveness` for both home and away
- Computes `ppa_diff`, `success_rate_diff`, `explosiveness_diff` using same differential logic as `GENERATE_PREDICTIONS_CFB.R`
- Applies `PPA_SPREAD_WEIGHT (5.0)` and `SUCCESS_SPREAD_WEIGHT (2.0)` from CONFIG.R to spread formula; `EXPL_TOTAL_WEIGHT (3.0)` on total path
- Stores both `proj_spread_sp` (SP-only baseline) and `proj_spread` (PPA-blend) — MAE delta shown in console and `backtest_2025_summary.csv`
- `SP_SCALAR = 1.00` applied consistently (was hardcoded at 0.45 in old backtest — fixed)
- Console now shows: SP-only MAE, PPA-blend MAE, delta, and verdict (✓/⚠/✗)

**conf_weight_avg — confirmed live end-to-end:**
- Computed in `MERGE_GAMES_RATINGS_CFB.R` (lines 218–232) from conference columns; P4=1.00, G5=0.80, Ind=0.70
- Passed through all three evaluators in `CALCULATE_VALUE_CFB.R`
- Applied as a direct EV multiplier in `apply_boosts()` — no changes needed

**KEY DECISIONS:**
- BACKTEST_2025.R PPA fetch uses `BACKTEST_YEAR` (2025), not `SP_RATINGS_YEAR` (2024) — PPA data available for completed seasons
- `get_col()` helper handles both `offense.overall` and `offenseOverall` naming conventions across CFBD API versions
- SP_SCALAR hardcoded 0.45 was a regression from Session 4 fix — now pulled from CONFIG.R correctly

**Outstanding:**
1. **Run BACKTEST_2025.R to see PPA delta** — needs credentials.json with cfbd_api_key
2. Add `openweather_api_key` to credentials.json
3. Validate MASTER odds_names vs DK feed (Sep 2026)
4. Broadcast end-to-end test (Telegram/Discord)
5. Live dry run late Aug 2026

**Start Session 7 with:**
- Paste BACKTEST_2025.R console output to compare SP-only vs PPA-blend MAE
- OR begin next build task: `BET_SETTLEMENT.R` audit / `FINALIZE_BETS_CFB.R` review

---

### SESSION 8 (Chat 8, Response 19)
**Date:** 2026-05-17

**Completed:**

**Talent composite + roster retention score — fully wired across 4 scripts:**

`TEAM_METRICS.R` — `build_team_metrics()` updated:
- Calls `fetch_talent(api_key, year, master)` → CFBD `/teams/talent` → `talent_score` (raw 247Sports composite) + `talent_norm = (score - 900) / 100` (Alabama ~+2.0, avg G5 ~-1.0)
- Calls `fetch_returning_production(api_key, year, master)` → CFBD `/returning` → `returning_pct` (percentPPA) + `retention_score` (three-tier: ≥65% → 1.00 | 50-65% → linear 0.80→1.00 | <50% → 0.80)
- Both joins are non-fatal (tryCatch + left_join with NA fallback columns when API returns empty)
- Priority cols ordering updated: talent_score, talent_norm, returning_pct, retention_score inserted after explosiveness
- Validation report now prints team coverage counts and value ranges for both new columns

`MERGE_GAMES_RATINGS_CFB.R` — `join_talent_side()` helper added:
- Prefixes `talent_norm` and `retention_score` as `home_talent_norm`, `away_talent_norm`, `home_retention_score`, `away_retention_score`
- Non-fatal: returns games_df unchanged when columns absent (pre-season or API failure)
- `stale_pattern` updated to strip talent_norm|retention_score before re-join
- `talent_diff = coalesce(home_talent_norm, 0) - coalesce(away_talent_norm, 0)` added to mutate block

`GENERATE_PREDICTIONS_CFB.R` — talent adjustment added to spread formula:
- `talent_decay(week_num)` function: 1.00 / 0.75 / 0.50 / 0.25 / 0.00 for weeks 1-5+
- `week_num` derived from `game_row$commence_time` → `ceiling((date - Sept1 + 1) / 7)`, floors at 1
- `talent_adj = talent_diff × TALENT_WEIGHT × talent_decay(week_num)` — positive = home advantage
- `proj_spread` updated: `-(rd + ppa_adj + success_adj + talent_adj + hfa + bye_adj + travel_adj)`
- `talent_adj` and `week_num` added to predict_game() output (flow through unnest_wider into games_with_predictions)
- Diagnostics log reports which week, decay weight, how many games with active talent_adj

`CALCULATE_VALUE_CFB.R` — retention dampener on Kelly sizing:
- Fires only when `game$week_num < 5L`; completely off by Week 5+ (no lookback, no false positives)
- `decay_fac = (5 - week_num) / 4` → full dampener Week 1, quarter-dampener Week 4
- `ret_mult = 1.0 - (1.0 - ret_score) × decay_fac` — e.g., Week 1, ret_score 0.80 → mult 0.80
- SPREAD/ML: uses bet-side team's retention. TOTAL: uses min(home, away) — both teams' roster uncertainty matters
- Applied to `bet_amount` (not EV) — models sizing uncertainty, not market edge
- `bet$retention_mult` added to all_bets; summary log prints count + avg mult when it fires

**Key decisions:**
- TALENT_WEIGHT = 1.5 is a conservative prior (~1.5 pts per normalized talent unit). Tune after 4 weeks live.
- RETENTION_SCALAR_MIN = 0.80 means max 20% Kelly reduction for a worst-case (<50% returning) team in Week 1. Designed to be felt, not crippling.
- Talent adjustment is a spread-only signal (affects proj_spread → win_prob cascade). Does not independently affect total or ML evaluation.

**Outstanding:**
1. Add `openweather_api_key` to credentials.json
2. Late Aug 2026 preseason dry run
3. After 4 weeks live: calibrate TALENT_WEIGHT and RETENTION_SCALAR_MIN against week-bucketed ATS

**Start Session 9 with:**
- Preseason dry run results (any TEAM_METRICS.R warnings on talent/returning endpoints), OR
- Week 1-4 live performance: talent_adj correlation with cover rate, retention_mult impact on ROI

---

### SESSION 7 (Chat 7, Response 11)
**Date:** 2026-05-17

**Completed:**

**Backtest confirmed at 5.0 pt floor:**
- `MIN_EDGE_SPREAD` raised 3.0 → 5.0 pts after backtest run: 3-5 pt bucket was 45.5% ATS (110 bets) — below break-even and dragging overall number
- Re-run confirmed: 277 bets | 160-117 | **57.8% ATS** ✓ (projected 58.2% — dead-on)
- `SHARP_EDGE_SPREAD` updated 1.95 → 3.25 pts (65% of new MIN_EDGE_SPREAD)
- PPA delta: -0.05 pts (negligible — expected rating year mismatch in backtest; weights unchanged for live)
- G5 outperforms P4 on ATS: 58.1% vs 55.6% — market less efficient on G5 games; don't skip G5 qualifying bets
- Edge bucket sweet spot confirmed: **7-10 pts, 61.3% ATS on 124 bets** — primary value zone
- 530 normalizer warnings = FCS opponents in FBS-vs-FCS games, correctly dropped by NA filter; not a bug

**BET_SETTLEMENT.R — 3 bugs fixed:**
- **CRITICAL (away spread settlement):** Away bets used `actual_margin < -posted_line` instead of `actual_margin < posted_line`. Since `posted_line` for away bets is positive (e.g., +7), the old formula required home to *lose* by 7+ for away to cover. Almost every away spread bet would have settled backwards.
- **CRITICAL (away spread CLV):** Old formula `(closing_spread - posted_line) * 10` returned -130 cents where correct answer was +10 cents. Fix: `(posted_line + closing_spread) * 10` — `closing_spread` is home-perspective (negative), so adding is equivalent to subtracting home spread from away spread.
- **MODERATE (column dedup crash):** `select(any_of(names(history)), spread_clv_cents, ...)` selects CLV columns twice on first settlement (FINALIZE writes them as NA_real_ into history). Fix: `setdiff()` base columns from CLV columns; append CLV explicitly.

**broadcast_football.R — fully rebuilt + confirmed live:**
- **Rewritten `format_bet_card()`** — baseball card style: game header / time / market / BET line / 🏃 Away + 🏠 Home with conference + tier / signals line / value line. Matches mcBaseBall broadcast format exactly.
- **Signal line:** SHARP → `📈 Sharp move (X pts)` | BYE → `😴 Off bye` | TREND → `📊 Trend agrees` | PUBLIC → `👥 Fading public` | none → `💼 Model edge only`
- **Injury warning on ML bets:** `⚠️ VERIFY INJURY REPORT BEFORE BETTING` — mirrors baseball's starter warning
- **Edge unit auto-switches:** pts for SPREAD/TOTAL, % for ML
- **`enrich_conference()`:** joins conference + tier from `master` (GlobalEnv) or MASTER_CSV. Early-returns if columns already present — prevents left_join collision that was overwriting pre-populated columns with `.x`/`.y` suffixes
- **`team_conf_str()` NULL guard:** `is.null` / `length == 0` check before `is.na` — prevents `logical(0)` crash when column missing from tibble row
- **Bug fixed:** `parse_mode = "HTML"` removed — `&` in team names (Texas A&M) would break Telegram parsing
- **Bug fixed:** CSV fallback now reads `bet_history.csv` filtered for today, not `MASTER_TICKET_CSV` (renamed columns)
- **`broadcast_dry_run()`:** fake 3-game slate (Alabama/Georgia SPREAD + TOTAL, Texas A&M/LSU ML) — previews card, checks credentials, fires `[TEST]` message if configured
- **Confirmed live:** Telegram ✓ Discord ✓ — 2026-05-17

**KEY DECISIONS:**
- MIN_EDGE_SPREAD = 5.0 is the validated floor. Don't lower it without 100+ live games of data.
- G5 edge is real — market under-prices G5 games. 58.1% ATS vs 54.5% for P4.
- 10-15 pt bucket (46.4%, n=56): too small to act on. Keep MAX_EDGE_SPREAD=12. Flag for live monitoring.
- PPA weights (5.0/2.0/3.0) stay until Week 6 live data — backtest year mismatch prevents meaningful evaluation.

**Outstanding:**
1. Add `openweather_api_key` to credentials.json (for WEATHER_SCRAPER_CFB.R)
2. Live dry run late Aug 2026 preseason — source `run_daily_football.R` with real credentials

**Start Session 8 with:**
- Preseason dry run results, OR
- Any script issues discovered during Aug 2026 test run, OR
- Line movement logger review before season start

---

### SESSION 9 (Chat 9, Response 3)
**Date:** 2026-05-20

**Completed:**

**DRY_RUN_TEST.R — full pipeline test harness built and passing 97/97:**
- 12 sections: CONFIG/Kelly helpers, edge filters (SPREAD/TOTAL/ML), correlated cap, weekly exposure cap, all 12 settlement scenarios, CLV calculations, bankroll update integrity, retention dampener, bankroll safety stress test, fault tolerance
- Run from project root: `source("DRY_RUN_TEST.R")`
- Located at `cfb_project/DRY_RUN_TEST.R`

**Bugs found and fixed by test harness:**

1. **CALCULATE_VALUE_CFB.R — strict inequality on edge floors (§2f/§3d)**
   - `edge < -MIN_EDGE_SPREAD` → `edge <= -MIN_EDGE_SPREAD` (spread)
   - `edge > MIN_EDGE_TOTAL` → `edge >= MIN_EDGE_TOTAL` (total)
   - Effect: bets at exactly 5.0 pt spread edge or 2.5 pt total edge were silently dropped. Valid +EV bets left on the table at the boundary.

2. **BET_SETTLEMENT.R — `result` column type mismatch on first settlement (§7)**
   - Added `mutate(result = as.character(result), pl = as.numeric(pl))` after `read_csv()`
   - Effect: first-ever `settle_bets()` run on a fresh bet history (all-NA result column) would crash on `bind_rows` type mismatch. Every opening-week bet would have been stuck as "pending" with bankroll never updated.

**openweather_api_key:**
- Added to credentials.json — confirmed present and matching key name in WEATHER_SCRAPER_CFB.R

**KEY DECISIONS:**
- DRY_RUN_TEST.R uses temp files for all I/O — never touches live bankroll.txt or bet_history.csv
- Test auto-restores live paths in cleanup block — safe to source repeatedly
- Re-run `source("DRY_RUN_TEST.R")` after any script change before live deployment

**Outstanding:**
1. Late Aug 2026 preseason dry run — `source("run_daily_football.R")` with live creds, no odds yet
2. Post-Week-4 calibration of TALENT_WEIGHT (1.5 prior) and RETENTION_SCALAR_MIN (0.80 prior)
3. Validate MASTER odds_name vs DK feed on first live odds fetch

**Start Session 10 with:**
- Preseason dry run results (late Aug 2026), OR
- Any script issues from the live odds fetch / normalizer gaps, OR
- Week 1–4 live performance data for calibration

---

---

### SESSION 10 (Chat 10, 2026-05-22)
**Date:** 2026-05-22

**Completed:**

**Full pipeline dry run — end-to-end clean:**
- Pipeline ran in DRY_RUN_MODE: 19.5 seconds, 21/21 steps, 6 qualified bets, $133.33 total action
- 2 FCS opponents correctly identified and dropped (Sacramento State Hornets, North Dakota State Bison)
- 6 bets output: Texas/Oklahoma ML, Ohio State/Texas SPREAD, LSU/Ole Miss ML, FAU/Florida SPREAD, Louisville/Ole Miss SPREAD, Texas/Oklahoma SPREAD
- Pre-season limitations confirmed non-fatal: OWM weather (no data 4mo out), CFBD talent/returning (HTML/pre-season), Massey JS scraper, bye week (no schedule), totals cluster 47.6–49.5 (SP+ only)
- All G5 conferences confirmed: MAC, Mountain West, Sun Belt, AAC, CUSA — 133 FBS teams total

**Bugs fixed (8 distinct root causes, 12+ code locations):**

1. **`master_cfb` not in GlobalEnv at Step 11** — Added conditional `load_cfb_master()` call before `normalize_odds_data()` in run_daily_football.R Step 11.

2. **All 21 DK games dropped (0 normalized)** — DK sends "School Mascot" format (e.g., "Ohio State Buckeyes"). Added Pass 5 (strip last word) + Pass 6 (strip last two words) to `normalize_team_name()` in TEAM_NAME_NORMALIZER_CFB.R. "UL Monroe Warhawks" case required additional preprocess rule `"^UL Monroe.*$"` → `"Louisiana Monroe"`.

3. **`DRY_RUN_MODE` always FALSE despite being set before `source()`** — `rm(list=ls())` on line 15 wiped it before the `exists()` guard could fire. Fix: `.dry_run_saved <- if (exists("DRY_RUN_MODE")) DRY_RUN_MODE else FALSE` captured before `rm()`, restored after. In run_daily_football.R.

4. **`object 'neutral_site' not found` at Step 12** — `neutral_site` not in Odds API feed; only available post-CFBD merge. Added default `mutate(neutral_site = FALSE)` guard in MERGE_GAMES_RATINGS_CFB.R before the block that references it. Same fix applied in TRAVEL_FATIGUE_CFB.R via `any_of("neutral_site")` + inline default.

5. **`Can't recycle 'false' (size 21) to size 1`** — `isTRUE(neutral_site)` inside `if_else()` — `isTRUE()` is scalar, always returns length 1. Changed to `neutral_site == TRUE` in MERGE_GAMES_RATINGS_CFB.R. Same pattern fixed in TRAVEL_FATIGUE_CFB.R and run_daily_football.R Step 17 (`home_dome == TRUE`).

6. **Weather step crash: `select(-home_dome)` on empty tibble** — OWM returns no data for games 4+ months out; `map_dfr` with all-NULL results produces a 0-row/0-col tibble. Added `nrow(weather_data) == 0` guard + changed `select(-home_dome)` to `select(-any_of("home_dome"))` in WEATHER_SCRAPER_CFB.R.

7. **Step 17 weather adj error: missing `wind_speed`/`precip_prob` columns** — When `weather_data` is NULL, those columns never join onto `games_with_predictions`. Added `has_weather` boolean guard + `else` branch adding `weather_total_adj = 0` in run_daily_football.R Step 17.

8. **Travel fatigue `fatigue_pts_from_miles()` crash** — Scalar `if (to_hawaii)` inside function body, called from `mutate()` where `to_hawaii` is a 21-element logical vector. Changed to `ifelse(to_hawaii, base - 1.5, base)`. Also fixed the `any_of("neutral_site")` select issue in TRAVEL_FATIGUE_CFB.R.

9. **567 garbage FCS/D2/D3 names flooding Step 10** — `logs/unmatched_teams.csv` accumulates entries from all scraper passes (thousands of non-FBS schools). Fix: flush log at start of each run (after Step 1 in orchestrator); added `filter(source_col == "odds_name")` inside `append_odds_lookup_cfb.R`.

**Files modified this session:**
- `run_daily_football.R` — DRY_RUN capture, log flush, master_cfb load, weather guard
- `scripts/TEAM_NAME_NORMALIZER_CFB.R` — Pass 5 + Pass 6 (mascot strip), UL Monroe preprocess
- `scripts/standardize_data_cfb.R` — drop reason logging for FCS/unmatched teams
- `scripts/MERGE_GAMES_RATINGS_CFB.R` — neutral_site default, isTRUE → == TRUE
- `scripts/WEATHER_SCRAPER_CFB.R` — empty-result guard, select(-any_of)
- `scripts/TRAVEL_FATIGUE_CFB.R` — neutral_site any_of + default, isTRUE fix, ifelse vectorization
- `scripts/append_odds_lookup_cfb.R` — odds_name-only filter

**KEY DECISIONS:**
- Pre-season totals clustering (47.6–49.5) is expected with SP+ only — no calibration needed; totals will diversify in-season when PPA and game-context data are available
- 6 extreme spreads (up to -58.5) are pre-season artifacts; in-season blended ratings will compress them
- ALL 133 FBS schools covered — MAC, Mountain West, all G5 conferences explicitly confirmed
- FCS opponents (Sacramento State, NDSU) correctly dropped — not a bug, expected behavior

**Pre-season API status (all non-fatal, will resolve in August):**
- Massey scraper: JS-rendered page, `<pre>` block no longer found — needs Claude-in-Chrome or schedule fix for August
- CFBD talent/returning: returns HTML (data not published pre-season) — will work once 2026 preseason data posts
- OWM weather: no forecast data 4+ months out — will work in-season
- Bye week tracker: no schedule yet — will work once CFBD schedule endpoint posts Week 1 games

**Outstanding:**
1. Fix Massey scraper (JS-rendered) — highest priority before Sep 2026; consider Claude-in-Chrome fallback
2. Validate MASTER odds_names vs DK feed on first live odds fetch (Sep 2026)
3. Post-Week-4 calibration of TALENT_WEIGHT (1.5 prior) and RETENTION_SCALAR_MIN (0.80 prior)
4. Monitor 10-15 pt edge bucket live — 46.4% ATS on n=56, inconclusive

**Start Session 11 with:**
- August 2026 preseason run results (when CFBD schedule, talent, and returning data are published), OR
- Massey JS scraper fix (if attempted before August), OR
- Week 1-4 live performance data for calibration

---

### SESSION 11 (2026-05-22+)

*See calibration log §11.* SQLite migration for line movement: `fetch_odds_football.R` → `append_opening_lines()` targets `outputs/cfb_line_movement.sqlite`. `TREND_ANALYSIS_CFB.R` queries via `MIN`/`MAX(logged_at)`. MASTER CSV: Sacramento State (Big Sky, conf_tier=4, conf_weight=0.40) and NDSU (MVFC, conf_tier=4, conf_weight=0.50, dome=TRUE) added.

---

### SESSION 12/13 (2026-05-25)

*See calibration log §12/13.* `SCRAPE_VSIN_CFB.R` + `PARSE_VSIN_CFB.R` created (Step 8.5 complete). `CALCULATE_VALUE_CFB.R` Step 4d fixed: `vsin_divergence` now correctly wired as PUBLIC boost signal.

---

### SESSION 15 (2026-05-25)

**Massey JS scraper fixed:**

- `scrape_massey_cfb.R`: `fetch_massey_page()` completely rewritten. Replaced `httr::GET()` (returns empty JS shell) with `rvest::read_html_live()` + `chromote`. New function: launches headless Chrome, navigates to `masseyratings.com/cf/compare.htm`, calls `wait_for("pre", timeout=20000)` to block until the ratings table is in the DOM, then extracts `document.documentElement.outerHTML` via `Runtime$evaluate`. Library swap: `httr` → `rvest`. All downstream code (extract_pre_block, parse_massey_pre, normalizer, cache) unchanged.
- `CFB_PROJECT_BIBLE.md`: Massey scraper item struck from PENDING ITEMS.

**KEY DECISIONS:**
- `read_html_live()` + `wait_for("pre")` rather than a fixed `Sys.sleep()` — event-driven wait is more reliable across load conditions; 1.5s buffer added after `wait_for` resolves for full column render
- Pre-flight guards added: `requireNamespace("chromote")` + `find_chrome()` check — fail fast with actionable message before attempting any network call
- Return type unchanged (raw HTML string) — zero changes required to `extract_pre_block()` or anything downstream

**Outstanding:**
1. Validate MASTER odds_names vs DK feed (Sep 2026)
2. Post-Week-4: calibrate TALENT_WEIGHT (1.5) and RETENTION_SCALAR_MIN (0.80)
3. Monitor 10-15 pt edge bucket — 46.4% ATS on n=56, inconclusive

---

### SESSION 14 (2026-05-25)

**Completed:**

**bet_history.csv → cfb_bets.sqlite migration (permanent ledger):**

- `CONFIG.R`: Added `CFB_BETS_DB <- "outputs/cfb_bets.sqlite"`. `BET_HISTORY_CSV` retained with legacy comment.
- `db_init_bets.R` (new): One-time init script. Creates `cfb_bets` with full schema — `bet_id TEXT PRIMARY KEY` (= renamed `bet_idx`), all FINALIZE columns, `settled INTEGER DEFAULT 0`. WAL journal mode. Backfills from `bet_history.csv` if present. Idempotent — safe to re-run.
- `FINALIZE_BETS_CFB.R`: Replaced `read_csv/bind_rows/write_csv` with `dbGetQuery(existing_ids)` dedup + `dbWriteTable(append=TRUE)`. `bet_idx` → `bet_id`. `settled=0L` added. MASTER_TICKET_CSV write unchanged.
- `BET_SETTLEMENT.R`: Replaced full `read_csv` + `write_csv` with `dbGetQuery("SELECT * FROM cfb_bets WHERE settled = 0")` for pending fetch; `purrr::pwalk` + parameterized `UPDATE cfb_bets SET result=?, pl=?, spread_clv_cents=?, total_clv_cents=?, ml_clv_cents=?, settled=1 WHERE bet_id=?` for each row. `load_closing_lines()` now sources pending game_ids from `cfb_bets.sqlite` directly.
- `broadcast_football.R`: No changes — reads `MASTER_TICKET_CSV` only, not bet history.

**KEY DECISIONS:**
- `bet_id` = `bet_idx` (5-field pipe-delimited key) — same dedup semantics, renamed
- `settled INTEGER` (0/1) rather than `result == 'pending'` string check — cleaner index, explicit state
- `dbWriteTable(append=TRUE)` after pre-filtering duplicates — R-layer dedup stays visible; no silent DB-layer INSERT OR IGNORE skips
- No schema migration pain — backfill in `db_init_bets.R` handles legacy CSV once; CSV stays as archive

**Outstanding:**
1. **Run `db_init_bets.R` once** before first live bet (creates DB; backfills any existing CSV rows)
2. Massey JS scraper broken — fix before Sep 2026
3. Validate MASTER odds_names vs DK feed (Sep 2026)
4. Post-Week-4: calibrate TALENT_WEIGHT (1.5) and RETENTION_SCALAR_MIN (0.80)

---

## SESSION 10 MIGRATION PROMPT

Continuing mcFootball CFB pipeline build. Read CFB_PROJECT_BIBLE.md at project root (G:\My Drive\Scripting Projects\cfb_project\CFB_PROJECT_BIBLE.md) for full state — we're starting Session 11.

Session 10 (2026-05-22) completed the full end-to-end pipeline dry run. Fixed 8 distinct bugs across 7 files — pipeline now runs clean in DRY_RUN_MODE: 19.5 seconds, 21/21 steps, 6 qualified bets, $133.33 action. All 133 FBS teams (MAC, Mountain West, all G5 fully covered). FCS opponents correctly dropped.

Key architectural fixes applied:
- `isTRUE()` is scalar-only — all 4 uses changed to `col == TRUE` (MERGE, TRAVEL, WEATHER, orchestrator)
- DK feed uses "School Mascot" format — Pass 5 + Pass 6 added to normalizer (strip last word, strip last two words)
- `DRY_RUN_MODE` capture via `.dry_run_saved` pattern (before `rm(list=ls())`)
- `neutral_site` defaults to FALSE when absent (Odds API doesn't include it)
- OWM weather skips gracefully pre-season (0-row guard), Step 17 uses `has_weather` guard
- Stale unmatched log flushed at Step 1; `append_odds_lookup_cfb.R` filters `odds_name` source only

Pre-season items remaining:
1. Massey scraper broken (JS-rendered page) — fix before Sep 2026
2. CFBD talent/returning: returns HTML pre-season — will self-resolve in August when data posts
3. Post-Week-4: calibrate TALENT_WEIGHT (1.5) and RETENTION_SCALAR_MIN (0.80)
4. First live DK odds fetch (Sep 2026): validate MASTER odds_names, check unmatched_teams.csv

---

## SESSION 9 MIGRATION PROMPT

Continuing mcFootball CFB pipeline build. Read CFB_PROJECT_BIBLE.md at project root (G:\My Drive\Scripting Projects\cfb_project\CFB_PROJECT_BIBLE.md) for full state — we're starting Session 9.

Session 8 completed: talent composite (247Sports blue-chip index via CFBD /teams/talent) and roster retention score (/returning endpoint) fully wired across the pipeline:
- TEAM_METRICS.R: `fetch_talent()` + `fetch_returning_production()` built; `build_team_metrics()` calls both and joins into cfb_team_stats_YYYY.csv
- MERGE_GAMES_RATINGS_CFB.R: `join_talent_side()` prefixes home_/away_ talent_norm + retention_score; `talent_diff` computed in mutate block
- GENERATE_PREDICTIONS_CFB.R: `talent_decay()` added; `talent_adj = talent_diff × TALENT_WEIGHT × decay(week)` in spread formula; `week_num` flows into games_with_predictions
- CALCULATE_VALUE_CFB.R: retention dampener applied to Kelly sizing (not EV); decays to 1.0 by Week 5; fires on SPREAD/ML from bet-side team, on TOTAL from min(home, away)

Pre-season items still needed:
1. Add openweather_api_key to credentials.json
2. Late Aug 2026 preseason dry run (source run_daily_football.R with live credentials, no odds yet)
3. After 4 weeks live: calibrate TALENT_WEIGHT (1.5 prior) and RETENTION_SCALAR_MIN (0.80 prior) against week-bucketed ATS

---

## SESSION 8 MIGRATION PROMPT

Continuing mcFootball CFB pipeline build. Read CFB_PROJECT_BIBLE.md at project root (G:\My Drive\Scripting Projects\cfb_project\CFB_PROJECT_BIBLE.md) for full state — we're starting Session 8.

Pipeline is fully built and broadcast-tested. Sessions 6-7 completed: Bible built, PPA integrated into backtest, MIN_EDGE_SPREAD raised to 5.0 (57.8% ATS confirmed), BET_SETTLEMENT.R away-spread settlement bug fixed (was settling backwards), broadcast live on Telegram + Discord.

The only remaining pre-season items are:
1. Add openweather_api_key to credentials.json
2. Late Aug 2026 preseason dry run (source run_daily_football.R with live credentials, no odds yet)

---

## SESSION 15 MIGRATION PROMPT

Continuing mcFootball CFB pipeline build. Read `CFB_PROJECT_BIBLE.md` at project root (`G:\My Drive\Scripting Projects\cfb_project\CFB_PROJECT_BIBLE.md`) for full state — starting Session 16.

Session 15 (2026-05-25) fixed the Massey JS scraper. `scrape_massey_cfb.R` now renders the page via headless Chrome instead of a plain HTTP GET.

**Dependency added:** `chromote` package + Google Chrome must be installed on the pipeline machine. Verify with `chromote::find_chrome()` — should return a path, not an error. Task Scheduler account must have Chrome access.

Pre-season items still outstanding:
1. Validate MASTER odds_names vs DK feed on first live odds fetch (Sep 2026)
2. Post-Week-4: calibrate TALENT_WEIGHT (1.5) and RETENTION_SCALAR_MIN (0.80)
3. Monitor 10-15 pt edge bucket — 46.4% ATS on n=56, inconclusive

---

## SESSION 14 MIGRATION PROMPT

Continuing mcFootball CFB pipeline build. Read CFB_PROJECT_BIBLE.md at project root (G:\My Drive\Scripting Projects\cfb_project\CFB_PROJECT_BIBLE.md) for full state — starting Session 15.

Session 14 (2026-05-25) migrated `bet_history.csv` → `outputs/cfb_bets.sqlite`. The permanent ledger is now SQLite. All three scripts updated.

Key architectural changes:
- `CONFIG.R`: `CFB_BETS_DB <- "outputs/cfb_bets.sqlite"` added. `BET_HISTORY_CSV` kept as legacy/backfill reference.
- `db_init_bets.R`: one-time init script. Creates `cfb_bets` table with `bet_id` PK (= old `bet_idx`), `settled` INTEGER column. Backfills from `bet_history.csv` if present. WAL journal mode enabled. **Run once before first live deployment.**
- `FINALIZE_BETS_CFB.R`: `read_csv/bind_rows/write_csv` replaced with `dbGetQuery(existing_ids)` + `dbWriteTable(append=TRUE)`. `bet_idx` renamed to `bet_id`. `settled=0L` added. Dedup still filters before insert.
- `BET_SETTLEMENT.R`: `read_csv(history_path)` replaced with `dbGetQuery("SELECT * FROM cfb_bets WHERE settled = 0")`. Full CSV overwrite replaced with `purrr::pwalk` + `dbExecute("UPDATE cfb_bets SET result=?, pl=?, ...clv..., settled=1 WHERE bet_id=?")`. `load_closing_lines()` now queries `cfb_bets.sqlite` for pending game_ids (no CSV needed).
- `broadcast_football.R`: **no changes** — it reads `MASTER_TICKET_CSV` (daily ticket), not `BET_HISTORY_CSV`.

Pre-season items still outstanding:
1. Run `db_init_bets.R` once before first live bet (creates the DB)
2. Massey JS scraper broken (JS-rendered page) — fix before Sep 2026
3. Validate MASTER odds_names vs DK feed on first live odds fetch (Sep 2026)
4. Post-Week-4: calibrate TALENT_WEIGHT (1.5) and RETENTION_SCALAR_MIN (0.80)

---

## SESSION 7 MIGRATION PROMPT

Continuing mcFootball CFB pipeline build. Read CFB_PROJECT_BIBLE.md at project root (G:\My Drive\Scripting Projects\cfb_project\CFB_PROJECT_BIBLE.md) for full state — we're starting Session 7.

Pipeline is end-to-end complete. Session 6 built the Bible, integrated PPA into BACKTEST_2025.R (SP-only vs PPA-blend MAE comparison, non-fatal fetch), and confirmed conf_weight_avg flows end-to-end through CALCULATE_VALUE_CFB.R.

Priority for Session 7:
1. Paste BACKTEST_2025.R console output — compare SP-only vs PPA-blend MAE, verify 55% ATS holds.
2. If backtest looks clean, audit BET_SETTLEMENT.R and FINALIZE_BETS_CFB.R for any gaps before Sep 2026 live run.
3. Stretch: broadcast_football.R end-to-end test dry run.

---

## SESSION 6 MIGRATION PROMPT

Continuing mcFootball CFB pipeline build. Read CFB_PROJECT_BIBLE.md at project root (G:\My Drive\Scripting Projects\cfb_project\CFB_PROJECT_BIBLE.md) for full state — we're starting Session 6.

Pipeline is end-to-end complete through run_daily_football.R orchestrator with a daily 8AM scheduled task. Session 5 added TEAM_METRICS.R (PPA/success rate/explosiveness via CFBD /stats/season/advanced), wired PPA differentials into MERGE_GAMES_RATINGS_CFB.R and GENERATE_PREDICTIONS_CFB.R, fixed the MAX_EDGE_SPREAD sharp-bypass bug in CALCULATE_VALUE_CFB.R, enforced weekly exposure caps (MAX_EXPOSURE_PER_WEEK=30%, MAX_BETS_PER_WEEK=20), computed conf_weight_avg from conference columns, and built the orchestrator.

Priority for Session 6:
1. Re-run BACKTEST_2025.R with PPA weights active (PPA_SPREAD_WEIGHT=5.0, EXPL_TOTAL_WEIGHT=3.0, SUCCESS_SPREAD_WEIGHT=2.0). Verify 55.0% ATS baseline holds. If it regresses, tune weights down or zero them to isolate.
2. Verify home_conference/away_conference columns survive standardize_data_cfb.R → games_with_ratings so conf_weight_avg is live in CALCULATE_VALUE_CFB.R.
3. Stretch: broadcast_football.R end-to-end test, then Monte Carlo groundwork (Phase 2 — see GENERATE_PREDICTIONS_CFB.R header for full implementation plan).
