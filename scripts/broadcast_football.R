# ==============================================================================
# broadcast_football.R — Telegram + Discord Bet Broadcast
# Pipeline Step 21b (non-fatal)
#
# Reads qualified_bets (GlobalEnv) — primary path when run inside pipeline.
# Standalone re-broadcast fallback: queries today's rows from cfb_bets.sqlite.
# Sends formatted message to Telegram channel and Discord webhook.
# Credentials from credentials.json:
#   telegram_bot_token, telegram_chat_id, discord_webhook_url
# ==============================================================================

suppressMessages(library(tidyverse))
suppressMessages(library(httr))
suppressMessages(library(DBI))
suppressMessages(library(RSQLite))

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

# Conference tier → display label
tier_label <- function(tier) {
  case_when(
    tier == 1L ~ "P4",
    tier == 2L ~ "G5",
    tier == 3L ~ "Ind",
    TRUE       ~ ""
  )
}

# "Team [Conference | P4]" or just "Team" if no MASTER data
team_conf_str <- function(team, conference, tier) {
  # Guard against NULL (length-0) inputs — happens when column missing from tibble row
  if (is.null(conference) || length(conference) == 0) conference <- NA_character_
  if (is.null(tier)       || length(tier) == 0)       tier       <- NA_integer_
  if (!is.na(conference) && nzchar(conference) && !is.na(tier)) {
    sprintf("%s [%s | %s]", team, conference, tier_label(tier))
  } else {
    as.character(team)
  }
}

# Boost flags string → signal line
# e.g. "SHARP|BYE" → "📈 Sharp move | 😴 Off bye"
signals_line <- function(flags, line_move) {
  if (is.na(flags) || !nzchar(flags)) return("💼 Model edge only")
  parts  <- strsplit(flags, "\\|")[[1]]
  labels <- character(0)
  if ("SHARP"      %in% parts)
    labels <- c(labels, sprintf("📈 Sharp move (%.1f pts)", coalesce(as.numeric(line_move), 0)))
  if ("BYE"        %in% parts) labels <- c(labels, "😴 Off bye")
  if ("TREND"      %in% parts) labels <- c(labels, "📊 Trend agrees")
  if ("PUBLIC"     %in% parts) labels <- c(labels, "👥 Fading public")
  if ("BBOC_LOVE"  %in% parts) labels <- c(labels, "🎙️ BBOC loves it")
  if ("BBOC_LIKE"  %in% parts) labels <- c(labels, "🎙️ BBOC likes it")
  if (length(labels) == 0) return("💼 Model edge only")
  paste(labels, collapse = " | ")
}

# Bet description line — matches baseball's "✅ BET ..." line
bet_line <- function(bet_type, bet_side, posted_line, juice,
                     canonical_home, canonical_away) {
  juice_i <- as.integer(round(juice))
  if (bet_type == "SPREAD") {
    team <- if (bet_side == "home") canonical_home else canonical_away
    loc  <- if (bet_side == "home") "Home" else "Away"
    sprintf("✅ BET %s (%s) %+.1f @ %+d", team, loc, posted_line, juice_i)
  } else if (bet_type == "TOTAL") {
    side <- toupper(bet_side)   # OVER / UNDER
    sprintf("✅ BET %s %.1f @ %+d", side, posted_line, juice_i)
  } else {   # ML
    team <- if (bet_side == "home") canonical_home else canonical_away
    loc  <- if (bet_side == "home") "Home" else "Away"
    sprintf("✅ BET %s (%s) ML @ %+d", team, loc, as.integer(round(posted_line)))
  }
}

# Edge/value footer line — edge unit differs by market
value_line <- function(bet_type, edge, ev, bet_amount) {
  edge_str <- if (bet_type == "ML") {
    sprintf("Edge: %.1f%%", edge * 100)   # ML edge is probability
  } else {
    sprintf("Edge: %.1f pts", edge)        # Spread/Total edge is points
  }
  sprintf("📈 Value: %+.1f%% | 💵 $%.2f | %s", ev * 100, bet_amount, edge_str)
}

# ------------------------------------------------------------------------------
# Enrich qualified_bets with conference info from MASTER (if available)
# ------------------------------------------------------------------------------
enrich_conference <- function(qb) {
  needed <- c("away_conference", "home_conference", "away_conf_tier", "home_conf_tier")

  # Already enriched — skip entirely to avoid left_join column collision
  if (all(needed %in% names(qb))) return(qb)

  m <- NULL
  if (exists("master", envir = .GlobalEnv)) {
    m <- get("master", envir = .GlobalEnv)
  } else if (exists("MASTER_CSV") && file.exists(MASTER_CSV)) {
    m <- tryCatch(read_csv(MASTER_CSV, show_col_types = FALSE), error = function(e) NULL)
  }

  if (is.null(m) || !all(c("canonical_name", "conference", "conf_tier") %in% names(m))) {
    return(qb %>%
             mutate(away_conference = NA_character_, away_conf_tier = NA_integer_,
                    home_conference = NA_character_, home_conf_tier = NA_integer_))
  }

  qb %>%
    left_join(m %>% select(canonical_name, conference, conf_tier) %>%
                rename(away_conference = conference, away_conf_tier = conf_tier),
              by = c("canonical_away" = "canonical_name")) %>%
    left_join(m %>% select(canonical_name, conference, conf_tier) %>%
                rename(home_conference = conference, home_conf_tier = conf_tier),
              by = c("canonical_home" = "canonical_name"))
}

# ------------------------------------------------------------------------------
# Main formatter — one block per bet, baseball card style
# ------------------------------------------------------------------------------
format_bet_card <- function(qb, bankroll) {

  if (nrow(qb) == 0) return("No bets qualify today.")

  SEP <- paste(rep("-", 26), collapse = "")

  # Enrich with conference info
  qb <- enrich_conference(qb)

  # Header
  n    <- nrow(qb)
  header <- paste(
    "🏈 CFB VALUE PLAYS",
    sprintf("📅 %s", format(Sys.Date(), "%a, %b %d")),
    sprintf("🎯 %d %s | Kelly %.1fx Active", n,
            if (n == 1) "Play" else "Plays", KELLY_FRACTION),
    sep = "\n"
  )

  # One block per bet
  blocks <- vector("character", n)
  for (i in seq_len(n)) {
    r <- qb[i, ]

    game_time <- tryCatch(
      format(as.POSIXct(r$commence_time, tz = "America/Denver"), "%I:%M %p MT"),
      error = function(e) "TBD"
    )

    away_str <- team_conf_str(r$canonical_away, r$away_conference, r$away_conf_tier)
    home_str <- team_conf_str(r$canonical_home, r$home_conference, r$home_conf_tier)

    # Injury warning on ML (narrow-spread games where a starter matters most)
    injury_warn <- if (r$bet_type == "ML") "⚠️ VERIFY INJURY REPORT BEFORE BETTING\n" else ""

    block <- paste0(
      SEP,                                                                   "\n",
      sprintf("🏈 %s @ %s", r$canonical_away, r$canonical_home),            "\n",
      sprintf("| 🕐 %s", game_time),                                         "\n",
      injury_warn,
      sprintf("📍 Market: %s", r$bet_type),                                  "\n",
      bet_line(r$bet_type, r$bet_side, r$posted_line, r$juice,
               r$canonical_home, r$canonical_away),                          "\n",
      sprintf("🏃 Away: %s", away_str),                                       "\n",
      sprintf("🏠 Home: %s", home_str),                                       "\n",
      signals_line(r$boost_flags, r$line_move),                              "\n",
      value_line(r$bet_type, r$edge, r$ev, r$bet_amount),
      # BBOC justification block — only when podcast intelligence fired
      if (grepl("BBOC", coalesce(r$boost_flags, "")) &&
          exists("bboc_picks", envir = .GlobalEnv)) {
        bp <- get("bboc_picks", envir = .GlobalEnv)
        bet_team <- if (r$bet_side == "home") r$canonical_home else
                    if (r$bet_side == "away") r$canonical_away else NA_character_
        bboc_row <- bp[!is.na(bp$team_mention) &
                       bp$team_mention == coalesce(bet_team, "") &
                       bp$market == r$bet_type, ]
        if (nrow(bboc_row) > 0 && !is.na(bboc_row$bboc_justification[1])) {
          # Truncate to first 2 justification entries for clean broadcast
          justs <- strsplit(bboc_row$bboc_justification[1], " \\| ")[[1]]
          justs <- head(justs, 2)
          paste0("\n🎙️ BBOC: ", paste(justs, collapse = " | "))
        } else ""
      } else ""
    )

    blocks[i] <- block
  }

  # Footer
  footer <- paste(
    SEP,
    sprintf("📊 Total Risk: $%.2f", sum(qb$bet_amount)),
    "🏈 mcFootball Kelly 0.5x active! 🏈",
    sep = "\n"
  )

  paste(c(header, blocks, footer), collapse = "\n")
}

# ------------------------------------------------------------------------------
# Send to Telegram (plain text — no parse_mode to avoid & breaking on team names)
# ------------------------------------------------------------------------------
send_telegram <- function(message, bot_token, chat_id) {
  resp <- POST(
    sprintf("https://api.telegram.org/bot%s/sendMessage", bot_token),
    body   = list(chat_id = chat_id, text = message),
    encode = "json",
    timeout(15)
  )
  if (http_error(resp)) {
    warning(sprintf("[BROADCAST] Telegram failed: HTTP %d", status_code(resp)))
    return(FALSE)
  }
  cat("[BROADCAST] Telegram ✓\n")
  TRUE
}

# ------------------------------------------------------------------------------
# Send to Discord (2000-char limit — truncates if needed)
# ------------------------------------------------------------------------------
send_discord <- function(message, webhook_url, label = "Discord") {
  if (nchar(message) > 1990) {
    message <- paste0(substr(message, 1, 1987), "...")
  }
  resp <- POST(
    webhook_url,
    body   = list(content = paste0("```\n", message, "\n```")),
    encode = "json",
    timeout(15)
  )
  if (http_error(resp)) {
    warning(sprintf("[BROADCAST] %s failed: HTTP %d", label, status_code(resp)))
    return(FALSE)
  }
  cat(sprintf("[BROADCAST] %s ✓\n", label))
  TRUE
}

# ------------------------------------------------------------------------------
# Main broadcast
# ------------------------------------------------------------------------------
broadcast_bets <- function() {

  creds <- tryCatch(load_credentials(), error = function(e) list())

  qb <- if (exists("qualified_bets", envir = .GlobalEnv)) {
    get("qualified_bets", envir = .GlobalEnv)
  } else if (file.exists(CFB_BETS_DB)) {
    # Standalone re-broadcast: pull today's bets from cfb_bets.sqlite
    con <- dbConnect(RSQLite::SQLite(), CFB_BETS_DB)
    on.exit(dbDisconnect(con), add = TRUE)
    today_bets <- dbGetQuery(
      con,
      "SELECT * FROM cfb_bets WHERE date(placed_at) = date('now')"
    )
    if (nrow(today_bets) == 0) {
      cat("[BROADCAST] No bets placed today in cfb_bets.sqlite.\n")
      return(invisible(NULL))
    }
    as_tibble(today_bets)
  } else {
    cat("[BROADCAST] No qualified_bets in memory and cfb_bets.sqlite not found.\n")
    return(invisible(NULL))
  }

  bankroll <- as.numeric(readLines(BANKROLL_FILE, warn = FALSE)[1])
  message  <- format_bet_card(qb, bankroll)

  cat(sprintf("[BROADCAST] Message preview (%d chars):\n%s\n",
              nchar(message), strtrim(message, 400)))

  if (!is.null(creds$telegram_bot_token) && !is.null(creds$telegram_chat_id)) {
    tryCatch(
      send_telegram(message, creds$telegram_bot_token, creds$telegram_chat_id),
      error = function(e) warning(sprintf("[BROADCAST] Telegram error: %s", e$message))
    )
  } else {
    cat("[BROADCAST] Telegram credentials not configured — skipping.\n")
  }

  # discord_auto_bet_webhook → #auto-bet-broadcast (primary bet channel)
  if (!is.null(creds$discord_auto_bet_webhook)) {
    tryCatch(
      send_discord(message, creds$discord_auto_bet_webhook, "#auto-bet-broadcast"),
      error = function(e) warning(sprintf("[BROADCAST] #auto-bet-broadcast error: %s", e$message))
    )
  }

  # discord_webhook_url → general channel (secondary; set to NULL to disable)
  if (!is.null(creds$discord_webhook_url)) {
    tryCatch(
      send_discord(message, creds$discord_webhook_url, "Discord"),
      error = function(e) warning(sprintf("[BROADCAST] Discord error: %s", e$message))
    )
  }

  if (is.null(creds$discord_auto_bet_webhook) && is.null(creds$discord_webhook_url)) {
    cat("[BROADCAST] No Discord webhooks configured — skipping.\n")
  }

  invisible(message)
}

# ------------------------------------------------------------------------------
# DRY RUN — test format + live send without running the full pipeline
# Usage:  source("scripts/CONFIG.R")
#         source("scripts/broadcast_football.R")
#         broadcast_dry_run()
# ------------------------------------------------------------------------------
broadcast_dry_run <- function() {
  cat("\n[BROADCAST DRY RUN] Building fake bet card...\n")

  fake_bets <- tibble(
    game_id          = c("2025_fake_01", "2025_fake_01", "2025_fake_02"),
    canonical_away   = c("Alabama",       "Alabama",       "Texas A&M"),
    canonical_home   = c("Georgia",       "Georgia",       "LSU"),
    commence_time    = c("2025-09-06T19:30:00Z",
                         "2025-09-06T19:30:00Z",
                         "2025-09-06T22:00:00Z"),
    bet_type         = c("SPREAD",  "TOTAL",  "ML"),
    bet_side         = c("away",    "over",   "away"),
    posted_line      = c(3.5,       56.5,     145),
    juice            = c(-110,      -110,     145),
    edge             = c(5.3,       3.7,      0.061),
    ev               = c(0.112,     0.089,    0.143),
    boost            = c(1.242,     1.000,    1.150),
    boost_flags      = c("SHARP|BYE", "",    "SHARP"),
    bet_amount       = c(18.50,     12.00,    9.75),
    line_move        = c(3.0,       NA,       2.5),
    conf_weight_avg  = c(1.00,      1.00,     1.00),
    # Conference info (normally joined from MASTER in live run)
    away_conference  = c("SEC",     "SEC",    "SEC"),
    away_conf_tier   = c(1L,        1L,       1L),
    home_conference  = c("SEC",     "SEC",    "SEC"),
    home_conf_tier   = c(1L,        1L,       1L)
  )

  bankroll <- tryCatch(
    as.numeric(readLines(BANKROLL_FILE, warn = FALSE)[1]),
    error = function(e) 500.00
  )

  msg <- format_bet_card(fake_bets, bankroll)

  cat(sprintf("\n--- BROADCAST PREVIEW (%d chars) ---\n", nchar(msg)))
  cat(msg)
  cat("\n--- END PREVIEW ---\n")

  cat("\n[BROADCAST DRY RUN] Checking credentials...\n")
  creds   <- tryCatch(load_credentials(), error = function(e) list())
  has_tg       <- !is.null(creds$telegram_bot_token) && !is.null(creds$telegram_chat_id)
  has_dc_auto  <- !is.null(creds$discord_auto_bet_webhook)
  has_dc_gen   <- !is.null(creds$discord_webhook_url)
  cat(sprintf("  Telegram:              %s\n", if (has_tg) "✓ configured" else "✗ not configured"))
  cat(sprintf("  Discord #auto-bet:     %s\n", if (has_dc_auto) "✓ configured" else "✗ not configured"))
  cat(sprintf("  Discord (general):     %s\n", if (has_dc_gen) "✓ configured" else "✗ not configured"))

  if (has_tg || has_dc) {
    cat("[BROADCAST DRY RUN] Sending [TEST] message...\n")
    test_msg <- paste0("[TEST]\n", msg)
    if (has_tg) tryCatch(
      send_telegram(test_msg, creds$telegram_bot_token, creds$telegram_chat_id),
      error = function(e) cat(sprintf("  Telegram error: %s\n", e$message))
    )
    if (has_dc) tryCatch(
      send_discord(test_msg, creds$discord_webhook_url),
      error = function(e) cat(sprintf("  Discord error: %s\n", e$message))
    )
  } else {
    cat("[BROADCAST DRY RUN] No credentials — preview only.\n")
  }

  invisible(msg)
}

broadcast_bets()
cat("[BROADCAST] broadcast_football.R complete.\n")
