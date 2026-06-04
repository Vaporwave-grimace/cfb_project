# firecrawl_utils.R (CFB)
# HTTP helper for Firecrawl REST API (v1/scrape).
# Used as primary scraper for JS-rendered or SSL-blocked sites.
#
# Requires: firecrawl_api_key in credentials.json (project root)

library(httr2)

FIRECRAWL_SCRAPE_URL <- "https://api.firecrawl.dev/v1/scrape"

if (!exists("%||%")) `%||%` <- function(a, b) if (!is.null(a) && length(a) > 0) a else b

.fc_api_key <- NULL

fc_api_key <- function() {
  if (!is.null(.fc_api_key)) return(.fc_api_key)
  # Try project root credentials.json; fall back one directory up
  creds_path <- if (file.exists("credentials.json")) "credentials.json"
                else if (file.exists("../credentials.json")) "../credentials.json"
                else NULL
  if (is.null(creds_path)) return(NULL)
  key <- tryCatch(
    jsonlite::fromJSON(creds_path)$firecrawl_api_key,
    error = function(e) NULL
  )
  if (is.null(key) || !nzchar(key)) return(NULL)
  .fc_api_key <<- key
  key
}

firecrawl_available <- function() !is.null(fc_api_key())

#' Scrape a URL via Firecrawl and return the markdown string, or NULL on failure.
firecrawl_scrape <- function(url, timeout_ms = 45000, wait_ms = 5000) {
  key <- fc_api_key()
  if (is.null(key)) {
    cat("[firecrawl] No API key — add firecrawl_api_key to credentials.json\n")
    return(NULL)
  }

  body <- list(
    url     = url,
    formats = list("markdown"),
    timeout = timeout_ms,
    waitFor = wait_ms
  )

  resp <- tryCatch(
    httr2::request(FIRECRAWL_SCRAPE_URL) |>
      httr2::req_headers(
        "Authorization" = paste("Bearer", key),
        "Content-Type"  = "application/json"
      ) |>
      httr2::req_body_json(body) |>
      httr2::req_timeout(ceiling(timeout_ms / 1000) + 20) |>
      httr2::req_perform(),
    error = function(e) {
      cat("[firecrawl] Request error:", conditionMessage(e), "\n")
      NULL
    }
  )

  if (is.null(resp)) return(NULL)

  data <- tryCatch(httr2::resp_body_json(resp), error = function(e) NULL)
  if (is.null(data) || !isTRUE(data$success)) {
    cat("[firecrawl] Scrape failed:", data$error %||% "unknown error", "\n")
    return(NULL)
  }

  data$data$markdown
}

#' Parse a Firecrawl markdown pipe-table into a list of named lists.
#' Strips verbose FanGraphs-style column descriptions (after <br>).
#' Extracts link text from Markdown [text](url) links.
parse_markdown_table <- function(markdown) {
  if (is.null(markdown) || !nzchar(markdown)) return(list())

  lines <- strsplit(markdown, "\n")[[1]]
  table_lines <- grep("^\\|", lines, value = TRUE)
  if (length(table_lines) < 3) return(list())

  raw_hdr   <- strsplit(table_lines[1], "\\|", fixed = TRUE)[[1]]
  col_names <- trimws(raw_hdr)
  col_names <- sub("<br>.*",    "", col_names)
  col_names <- sub("\\\\-\\\\-.*", "", col_names)
  col_names <- gsub("\\\\", "", col_names)
  col_names <- trimws(col_names)

  data_lines <- table_lines[-(1:2)]

  lapply(data_lines, function(line) {
    cells <- strsplit(line, "\\|", fixed = TRUE)[[1]]
    cells <- trimws(cells)
    cells <- gsub("\\[([^]]+)\\]\\([^)]+\\)", "\\1", cells)
    if (length(cells) < length(col_names))
      cells <- c(cells, rep("", length(col_names) - length(cells)))
    else if (length(cells) > length(col_names))
      cells <- cells[seq_along(col_names)]
    row <- setNames(as.list(cells), col_names)
    row[nzchar(names(row))]
  })
}
