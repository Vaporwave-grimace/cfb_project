# ==============================================================================
# BYE_WEEK_TRACKER.R — Flag Teams on Bye This Week
# Pipeline Step 14 (non-fatal)
#
# Strategy: compare this week's game slate against all FBS teams.
# Any team NOT appearing in this week's schedule = on bye.
# Source: cfbd_schedule (from SCRAPE_CFB_DATA.R) or CFBD API direct call.
#
# Output: bye_week_data tibble (canonical_name) → .GlobalEnv
# ==============================================================================

suppressMessages(library(tidyverse))

track_bye_weeks <- function(date = Sys.Date()) {

  # Load this week's schedule
  schedule <- if (exists("cfbd_schedule", envir = .GlobalEnv)) {
    get("cfbd_schedule", envir = .GlobalEnv)
  } else {
    candidates <- list.files("clean", pattern = "^cfb_schedule_", full.names = TRUE)
    if (length(candidates) == 0) {
      warning("[BYE] No schedule found — bye week tracking skipped.")
      assign("bye_week_data", NULL, envir = .GlobalEnv)
      return(invisible(NULL))
    }
    read_csv(candidates[order(file.mtime(candidates), decreasing = TRUE)][1],
             show_col_types = FALSE)
  }

  # Load master for full FBS team list
  master <- if (exists("master_cfb", envir = .GlobalEnv)) {
    get("master_cfb", envir = .GlobalEnv)
  } else {
    load_cfb_master()
  }

  # Teams playing this week
  playing <- unique(c(schedule$canonical_home, schedule$canonical_away))
  playing <- playing[!is.na(playing)]

  # Teams on bye = in master but not playing
  on_bye <- master %>%
    filter(!canonical_name %in% playing) %>%
    select(canonical_name, conference)

  cat(sprintf("[BYE] %d teams on bye this week: %s\n",
              nrow(on_bye),
              if (nrow(on_bye) > 0)
                paste(head(on_bye$canonical_name, 8), collapse = ", ")
              else "none"))

  assign("bye_week_data", on_bye, envir = .GlobalEnv)
  invisible(on_bye)
}

track_bye_weeks()
cat("[BYE] BYE_WEEK_TRACKER.R complete.\n")
