# ==============================================================================
# FINALIZE_BETS_CFB.R — Write Bet History + Master Ticket + Base44 exports
# Pipeline Step 21a
#
# Appends qualified_bets to outputs/cfb_bets.sqlite (cfb_bets table)
# Writes outputs/master_ticket.csv (today's bets only, formatted for review)
# Writes exports/BET_HISTORY_CFB_YYYYMMDD.csv + MASTER_TICKET_CFB_YYYYMMDD.csv
# Triggers node base44/sync.js for Base44 upsert (non-fatal)
#
# Session 14: migrated from bet_history.csv → SQLite.
# Session 19: dated CSV exports + Base44 sync added.
# Run db_schema_init.R once before first use to create both DBs.
# Dedup key: bet_id (= game_id|away|home|bet_type|bet_side)
# ==============================================================================

suppressMessages(library(tidyverse))
suppressMessages(library(DBI))
suppressMessages(library(RSQLite))

finalize_bets <- function() {

  if (!exists("qualified_bets", envir = .GlobalEnv)) {
    cat("[FINALIZE] No qualified_bets — nothing to write.\n")
    return(invisible(NULL))
  }

  qb <- get("qualified_bets", envir = .GlobalEnv)
  if (nrow(qb) == 0) {
    cat("[FINALIZE] qualified_bets is empty — no bets to record.\n")
    return(invisible(NULL))
  }

  # Add required tracking columns
  qb <- qb %>%
    mutate(
      bet_id     = paste(game_id, canonical_away, canonical_home,
                         bet_type, bet_side, sep = "|"),
      placed_at  = as.character(Sys.time()),
      result     = "pending",
      pl         = NA_real_,
      spread_clv_cents = NA_real_,
      total_clv_cents  = NA_real_,
      ml_clv_cents     = NA_real_,
      settled    = 0L,
      commence_time = as.character(commence_time)
    )

  # --- Append to cfb_bets.sqlite ---
  con <- dbConnect(RSQLite::SQLite(), CFB_BETS_DB)
  on.exit(dbDisconnect(con), add = TRUE)

  # Fetch existing bet_ids to avoid duplicates (PK would also catch this,
  # but we want the informative log message rather than a hard error)
  existing_ids <- dbGetQuery(con, "SELECT bet_id FROM cfb_bets")$bet_id
  new_bets <- qb %>% filter(!bet_id %in% existing_ids)

  if (nrow(new_bets) == 0) {
    cat("[FINALIZE] All bets already recorded — no duplicates added.\n")
  } else {
    # Retain only columns present in DB schema
    db_cols <- dbListFields(con, "cfb_bets")
    to_write <- new_bets %>% select(any_of(db_cols))
    dbWriteTable(con, "cfb_bets", to_write, append = TRUE, row.names = FALSE)
    cat(sprintf("[FINALIZE] Inserted %d new bet(s) into cfb_bets.sqlite\n",
                nrow(new_bets)))
  }

  # --- Master ticket (today's bets, human-readable) ---
  ticket <- qb %>%
    arrange(commence_time, bet_type) %>%
    transmute(
      Game       = paste(canonical_away, "@", canonical_home),
      Time       = format(as.POSIXct(commence_time, tz = "America/Denver"),
                          "%a %b %d %I:%M%p MT"),
      Market     = bet_type,
      Side       = bet_side,
      Line       = posted_line,
      `Proj`     = round(proj_line, 1),
      Edge       = round(edge, 2),
      `Win%`     = scales::percent(win_prob_raw, accuracy = 0.1),
      EV         = round(ev, 3),
      Boost      = round(boost, 3),
      Flags      = boost_flags,
      `Bet $`    = round(bet_amount, 2)
    )

  write_csv(ticket, MASTER_TICKET_CSV)
  cat(sprintf("[FINALIZE] Master ticket → %s (%d bets, $%.2f total action)\n",
              MASTER_TICKET_CSV, nrow(ticket), sum(qb$bet_amount)))

  # --- Dated exports for Base44 sync ---
  date_str <- format(Sys.Date(), "%Y%m%d")
  if (!dir.exists("exports")) dir.create("exports", recursive = TRUE)

  # BET_HISTORY_CFB — matches BetHistory entity schema (same as MLB)
  bet_export <- qb %>%
    mutate(
      game_date        = as.character(Sys.Date()),
      sport            = "CFB",
      game_label       = paste(canonical_away, "@", canonical_home),
      away_canonical   = canonical_away,
      home_canonical   = canonical_home,
      bet_line         = posted_line,
      odds             = juice,
      primary_bet_size = bet_amount,
      to_win           = round(ifelse(juice < 0,
                           bet_amount * 100 / abs(juice),
                           bet_amount * juice / 100), 2),
      result           = "PENDING",
      profit_loss      = NA_real_,
      edge_pct         = ifelse(bet_type == "ML", round(edge * 100, 2), NA_real_),
      pick_label       = case_when(
        bet_type == "SPREAD" & bet_side == "home" ~
          paste0(canonical_home, " ", ifelse(posted_line > 0, "+", ""),
                 posted_line, " (SPREAD ", juice, ")"),
        bet_type == "SPREAD" & bet_side == "away" ~
          paste0(canonical_away, " ", ifelse(-posted_line > 0, "+", ""),
                 -posted_line, " (SPREAD ", juice, ")"),
        bet_type == "TOTAL"  & bet_side == "over"  ~
          paste0("OVER ",  posted_line, " (TOTAL ", juice, ")"),
        bet_type == "TOTAL"  & bet_side == "under" ~
          paste0("UNDER ", posted_line, " (TOTAL ", juice, ")"),
        bet_type == "ML"     & bet_side == "home"  ~
          paste0(canonical_home, " ML (",
                 ifelse(juice > 0, paste0("+", juice), juice), ")"),
        bet_type == "ML"     & bet_side == "away"  ~
          paste0(canonical_away, " ML (",
                 ifelse(juice > 0, paste0("+", juice), juice), ")"),
        TRUE ~ paste0(bet_type, " ", bet_side)
      ),
      model_prob       = win_prob_raw,
      market_prob      = ifelse(juice < 0,
                           abs(juice) / (abs(juice) + 100),
                           100 / (juice + 100)),
      confidence       = boost,
      value_score      = ev,
      away_starter     = NA_character_, home_starter     = NA_character_,
      away_starter_status = NA_character_, home_starter_status = NA_character_,
      starter_confidence  = NA_real_,
      away_starter_source = NA_character_, home_starter_source = NA_character_,
      n_books          = 1L,
      model_version    = "mcFootball-v1"
    ) %>%
    select(
      game_id, game_date, game_label, commence_time,
      away_team = canonical_away, home_team = canonical_home,
      away_canonical, home_canonical,
      bet_type, bet_side, bet_line, odds,
      bet_amount, primary_bet_size, to_win,
      result, profit_loss, edge, edge_pct,
      pick_label, model_prob, market_prob,
      confidence, value_score,
      away_starter, home_starter,
      away_starter_status, home_starter_status, starter_confidence,
      away_starter_source, home_starter_source,
      n_books, model_version, sport
    )
  bet_path <- sprintf("exports/BET_HISTORY_CFB_%s.csv", date_str)
  write_csv(bet_export, bet_path)
  cat(sprintf("[FINALIZE] Bet history export → %s\n", bet_path))

  # MASTER_TICKET_CFB — matches Game entity schema (one row per game)
  ticket_export <- qb %>%
    group_by(game_id) %>%
    summarise(
      game_date       = as.character(Sys.Date()),
      game_label      = paste(first(canonical_away), "@", first(canonical_home)),
      commence_time   = as.character(first(commence_time)),
      away_team       = first(canonical_away),
      home_team       = first(canonical_home),
      away_canonical  = first(canonical_away),
      home_canonical  = first(canonical_home),
      n_bets          = n(),
      total_action    = round(sum(bet_amount), 2),
      best_edge       = round(max(edge), 2),
      passes_ev_threshold = TRUE,
      result          = "PENDING",
      profit_loss     = NA_real_,
      settled         = FALSE,
      settlement_date = NA_character_,
      computed_at     = as.character(Sys.time()),
      model_version   = "mcFootball-v1",
      sport           = "CFB",
      .groups         = "drop"
    )
  ticket_path <- sprintf("exports/MASTER_TICKET_CFB_%s.csv", date_str)
  write_csv(ticket_export, ticket_path)
  cat(sprintf("[FINALIZE] Master ticket export → %s\n", ticket_path))

  # --- Base44 sync (non-fatal) ---
  sync_js <- normalizePath("base44/sync.js", mustWork = FALSE)
  if (file.exists(sync_js)) {
    tryCatch({
      sync_cmd <- sprintf("node %s %s", shQuote(sync_js), date_str)
      cat(sprintf("[FINALIZE] Base44 sync: %s\n", sync_cmd))
      ret <- system(sync_cmd)
      if (ret != 0L) warning(sprintf("[FINALIZE] Base44 sync exited with code %d", ret))
    }, error = function(e) {
      warning(sprintf("[FINALIZE] Base44 sync failed: %s", e$message))
    })
  } else {
    cat("[FINALIZE] base44/sync.js not found — skipping Base44 sync.\n")
  }

  invisible(qb)
}

finalize_bets()
cat("[FINALIZE] FINALIZE_BETS_CFB.R complete.\n")
