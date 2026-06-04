# ==============================================================================
# TRAVEL_FATIGUE_CFB.R — Away Travel Distance Fatigue Adjustment
# Pipeline Step 16 (non-fatal)
#
# Calculates away team's travel distance using Haversine formula.
# Teams traveling > 1000 miles get a fatigue penalty on their side.
# Tiers: 500-1000 mi → -0.5 pts | 1000-2000 mi → -1.0 pt | 2000+ mi → -1.5 pts
# Hawaii road games: additional -1.5 pts (extreme travel, time zone)
#
# Output: travel_fatigue tibble → .GlobalEnv
#   canonical_name, travel_miles, fatigue_pts
# Also joins fatigue_pts_away onto odds_data for GENERATE_PREDICTIONS_CFB.R
# ==============================================================================

suppressMessages(library(tidyverse))

# Haversine distance in miles
haversine_miles <- function(lat1, lon1, lat2, lon2) {
  R   <- 3958.8   # Earth radius in miles
  phi1 <- lat1 * pi / 180; phi2 <- lat2 * pi / 180
  dphi <- (lat2 - lat1) * pi / 180
  dlam <- (lon2 - lon1) * pi / 180
  a <- sin(dphi/2)^2 + cos(phi1) * cos(phi2) * sin(dlam/2)^2
  R * 2 * atan2(sqrt(a), sqrt(1 - a))
}

fatigue_pts_from_miles <- function(miles, to_hawaii = FALSE) {
  base <- case_when(
    miles >= 2000 ~ -1.5,
    miles >= 1000 ~ -1.0,
    miles >=  500 ~ -0.5,
    TRUE          ~  0.0
  )
  # Vectorized: to_hawaii may be a logical vector when called inside mutate()
  ifelse(to_hawaii, base - 1.5, base)
}

calculate_travel_fatigue <- function() {

  master <- if (exists("master_cfb", envir = .GlobalEnv)) {
    get("master_cfb", envir = .GlobalEnv)
  } else {
    load_cfb_master()
  }

  games <- if (exists("odds_data", envir = .GlobalEnv)) {
    get("odds_data", envir = .GlobalEnv)
  } else {
    warning("[TRAVEL] No odds_data — travel fatigue skipped.")
    assign("travel_fatigue", NULL, envir = .GlobalEnv)
    return(invisible(NULL))
  }

  coords <- master %>%
    select(canonical_name, latitude, longitude)

  # Away team travels from their home stadium to the game venue
  # home_lat/lon = venue coords (from standardize_data_cfb.R join)
  # neutral_site may not be in odds_data (added later in MERGE_GAMES_RATINGS) — default FALSE
  travel <- games %>%
    select(game_id, canonical_away, canonical_home,
           venue_lat = home_latitude, venue_lon = home_longitude,
           any_of("neutral_site")) %>%
    mutate(neutral_site = if ("neutral_site" %in% names(.)) neutral_site else FALSE) %>%
    left_join(coords %>% rename(away_lat = latitude, away_lon = longitude),
              by = c("canonical_away" = "canonical_name")) %>%
    mutate(
      travel_miles = pmap_dbl(
        list(away_lat, away_lon, venue_lat, venue_lon),
        function(la, lo, vla, vlo) {
          if (any(is.na(c(la, lo, vla, vlo)))) return(NA_real_)
          haversine_miles(la, lo, vla, vlo)
        }
      ),
      to_hawaii  = str_detect(canonical_home, "Hawaii"),
      # Neutral site: both teams travel — split fatigue, net ≈ 0
      fatigue_pts = if_else(
        neutral_site == TRUE,
        0,
        fatigue_pts_from_miles(travel_miles, to_hawaii)
      )
    ) %>%
    select(canonical_name = canonical_away, game_id,
           travel_miles, fatigue_pts)

  cat(sprintf("[TRAVEL] %d away teams | median distance: %.0f mi | max: %.0f mi\n",
              nrow(travel),
              median(travel$travel_miles, na.rm = TRUE),
              max(travel$travel_miles, na.rm = TRUE)))

  long_haul <- travel %>% filter(travel_miles > 1500)
  if (nrow(long_haul) > 0) {
    cat(sprintf("[TRAVEL] Long-haul trips (>1500 mi): %s\n",
                paste(sprintf("%s (%.0f mi, %.1f pts)",
                              long_haul$canonical_name,
                              long_haul$travel_miles,
                              long_haul$fatigue_pts),
                      collapse = " | ")))
  }

  assign("travel_fatigue", travel, envir = .GlobalEnv)
  invisible(travel)
}

calculate_travel_fatigue()
cat("[TRAVEL] TRAVEL_FATIGUE_CFB.R complete.\n")
