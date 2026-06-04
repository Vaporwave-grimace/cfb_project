# ==============================================================================
# WEATHER_SCRAPER_CFB.R — Weather by Stadium Coordinates
# Pipeline Step 15 (non-fatal)
#
# Source: OpenWeatherMap API (free tier, 1000 calls/day)
#         GET /data/2.5/weather?lat=&lon=&appid=&units=imperial
#
# DOME GUARD: if home_dome == TRUE, skip API call entirely.
#   Set wind=0, temp=72, precip=0 — weather adjustments in Step 17 will fire 0.
#
# Output: weather_data tibble → .GlobalEnv
#   game_id, wind_speed, temp_f, precip_prob, condition, home_dome
# ==============================================================================

suppressMessages(library(tidyverse))
suppressMessages(library(httr))
suppressMessages(library(jsonlite))

OWM_BASE <- "https://api.openweathermap.org/data/2.5/weather"

`%||%` <- function(a, b) if (!is.null(a) && length(a) > 0) a else b

fetch_game_weather <- function(game_row, api_key) {

  # Dome guard — no fetch needed
  if (isTRUE(game_row$home_dome)) {
    return(tibble(
      game_id    = game_row$game_id,
      wind_speed = 0, temp_f = 72, precip_prob = 0,
      condition  = "dome", home_dome = TRUE
    ))
  }

  lat <- game_row$home_latitude
  lon <- game_row$home_longitude
  if (is.na(lat) || is.na(lon)) return(NULL)

  resp <- tryCatch(GET(OWM_BASE,
    query   = list(lat = lat, lon = lon, appid = api_key,
                   units = "imperial"),
    timeout(15)
  ), error = function(e) NULL)

  if (is.null(resp) || http_error(resp)) return(NULL)

  wx <- fromJSON(content(resp, "text", encoding = "UTF-8"), flatten = TRUE)

  tibble(
    game_id     = game_row$game_id,
    wind_speed  = as.numeric(wx$wind$speed %||% 0),
    temp_f      = as.numeric(wx$main$temp  %||% 55),
    precip_prob = as.numeric((wx$rain$`1h` %||% 0) > 0),
    condition   = as.character(wx$weather[[1]]$main %||% "Clear"),
    home_dome   = FALSE
  )
}

scrape_weather_cfb <- function() {
  creds   <- tryCatch(load_credentials(), error = function(e) list())
  api_key <- creds$openweather_api_key
  if (is.null(api_key) || nchar(api_key) < 5) {
    warning("[WEATHER] openweather_api_key missing — weather step skipped.")
    assign("weather_data", NULL, envir = .GlobalEnv)
    return(invisible(NULL))
  }

  games <- if (exists("odds_data", envir = .GlobalEnv))
    get("odds_data", envir = .GlobalEnv) else NULL
  if (is.null(games) || nrow(games) == 0) {
    warning("[WEATHER] No odds_data found — weather step skipped.")
    assign("weather_data", NULL, envir = .GlobalEnv)
    return(invisible(NULL))
  }

  cat(sprintf("[WEATHER] Fetching weather for %d games...\n", nrow(games)))

  weather_data <- map_dfr(seq_len(nrow(games)), function(i) {
    Sys.sleep(0.12)   # ~8 req/sec — well within free tier
    tryCatch(fetch_game_weather(as.list(games[i, ]), api_key),
             error = function(e) NULL)
  })

  # Guard: map_dfr returns 0-col tibble when every game returns NULL
  # (e.g. pre-season dry run — OWM has no forecast 4+ months out).
  if (nrow(weather_data) == 0) {
    cat("[WEATHER] Done — 0 outdoor | 0 dome (no weather data available for these dates).\n")
    assign("weather_data", NULL, envir = .GlobalEnv)
    return(invisible(NULL))
  }

  n_dome    <- sum(weather_data$home_dome, na.rm = TRUE)
  n_outdoor <- nrow(weather_data) - n_dome
  cat(sprintf("[WEATHER] Done — %d outdoor | %d dome (skipped fetch).\n",
              n_outdoor, n_dome))

  # Join back onto odds_data
  games <- games %>%
    select(-any_of(c("wind_speed","temp_f","precip_prob","condition"))) %>%
    left_join(weather_data %>% select(-any_of("home_dome")), by = "game_id")

  assign("odds_data",     games,        envir = .GlobalEnv)
  assign("weather_data",  weather_data, envir = .GlobalEnv)
  invisible(weather_data)
}

scrape_weather_cfb()
cat("[WEATHER] WEATHER_SCRAPER_CFB.R complete.\n")
