# FRED rates: full history of each series, one keyless fredgraph.csv
# request per series, every night. Nothing is cached: each pull is checked,
# diffed against the stored copy (revisions go to fred.revisions.csv) and
# only then stored, so a bad pull never replaces the last good files.
# Not critical: if this fails, the FDIC marts still publish (R/sources.R).
#
# Raw files, in RAW (release data-raw, all with the "fred." prefix):
#   fred.<SERIES>.csv      date,value. Missing days stay NA (blank), never 0
#   fred.manifest.csv      one row per series: rows, NAs, first/last date,
#                          md5, pulled_at, changes_vs_stored
#   fred.revisions.csv     appended: series, date, old, new, seen
#
# FRED_BASE_URL overrides the endpoint (used to test the failure path).

FRED_BASE <- Sys.getenv("FRED_BASE_URL",
                        "https://fred.stlouisfed.org/graph/fredgraph.csv")

# max_age_days: the newest observation may be at most this old
FRED_SERIES <- utils::read.table(header = TRUE, text = "
  series        freq    max_age_days
  DGS10         daily   7
  MORTGAGE30US  weekly  10
  MORTGAGE15US  weekly  10
")

# Known method changes, flagged in rates_monthly (method_break). Freddie
# Mac's PMMS moved to application data on 2022-11-17: a small level break
# in both mortgage series.
FRED_BREAKS <- data.frame(series = c("MORTGAGE30US", "MORTGAGE15US"),
                          date   = as.Date("2022-11-17"))

FRED_MIN <- 0; FRED_MAX <- 25   # percent
FRED_MAX_SHRINK <- 5L           # rows a series may lose between pulls

fred_path <- function(s) file.path(RAW, paste0("fred.", s, ".csv"))

# fredgraph.csv text -> data.frame(date, value). Blank or "." is missing.
parse_fred <- function(txt, series) {
  d <- utils::read.csv(text = txt, colClasses = "character",
                       na.strings = c("", "."))
  if (!identical(names(d), c("observation_date", series))) {
    stop("FRED ", series, ": unexpected header ", paste(names(d), collapse = ","))
  }
  date  <- as.Date(d[[1]], format = "%Y-%m-%d")
  value <- suppressWarnings(as.numeric(d[[2]]))
  bad <- is.na(date) | (!is.na(d[[2]]) & is.na(value))
  if (any(bad)) stop("FRED ", series, ": ", sum(bad), " rows did not parse")
  data.frame(date = date, value = value)
}

# The stored copy, or NULL before the first pull
fred_read <- function(s) {
  path <- fred_path(s)
  if (!file.exists(path)) return(NULL)
  d <- utils::read.csv(path, colClasses = c("character", "numeric"))
  d$date <- as.Date(d$date)
  d
}

# stop()s on a bad pull. old = stored copy or NULL.
check_fred <- function(new, old, series, max_age_days, today) {
  fail <- function(msg) stop("FRED check failed: ", series, " ", msg)
  ok <- !is.na(new$value)
  if (!any(ok)) fail("has no observations")
  if (anyDuplicated(new$date)) fail("has duplicate dates")
  if (is.unsorted(new$date, strictly = TRUE)) fail("dates are not in order")
  if (any(new$value[ok] < FRED_MIN | new$value[ok] > FRED_MAX)) {
    fail(paste0("has values outside [", FRED_MIN, ", ", FRED_MAX, "]%"))
  }
  newest <- max(new$date[ok])
  if (as.numeric(today - newest) > max_age_days) {
    fail(paste("newest observation", newest, "is older than", max_age_days, "days"))
  }
  if (!is.null(old) && nrow(new) < nrow(old) - FRED_MAX_SHRINK) {
    fail(paste("history shrank from", nrow(old), "to", nrow(new), "rows"))
  }
  invisible(TRUE)
}

# Values FRED changed or dropped for dates we already had. New dates are
# not revisions. NA vs a value counts as a change.
diff_fred <- function(old, new, series, seen) {
  if (is.null(old)) return(NULL)
  b <- new$value[match(old$date, new$date)]
  gone <- !old$date %in% new$date
  same <- !gone & ((is.na(old$value) & is.na(b)) |
                   (!is.na(old$value) & !is.na(b) & abs(old$value - b) <= 1e-9))
  if (all(same)) return(NULL)
  data.frame(series = series, date = format(old$date[!same]),
             old = ifelse(is.na(old$value[!same]), "", as.character(old$value[!same])),
             new = ifelse(gone[!same], "absent",
                          ifelse(is.na(b[!same]), "", as.character(b[!same]))),
             seen = seen)
}

# Pull every series, check them all, then store them all
fred_run <- function(ctx) {
  new <- list()
  for (s in FRED_SERIES$series) {
    new[[s]] <- parse_fred(polite_get(paste0(FRED_BASE, "?id=", s), "FRED"), s)
  }
  old <- lapply(stats::setNames(nm = FRED_SERIES$series), fred_read)
  for (i in seq_len(nrow(FRED_SERIES))) {
    s <- FRED_SERIES$series[i]
    check_fred(new[[s]], old[[s]], s, FRED_SERIES$max_age_days[i], ctx$today)
  }
  revisions <- list(); manifest <- list()
  for (s in FRED_SERIES$series) {
    d <- diff_fred(old[[s]], new[[s]], s, ctx$seen)
    if (!is.null(d)) revisions[[s]] <- d
    utils::write.csv(data.frame(date = format(new[[s]]$date), value = new[[s]]$value),
                     fred_path(s), row.names = FALSE, quote = FALSE, na = "")
    ok <- !is.na(new[[s]]$value)
    manifest[[s]] <- data.frame(
      series = s, n_obs = nrow(new[[s]]), n_na = sum(!ok),
      first = format(min(new[[s]]$date)), last = format(max(new[[s]]$date[ok])),
      md5 = unname(tools::md5sum(fred_path(s))), pulled_at = ctx$seen,
      changes_vs_stored = if (is.null(old[[s]])) NA_integer_ else
                            if (is.null(d)) 0L else nrow(d))
    cat(sprintf("  FRED %-12s %6d rows, newest %s, changes: %s\n", s,
                nrow(new[[s]]), manifest[[s]]$last,
                if (is.null(old[[s]])) "first pull" else manifest[[s]]$changes_vs_stored))
  }
  manifest <- do.call(rbind, manifest)
  utils::write.csv(manifest, file.path(RAW, "fred.manifest.csv"), row.names = FALSE)
  if (length(revisions)) {
    rev <- do.call(rbind, revisions)
    rev_path <- file.path(RAW, "fred.revisions.csv")
    utils::write.table(rev, rev_path, sep = ",", row.names = FALSE,
                       col.names = !file.exists(rev_path),
                       append = file.exists(rev_path))
    cat("FRED revisions logged:", nrow(rev), "->", rev_path, "\n")
  }
  manifest
}

# When the stored files were last pulled successfully (NA if never)
fred_last_pull <- function() {
  path <- file.path(RAW, "fred.manifest.csv")
  if (!file.exists(path)) return(as.POSIXct(NA))
  min(as.POSIXct(utils::read.csv(path)$pulled_at, format = "%Y-%m-%dT%H:%M:%S%z"))
}

SOURCE_FRED <- list(
  name = "fred", critical = FALSE, cadence = "nightly",
  max_age_days = max(FRED_SERIES$max_age_days),
  run = fred_run, last_pull = fred_last_pull
)
