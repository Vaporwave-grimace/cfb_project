# ==============================================================================
# scrape_talent_247.R — 247Sports Composite Team Rankings via Firecrawl
#
# Scrapes the 247Sports composite class recruiting rankings for a given year.
# Returns one row per team: team name, total composite score, avg player rating.
#
# URL pattern: https://247sports.com/season/{year}-football/CompositeTeamRankings/
# Coverage: 2013+ (reliable; earlier years may have sparse commits data)
#
# The total composite score (e.g., 317.19 for Georgia 2024) is used as
# `talent_score` — it represents the sum of all recruits' normalized ratings.
# Used as a proxy for incoming talent quality (prior-year class recruited).
#
# Usage (from build_ml_training_data.R):
#   source("scripts/scrape_talent_247.R")
#   talent <- scrape_talent_247(2024)  # 2024 recruiting class
# ==============================================================================

suppressMessages({
  library(httr)
  library(jsonlite)
  library(dplyr)
  library(purrr)
})

# ── Parser ─────────────────────────────────────────────────────────────────────
# Markdown format per team block (from Firecrawl):
#
#   - N  ← rank as bullet
#   N    ← rank standalone
#   TEAMNAME](logo_url)       ← broken image link tail (ignored)
#   [TEAMNAME](profile_url)   ← team text link  ← we anchor on this
#   [N Commits](profile_url)
#   AVG_RATING                ← bare float like 93.37
#   ## 5-Star N / ## 4-Star N / ## 3-Star N
#   [TOTAL_SCORE](profile_url) ← composite total like 317.19

parse_247_markdown <- function(md, year) {
  lines <- trimws(strsplit(md, "\n")[[1]])
  lines <- lines[nchar(lines) > 0L]

  results <- list()
  n       <- length(lines)
  i       <- 1L

  while (i <= n) {
    line <- lines[i]

    # Detect team profile link: [TEAM](247sports.com/college/SLUG/season/Y-football/commits/)
    # Exclude commit-count links which contain the word "Commits"
    is_team_link <- grepl(
      "^\\[.+\\]\\(https://247sports\\.com/college/[^/]+/season/\\d{4}-football/commits/\\)$",
      line, perl = TRUE
    ) && !grepl("Commits", line, fixed = TRUE)

    if (is_team_link) {
      team_name <- sub("^\\[([^\\]]+)\\].*", "\\1", line, perl = TRUE)

      commits    <- NA_integer_
      avg_rating <- NA_real_
      total_score <- NA_real_

      lookahead <- min(i + 25L, n)
      for (j in seq(i + 1L, lookahead)) {
        lj <- lines[j]

        # [N Commits](url)
        if (is.na(commits) && grepl("^\\[\\d+ Commits\\]", lj, perl = TRUE)) {
          commits <- suppressWarnings(as.integer(
            sub("^\\[(\\d+) Commits\\].*", "\\1", lj)
          ))
        }

        # Bare average rating: two digits, dot, two digits (e.g. 93.37)
        if (is.na(avg_rating) && grepl("^\\d{2}\\.\\d{2}$", lj)) {
          avg_rating <- as.numeric(lj)
        }

        # [TOTAL_SCORE](url) — composite total, typically 3-4 digits then .XX
        if (is.na(total_score) &&
            grepl("^\\[\\d+\\.\\d{2}\\]\\(https://247sports", lj, perl = TRUE)) {
          total_score <- suppressWarnings(as.numeric(
            sub("^\\[([0-9]+\\.[0-9]{2})\\].*", "\\1", lj)
          ))
          break
        }

        # Stop if we hit the next team's link
        next_team <- grepl(
          "^\\[.+\\]\\(https://247sports\\.com/college/[^/]+/season/\\d{4}-football/commits/\\)$",
          lj, perl = TRUE
        ) && !grepl("Commits", lj, fixed = TRUE)
        if (next_team) break
      }

      if (!is.na(total_score)) {
        results[[length(results) + 1L]] <- list(
          team_name_raw      = team_name,
          talent_score       = total_score,
          talent_avg_rating  = avg_rating,
          talent_commits     = commits
        )
      }
    }

    i <- i + 1L
  }

  if (length(results) == 0L) return(tibble())
  bind_rows(map(results, as_tibble))
}

# ── Main fetch ─────────────────────────────────────────────────────────────────

scrape_talent_247 <- function(year, api_key = NULL) {
  if (is.null(api_key)) {
    creds   <- tryCatch(load_credentials(), error = function(e) NULL)
    api_key <- creds$firecrawl_api_key
  }
  if (is.null(api_key) || nchar(api_key) < 5L) {
    warning("[247Sports] firecrawl_api_key missing — skipping talent data")
    return(tibble())
  }

  url  <- sprintf("https://247sports.com/season/%d-football/CompositeTeamRankings/", year)
  body <- toJSON(list(
    url     = url,
    formats = list("markdown"),
    timeout = 30000L,
    waitFor = 8000L
  ), auto_unbox = TRUE)

  resp <- tryCatch(
    POST("https://api.firecrawl.dev/v1/scrape",
         add_headers(Authorization = paste("Bearer", api_key)),
         content_type_json(),
         body = body,
         timeout(90)),
    error = function(e) { warning("[247Sports] Request failed: ", e$message); NULL }
  )

  if (is.null(resp) || http_error(resp)) {
    warning(sprintf("[247Sports] HTTP error for %d", year))
    return(tibble())
  }

  result <- fromJSON(content(resp, "text", encoding = "UTF-8"))
  if (!isTRUE(result$success)) {
    warning(sprintf("[247Sports] Firecrawl error for %d", year))
    return(tibble())
  }

  md <- result$data$markdown
  if (is.null(md) || nchar(md) < 500L) {
    warning(sprintf("[247Sports] Empty/short response for %d", year))
    return(tibble())
  }

  out <- tryCatch(
    parse_247_markdown(md, year),
    error = function(e) { warning("[247Sports] Parse error: ", e$message); tibble() }
  )

  cat(sprintf("[247Sports talent] %d: %d teams parsed\n", year, nrow(out)))
  out
}
