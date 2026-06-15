# ==============================================================================
# WEATHER_SCRAPER_CFB.R — CFB Game-Time Weather Forecasts
# Pipeline Step 15 (non-fatal — wrapped in tryCatch by orchestrator)
#
# Source: OpenWeatherMap 5-day / 3-hour forecast API (free tier)
#         Stadium coordinates + dome flag from CFBD /teams (location.latitude,
#         location.longitude, location.dome)
#
# Outputs:
#   weather_data          — tibble in GlobalEnv (one row per game)
#   games_with_predictions — mutated in place: adds wind_speed, precip_prob,
#                            temp_f, home_dome columns consumed by Step 17
#
# Step 17 checks:
#   !is.null(weather_data) && all(c("wind_speed","precip_prob") %in% names(gwp))
# This script ensures both conditions are true for outdoor games.
# ==============================================================================

suppressMessages(library(tidyverse))
suppressMessages(library(httr))
suppressMessages(library(jsonlite))

OWM_FORECAST <- "https://api.openweathermap.org/data/2.5/forecast"
CFBD_BASE    <- "https://api.collegefootballdata.com"

`%||%` <- function(a, b) if (!is.null(a) && length(a) > 0) a else b

# ------------------------------------------------------------------------------
# 1. Team stadium locations — CFBD /teams?division=fbs
#    Returns: canonical_name, lat, lon, dome, venue
# ------------------------------------------------------------------------------
.cfb_team_locations <- function(cfbd_key, master) {
  cat("[WEATHER] Loading stadium coordinates from CFBD /teams...\n")

  resp <- GET(
    paste0(CFBD_BASE, "/teams"),
    add_headers(Authorization = paste("Bearer", cfbd_key)),
    query = list(division = "fbs"),
    timeout(30)
  )
  if (http_error(resp))
    stop(sprintf("[WEATHER] /teams HTTP %d", status_code(resp)))

  raw <- fromJSON(content(resp, "text", encoding = "UTF-8"), flatten = TRUE)
  df  <- as_tibble(raw)

  # After flatten=TRUE, nested location fields become "location.xxx"
  get_col <- function(df, candidates)
    .data[[intersect(candidates, names(df))[1]]]

  locs <- df %>%
    transmute(
      team_raw = school,
      lat      = suppressWarnings(as.numeric(
                   if ("location.latitude"  %in% names(df)) location.latitude  else NA_real_)),
      lon      = suppressWarnings(as.numeric(
                   if ("location.longitude" %in% names(df)) location.longitude else NA_real_)),
      dome     = coalesce(as.logical(
                   if ("location.dome" %in% names(df)) location.dome else FALSE), FALSE),
      venue    = if ("location.name" %in% names(df)) location.name else NA_character_
    ) %>%
    filter(!is.na(lat), !is.na(lon)) %>%
    mutate(
      canonical_name = normalize_team_name(
        team_raw, mappings = master,
        source_col = "massey_name", unmatched_log = "logs/unmatched_teams.csv"
      )
    ) %>%
    filter(!is.na(canonical_name)) %>%
    distinct(canonical_name, .keep_all = TRUE) %>%
    select(canonical_name, lat, lon, dome, venue)

  cat(sprintf("[WEATHER] %d teams with coordinates (%d dome/retractable).\n",
              nrow(locs), sum(locs$dome, na.rm = TRUE)))
  locs
}

# ------------------------------------------------------------------------------
# 2. OpenWeather 5-day forecast — pick slot closest to game time (UTC)
#    Uses /forecast (3-hr intervals, 5 days ahead) — better than /weather
#    for Thursday pipeline fetching Saturday game conditions.
# ------------------------------------------------------------------------------
.owm_forecast <- function(lat, lon, commence_utc, owm_key) {
  tryCatch({
    resp <- GET(
      OWM_FORECAST,
      query = list(lat = lat, lon = lon, appid = owm_key,
                   units = "imperial", cnt = 16L),
      timeout(15)
    )
    if (http_error(resp)) return(NULL)

    body  <- fromJSON(content(resp, "text", encoding = "UTF-8"), flatten = FALSE)
    slots <- body$list
    if (length(slots) == 0) return(NULL)

    game_ts  <- as.POSIXct(commence_utc, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
    slot_ts  <- as.POSIXct(sapply(slots, `[[`, "dt"),
                            origin = "1970-01-01", tz = "UTC")
    idx      <- which.min(abs(difftime(slot_ts, game_ts, units = "secs")))

    s <- slots[[idx]]
    list(
      wind_speed  = as.numeric(s$wind$speed  %||% 0),
      precip_prob = as.numeric(s$pop         %||% 0),   # 0–1 probability
      temp_f      = as.numeric(s$main$temp   %||% 55),
      condition   = as.character(s$weather[[1]]$main %||% "Clear")
    )
  }, error = function(e) {
    cat(sprintf("[WEATHER] Forecast error (%.3f, %.3f): %s\n", lat, lon, e$message))
    NULL
  })
}

# ------------------------------------------------------------------------------
# 3. Main entry point
# ------------------------------------------------------------------------------
scrape_weather_cfb <- function() {
  creds   <- tryCatch(load_credentials(), error = function(e) list())
  owm_key  <- creds$openweather_api_key
  cfbd_key <- creds$cfbd_api_key %||% ""

  if (is.null(owm_key) || nchar(owm_key) < 5) {
    warning("[WEATHER] openweather_api_key missing — weather step skipped.")
    assign("weather_data", NULL, envir = .GlobalEnv)
    return(invisible(NULL))
  }

  # Need games_with_predictions for game list + the final join (Step 17)
  if (!exists("games_with_predictions", envir = .GlobalEnv)) {
    warning("[WEATHER] games_with_predictions not found — weather step skipped.")
    assign("weather_data", NULL, envir = .GlobalEnv)
    return(invisible(NULL))
  }
  games <- get("games_with_predictions", envir = .GlobalEnv)

  master <- if (exists("master_cfb", envir = .GlobalEnv)) {
    get("master_cfb", envir = .GlobalEnv)
  } else {
    tryCatch(load_cfb_master("team_name_mappings_MASTER_CFB.csv"),
             error = function(e) NULL)
  }

  # Load stadium coordinates
  locs <- tryCatch(
    .cfb_team_locations(cfbd_key, master),
    error = function(e) {
      warning(sprintf("[WEATHER] Stadium lookup failed: %s", e$message))
      NULL
    }
  )
  if (is.null(locs)) {
    assign("weather_data", NULL, envir = .GlobalEnv)
    return(invisible(NULL))
  }

  cat(sprintf("[WEATHER] Fetching forecasts for %d games...\n", nrow(games)))

  weather_data <- map_dfr(seq_len(nrow(games)), function(i) {
    g    <- games[i, ]
    home <- g$canonical_home
    loc  <- locs[locs$canonical_name == home, ]

    if (nrow(loc) == 0) {
      cat(sprintf("[WEATHER] No stadium data for %s — neutral.\n", home))
      return(tibble(canonical_home = home,
                    wind_speed = NA_real_, precip_prob = NA_real_,
                    temp_f = NA_real_, home_dome = FALSE,
                    condition = "unknown"))
    }
    loc <- loc[1, ]

    if (isTRUE(loc$dome)) {
      cat(sprintf("[WEATHER] %-32s  dome — no weather adj.\n",
                  coalesce(loc$venue, home)))
      return(tibble(canonical_home = home,
                    wind_speed = NA_real_, precip_prob = NA_real_,
                    temp_f = NA_real_, home_dome = TRUE,
                    condition = "dome"))
    }

    Sys.sleep(0.15)
    wx <- .owm_forecast(loc$lat, loc$lon, g$commence_time, owm_key)
    if (is.null(wx)) {
      return(tibble(canonical_home = home,
                    wind_speed = NA_real_, precip_prob = NA_real_,
                    temp_f = NA_real_, home_dome = FALSE,
                    condition = "unavailable"))
    }

    cat(sprintf("[WEATHER] %-32s  %.0f°F  wind=%.0f mph  precip=%.0f%%  [%s]\n",
                coalesce(loc$venue, home),
                wx$temp_f, wx$wind_speed, wx$precip_prob * 100, wx$condition))

    tibble(canonical_home = home,
           wind_speed     = wx$wind_speed,
           precip_prob    = wx$precip_prob,
           temp_f         = wx$temp_f,
           home_dome      = FALSE,
           condition      = wx$condition)
  })

  if (nrow(weather_data) == 0) {
    cat("[WEATHER] No forecast data returned (dates too far out?).\n")
    assign("weather_data", NULL, envir = .GlobalEnv)
    return(invisible(NULL))
  }

  n_dome    <- sum(weather_data$home_dome, na.rm = TRUE)
  n_outdoor <- nrow(weather_data) - n_dome
  cat(sprintf("[WEATHER] Done — %d outdoor | %d dome.\n", n_outdoor, n_dome))

  assign("weather_data", weather_data, envir = .GlobalEnv)

  # --- Join wind_speed, precip_prob, temp_f, home_dome onto games_with_predictions
  # Step 17 checks: all(c("wind_speed","precip_prob") %in% names(games_with_predictions))
  gwp <- get("games_with_predictions", envir = .GlobalEnv)
  gwp <- gwp %>%
    select(-any_of(c("wind_speed", "precip_prob", "temp_f", "home_dome"))) %>%
    left_join(
      distinct(weather_data, canonical_home, .keep_all = TRUE) %>%
        select(canonical_home, wind_speed, precip_prob, temp_f, home_dome),
      by = "canonical_home"
    )
  assign("games_with_predictions", gwp, envir = .GlobalEnv)

  invisible(weather_data)
}

scrape_weather_cfb()
cat("[WEATHER] WEATHER_SCRAPER_CFB.R complete.\n")
