# FDIC financials: every bank, one request (or a few pages) per quarter.
# Loops over quarters, never over banks.

HISTORY_START <- 19840331L   # first quarter in the FDIC API
PAGE_SIZE     <- 10000L
RAW_FIELDS    <- paste0(APP_FIELDS, ",CITY")

# The quarters to pull, newest first: the last n, or the newest plus an
# explicit sample (sample = integer vector, or NULL)
fdic_quarters <- function(newest, n, sample = NULL) {
  if (!is.null(sample)) {
    return(sort(unique(c(newest, sample)), decreasing = TRUE))
  }
  quarters <- newest
  while (length(quarters) < n &&
         quarters[length(quarters)] > HISTORY_START) {
    quarters <- c(quarters, prev_quarter_end(quarters[length(quarters)]))
  }
  quarters
}

# Every bank for one quarter, paging past the 10k cap, sorted by CERT so
# the file is deterministic and diffs line up.
pull_quarter <- function(rd) {
  pages <- list(); offset <- 0L; total <- NA_integer_
  repeat {
    body <- fdic_query(FDIC_FINANCIALS_ENDPOINT, list(
      filters = paste0("RISDATE:", rd), fields = RAW_FIELDS,
      sort_by = "CERT", sort_order = "ASC",
      limit = PAGE_SIZE, offset = offset
    ))
    total <- as.integer(body$meta$total)
    page  <- flatten_body(body)
    if (is.null(page) || nrow(page) == 0) break
    pages[[length(pages) + 1]] <- page
    offset <- offset + nrow(page)
    if (offset >= total) break
  }
  if (length(pages) == 0) return(NULL)
  df <- do.call(rbind, pages)
  df$ID <- NULL                                  # "CERT_RISDATE", redundant
  if (nrow(df) != total) stop("Quarter ", rd, ": got ", nrow(df), " of ", total)
  if (anyDuplicated(df$CERT)) stop("Quarter ", rd, ": duplicate CERTs")
  df <- df[order(df$CERT), c("CERT", setdiff(sort(names(df)), "CERT"))]
  rownames(df) <- NULL
  df
}

# Pull each quarter, diff it against the stored copy and overwrite it.
# Returns this run's manifest rows and the list of revision tables.
pull_fdic <- function(quarters, seen) {
  manifest <- list(); revisions <- list()
  for (rd in quarters) {
    t1 <- Sys.time()
    df <- pull_quarter(rd)
    if (is.null(df)) stop("Quarter ", rd, " came back empty")
    s <- store_quarter(df, rd, seen, t1)
    manifest[[length(manifest) + 1]] <- s$manifest
    if (!is.null(s$revisions)) revisions[[length(revisions) + 1]] <- s$revisions
  }
  list(manifest = do.call(rbind, manifest), revisions = revisions)
}
