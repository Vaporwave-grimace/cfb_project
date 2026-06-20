# ==============================================================================
# ml_model_cfb.R — CFB XGBoost Spread + Total Models
#
# Trains two XGBoost regression models:
#   cfb_spread_xgb.rds  — predicts actual_margin (home - away)
#   cfb_total_xgb.rds   — predicts actual_total  (home + away)
#
# Input:  clean/ml_training_data_2013_2025.csv (from build_ml_training_data.R)
# Output: models/cfb_spread_xgb.rds
#         models/cfb_total_xgb.rds
#         models/cfb_ml_meta.rds
#
# Training strategy:
#   Train  2013–2024 (~9,000 games); validate holdout 2025 (~750 games)
#   CV: group_vfold_cv by season (leave-one-season-out within training set)
#   Target for spread: actual_margin   (positive = home won; converted to spread in pipeline)
#   Target for total:  actual_total
#
# Usage:
#   source("scripts/ml_model_cfb.R")
#   train_cfb_ml()                   # trains + saves both models
#   predict_ml_spread(game_row)      # returns predicted home margin (scalar)
#   predict_ml_total(game_row)       # returns predicted total (scalar)
# ==============================================================================

suppressMessages({
  library(tidymodels)
  library(xgboost)
  library(vip)
  library(dplyr)
  library(readr)
  library(tibble)
})

# ── Paths ─────────────────────────────────────────────────────────────────────

ML_TRAINING_DATA <- "clean/ml_training_data_2013_2025.csv"
MODELS_DIR       <- "models"
SPREAD_MODEL_PATH <- file.path(MODELS_DIR, "cfb_spread_xgb.rds")
TOTAL_MODEL_PATH  <- file.path(MODELS_DIR, "cfb_total_xgb.rds")
META_PATH         <- file.path(MODELS_DIR, "cfb_ml_meta.rds")

TRAIN_SEASONS <- 2013:2024
TEST_SEASON   <- 2025

# ── Feature columns (available both in training CSV and at live prediction time)

SPREAD_PREDICTORS <- c(
  "posted_spread",       # market prior — most predictive single feature
  "rating_diff_blend",   # SP+ + ELO blend
  "sp_diff",             # raw SP+ differential (prior year)
  "elo_diff_scaled",     # ELO diff scaled to SP+ units
  "ppa_diff",            # net EPA/play advantage
  "success_rate_diff",   # drive consistency signal
  "expl_diff",           # big-play threat differential
  "rush_rate_diff",      # run/pass tendency mismatch
  "third_down_diff",     # 3rd-down conversion rate diff
  "scheme_adj",          # computed from PPA scheme splits
  "effective_hfa",       # home field advantage pts (0 when neutral)
  "neutral_site",        # 1/0
  "week",                # season week (1–15)
  "is_postseason",       # bowl game flag
  "conf_tier"            # 1 = P4 vs P4, 0 = mixed/G5
)

TOTAL_PREDICTORS <- c(
  "posted_total",        # market prior for totals
  "rating_diff_blend",   # stronger teams → higher scoring on average
  "ppa_diff",            # offensive efficiency signal
  "expl_diff",           # big-play threat → inflates totals
  "success_rate_diff",   # sustained drives → more points
  "third_down_diff",     # 3rd-down conversion = more possessions
  "rush_rate_diff",      # run-heavy teams → slightly lower totals
  "neutral_site",
  "week",
  "is_postseason",
  "conf_tier"
)

# ── XGBoost workflow builder (tidymodels) ──────────────────────────────────────

build_cfb_model <- function(train_df, test_df, predictors, target, label) {
  cat(sprintf("\n── %s model ──\n", label))
  cat(sprintf("   Train: %d games (%d–%d) | Test: %d games (%d)\n",
              nrow(train_df), min(train_df$season), max(train_df$season),
              nrow(test_df),  TEST_SEASON))

  # Build feature matrices
  prep_df <- function(df) {
    df %>%
      select(all_of(c(predictors, target, "season"))) %>%
      filter(!is.na(.data[[target]])) %>%
      rename(outcome = all_of(target)) %>%
      mutate(across(all_of(predictors), as.numeric))
  }

  train_prepped <- prep_df(train_df)
  test_prepped  <- prep_df(test_df)

  if (nrow(train_prepped) < 100) stop("Too few training rows for ", label)

  set.seed(2026)

  # Recipe: median imputation for NA features (PPA missing in early years)
  rec <- recipe(outcome ~ ., data = select(train_prepped, -season)) %>%
    step_impute_median(all_numeric_predictors()) %>%
    step_zv(all_predictors())

  spec <- boost_tree(
    trees          = tune(),
    tree_depth     = tune(),
    learn_rate     = tune(),
    loss_reduction = tune(),
    min_n          = tune()
  ) %>%
    set_engine("xgboost") %>%
    set_mode("regression")

  wf <- workflow() %>%
    add_recipe(rec) %>%
    add_model(spec)

  # Leave-one-season-out CV within training set
  season_folds <- group_vfold_cv(train_prepped,
                                  group = "season",
                                  v     = min(n_distinct(train_prepped$season), 10L))
  cat(sprintf("   CV: %d season folds\n", length(season_folds$splits)))

  grid <- grid_space_filling(
    trees(range          = c(200L, 1000L)),
    tree_depth(range     = c(3L,   7L)),
    learn_rate(range     = c(-3,  -1)),
    loss_reduction(),
    min_n(range          = c(5L,  40L)),
    size = 25L
  )

  cat("   Tuning (leave-one-season-out CV, 25 candidates)...\n")
  tune_res <- tune_grid(
    wf,
    resamples = season_folds,
    grid      = grid,
    metrics   = metric_set(rmse, mae),
    control   = control_grid(verbose = FALSE)
  )

  best  <- select_best(tune_res, metric = "rmse")
  cv_rmse <- round(show_best(tune_res, metric = "rmse")$mean[1], 3)
  cv_mae  <- round(show_best(tune_res, metric = "mae")$mean[1],  3)
  cat(sprintf("   Best CV RMSE: %.3f | MAE: %.3f\n", cv_rmse, cv_mae))

  # Refit on full training set with best params
  final_wf  <- finalize_workflow(wf, best)
  final_fit <- fit(final_wf, data = select(train_prepped, -season))

  # Evaluate on 2025 holdout
  test_preds <- predict(final_fit,
                         new_data = select(test_prepped, -season, -outcome)) %>%
    bind_cols(select(test_prepped, outcome))

  test_rmse <- sqrt(mean((test_preds$.pred - test_preds$outcome)^2, na.rm = TRUE))
  test_mae  <- mean(abs(test_preds$.pred - test_preds$outcome), na.rm = TRUE)
  test_bias <- mean(test_preds$.pred - test_preds$outcome, na.rm = TRUE)

  cat(sprintf("   2025 holdout — RMSE: %.2f | MAE: %.2f | Bias: %.2f\n",
              test_rmse, test_mae, test_bias))

  # Variable importance (top 10)
  cat("   Top features:\n")
  vi <- vip::vi(extract_fit_parsnip(final_fit))
  print(head(vi, 10), n = 10)

  list(
    fit       = final_fit,
    cv_rmse   = cv_rmse,
    cv_mae    = cv_mae,
    test_rmse = test_rmse,
    test_mae  = test_mae,
    test_bias = test_bias,
    test_preds = test_preds,
    vi        = vi
  )
}

# ── ATS accuracy on 2025 holdout ───────────────────────────────────────────────
# Compares ML ensemble spread vs formula-only on cover accuracy.

evaluate_ats <- function(spread_result, test_df,
                          formula_col  = "proj_spread",
                          ml_weight    = 0.60) {
  if (!formula_col %in% names(test_df)) {
    cat("   (ATS comparison skipped — formula spread not in test_df)\n")
    return(invisible(NULL))
  }

  preds <- spread_result$test_preds %>%
    bind_cols(test_df %>%
                filter(!is.na(actual_margin), !is.na(posted_spread)) %>%
                select(posted_spread, actual_margin))

  # ML: predicted margin → spread convention
  ml_spread    <- -preds$.pred

  # Formula (if available — 2025 backtest CSV has proj_spread)
  formula_spread <- if (formula_col %in% names(test_df)) test_df[[formula_col]] else ml_spread

  ensemble_spread <- ml_weight * ml_spread + (1 - ml_weight) * formula_spread

  covered <- function(proj_spread, posted_spread, actual_margin) {
    # Project covers if predicted_margin - posted_spread is on same side as actual
    mean((actual_margin - posted_spread) *
         (-proj_spread  - posted_spread) > 0, na.rm = TRUE)
  }

  cat(sprintf("   ATS comparison (2025, edge ≥ 5 pts):\n"))
  has_edge <- abs(ensemble_spread - preds$posted_spread) >= 5
  n_ens  <- sum(has_edge, na.rm = TRUE)
  if (n_ens > 0) {
    ats_ens <- mean(
      (preds$actual_margin[has_edge] - preds$posted_spread[has_edge]) *
      sign(-ensemble_spread[has_edge]  - preds$posted_spread[has_edge]) > 0,
      na.rm = TRUE)
    cat(sprintf("     Ensemble (%.0f%% ML + %.0f%% formula): %.1f%% ATS on %d bets\n",
                ml_weight * 100, (1 - ml_weight) * 100, ats_ens * 100, n_ens))
  }
}

# ── Main training function ─────────────────────────────────────────────────────

train_cfb_ml <- function(ml_weight = 0.60) {
  if (!file.exists(ML_TRAINING_DATA)) {
    stop("[ML] Training data not found. Run scripts/build_ml_training_data.R first.\n",
         "    Expected: ", ML_TRAINING_DATA)
  }

  cat(sprintf("\n========== CFB ML Training | Train %d–%d | Test %d ==========\n",
              min(TRAIN_SEASONS), max(TRAIN_SEASONS), TEST_SEASON))

  data <- read_csv(ML_TRAINING_DATA, show_col_types = FALSE)
  cat(sprintf("Loaded %d rows across seasons %d–%d\n",
              nrow(data), min(data$season), max(data$season)))

  train_df <- data %>% filter(season %in% TRAIN_SEASONS)
  test_df  <- data %>% filter(season == TEST_SEASON)

  cat(sprintf("Train: %d games | Test: %d games\n", nrow(train_df), nrow(test_df)))

  dir.create(MODELS_DIR, showWarnings = FALSE)

  # Spread model
  spread_res <- build_cfb_model(train_df, test_df,
                                 SPREAD_PREDICTORS, "actual_margin", "SPREAD")
  evaluate_ats(spread_res, test_df)
  saveRDS(spread_res$fit, SPREAD_MODEL_PATH)
  cat(sprintf("Saved → %s\n", SPREAD_MODEL_PATH))

  # Total model
  total_res  <- build_cfb_model(train_df, test_df,
                                 TOTAL_PREDICTORS,  "actual_total",  "TOTAL")
  saveRDS(total_res$fit, TOTAL_MODEL_PATH)
  cat(sprintf("Saved → %s\n", TOTAL_MODEL_PATH))

  # Metadata
  meta <- list(
    trained_at       = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
    train_seasons    = TRAIN_SEASONS,
    test_season      = TEST_SEASON,
    n_train          = nrow(train_df),
    n_test           = nrow(test_df),
    ensemble_weight  = ml_weight,
    spread_cv_rmse   = spread_res$cv_rmse,
    spread_cv_mae    = spread_res$cv_mae,
    spread_test_rmse = spread_res$test_rmse,
    spread_test_mae  = spread_res$test_mae,
    spread_test_bias = spread_res$test_bias,
    total_test_rmse  = total_res$test_rmse,
    total_test_mae   = total_res$test_mae
  )
  saveRDS(meta, META_PATH)

  cat(sprintf("\n── Summary ──\n"))
  cat(sprintf("  Spread — 2025 MAE: %.2f pts (formula baseline: 13.17)\n", spread_res$test_mae))
  cat(sprintf("  Total  — 2025 MAE: %.2f pts\n",  total_res$test_mae))
  cat(sprintf("  Saved: %s, %s\n", SPREAD_MODEL_PATH, TOTAL_MODEL_PATH))

  invisible(list(spread = spread_res, total = total_res, meta = meta))
}

# ── Live prediction helpers ────────────────────────────────────────────────────
# Called row-by-row from GENERATE_PREDICTIONS_CFB.R.
# Each function accepts a game_row list (same format as predict_game input).

.ml_feature_row <- function(game_row, predictors) {
  # Build a single-row tibble from the game_row named list / environment.
  # Returns NA for any feature not present in game_row.
  vals <- lapply(predictors, function(f) {
    v <- tryCatch(as.numeric(game_row[[f]]), error = function(e) NA_real_)
    if (length(v) == 0 || is.null(v)) NA_real_ else v[1]
  })
  names(vals) <- predictors
  as_tibble(vals)
}

predict_ml_spread <- function(game_row, model = NULL) {
  if (is.null(model)) {
    model <- tryCatch(readRDS(SPREAD_MODEL_PATH), error = function(e) NULL)
  }
  if (is.null(model)) return(NA_real_)
  tryCatch({
    feat <- .ml_feature_row(game_row, SPREAD_PREDICTORS)
    as.numeric(predict(model, new_data = feat)$.pred)
  }, error = function(e) NA_real_)
}

predict_ml_total <- function(game_row, model = NULL) {
  if (is.null(model)) {
    model <- tryCatch(readRDS(TOTAL_MODEL_PATH), error = function(e) NULL)
  }
  if (is.null(model)) return(NA_real_)
  tryCatch({
    feat <- .ml_feature_row(game_row, TOTAL_PREDICTORS)
    as.numeric(predict(model, new_data = feat)$.pred)
  }, error = function(e) NA_real_)
}

# ── Print saved metadata ───────────────────────────────────────────────────────

print_ml_meta <- function() {
  if (!file.exists(META_PATH)) { cat("No ML metadata found — run train_cfb_ml() first.\n"); return() }
  m <- readRDS(META_PATH)
  cat(sprintf("\n── CFB ML Model Metadata ──\n"))
  cat(sprintf("  Trained:          %s\n",  m$trained_at))
  cat(sprintf("  Train seasons:    %d–%d (%d games)\n",
              min(m$train_seasons), max(m$train_seasons), m$n_train))
  cat(sprintf("  Test season:      %d (%d games)\n", m$test_season, m$n_test))
  cat(sprintf("  Ensemble weight:  %.0f%% ML | %.0f%% formula\n",
              m$ensemble_weight * 100, (1 - m$ensemble_weight) * 100))
  cat(sprintf("  Spread CV  RMSE:  %.2f | MAE: %.2f\n", m$spread_cv_rmse, m$spread_cv_mae))
  cat(sprintf("  Spread 2025 RMSE: %.2f | MAE: %.2f | Bias: %.2f\n",
              m$spread_test_rmse, m$spread_test_mae, m$spread_test_bias))
  cat(sprintf("  Total  2025 RMSE: %.2f | MAE: %.2f\n", m$total_test_rmse, m$total_test_mae))
  invisible(m)
}

# ── CLI guard ─────────────────────────────────────────────────────────────────

.ml_is_main <- identical(commandArgs(trailingOnly = FALSE)[1], "--vanilla") ||
  any(grepl("ml_model_cfb\\.R$", commandArgs(trailingOnly = FALSE)))

if (.ml_is_main) {
  setwd("G:/My Drive/Scripting Projects/cfb_project")
  train_cfb_ml()
}
