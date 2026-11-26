# FDIC failures list: every failure and assistance transaction since 1934,
# one request a night (about 4,100 rows; the list changes a few times a
# year). Each pull is checked, diffed against the stored copy (revisions go
# to failures.revisions.csv) and only then stored, so a bad pull never
# replaces the last good file. Not critical: if this fails, the FDIC marts
# still publish and fail_panel is rebuilt from the stored copy while it is
# under max_age_days old (R/sources.R).
#
# Raw files, in RAW (release data-raw, all with the "failures." prefix):
#   failures.parquet            every row as FDIC sent it (FAILDATE stays
#                               "M/D/YYYY" text), sorted by date then CERT
#   failures.manifest.csv       rows, md5, pulled_at, changes_vs_stored
#   failures.revisions.csv      appended: CERT, FAILDATE, field, old, new, seen
#
# Every RESTYPE is kept. Which rows count as a "failure" is each mart's
# choice, made explicitly (see marts/fail_panel.R).

FDIC_FAILURES_ENDPOINT <- "https://api.fdic.gov/banks/failures"
FAILURE_FIELDS <- paste0(
  "CERT,FIN,NAME,CITY,PSTALP,FAILDATE,FAILYR,RESDATE,RESTYPE,RESTYPE1,",
  "CHCLASS1,SAVR,FUND,QBFASSET,QBFDEP,COST,BIDNAME,BIDCITY,BIDSTATE")
FAILURE_KEY <- c("CERT", "FAILDATE")

# Rows before 1977 have no CERT (488 of them, all before the FDIC
# financials start in 1984, so no mart can join them anyway). Those are
# keyed by name as well.
failure_key <- function(df) {
  paste(df$CERT, df$FAILDATE, ifelse(is.na(df$CERT), df$NAME, ""))
}

# Failures every good pull must contain, with their 2023 dates
FAILURE_ANCHORS <- data.frame(CERT = c(24735L, 57053L, 59017L),
                              name = c("SVB", "Signature", "First Republic"))

failures_path <- function() file.path(RAW, "failures.parquet")

failure_date <- function(x) as.Date(x, format = "%m/%d/%Y")

# The stored copy, or NULL before the first pull
failures_read <- function() {
  if (!file.exists(failures_path())) return(NULL)
  as.data.frame(read_parquet(failures_path()))
}

pull_failures <- function() {
  body <- fdic_query(FDIC_FAILURES_ENDPOINT, list(
    fields = FAILURE_FIELDS, sort_by = "FAILDATE", sort_order = "ASC",
    limit = 10000, offset = 0))
  total <- as.integer(body$meta$total)
  if (total >= 10000) stop("failures: ", total, " rows, past the 10k cap; page the request")
  df <- flatten_body(body)
  if (is.null(df) || nrow(df) != total) {
    stop("failures: got ", if (is.null(df)) 0 else nrow(df), " of ", total, " rows")
  }
  df$ID <- NULL
  df <- df[order(failure_date(df$FAILDATE), df$CERT, df$NAME, df$CITY),
           strsplit(FAILURE_FIELDS, ",")[[1]]]
  rownames(df) <- NULL
  df
}

# stop()s on a bad pull. old = stored copy or NULL.
check_failures <- function(new, old) {
  fail <- function(msg) stop("failures check failed: ", msg)
  d <- failure_date(new$FAILDATE)
  if (anyNA(d)) fail(paste(sum(is.na(d)), "FAILDATE values did not parse as M/D/YYYY"))
  if (any(is.na(new$CERT) & d >= as.Date("1984-01-01"))) fail("rows since 1984 with no CERT")
  if (anyDuplicated(failure_key(new))) fail("duplicate CERT + FAILDATE")
  if (!is.null(old) && nrow(new) < nrow(old)) {
    fail(paste("list shrank from", nrow(old), "to", nrow(new), "rows"))
  }
  for (i in seq_len(nrow(FAILURE_ANCHORS))) {
    hit <- new$CERT == FAILURE_ANCHORS$CERT[i] & format(d, "%Y") == "2023"
    if (!any(hit)) fail(paste(FAILURE_ANCHORS$name[i], "missing or not dated 2023"))
  }
  invisible(TRUE)
}

# Values FDIC changed for failures we already had, and failures that
# vanished. New failures are not revisions. Compared as text.
diff_failures <- function(old, new, seen) {
  if (is.null(old)) return(NULL)
  m <- match(failure_key(old), failure_key(new))
  out <- list()
  if (any(is.na(m))) {
    out$gone <- data.frame(CERT = old$CERT[is.na(m)], FAILDATE = old$FAILDATE[is.na(m)],
                           field = "<row>", old = "present", new = "absent")
  }
  o <- old[!is.na(m), , drop = FALSE]
  n <- new[m[!is.na(m)], , drop = FALSE]
  for (f in setdiff(union(names(o), names(n)), FAILURE_KEY)) {
    a <- if (f %in% names(o)) as.character(o[[f]]) else rep(NA_character_, nrow(o))
    b <- if (f %in% names(n)) as.character(n[[f]]) else rep(NA_character_, nrow(n))
    same <- (is.na(a) & is.na(b)) | (!is.na(a) & !is.na(b) & a == b)
    if (any(!same)) {
      out[[f]] <- data.frame(CERT = o$CERT[!same], FAILDATE = o$FAILDATE[!same],
                             field = f, old = a[!same], new = b[!same])
    }
  }
  if (!length(out)) return(NULL)
  d <- do.call(rbind, out); d$seen <- seen; rownames(d) <- NULL
  d
}

failures_run <- function(ctx) {
  new <- pull_failures()
  old <- failures_read()
  check_failures(new, old)
  rev <- diff_failures(old, new, ctx$seen)
  write_parquet(new, failures_path(), compression = "zstd")
  manifest <- data.frame(
    n_rows = nrow(new), md5 = unname(tools::md5sum(failures_path())),
    pulled_at = ctx$seen,
    changes_vs_stored = if (is.null(old)) NA_integer_ else if (is.null(rev)) 0L else nrow(rev))
  utils::write.csv(manifest, file.path(RAW, "failures.manifest.csv"), row.names = FALSE)
  cat(sprintf("  failures %5d rows, newest %s, changes: %s\n", nrow(new),
              format(max(failure_date(new$FAILDATE))),
              if (is.null(old)) "first pull" else manifest$changes_vs_stored))
  if (!is.null(rev)) {
    rev_path <- file.path(RAW, "failures.revisions.csv")
    utils::write.table(rev, rev_path, sep = ",", row.names = FALSE,
                       col.names = !file.exists(rev_path),
                       append = file.exists(rev_path))
    cat("failures revisions logged:", nrow(rev), "->", rev_path, "\n")
  }
  manifest
}

# When the stored file was last pulled successfully (NA if never)
failures_last_pull <- function() {
  path <- file.path(RAW, "failures.manifest.csv")
  if (!file.exists(path)) return(as.POSIXct(NA))
  as.POSIXct(utils::read.csv(path)$pulled_at[1], format = "%Y-%m-%dT%H:%M:%S%z")
}

# max_age_days 35: the panel this replaces was refreshed monthly, so a
# stored list up to about a month old is never worse than before
SOURCE_FAILURES <- list(
  name = "failures", critical = FALSE, cadence = "nightly", max_age_days = 35,
  run = failures_run, last_pull = failures_last_pull
)
