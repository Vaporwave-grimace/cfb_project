# ==============================================================================
# scrape_portal_on3.R — On3 Transfer Portal Team Rankings via Firecrawl
#
# Returns team-level portal data: transfers in/out counts, avg ratings,
# and the On3 portal index score (net talent gain/loss).
#
# Coverage: 2022–present (On3 didn't track team rankings before 2022).
#           Returns empty tibble for year < 2022.
#
# Usage (from build_ml_training_data.R):
#   source("scripts/scrape_portal_on3.R")
#   portal <- scrape_portal_on3(2024)
# ==============================================================================

suppressMessages({
  library(httr)
  library(jsonlite)
  library(dplyr)
  library(purrr)
})

# ── Parser ─────────────────────────────────────────────────────────────────────
# On3 markdown format per team block (50 teams per page load):
#
#   {rank_2digits}
#   [![Team Name](logo_url)Team Name](profile_url) CONF
#   {in_n}Avg. Rating{in_avg}
#   {out_n}Avg. Rating{out_avg}
#   Stars{digits}
#   {index_score}
#
# "Show More Results" truncates at 50 — acceptable for P4/major programs.
# Teams not returned default to NA → imputed as median in ML recipe.

parse_on3_markdown <- function(md, year) {
  lines <- strsplit(md, "\n")[[1]]

  # Locate rank markers (two-digit lines: "01" through "99")
  rank_idx <- grep("^\\d{2}$", lines)
  if (length(rank_idx) == 0) {
    warning(sprintf("[On3 %d] No rank markers found", year))
    return(tibble())
  }

  # Block boundaries: from rank line to one before next rank line
  block_ends <- c(rank_idx[-1] - 1L, length(lines))

  map_dfr(seq_along(rank_idx), function(i) {
    rank    <- as.integer(lines[rank_idx[i]])
    block   <- lines[(rank_idx[i] + 1L):block_ends[i]]
    block_t <- paste(block, collapse = "\n")

    # Team name: [![NAME](logo)NAME](url)
    name_match <- regexpr("\\[!\\[[^\\]]+\\]\\([^\\)]+\\)([^\\]]+)\\]\\(", block_t, perl = TRUE)
    if (name_match == -1L) return(NULL)
    name_raw <- sub(".*\\[!\\[[^\\]]+\\]\\([^\\)]+\\)([^\\]]+)\\]\\(.*", "\\1", block_t)
    team_name <- trimws(name_raw)

    # Transfers In/Out: "NAvg. RatingX.XX" appears twice in order
    hits <- regmatches(block_t,
                       gregexpr("(\\d+)Avg\\. Rating([0-9]+\\.[0-9]+)", block_t, perl = TRUE))[[1]]

    in_n   <- NA_integer_; in_avg  <- NA_real_
    out_n  <- NA_integer_; out_avg <- NA_real_

    if (length(hits) >= 1L) {
      p    <- regmatches(hits[1], regexec("^(\\d+)Avg\\. Rating([0-9]+\\.[0-9]+)$", hits[1]))[[1]]
      in_n <- as.integer(p[2]); in_avg <- as.numeric(p[3])
    }
    if (length(hits) >= 2L) {
      p     <- regmatches(hits[2], regexec("^(\\d+)Avg\\. Rating([0-9]+\\.[0-9]+)$", hits[2]))[[1]]
      out_n <- as.integer(p[2]); out_avg <- as.numeric(p[3])
    }

    # Index score: integer (possibly negative) after "Stars\d+" line
    idx_match <- regmatches(block_t,
                             regexpr("Stars\\d+\\n+\\s*(-?\\d+)", block_t, perl = TRUE))
    index_score <- NA_integer_
    if (length(idx_match) > 0L && nchar(idx_match) > 0L) {
      score_part <- sub("Stars\\d+\\n+\\s*", "", idx_match)
      index_score <- suppressWarnings(as.integer(trimws(score_part)))
    }

    tibble(
      rank                  = rank,
      team_name_raw         = team_name,
      portal_in_n           = in_n,
      portal_in_avg_rating  = in_avg,
      portal_out_n          = out_n,
      portal_out_avg_rating = out_avg,
      portal_index_score    = index_score
    )
  })
}

# ── Main fetch function ────────────────────────────────────────────────────────

scrape_portal_on3 <- function(year, api_key = NULL) {
  if (year < 2022L) {
    cat(sprintf("[On3 portal] %d: no data (available 2022+)\n", year))
    return(tibble())
  }

  if (is.null(api_key)) {
    creds   <- tryCatch(load_credentials(), error = function(e) NULL)
    api_key <- creds$firecrawl_api_key
  }
  if (is.null(api_key) || nchar(api_key) < 5L) {
    warning("[On3 portal] firecrawl_api_key missing — skipping portal data")
    return(tibble())
  }

  url  <- sprintf("https://www.on3.com/transfer-portal/team-rankings/football/%d/", year)
  body <- toJSON(list(
    url     = url,
    formats = list("markdown"),
    timeout = 30000L,
    waitFor = 5000L
  ), auto_unbox = TRUE)

  resp <- tryCatch(
    POST("https://api.firecrawl.dev/v1/scrape",
         add_headers(Authorization = paste("Bearer", api_key)),
         content_type_json(),
         body = body,
         timeout(60)),
    error = function(e) { warning("[On3 portal] Request failed: ", e$message); NULL }
  )

  if (is.null(resp) || http_error(resp)) {
    warning(sprintf("[On3 portal] HTTP error for %d", year))
    return(tibble())
  }

  result <- fromJSON(content(resp, "text", encoding = "UTF-8"))
  if (!isTRUE(result$success)) {
    warning(sprintf("[On3 portal] Firecrawl returned error for %d", year))
    return(tibble())
  }

  md <- result$data$markdown
  if (is.null(md) || nchar(md) < 100L) {
    warning(sprintf("[On3 portal] Empty response for %d", year))
    return(tibble())
  }
  if (grepl("No team rankings available", md, fixed = TRUE)) {
    cat(sprintf("[On3 portal] %d: no team rankings available\n", year))
    return(tibble())
  }

  out <- tryCatch(
    parse_on3_markdown(md, year),
    error = function(e) { warning("[On3 portal] Parse error: ", e$message); tibble() }
  )

  cat(sprintf("[On3 portal] %d: %d teams parsed\n", year, nrow(out)))
  out
}
