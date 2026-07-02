# ==============================================================================
# fetch_odds_football.R — Odds API CFB Fetch
# Pipeline Step 7 (FATAL — no odds = no pipeline)
#
# Markets fetched: spreads | totals | h2h (moneyline)
# Primary book:    DraftKings (key = "draftkings")
# Fallback books:  FanDuel → BetMGM → Caesars (in that order, fills NAs)
#
# Output tibble: odds_data (assigned to .GlobalEnv)
# Columns produced:
#   id, sport_key, commence_time, home_team, away_team
#   dk_spread_home, dk_spread_away, dk_spread_juice_home, dk_spread_juice_away
#   dk_total, dk_total_juice_over, dk_total_juice_under
#   dk_ml_home, dk_ml_away
#   open_spread_home  (first recorded line — for movement calc)
#   n_books_spread, n_books_total, n_books_ml  (market liquidity signals)
#
# Odds API docs: https://the-odds-api.com/liveapi/guides/v4/
# Sport key for CFB: "americanfootball_ncaaf"
# ==============================================================================

suppressMessages(library(tidyverse))
suppressMessages(library(httr))
suppressMessages(library(jsonlite))
suppressMessages(library(DBI))
suppressMessages(library(RSQLite))

DB_PATH         <- "C:/Users/Mike/sports_data/cfb_line_movement.sqlite"
ODDS_SPORT_KEY  <- "americanfootball_ncaaf"
ODDS_REGIONS    <- "us"
ODDS_MARKETS    <- "spreads,totals,h2h"
ODDS_BASE_URL   <- "https://api.the-odds-api.com/v4/sports"
PRIMARY_BOOK    <- "draftkings"
FALLBACK_BOOKS  <- c("fanduel", "betmgm", "caesars", "williamhill_us")

# ------------------------------------------------------------------------------
# 1. Fetch raw JSON from Odds API
# ------------------------------------------------------------------------------
fetch_odds_raw <- function(api_key) {
  url <- sprintf("%s/%s/odds", ODDS_BASE_URL, ODDS_SPORT_KEY)

  cat(sprintf("[ODDS] Fetching CFB odds (markets: %s)...\n", ODDS_MARKETS))

  resp <- GET(
    url,
    query = list(
      apiKey      = api_key,
      regions     = ODDS_REGIONS,
      markets     = ODDS_MARKETS,
      oddsFormat  = "american",
      dateFormat  = "iso"
    ),
    timeout(30)
  )

  # Log remaining API requests from response headers
  remaining <- headers(resp)[["x-requests-remaining"]]
  used      <- headers(resp)[["x-requests-used"]]
  if (!is.null(remaining)) {
    cat(sprintf("[ODDS] API quota — used: %s | remaining: %s\n", used, remaining))
  }

  if (http_error(resp)) {
    stop(sprintf("[ODDS] HTTP %d: %s",
                 status_code(resp),
                 content(resp, "text", encoding = "UTF-8")))
  }

  raw <- content(resp, "text", encoding = "UTF-8")
  games <- fromJSON(raw, flatten = FALSE)

  if (length(games) == 0) {
    stop("[ODDS] Odds API returned 0 games — no CFB games on the slate or API issue.")
  }

  cat(sprintf("[ODDS] Raw fetch: %d games returned.\n", length(games)))
  games
}

# ------------------------------------------------------------------------------
# Helper: fromJSON with flatten=FALSE returns data frames for uniform JSON arrays.
# Every nested array in the Odds API response (bookmakers, markets, outcomes)
# must be normalized to a list-of-named-lists before Filter/map_chr can work.
# ------------------------------------------------------------------------------
as_row_list <- function(x) {
  if (is.null(x) || length(x) == 0) return(list())
  if (!is.data.frame(x)) return(x)
  lapply(seq_len(nrow(x)), function(i) {
    lapply(x, function(col) if (is.list(col)) col[[i]] else col[i])
  })
}

# ------------------------------------------------------------------------------
# 2. Extract a single market value from a bookmaker's outcomes list
# ------------------------------------------------------------------------------
extract_market <- function(bookmaker_list, book_key, market_key, outcome_name,
                            value_field = "price") {
  tryCatch({
    bookmaker_list <- as_row_list(bookmaker_list)   # normalize: df → list-of-lists

    bk <- Filter(function(b) b$key == book_key, bookmaker_list)
    if (length(bk) == 0) return(NA_real_)
    bk <- bk[[1]]

    bk_markets <- as_row_list(bk$markets)           # normalize markets too
    mkt <- Filter(function(m) m$key == market_key, bk_markets)
    if (length(mkt) == 0) return(NA_real_)
    mkt <- mkt[[1]]

    outcomes <- mkt$outcomes
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
# 3. Parse one game's bookmaker data into flat columns
# ------------------------------------------------------------------------------
parse_game_odds <- function(game) {
  books  <- as_row_list(game$bookmakers)   # normalize: bookmakers df → list-of-lists
  home   <- game$home_team
  away   <- game$away_team

  if (is.null(books) || length(books) == 0) {
    return(tibble(
      id = game$id, home_team = home, away_team = away,
      dk_spread_home = NA_real_, dk_spread_away = NA_real_,
      dk_spread_juice_home = NA_real_, dk_spread_juice_away = NA_real_,
      dk_total = NA_real_, dk_total_juice_over = NA_real_,
      dk_total_juice_under = NA_real_,
      dk_ml_home = NA_real_, dk_ml_away = NA_real_,
      n_books_spread = 0L, n_books_total = 0L, n_books_ml = 0L
    ))
  }

  # -- Primary: DraftKings --
  dk_sh   <- extract_market(books, PRIMARY_BOOK, "spreads", home,  "point")
  dk_sa   <- extract_market(books, PRIMARY_BOOK, "spreads", away,  "point")
  dk_sjh  <- extract_market(books, PRIMARY_BOOK, "spreads", home,  "price")
  dk_sja  <- extract_market(books, PRIMARY_BOOK, "spreads", away,  "price")
  dk_tot  <- extract_market(books, PRIMARY_BOOK, "totals",  "Over", "point")
  dk_tjo  <- extract_market(books, PRIMARY_BOOK, "totals",  "Over", "price")
  dk_tju  <- extract_market(books, PRIMARY_BOOK, "totals",  "Under","price")
  dk_mlh  <- extract_market(books, PRIMARY_BOOK, "h2h",     home,  "price")
  dk_mla  <- extract_market(books, PRIMARY_BOOK, "h2h",     away,  "price")

  # -- Fallback: fill NAs from other books in priority order --
  for (fb in FALLBACK_BOOKS) {
    if (is.na(dk_sh))  dk_sh  <- extract_market(books, fb, "spreads", home,  "point")
    if (is.na(dk_sa))  dk_sa  <- extract_market(books, fb, "spreads", away,  "point")
    if (is.na(dk_sjh)) dk_sjh <- extract_market(books, fb, "spreads", home,  "price")
    if (is.na(dk_sja)) dk_sja <- extract_market(books, fb, "spreads", away,  "price")
    if (is.na(dk_tot)) dk_tot <- extract_market(books, fb, "totals",  "Over", "point")
    if (is.na(dk_tjo)) dk_tjo <- extract_market(books, fb, "totals",  "Over", "price")
    if (is.na(dk_tju)) dk_tju <- extract_market(books, fb, "totals",  "Under","price")
    if (is.na(dk_mlh)) dk_mlh <- extract_market(books, fb, "h2h",     home,  "price")
    if (is.na(dk_mla)) dk_mla <- extract_market(books, fb, "h2h",     away,  "price")
    # Stop early if all filled
    if (!any(is.na(c(dk_sh, dk_sa, dk_tot, dk_mlh, dk_mla)))) break
  }

  # -- Consensus liquidity: count books offering each market --
  book_keys <- map_chr(books, function(b) b$key)   # safe: books already row-listed
  count_market <- function(mkt) {
    sum(map_lgl(books, function(b) {
      any(map_chr(as_row_list(b$markets), function(m) m$key) == mkt)
    }), na.rm = TRUE)
  }
  n_spread <- count_market("spreads")
  n_total  <- count_market("totals")
  n_ml     <- count_market("h2h")

  tibble(
    id                   = game$id,
    home_team            = home,
    away_team            = away,
    dk_spread_home       = dk_sh,
    dk_spread_away       = dk_sa,
    dk_spread_juice_home = dk_sjh,
    dk_spread_juice_away = dk_sja,
    dk_total             = dk_tot,
    dk_total_juice_over  = dk_tjo,
    dk_total_juice_under = dk_tju,
    dk_ml_home           = dk_mlh,
    dk_ml_away           = dk_mla,
    n_books_spread       = as.integer(n_spread),
    n_books_total        = as.integer(n_total),
    n_books_ml           = as.integer(n_ml)
  )
}

# ------------------------------------------------------------------------------
# 4. Build opening line snapshot for movement tracking
#
# Writes to: outputs/cfb_line_movement.sqlite  (table: line_movement)
# Schema shared with LINE_MOVEMENT_LOGGER_CFB.R — pipeline entries have
# game_id = NULL (canonical normalization hasn't run yet at Step 7).
# The hourly logger fills in canonical game_id entries independently.
# BET_SETTLEMENT.R uses only non-NULL game_id rows for CLV lookup.
# ------------------------------------------------------------------------------
append_opening_lines <- function(odds_df, date = Sys.Date()) {

  snapshot <- odds_df %>%
    mutate(
      logged_at     = format(Sys.time(),      "%Y-%m-%d %H:%M:%S"),
      commence_time = format(commence_time,   "%Y-%m-%d %H:%M:%S"),
      game_id       = NA_character_
    ) %>%
    select(logged_at, id, game_id, home_team, away_team, commence_time,
           dk_spread_home, dk_total, dk_ml_home, dk_ml_away)

  con <- dbConnect(RSQLite::SQLite(), DB_PATH)
  on.exit(dbDisconnect(con), add = TRUE)

  table_exists <- dbExistsTable(con, "line_movement")

  if (!table_exists) {
    # First ever run — DB not yet created by logger; create with pipeline schema.
    # Logger will add its book columns when it first runs (append=TRUE pads NULLs).
    dbWriteTable(con, "line_movement", snapshot, append = FALSE)
    odds_df <- odds_df %>%
      mutate(open_spread_home = dk_spread_home,
             open_total       = dk_total)
    cat("[ODDS] Line movement DB initialized.\n")
    return(odds_df)
  }

  # Table exists — pad any extra columns (added by logger) with NA before INSERT
  existing_cols <- dbListFields(con, "line_movement")
  for (col in setdiff(existing_cols, names(snapshot))) snapshot[[col]] <- NA_real_
  snapshot <- snapshot %>% select(all_of(existing_cols))

  dbWriteTable(con, "line_movement", snapshot, append = TRUE)

  # Opening line per game = values at the earliest logged_at snapshot
  opens_raw <- dbGetQuery(con,
    "SELECT l.id,
            l.dk_spread_home AS open_spread_home,
            l.dk_total       AS open_total
     FROM   line_movement l
     INNER JOIN (
       SELECT id, MIN(logged_at) AS first_seen
       FROM   line_movement
       GROUP  BY id
     ) m ON l.id = m.id AND l.logged_at = m.first_seen")

  odds_df <- odds_df %>%
    left_join(opens_raw, by = "id") %>%
    mutate(
      open_spread_home = coalesce(open_spread_home, dk_spread_home),
      open_total       = coalesce(open_total,       dk_total)
    )

  odds_df
}

# ------------------------------------------------------------------------------
# 5. Main entry point
# ------------------------------------------------------------------------------
fetch_odds_football <- function(date = Sys.Date()) {
  creds    <- load_credentials()

  # Support both singular (odds_api_key) and array (odds_api_keys) in credentials.json
  api_keys <- creds$odds_api_keys %||% list(creds$odds_api_key)
  api_keys <- api_keys[!sapply(api_keys, function(k) is.null(k) || nchar(k) < 10)]
  if (length(api_keys) == 0) {
    stop("[ODDS] No valid odds_api_keys found in credentials.json")
  }

  # Key rotation: try each key in order, advance on rate-limit (429) or auth error (401)
  games_raw <- NULL
  for (i in seq_along(api_keys)) {
    key <- api_keys[[i]]
    cat(sprintf("[ODDS] Trying key %d of %d...\n", i, length(api_keys)))
    result <- tryCatch(
      fetch_odds_raw(key),
      error = function(e) {
        msg <- e$message
        if (grepl("401|403|429|quota|rate", msg, ignore.case = TRUE)) {
          cat(sprintf("[ODDS] Key %d rejected (%s) — rotating to next key.\n",
                      i, substring(msg, 1, 60)))
          NULL
        } else {
          stop(e)   # re-throw non-key errors (network, parse, etc.)
        }
      }
    )
    if (!is.null(result)) {
      games_raw <- result
      cat(sprintf("[ODDS] Key %d succeeded.\n", i))
      break
    }
  }
  if (is.null(games_raw)) {
    stop("[ODDS] All API keys exhausted or rejected. Check quota at the-odds-api.com.")
  }

  # fromJSON returns a data frame when the API response is a uniform JSON array.
  # Convert to a list-of-row-lists so parse_game_odds() receives one game at a time,
  # not one column at a time. List-columns (bookmakers) need [[i]], scalars need [i].
  games_list <- lapply(seq_len(nrow(games_raw)), function(i) {
    lapply(games_raw, function(col) {
      if (is.list(col)) col[[i]] else col[i]
    })
  })

  # Parse each game
  odds_data <- map_dfr(games_list, parse_game_odds) %>%
    mutate(
      sport_key     = ODDS_SPORT_KEY,
      commence_time = map_chr(games_list, "commence_time") %>%
                        as.POSIXct(format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
    )

  # Movement tracking
  odds_data <- tryCatch(
    append_opening_lines(odds_data, date),
    error = function(e) {
      warning(sprintf("[ODDS] Line movement tracking failed (non-fatal): %s", e$message))
      odds_data %>% mutate(open_spread_home = dk_spread_home,
                           open_total       = dk_total)
    }
  )

  # Summary
  n_spread <- sum(!is.na(odds_data$dk_spread_home))
  n_total  <- sum(!is.na(odds_data$dk_total))
  n_ml     <- sum(!is.na(odds_data$dk_ml_home))
  cat(sprintf("[ODDS] Parsed: %d games | spread: %d | total: %d | ML: %d\n",
              nrow(odds_data), n_spread, n_total, n_ml))

  assign("odds_data", odds_data, envir = .GlobalEnv)
  invisible(odds_data)
}

# Run when sourced (fatal — will stop pipeline on error)
fetch_odds_football()

cat("[ODDS] fetch_odds_football.R complete.\n")
