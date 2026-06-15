# ==============================================================================
# MERGE_ALL_RATINGS_CFB.R — Blend SP+, Sagarin, Massey into one ratings table
# Pipeline Step 5 (non-fatal — wrapped in tryCatch by orchestrator)
#
# Inputs (from global env, written by Step 4 scrapers):
#   cfbd_sp_plus    — SP+ ratings per team  (canonical_name, sp_overall,
#                                             sp_offense, sp_defense)
#   sagarin_ratings — Sagarin per team      (canonical_name, sagarin_rating,
#                                             sagarin_predictor)
#   massey_ratings  — Massey per team       (canonical_name, massey_rating)
#
# Blend strategy:
#   1. Each source z-scored independently (mean=0, sd=1 across FBS teams)
#   2. Weighted sum: SP+ 0.50 + Sagarin 0.30 + Massey 0.20 (from CONFIG.R)
#      Weights renormalized when a source is missing for a given team
#   3. Rescaled to SP+ units (points above average) so projected spreads are
#      interpretable: blended_pts = z_blend * sd(sp_overall) + mean(sp_overall)
#
# Why z-score first:
#   SP+ ≈ ±30 pts above average | Sagarin ≈ 50–100 absolute | Massey similar
#   Raw blend would be dominated by whichever system has the largest variance.
#   Z-scoring puts all three on the same footing before weighting.
#
# Output:
#   clean/cfb_ratings_blended_YYYYMMDD.csv
#   Global: blended_ratings tibble
# ==============================================================================

suppressMessages(library(tidyverse))

# ------------------------------------------------------------------------------
# Helper: z-score a numeric vector, return NA for all-NA input
# ------------------------------------------------------------------------------
safe_zscore <- function(x) {
  if (all(is.na(x))) return(x)
  mu <- mean(x, na.rm = TRUE)
  sg <- sd(x,   na.rm = TRUE)
  if (is.na(sg) || sg == 0) return(rep(0, length(x)))
  (x - mu) / sg
}

# ------------------------------------------------------------------------------
# Helper: weighted blend of z-scores with per-row weight renormalization
#   z_mat   — numeric matrix, rows = teams, cols = sources
#   weights — named numeric vector matching ncol(z_mat)
# ------------------------------------------------------------------------------
weighted_blend <- function(z_mat, weights) {
  stopifnot(ncol(z_mat) == length(weights))
  apply(z_mat, 1, function(row) {
    avail <- !is.na(row)
    if (!any(avail)) return(NA_real_)
    w_avail <- weights[avail]
    w_avail <- w_avail / sum(w_avail)   # renormalize to sum=1
    sum(row[avail] * w_avail)
  })
}

# ------------------------------------------------------------------------------
# Load source data from global env OR from latest clean/ CSV
# ------------------------------------------------------------------------------
load_or_get <- function(env_name, file_pattern, date = Sys.Date()) {
  # Try global env first
  if (exists(env_name, envir = .GlobalEnv)) {
    df <- get(env_name, envir = .GlobalEnv)
    if (!is.null(df) && nrow(df) > 0) return(df)
  }
  # Fall back to most recent matching CSV
  candidates <- list.files("clean", pattern = file_pattern, full.names = TRUE)
  if (length(candidates) == 0) return(NULL)
  most_recent <- candidates[order(file.mtime(candidates), decreasing = TRUE)][1]
  cat(sprintf("[MERGE] Loading %s from %s\n", env_name, most_recent))
  read_csv(most_recent, show_col_types = FALSE)
}

# ------------------------------------------------------------------------------
# Main merge function
# ------------------------------------------------------------------------------
merge_all_ratings <- function(date = Sys.Date()) {

  # --- Load four sources ---
  sp_plus  <- load_or_get("cfbd_sp_plus",    "^cfb_ratings_\\d{4}\\.csv$",          date)
  sagarin  <- load_or_get("sagarin_ratings", "^sagarin_ratings_\\d{8}\\.csv$",       date)
  massey   <- load_or_get("massey_ratings",  "^massey_ratings_\\d{8}\\.csv$",        date)
  elo      <- load_or_get("cfbd_elo_ratings","^cfb_elo_ratings_\\d{4}\\.csv$",       date)

  # At least one source required
  if (is.null(sp_plus) && is.null(sagarin) && is.null(massey) && is.null(elo)) {
    stop("[MERGE] All rating sources are NULL — cannot build blended ratings.")
  }

  n_sp  <- if (!is.null(sp_plus))  nrow(sp_plus)  else 0
  n_sag <- if (!is.null(sagarin))  nrow(sagarin)   else 0
  n_mas <- if (!is.null(massey))   nrow(massey)    else 0
  n_elo <- if (!is.null(elo))      nrow(elo)       else 0
  cat(sprintf("[MERGE] Sources — SP+: %d | Sagarin: %d | Massey: %d | ELO: %d teams\n",
              n_sp, n_sag, n_mas, n_elo))

  # --- Build master team list from all available sources ---
  all_teams <- unique(c(
    if (!is.null(sp_plus))  sp_plus$canonical_name,
    if (!is.null(sagarin))  sagarin$canonical_name,
    if (!is.null(massey))   massey$canonical_name,
    if (!is.null(elo))      elo$canonical_name
  ))

  base <- tibble(canonical_name = all_teams)

  # --- Join each source ---
  if (!is.null(sp_plus)) {
    sp_join <- sp_plus %>%
      select(canonical_name,
             sp_overall  = any_of("sp_overall"),
             sp_offense  = any_of("sp_offense"),
             sp_defense  = any_of("sp_defense"),
             sp_st       = any_of("sp_st"))
    base <- left_join(base, sp_join, by = "canonical_name")
  } else {
    base <- base %>%
      mutate(sp_overall = NA_real_, sp_offense = NA_real_,
             sp_defense = NA_real_, sp_st      = NA_real_)
  }

  if (!is.null(sagarin)) {
    # Prefer sagarin_predictor for spread modeling; fall back to sagarin_rating
    sag_join <- sagarin %>%
      mutate(
        sag_value = coalesce(
          if ("sagarin_predictor" %in% names(.)) sagarin_predictor else NA_real_,
          sagarin_rating
        )
      ) %>%
      select(canonical_name, sagarin_rating,
             sagarin_predictor = any_of("sagarin_predictor"),
             sag_value)
    base <- left_join(base, sag_join, by = "canonical_name")
  } else {
    base <- base %>%
      mutate(sagarin_rating    = NA_real_,
             sagarin_predictor = NA_real_,
             sag_value         = NA_real_)
  }

  if (!is.null(massey)) {
    mas_join <- massey %>% select(canonical_name, massey_rating)
    base <- left_join(base, mas_join, by = "canonical_name")
  } else {
    base <- base %>% mutate(massey_rating = NA_real_)
  }

  if (!is.null(elo)) {
    elo_join <- elo %>% select(canonical_name, elo_rating)
    base <- left_join(base, elo_join, by = "canonical_name")
  } else {
    base <- base %>% mutate(elo_rating = NA_real_)
  }

  # --- Z-score each source ---
  base <- base %>%
    mutate(
      z_sp  = safe_zscore(sp_overall),
      z_sag = safe_zscore(sag_value),
      z_mas = safe_zscore(massey_rating),
      z_elo = safe_zscore(elo_rating)
    )

  # --- Weighted blend (weights renormalized per-row when a source is missing) ---
  z_matrix <- base %>% select(z_sp, z_sag, z_mas, z_elo) %>% as.matrix()
  weights  <- c(
    z_sp  = WEIGHT_SP_PLUS,
    z_sag = WEIGHT_SAGARIN,
    z_mas = WEIGHT_MASSEY,
    z_elo = if (exists("WEIGHT_ELO")) WEIGHT_ELO else 0.10
  )

  base <- base %>%
    mutate(
      z_blended   = weighted_blend(z_matrix, weights),
      n_sources   = rowSums(!is.na(z_matrix)),
      # Rescale to SP+ points-above-average units
      # If SP+ is available: use its mean/sd as the reference scale
      # Otherwise fall back to a ±20 point range (z * 12)
      blended_rating = if (!is.null(sp_plus) && sum(!is.na(base$sp_overall)) > 30) {
        sp_mu <- mean(sp_plus$sp_overall, na.rm = TRUE)
        sp_sd <- sd(sp_plus$sp_overall,   na.rm = TRUE)
        z_blended * sp_sd + sp_mu
      } else {
        z_blended * 12    # fallback scaling: ±2 sd ≈ ±24 pts
      }
    )

  # --- Quality flag: warn on teams with only 1 source ---
  single_source <- base %>% filter(n_sources == 1)
  if (nrow(single_source) > 0) {
    cat(sprintf("[MERGE] %d team(s) have only 1 rating source (blended rating less reliable):\n",
                nrow(single_source)))
    cat(paste(" ", single_source$canonical_name, collapse = "\n"), "\n")
  }

  # --- Final output columns ---
  output <- base %>%
    select(
      canonical_name,
      blended_rating,        # primary — used by GENERATE_PREDICTIONS
      n_sources,             # data quality indicator
      sp_overall,
      sp_offense,
      sp_defense,
      sp_st,
      sagarin_rating,
      sagarin_predictor,
      massey_rating,
      elo_rating,
      z_sp, z_sag, z_mas, z_elo, z_blended  # kept for diagnostics / recalibration
    ) %>%
    arrange(desc(blended_rating))

  out_path <- sprintf("clean/cfb_ratings_blended_%s.csv", format(date, "%Y%m%d"))
  write_csv(output, out_path)

  n_elo_blended <- sum(!is.na(output$elo_rating))
  cat(sprintf(
    "[MERGE] Blended ratings: %d teams (ELO available: %d) | top 5: %s\n",
    nrow(output), n_elo_blended,
    paste(head(output$canonical_name, 5), collapse = ", ")
  ))
  cat(sprintf("[MERGE] Rating range: %.1f to %.1f pts | saved → %s\n",
              min(output$blended_rating, na.rm = TRUE),
              max(output$blended_rating, na.rm = TRUE),
              out_path))

  assign("blended_ratings", output, envir = .GlobalEnv)
  invisible(output)
}

# Run when sourced by pipeline
merge_all_ratings()

cat("[MERGE] MERGE_ALL_RATINGS_CFB.R complete.\n")
