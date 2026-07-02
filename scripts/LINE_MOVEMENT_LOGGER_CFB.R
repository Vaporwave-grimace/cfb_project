# ==============================================================================
# LINE_MOVEMENT_LOGGER_CFB.R — Hourly DK Line Snapshot Logger
# Standalone script run hourly by scheduler (independent of pipeline).
#
# Fetches current DraftKings CFB lines and appends a timestamped snapshot to:
#   outputs/cfb_line_movement.sqlite
#
# Log schema:
#   logged_at | id | game_id | home_team | away_team | commence_time |
#   dk_spread_home | dk_total | dk_ml_home | dk_ml_away | ... (Big 5 Books)
#
# Consumed by:
#   TREND_ANALYSIS_CFB.R (Step 8) — diffs opening vs current for sharp signals
#   BET_SETTLEMENT.R     (Step 2) — last snapshot before commence_time = closing line
#
# Purges entries older than LOG_RETENTION_DAYS (21) to cap file growth.
# ==============================================================================

suppressMessages(library(tidyverse))
suppressMessages(library(httr))
suppressMessages(library(jsonlite))
suppressMessages(library(DBI))
suppressMessages(library(RSQLite))

setwd("G:/My Drive/Scripting Projects/cfb_project")

DB_PATH <- "C:/Users/Mike/sports_data/cfb_line_movement.sqlite"
LOG_RETENTION_DAYS <- 21
ODDS_SPORT_KEY     <- "americanfootball_ncaaf"

source("scripts/CONFIG.R")
source("scripts/TEAM_NAME_NORMALIZER_CFB.R")

# ------------------------------------------------------------------------------
# as_row_list() — normalize df or list to list-of-named-lists
# (mirrors helper in fetch_odds_football.R — kept inline for standalone use)
# ------------------------------------------------------------------------------
as_row_list <- function(x) {
  if (is.null(x) || length(x) == 0) return(list())
  if (!is.data.frame(x)) return(x)
  lapply(seq_len(nrow(x)), function(i)
    lapply(x, function(col) if (is.list(col)) col[[i]] else col[i]))
}

# ------------------------------------------------------------------------------
# extract_val() — pull a single point or price from nested bookmaker structure
# ------------------------------------------------------------------------------
extract_val <- function(bookmakers, book_key, market_key,
                        outcome_name, value_field) {
  tryCatch({
    bk_list <- as_row_list(bookmakers)
    bk      <- Filter(function(b) identical(b$key, book_key), bk_list)
    if (length(bk) == 0) return(NA_real_)
    bk <- bk[[1]]

    mkts <- as_row_list(bk$markets)
    mkt  <- Filter(function(m) identical(m$key, market_key), mkts)
    if (length(mkt) == 0) return(NA_real_)
    outcomes <- mkt[[1]]$outcomes

    if (is.data.frame(outcomes)) {
      row <- outcomes[outcomes$name == outcome_name, ]
      if (nrow(row) == 0) return(NA_real_)
      as.numeric(row[[value_field]][1])
    } else {
      out <- Filter(function(o) o$name == outcome_name, outcomes)
      if (length(out) == 0) return(NA_real_)
      as.numeric(out[[1]][[value_field]])
    }
  }, error = function(e) NA_real_)
}

# ------------------------------------------------------------------------------
# log_current_lines() — main entry point
# ------------------------------------------------------------------------------
log_current_lines <- function() {

  creds   <- tryCatch(load_credentials(), error = function(e) list())
  
  # Load all available keys
  all_keys <- creds$odds_api_key
  
  # Randomly sample 1 key to act as a load balancer!
  if (length(all_keys) > 0) {
    api_key <- tryCatch(as.character(sample(all_keys, 1)), error = function(e) NULL)
  } else {
    api_key <- NULL
  }

  # Check against length strictly and safely
  if (is.null(api_key) || is.na(api_key) || nchar(api_key) < 5) {
    warning("[LOGGER] odds_api_key missing or invalid — logger skipped.")
    return(invisible(NULL))
  }

  # Fetch current lines
  resp <- tryCatch(GET(
    sprintf("https://api.the-odds-api.com/v4/sports/%s/odds", ODDS_SPORT_KEY),
    query   = list(apiKey     = api_key,
                   regions    = "us",
                   markets    = "spreads,totals,h2h",
                   oddsFormat = "american",
                   dateFormat = "iso"),
    timeout(30)
  ), error = function(e) {
    warning(sprintf("[LOGGER] Fetch failed: %s", e$message))
    NULL
  })

  if (is.null(resp) || http_error(resp)) {
    warning("[LOGGER] Odds API error — logger skipped.")
    return(invisible(NULL))
  }

  raw <- fromJSON(content(resp, "text", encoding = "UTF-8"), flatten = FALSE)
  if (length(raw) == 0) {
    cat("[LOGGER] No active CFB games on slate — logger skipped.\n")
    return(invisible(NULL))
  }

  # Normalize to list-of-games
  games_list <- if (is.data.frame(raw)) {
    lapply(seq_len(nrow(raw)), function(i)
      lapply(raw, function(col) if (is.list(col)) col[[i]] else col[i]))
  } else {
    raw
  }

  # Parse each game into a flat row
  snapshot <- map_dfr(games_list, function(g) {
    tryCatch({
      home  <- g$home_team[[1]]
      away  <- g$away_team[[1]]
      books <- g$bookmakers
      tibble(
        id             = g$id[[1]],
        home_team      = home,
        away_team      = away,
        commence_time  = as.POSIXct(g$commence_time[[1]], format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
        
        # --- DRAFTKINGS ---
        dk_spread_home = extract_val(books, "draftkings", "spreads", home, "point"),
        dk_total       = extract_val(books, "draftkings", "totals", "Over", "point"),
        dk_ml_home     = extract_val(books, "draftkings", "h2h",    home,  "price"),
        dk_ml_away     = extract_val(books, "draftkings", "h2h",    away,  "price"),
        
        # --- FANDUEL ---
        fd_spread_home = extract_val(books, "fanduel", "spreads", home, "point"),
        fd_total       = extract_val(books, "fanduel", "totals", "Over", "point"),
        fd_ml_home     = extract_val(books, "fanduel", "h2h",    home,  "price"),
        fd_ml_away     = extract_val(books, "fanduel", "h2h",    away,  "price"),

        # --- BETMGM ---
        mgm_spread_home = extract_val(books, "betmgm", "spreads", home, "point"),
        mgm_total       = extract_val(books, "betmgm", "totals", "Over", "point"),
        mgm_ml_home     = extract_val(books, "betmgm", "h2h",    home,  "price"),
        mgm_ml_away     = extract_val(books, "betmgm", "h2h",    away,  "price"),

        # --- CAESARS ---
        czr_spread_home = extract_val(books, "caesars", "spreads", home, "point"),
        czr_total       = extract_val(books, "caesars", "totals", "Over", "point"),
        czr_ml_home     = extract_val(books, "caesars", "h2h",    home,  "price"),
        czr_ml_away     = extract_val(books, "caesars", "h2h",    away,  "price"),

        # --- PINNACLE (The Sharp Market) ---
        pin_spread_home = extract_val(books, "pinnacle", "spreads", home, "point"),
        pin_total       = extract_val(books, "pinnacle", "totals", "Over", "point"),
        pin_ml_home     = extract_val(books, "pinnacle", "h2h",    home,  "price"),
        pin_ml_away     = extract_val(books, "pinnacle", "h2h",    away,  "price")
      )
    }, error = function(e) NULL)
  })

  if (is.null(snapshot) || nrow(snapshot) == 0) {
    cat("[LOGGER] No parseable lines — logger skipped.\n")
    return(invisible(NULL))
  }

  # Normalize team names to derive canonical game_id
  if (!exists("master_cfb", envir = .GlobalEnv)) {
    master_cfb <- load_cfb_master("team_name_mappings_MASTER_CFB.csv")
    assign("master_cfb", master_cfb, envir = .GlobalEnv)
  }
  master <- get("master_cfb", envir = .GlobalEnv)

  snapshot <- snapshot %>%
    mutate(
      canonical_home = normalize_team_name(home_team, master, source_col = "odds_name"),
      canonical_away = normalize_team_name(away_team, master, source_col = "odds_name"),
      game_id = if_else(
        !is.na(canonical_away) & !is.na(canonical_home),
        paste(canonical_away, canonical_home,
              format(as.Date(commence_time), "%Y%m%d"), sep = "_"),
        NA_character_
      ),
      logged_at = Sys.time()
    ) %>%
    select(logged_at, id, game_id, home_team, away_team, commence_time,
           dk_spread_home, dk_total, dk_ml_home, dk_ml_away,
           fd_spread_home, fd_total, fd_ml_home, fd_ml_away,
           mgm_spread_home, mgm_total, mgm_ml_home, mgm_ml_away,
           czr_spread_home, czr_total, czr_ml_home, czr_ml_away,
           pin_spread_home, pin_total, pin_ml_home, pin_ml_away)

  # ==========================================
  # SQLITE DATABASE INJECTION & PRUNING
  # ==========================================
  # SQLite prefers timestamps as ISO8601 strings rather than complex POSIXct objects
  snapshot_db <- snapshot %>%
    mutate(
      logged_at = format(logged_at, "%Y-%m-%d %H:%M:%S"),
      commence_time = format(commence_time, "%Y-%m-%d %H:%M:%S")
    )

  # 1. Open connection (this automatically creates the .sqlite file if it doesn't exist)
  con <- dbConnect(RSQLite::SQLite(), DB_PATH)
  
  # 2. Append the new snapshot instantly
  dbWriteTable(con, name = "line_movement", value = snapshot_db, append = TRUE)
  
  # 3. Prune old entries using native SQL (Much faster than reading/filtering in R!)
  cutoff_str <- format(Sys.time() - as.difftime(LOG_RETENTION_DAYS, units = "days"), "%Y-%m-%d %H:%M:%S")
  prune_query <- sprintf("DELETE FROM line_movement WHERE logged_at < '%s'", cutoff_str)
  dbExecute(con, prune_query)
  
  # 4. Count total rows for your console output
  total_rows <- dbGetQuery(con, "SELECT COUNT(*) as n FROM line_movement")$n
  
  # 5. Safely close the connection
  dbDisconnect(con)
  # ==========================================

  n_with_id <- sum(!is.na(snapshot$game_id))
  cat(sprintf("[LOGGER] %d game(s) logged (%d canonical) | %d total entries in DB | %s\n",
              nrow(snapshot), n_with_id, total_rows,
              format(Sys.time(), "%Y-%m-%d %H:%M %Z")))

  # Telegram ping — non-fatal
  tryCatch({
    tg_token <- creds$telegram_bot_token
    tg_chat  <- creds$telegram_chat_id
    if (!is.null(tg_token) && !is.null(tg_chat) &&
        nchar(tg_token) > 5 && nchar(tg_chat) > 0) {

      spread_range <- snapshot %>%
        filter(!is.na(dk_spread_home)) %>%
        summarise(lo = min(dk_spread_home), hi = max(dk_spread_home))
      total_range <- snapshot %>%
        filter(!is.na(dk_total)) %>%
        summarise(lo = min(dk_total), hi = max(dk_total))

      spread_str <- if (nrow(spread_range) > 0 && !is.na(spread_range$lo))
        sprintf("Spreads: %.1f to %.1f", spread_range$lo, spread_range$hi) else "Spreads: N/A"
      total_str  <- if (nrow(total_range) > 0 && !is.na(total_range$lo))
        sprintf("Totals: %.1f–%.1f", total_range$lo, total_range$hi) else "Totals: N/A"

      msg <- sprintf(
        "📡 CFB Lines | %d game(s) | %s\n%s | %s",
        nrow(snapshot),
        format(Sys.time(), "%Y-%m-%d %H:%M %Z"),
        spread_str,
        total_str
      )

      resp <- POST(
        sprintf("https://api.telegram.org/bot%s/sendMessage", tg_token),
        body   = list(chat_id = tg_chat, text = msg),
        encode = "json",
        timeout(15)
      )
      if (http_error(resp)) {
        warning(sprintf("[LOGGER] Telegram ping failed: HTTP %d", status_code(resp)))
      } else {
        cat("[LOGGER] Telegram ping sent.\n")
      }
    }
  }, error = function(e) warning(sprintf("[LOGGER] Telegram ping error: %s", e$message)))

  invisible(snapshot)
}

log_current_lines()
cat("[LOGGER] LINE_MOVEMENT_LOGGER_CFB.R complete.\n")