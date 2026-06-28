# ==============================================================================
# CONFIG.R — mcFootball Pipeline Constants
# Project: cfb_project
# Philosophy: Edge + Positive EV + CLV | Spread / Total / ML markets
# No player props (Colorado restriction)
# ==============================================================================

# ------------------------------------------------------------------------------
# BANKROLL & KELLY
# ------------------------------------------------------------------------------
BANKROLL_FILE      <- "outputs/bankroll.txt"
KELLY_FRACTION     <- 0.5          # Fractional Kelly multiplier
MIN_BET            <- 5.00         # Minimum bet amount in dollars
MAX_BETS_PER_WEEK  <- 20           # Hard cap on total bets per run

# ------------------------------------------------------------------------------
# EDGE THRESHOLDS — minimum edge to qualify for a bet
# ------------------------------------------------------------------------------
MIN_EDGE_SPREAD    <- 5.0          # Points: projected vs. posted spread
                                   # Raised 3.0 → 5.0 after 2025 backtest:
                                   # 3-5 pt bucket: 110 bets at 45.5% ATS (below break-even, -EV).
                                   # 5+ pt floor: 275 bets at 58.2% ATS.  Validated 2026-05-17.
MIN_EDGE_TOTAL     <- 2.5          # Points: projected vs. posted total
MIN_EDGE_ML        <- 0.04         # Probability: win_prob vs. implied odds (4%)

# ------------------------------------------------------------------------------
# SHARP OVERRIDE FLOORS — lower threshold when sharp money confirms direction
# Sharp boost fires when line moves >= SHARP_MOVE_SPREAD or SHARP_MOVE_TOTAL
# ------------------------------------------------------------------------------
SHARP_EDGE_SPREAD  <- 3.25         # 65% of MIN_EDGE_SPREAD (5.0 × 0.65)
SHARP_EDGE_ML      <- 0.024        # 60% of MIN_EDGE_ML

SHARP_MOVE_SPREAD  <- 2.5          # Points: spread must move this much for sharp flag
SHARP_MOVE_TOTAL   <- 0.5          # Points: total must move this much for sharp flag

# ------------------------------------------------------------------------------
# ML FILTER
# ------------------------------------------------------------------------------
ML_SPREAD_THRESHOLD <- 7           # Only evaluate ML when |posted_spread| <= this
                                   # Lowered 10 → 7 (2026-05-17):
                                   # At a 10-pt spread the ML juice is ~-380 to -420.
                                   # Break-even win% at -400 is ~80% — market is near-
                                   # efficient at that price; edge rarely clears the vig.
                                   # 7-pt spread (~-230 to -260) is the practical ceiling
                                   # for findable +EV on the moneyline in CFB.

# ------------------------------------------------------------------------------
# EXPOSURE CAPS
# ------------------------------------------------------------------------------
MAX_SINGLE_GAME_EXPOSURE <- 0.08   # 8%  — combined spread+ML on same game
MAX_EXPOSURE_PER_WEEK    <- 0.30   # 30% — total bankroll at risk per week

# ------------------------------------------------------------------------------
# BOOST MULTIPLIERS (applied to EV, compound when multiple fire)
# Max combined: 1.15 * 1.08 * 1.08 * 1.20 = 1.606x
# ------------------------------------------------------------------------------
BOOST_SHARP        <- 1.15         # Sharp line movement confirms model pick
BOOST_TREND        <- 1.08         # Trend signal agrees with model pick
BOOST_BYE_WEEK     <- 1.08         # Team off bye, model agrees on direction
BOOST_PUBLIC_PCT   <- 1.20         # VSiN public % divergence >= 15%
PUBLIC_PCT_MIN_DIV <- 0.15         # Minimum divergence threshold to fire BOOST_PUBLIC_PCT
RIVALRY_SOFTEN_PTS <- 1.5          # Reduce effective spread edge for rivalry games

# ------------------------------------------------------------------------------
# RATINGS BLEND WEIGHTS (SP+ / Sagarin / Massey / ELO)
# Sum must equal 1.0. ELO added from CFBD /ratings/elo (week-by-week).
# ELO is especially valuable early season before SP+ stabilizes.
# Adjust weights after validation against 2025 CFB season MAE.
# ------------------------------------------------------------------------------
WEIGHT_SP_PLUS     <- 0.41
WEIGHT_SAGARIN     <- 0.25
WEIGHT_MASSEY      <- 0.17
WEIGHT_ELO         <- 0.09   # CFBD /ratings/elo — Elo rating per team, latest week
WEIGHT_RECRUITING  <- 0.08   # 247Sports 3-yr composite — talent proxy; decays to 0 after Week 4

# ------------------------------------------------------------------------------
# SPREAD FORMULA CALIBRATION
# SP+ rating differences don't map 1:1 to point spreads at the tails.
# SP_SCALAR dampens extreme projections — validated at 0.65 against 2025 backtest.
# Formula: proj_spread = -(rating_diff * SP_SCALAR + effective_hfa)
# Tuning guide:
#   0.50 → conservative (fewer large-edge bets)
#   0.65 → balanced     (validated against 2025 preseason SP+)
#   0.80 → aggressive   (larger projected spreads, more 15+ pt edges)
# Revisit after Sagarin/Massey blend is live — blended ratings are tighter.
# ------------------------------------------------------------------------------
SP_SCALAR          <- 1.00   # reverted — scaling degraded ATS (7-10 bucket collapsed)
                              # Raw SP+ diffs ARE the right scale; edge cap handles outliers.
MAX_EDGE_SPREAD    <- 12.0   # Maximum spread model_edge to qualify for a bet.
                              # Bets with |edge| > 12 pts are model-confidence outliers —
                              # 2025 backtest: 126 bets at 43.7% ATS (negative EV).
                              # Capping at 12 pts: 479 bets at ~56.4% ATS (model validated).

# ------------------------------------------------------------------------------
# PPA BLEND WEIGHTS (TEAM_METRICS.R — Step 6)
# Controls how much advanced efficiency metrics shift spread/total projections.
#
# PPA_SPREAD_WEIGHT: ppa_diff (per-play EPA) → spread pts
#   ppa_diff of 0.1 EPA/play × 5.0 = 0.5 pt spread shift (conservative)
#   Tune up to 8.0 if PPA proves more predictive than SP+ in live validation.
#
# EXPL_TOTAL_WEIGHT: explosiveness_diff → total pts
#   Used when PPA data available; replaces SP+ off/def sub-rating contribution.
#   0.0 = disabled (use SP+ only); 3.0 = modest PPA influence on totals.
#
# SUCCESS_SPREAD_WEIGHT: success_rate_diff → spread pts
#   Captures drive consistency signal independent of PPA magnitude.
# ------------------------------------------------------------------------------
# ------------------------------------------------------------------------------
# TALENT COMPOSITE BLEND (CFBD /teams/talent — 247Sports blue-chip composite)
# Controls how much raw roster talent shifts the spread in weeks 1-4 before
# in-season SP+ has stabilized. Zeroes out by Week 5.
#
# Normalization: raw talent score is centered at TALENT_NORM_BASE (≈ FBS median)
# and divided by 100. Alabama (~1100) → +2.0; G5 avg (~800) → -1.0.
# talent_adj = talent_diff × TALENT_WEIGHT × talent_decay(week)
#
# TALENT_WEIGHT = 1.5 → a normalized diff of 1.0 (≈ 100 composite points)
#   shifts the projected spread by 1.5 pts in week 1.
#   Tune up to 2.5 if early-season MAE improves; down to 0.5 if it doesn't.
# ------------------------------------------------------------------------------
TALENT_WEIGHT         <- 1.5   # pts per normalized talent diff unit (tune 0.5–2.5)
TALENT_NORM_BASE      <- 900   # center of normalization (≈ FBS median composite)

# ------------------------------------------------------------------------------
# ROSTER RETENTION — Kelly confidence dampener for weeks 1-4
# Uses CFBD /returning endpoint (percentPPA = returning production %).
# Applied to bet sizing only (not EV) — represents uncertainty in team rating,
# not a market edge signal.
#
# Retention tiers (based on percentPPA):
#   ≥ RETENTION_HIGH_PCT → retention_score = 1.00  (full confidence)
#   RETENTION_LOW_PCT to RETENTION_HIGH_PCT → linear interpolation 0.90 → 1.00
#   < RETENTION_LOW_PCT  → retention_score = RETENTION_SCALAR_MIN
#
# Dampener decays linearly to 1.0 by Week 5 regardless of score.
# ------------------------------------------------------------------------------
RETENTION_HIGH_PCT    <- 0.65  # ≥ 65% returning production → full confidence
RETENTION_LOW_PCT     <- 0.50  # < 50% → minimum confidence scalar
RETENTION_SCALAR_MIN  <- 0.80  # floor Kelly multiplier for low-retention teams

PPA_SPREAD_WEIGHT     <- 5.0   # per-play EPA diff → pts (tune 3.0–10.0)
EXPL_TOTAL_WEIGHT     <- 3.0   # explosiveness diff → pts (tune 0.0–6.0)
SUCCESS_SPREAD_WEIGHT <- 2.0   # success rate diff → pts (tune 0.0–4.0)

# ------------------------------------------------------------------------------
# TEMPO MODEL (plays_per_game signal — Step 4 team stats from CFBD)
# Controls how game pace (total plays) shifts projected totals.
# Formula: (avg_plays_dev_home + avg_plays_dev_away) * TEMPO_TOTAL_WEIGHT
#
# LEAGUE_AVG_PACE = 70 plays/game (FBS average; teams running 75+ are fast, <65 slow)
# TEMPO_TOTAL_WEIGHT = 0.15 pts per 1-play deviation from league avg
#   e.g., two fast teams (+5 plays each) → (5 + 5) * 0.15 = +1.5 pts on total
#   Tune up to 0.25 if tempo proves predictive in live validation.
#
# Falls back to possessionTime (old signal) when plays_per_game is unavailable.
# ------------------------------------------------------------------------------
LEAGUE_AVG_PACE       <- 70.0  # avg plays/game; calibrate from CFBD historical data
TEMPO_TOTAL_WEIGHT    <- 0.15  # pts per 1-play deviation from avg (tune 0.10–0.25)

# ------------------------------------------------------------------------------
# THIRD-DOWN CONVERSION RATE ADJUSTMENTS
# Source: CFBD /stats/season (thirdDownConversions / thirdDowns → third_down_rate)
# Applied in GENERATE_PREDICTIONS_CFB.R alongside PPA and tempo signals.
# These are additive; tune down toward 0 if they degrade MAE vs 2025 backtest.
#
# LEAGUE_AVG_3D_RATE: historical FBS average ~41%
# THIRD_DOWN_SPREAD_WEIGHT: pts per 0.01 rate differential (home - away)
#   e.g., home 50% vs away 41%: 0.09 × 3.0 = 0.27 pt shift toward home
# THIRD_DOWN_TOTAL_WEIGHT: pts per combined 0.01 deviation from avg (both teams)
#   e.g., home +5% and away +5% above avg: (0.05 + 0.05) × 4.0 = 0.40 pts added
# ------------------------------------------------------------------------------
LEAGUE_AVG_3D_RATE       <- 0.41  # FBS average; update from CFBD after each season
THIRD_DOWN_SPREAD_WEIGHT <- 3.0   # pts per unit 3rd-down rate diff (tune 2.0–5.0)
THIRD_DOWN_TOTAL_WEIGHT  <- 4.0   # pts per combined deviation from avg (tune 2.0–6.0)

# ------------------------------------------------------------------------------
# SCHEME MATCHUP — Offensive run/pass tendency vs. defensive play-type efficiency
# Source: CFBD /ppa/teams (off_rush_ppa, off_pass_ppa, def_rush_ppa, def_pass_ppa)
#         CFBD /stats/season (rushingAttempts, passAttempts → rush_rate)
#
# Formula (home-team spread perspective):
#   home_edge = rush_rate_home × (away_def_rush_ppa - LG_RUSH)
#             + (1 - rush_rate_home) × (away_def_pass_ppa - LG_PASS)
#   away_edge = rush_rate_away × (home_def_rush_ppa - LG_RUSH)
#             + (1 - rush_rate_away) × (home_def_pass_ppa - LG_PASS)
#   scheme_adj = (home_edge - away_edge) × SCHEME_SPREAD_WEIGHT
#
# EPA/play is zero-centered across FBS; positive def_ppa = weak defense.
# LG averages seeded at 0 — refine from CFBD season totals post-season.
# SCHEME_SPREAD_WEIGHT: 0.1 EPA/play edge × 4.0 = 0.4 pt shift (conservative prior)
# Tune toward 6.0–8.0 if scheme proves predictive in live 2026 validation.
# ------------------------------------------------------------------------------
SCHEME_SPREAD_WEIGHT  <- 4.0   # pts per net EPA/play scheme edge (tune 2.0–8.0)
LG_AVG_DEF_RUSH_PPA   <- 0.0   # FBS avg EPA/play allowed on rushes (≈ 0; refine post-season)
LG_AVG_DEF_PASS_PPA   <- 0.0   # FBS avg EPA/play allowed on passes (≈ 0; refine post-season)
LG_AVG_RUSH_RATE      <- 0.42  # FBS avg rush-play fraction (tune from /stats/season data)

# ------------------------------------------------------------------------------
# BBOC PODCAST INTELLIGENCE (BBOC_PODCAST_PARSER.R — Step 8.75)
# Source: Action Network "Big Bets on Campus" podcast (Stuckey + Collin Wilson)
# Omny Studio RSS — includes full episode transcripts via <podcast:transcript>
#
# BBOC_CONFIRM_BOOST: applied to EV when bboc_agrees = TRUE for a game.
#   Set between BOOST_TREND (1.08) and BOOST_SHARP (1.15) — BBOC analysts are
#   sharp public handicappers; meaningful signal but not market-moving steam.
#   Compounds with other boosts (max combined stays within portfolio limits).
#
# BBOC_LOOKBACK_DAYS: how many days back to scan for episodes.
#   7 = one week covers Thu/Fri/Sat slate thoroughly (BBOC drops episodes
#   Mon–Wed for the upcoming weekend).
#
# BBOC_MAX_EPISODES: cap to avoid over-fetching transcripts per run.
# ------------------------------------------------------------------------------
BBOC_RSS_URL        <- "https://www.omnycontent.com/d/playlist/e73c998e-6e60-432f-8610-ae210140c5b1/61403825-97cd-4547-b4f2-b3ec011d3f83/b96a4573-5dc1-4181-add2-b3ec011d3f8a/podcast.rss"
BBOC_CONFIRM_BOOST  <- 1.12        # EV multiplier when BBOC pick confirms model (tune 1.08–1.15)
BBOC_LOOKBACK_DAYS  <- 7L          # days back to scan for new episodes
BBOC_MAX_EPISODES   <- 5L          # max episodes to parse per run

# ------------------------------------------------------------------------------
# DATA PATHS
# ------------------------------------------------------------------------------
MASTER_CSV         <- "team_name_mappings_MASTER_CFB.csv"
BET_HISTORY_CSV    <- "outputs/bet_history.csv"   # ARCHIVE ONLY — not written post-Session 14
                                                   # used only by db_init_bets.R backfill (one-time)
CFB_BETS_DB        <- "outputs/cfb_bets.sqlite"   # primary ledger (Session 14+)
MASTER_TICKET_CSV  <- "outputs/master_ticket.csv"
# LINE_MOVEMENT_CSV removed — line movement is cfb_line_movement.sqlite (Session 11+)

# ------------------------------------------------------------------------------
# API / CREDENTIALS
# Keys stored in credentials.json at project root (gitignored)
# Required keys: odds_api_key, cfbd_api_key, openweather_api_key
# Optional:      telegram_bot_token, telegram_chat_id, discord_webhook_url
# ------------------------------------------------------------------------------
CREDS_FILE         <- "credentials.json"

load_credentials <- function() {
  if (!file.exists(CREDS_FILE)) {
    stop(sprintf("credentials.json not found at %s. Create it with odds_api_key and cfbd_api_key.", getwd()))
  }
  jsonlite::fromJSON(CREDS_FILE)
}

# ------------------------------------------------------------------------------
# HELPER: American odds → implied probability (with vig)
# ------------------------------------------------------------------------------
american_to_prob <- function(odds) {
  ifelse(odds < 0,
         abs(odds) / (abs(odds) + 100),
         100 / (odds + 100))
}

# ------------------------------------------------------------------------------
# HELPER: Fractional Kelly bet size
# f* = (bp - q) / b  where b = decimal_odds - 1, p = win_prob, q = 1 - p
# Returns dollar amount based on current BANKROLL
# ------------------------------------------------------------------------------
kelly_bet <- function(win_prob, decimal_odds, bankroll = BANKROLL,
                      fraction = KELLY_FRACTION) {
  b <- decimal_odds - 1
  q <- 1 - win_prob
  f_star <- (b * win_prob - q) / b
  f_star <- max(f_star, 0)              # no negative Kelly
  round(bankroll * fraction * f_star, 2)
}

# ------------------------------------------------------------------------------
# HELPER: American odds → decimal odds
# ------------------------------------------------------------------------------
american_to_decimal <- function(odds) {
  ifelse(odds < 0,
         (100 / abs(odds)) + 1,
         (odds / 100) + 1)
}

# ------------------------------------------------------------------------------
# HELPER: Spread → ML implied win probability (Poisson-based approximation)
# Sigmoid fit to historical CFB ATS covers: logistic(spread / 7.5)
# ------------------------------------------------------------------------------
spread_to_win_prob <- function(spread) {
  # spread is from home team's perspective (negative = home favored)
  1 / (1 + exp(spread / 7.5))
}

cat("[CONFIG] mcFootball config loaded.\n")
cat(sprintf("[CONFIG] BANKROLL_FILE: %s | KELLY: %.2f | MIN_BET: $%.2f\n",
            BANKROLL_FILE, KELLY_FRACTION, MIN_BET))
cat(sprintf("[CONFIG] Edge thresholds — Spread: %.1f pts | Total: %.1f pts | ML: %.1f%%\n",
            MIN_EDGE_SPREAD, MIN_EDGE_TOTAL, MIN_EDGE_ML * 100))
