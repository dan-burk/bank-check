# Data pipeline: pull the last N quarters for every bank, store one parquet
# file per quarter, log any FDIC revisions against the copy already on disk,
# build the marts the app reads, and check them. Stops with an error (and
# writes no marts) if any check fails. Design: see pipeline/README.md.
#
# Run from the repo root:
#   Rscript.exe pipeline/build.R          # last 10 quarters
#   Rscript.exe pipeline/build.R 40       # last 40 quarters
#   Rscript.exe pipeline/build.R 171      # backfill: 1984 Q1 to now
#   Rscript.exe pipeline/build.R 19841231,19880630   # a sample, plus the
#                                         # newest quarter (local testing:
#                                         # gaps are reported, not failed)
#
# Output (gitignored), under pipeline/out/:
#   raw/risdate.YYYYMMDD.parquet   every bank, one quarter, APP_FIELDS + CITY
#   raw/manifest.csv               one row per quarter on hand (merged with
#                                  the stored manifest by risdate)
#   revisions.csv                  appended: every value FDIC changed since
#                                  the last pull (quarter, CERT, field, old, new)
#   marts/industry_quarterly.parquet  statement lines summed, one row per quarter
#   marts/latest_snapshot.parquet     newest quarter, one row per bank, plus
#                                     the active directory (NAME, active flag)
#   marts/field_coverage.parquet      per quarter and statement field: banks
#                                     reporting it and their share of assets
#
# API etiquette: one request at a time, at least 2 s apart, 3 retries with
# growing waits, then stop. Loops over quarters, never over banks.

suppressPackageStartupMessages(library(nanoparquet))

ARG <- commandArgs(trailingOnly = TRUE)[1]
SAMPLE <- !is.na(ARG) && grepl(",", ARG)   # explicit quarter list
N_QUARTERS  <- if (SAMPLE) NA_integer_ else as.integer(ARG)
if (!SAMPLE && is.na(N_QUARTERS)) N_QUARTERS <- 10L
HISTORY_START <- 19840331L   # first quarter in the FDIC API
RECENT <- 10L                # quarters where any gap fails the run
MIN_GAP_S   <- 2
RETRY_WAITS <- c(10, 30, 90)
PAGE_SIZE   <- 10000L

OUT   <- normalizePath(file.path("pipeline", "out"), mustWork = FALSE)
RAW   <- file.path(OUT, "raw")
MARTS <- file.path(OUT, "marts")
for (d in c(RAW, MARTS)) dir.create(d, recursive = TRUE, showWarnings = FALSE)

# The app's API client and statement definitions, unchanged
source(file.path("app", "R", "api.R"))
source(file.path("app", "R", "statements.R"))
RAW_FIELDS <- paste0(APP_FIELDS, ",CITY")

# ---- Throttled transport ---------------------------------------------------
# Replaces fdic_query() for everything sourced above (latest_risdate,
# count_quarter), so no request anywhere in this run skips the throttle.
.last_request <- 0
.n_requests   <- 0L
fdic_query_raw <- fdic_query
fdic_query <- function(endpoint, params) {
  for (attempt in 0:length(RETRY_WAITS)) {
    wait <- MIN_GAP_S - (as.numeric(Sys.time()) - .last_request)
    if (wait > 0) Sys.sleep(wait)
    .last_request <<- as.numeric(Sys.time())
    .n_requests   <<- .n_requests + 1L
    res <- tryCatch(fdic_query_raw(endpoint, params), error = function(e) e)
    if (!inherits(res, "error")) return(res)
    if (attempt == length(RETRY_WAITS)) {
      stop("FDIC request failed after ", attempt + 1, " tries: ",
           conditionMessage(res))
    }
    message("  request failed (", conditionMessage(res), "); retrying in ",
            RETRY_WAITS[attempt + 1], " s")
    Sys.sleep(RETRY_WAITS[attempt + 1])
  }
}

# ---- Extract ---------------------------------------------------------------
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

# ---- Change check ----------------------------------------------------------
# Every value that differs between the stored copy and the new pull, keyed by
# CERT. Numbers compare with a small tolerance (JSON round-trips can wobble
# in the last digit); NA vs a value counts as a change.
diff_quarter <- function(old, new, rd, seen) {
  out <- list()
  gone  <- setdiff(old$CERT, new$CERT)
  added <- setdiff(new$CERT, old$CERT)
  if (length(gone))  out$gone  <- data.frame(risdate = rd, CERT = gone,  field = "<bank>", old = "present", new = "absent")
  if (length(added)) out$added <- data.frame(risdate = rd, CERT = added, field = "<bank>", old = "absent",  new = "present")
  both <- intersect(old$CERT, new$CERT)
  o <- old[match(both, old$CERT), , drop = FALSE]
  n <- new[match(both, new$CERT), , drop = FALSE]
  for (f in union(setdiff(names(o), "CERT"), setdiff(names(n), "CERT"))) {
    a <- if (f %in% names(o)) o[[f]] else rep(NA, length(both))
    b <- if (f %in% names(n)) n[[f]] else rep(NA, length(both))
    if (is.numeric(a) && is.numeric(b)) {
      same <- (is.na(a) & is.na(b)) |
              (!is.na(a) & !is.na(b) & abs(a - b) <= 1e-9 * pmax(1, abs(a)))
    } else {
      a <- as.character(a); b <- as.character(b)
      same <- (is.na(a) & is.na(b)) | (!is.na(a) & !is.na(b) & a == b)
    }
    if (any(!same)) {
      out[[f]] <- data.frame(risdate = rd, CERT = both[!same], field = f,
                             old = as.character(a[!same]),
                             new = as.character(b[!same]))
    }
  }
  if (length(out) == 0) return(NULL)
  d <- do.call(rbind, out); d$seen <- seen; rownames(d) <- NULL
  d
}

raw_path <- function(rd) file.path(RAW, paste0("risdate.", rd, ".parquet"))

# ---- Run -------------------------------------------------------------------
t0 <- Sys.time()
newest <- latest_risdate()
if (is.na(newest)) stop("FDIC API returned no quarters")
quarters <- newest
if (SAMPLE) {
  quarters <- sort(unique(c(newest, as.integer(strsplit(ARG, ",")[[1]]))),
                   decreasing = TRUE)
} else {
  while (length(quarters) < N_QUARTERS &&
         quarters[length(quarters)] > HISTORY_START) {
    quarters <- c(quarters, prev_quarter_end(quarters[length(quarters)]))
  }
}
cat("Pulling", length(quarters), "quarters:", min(quarters), "to", newest, "\n")

seen <- format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
manifest <- list(); revisions <- list()
for (rd in quarters) {
  t1 <- Sys.time()
  df <- pull_quarter(rd)
  if (is.null(df)) stop("Quarter ", rd, " came back empty")

  path <- raw_path(rd)
  n_changes <- NA_integer_
  if (file.exists(path)) {
    d <- diff_quarter(as.data.frame(read_parquet(path)), df, rd, seen)
    n_changes <- if (is.null(d)) 0L else nrow(d)
    if (!is.null(d)) revisions[[length(revisions) + 1]] <- d
  }
  write_parquet(df, path, compression = "zstd")

  manifest[[length(manifest) + 1]] <- data.frame(
    risdate = rd, n_banks = nrow(df), n_fields = ncol(df),
    bytes = file.size(path),
    md5 = unname(tools::md5sum(path)),
    pulled_at = seen,
    changes_vs_stored = n_changes,
    seconds = round(as.numeric(difftime(Sys.time(), t1, units = "secs")), 1)
  )
  cat(sprintf("  %d  %5d banks  %6.0f KB  changes: %s\n", rd, nrow(df),
              file.size(path) / 1024,
              if (is.na(n_changes)) "first pull" else n_changes))
}

# Merge into the stored manifest, so quarters pulled by an earlier run
# (the backfill) keep their rows
manifest <- do.call(rbind, manifest)
man_path <- file.path(RAW, "manifest.csv")
if (file.exists(man_path)) {
  old <- utils::read.csv(man_path)
  manifest <- rbind(old[!old$risdate %in% manifest$risdate, names(manifest)],
                    manifest)
}
manifest <- manifest[order(-manifest$risdate), ]
utils::write.csv(manifest, man_path, row.names = FALSE)

rev_path <- file.path(OUT, "revisions.csv")
if (length(revisions)) {
  rev <- do.call(rbind, revisions)
  utils::write.table(rev, rev_path, sep = ",", row.names = FALSE,
                     col.names = !file.exists(rev_path),
                     append = file.exists(rev_path))
  cat("Revisions logged:", nrow(rev), "->", rev_path, "\n")
}

# ---- Marts: industry_quarterly, field_coverage -----------------------------
# Built from every raw quarter on disk (not just this run), with the app's
# own industry_totals() so the numbers match the Industry tab exactly.
# raw_sums are plain sums for the aggregation cross-check below.
AGG_FIELDS <- c("ASSET", "LIAB", "EQTOT", "DEP", "NETINCQ",
                "LNLSGR", "P3LNLS", "NCLNLS")
files <- sort(list.files(RAW, pattern = "^risdate\\.\\d{8}\\.parquet$",
                         full.names = TRUE), decreasing = TRUE)
ind <- list(); cov <- list(); raw_sums <- list()
for (f in files) {
  x <- as.data.frame(read_parquet(f))
  ind[[f]] <- industry_totals(x)
  cov[[f]] <- field_coverage(x)
  raw_sums[[f]] <- data.frame(
    RISDATE = as.integer(x$RISDATE[1]), n = nrow(x),
    as.list(colSums(x[AGG_FIELDS], na.rm = TRUE)),
    NETINC = sum(x$NETINC, na.rm = TRUE))
}
ind <- do.call(rbind, ind); cov <- do.call(rbind, cov)
raw_sums <- do.call(rbind, raw_sums)
rownames(ind) <- rownames(cov) <- rownames(raw_sums) <- NULL
ind$RISDATE <- as.integer(ind$RISDATE)

# Coverage report: every field and quarter below 100% of assets
low <- cov[cov$asset_share < 1, ]
if (nrow(low)) {
  cat("Field coverage below 100% of assets (* = below COVERAGE_MIN, mart NA):\n")
  for (k in unique(low$field)) {
    l <- low[low$field == k, ]
    cat(sprintf("  %-8s %s\n", k, paste0(l$RISDATE, ifelse(
      l$asset_share < COVERAGE_MIN, "*", ""), " ",
      formatC(l$asset_share, format = "f", digits = 4), collapse = ", ")))
  }
} else {
  cat("Field coverage: 100% of assets for every field and quarter.\n")
}

# Cross-check 1: FDIC's own server-side sums over the same quarters, one
# request. Aggregate output gives RISDATE as epoch milliseconds.
agg <- flatten_body(fdic_query(FDIC_FINANCIALS_ENDPOINT, list(
  filters = paste0("RISDATE:[", min(ind$RISDATE), " TO ", newest, "]"),
  agg_by = "RISDATE", agg_sum_fields = paste(AGG_FIELDS, collapse = ","),
  agg_limit = 1000, limit = 0)))
agg$RISDATE <- as.integer(format(as.POSIXct(agg$RISDATE / 1000,
  origin = "1970-01-01", tz = "UTC"), "%Y%m%d"))
agg <- agg[match(raw_sums$RISDATE, agg$RISDATE), ]
agg_ok <- !is.na(agg$count) & agg$count == raw_sums$n
for (k in AGG_FIELDS) {
  a <- agg[[paste0("sum_", k)]]; b <- raw_sums[[k]]
  agg_ok <- agg_ok & !is.na(a) & abs(a - b) <= 1e-9 * pmax(1, abs(b))
}

# Cross-check 2: in Q1, quarterly net income is the year to date
q1 <- raw_sums$RISDATE %% 10000L == 331L
q1_gap <- abs(raw_sums$NETINCQ - raw_sums$NETINC) / pmax(1, abs(raw_sums$NETINC))
q1_bad <- raw_sums$RISDATE[q1 & q1_gap > 0.001]
if (length(q1_bad)) cat("Q1 NETINCQ != NETINC (>0.1%):", q1_bad, "\n")

# The quarter sequence must have no holes from the oldest file to newest
want <- newest
while (want[length(want)] > min(ind$RISDATE)) {
  want <- c(want, prev_quarter_end(want[length(want)]))
}
holes <- setdiff(want, ind$RISDATE)
recent <- utils::head(want, RECENT)
if (length(holes)) cat("Quarters missing from raw:", length(holes), "\n")
if (min(ind$RISDATE) > HISTORY_START) {
  cat("History starts at", min(ind$RISDATE), "not", HISTORY_START,
      "(backfill not run yet)\n")
}

# ---- Mart: latest_snapshot -------------------------------------------------
# The newest quarter's filings joined to the FDIC directory of active banks.
# Replaces both the cross-section (peer bands) and the institution list
# (picker). Rows: every bank that filed, plus any active bank that has not
# filed yet (a new charter), so the picker never loses one. Banks that filed
# but are not active (clearing houses, trust-only charters, banks closed
# after quarter end) stay for the peer bands with active = FALSE.
dir_df <- fetch_institutions()
if (is.null(dir_df) || nrow(dir_df) < 3000) {
  stop("Directory came back with ", if (is.null(dir_df)) 0 else nrow(dir_df), " banks")
}
snap <- as.data.frame(read_parquet(raw_path(newest)))
snap$active <- snap$CERT %in% dir_df$CERT
d <- dir_df[match(snap$CERT, dir_df$CERT), ]
snap$NAME <- ifelse(is.na(d$NAME), snap$NAMEFULL, d$NAME)
snap$CITY <- ifelse(is.na(snap$CITY), d$CITY, snap$CITY)
unfiled <- dir_df[!dir_df$CERT %in% snap$CERT, ]
if (nrow(unfiled)) {
  extra <- snap[0, ][seq_len(nrow(unfiled)), ]
  extra$CERT <- unfiled$CERT; extra$NAME <- unfiled$NAME
  extra$CITY <- unfiled$CITY; extra$STALP <- unfiled$STALP
  extra$ASSET <- unfiled$ASSET; extra$active <- TRUE
  snap <- rbind(snap, extra)
}
snap <- snap[order(-ifelse(is.na(snap$ASSET), -Inf, snap$ASSET)), ]
rownames(snap) <- NULL

# ---- Checks: nothing is written unless all pass ---------------------------
check <- function(ok, msg) if (!isTRUE(ok)) stop("Mart check failed: ", msg)
filed <- snap[!is.na(snap$RISDATE), ]
check(length(unique(filed$RISDATE)) == 1, "snapshot mixes quarters")
check(nrow(filed) >= 3000, paste("snapshot has only", nrow(filed), "filers"))
check(sum(snap$active) >= 3000, paste("only", sum(snap$active), "active banks"))
check(!anyDuplicated(snap$CERT), "duplicate CERTs in snapshot")
check(!any(is.na(snap$NAME[snap$active])), "active bank without a name")
need <- c("CERT", "RISDATE", "ASSET", "DEP", "EQ", "LNLSNET", "LNATRES")
check(all(need %in% names(snap)), "snapshot missing core columns")
check(nrow(ind) == length(files), "industry_quarterly row per raw quarter")
check(!anyDuplicated(ind$RISDATE), "duplicate quarters in industry_quarterly")
check(all(ind$ASSET > 1e9), "industry assets below $1T")   # $ thousands; 1984 was $3.7T
check(SAMPLE || length(holes) == 0,
      paste("quarters missing from raw:", paste(utils::head(holes, 10), collapse = ",")))
check(all(manifest$risdate %in% ind$RISDATE), "manifest lists quarters with no raw file")
check(all(cov$asset_share[cov$RISDATE %in% recent] >= COVERAGE_MIN),
      "a statement field is below COVERAGE_MIN in the last 10 quarters")
n_fields <- length(strsplit(STATEMENT_FIELDS, ",")[[1]]) - 2L   # less CERT, RISDATE
check(nrow(cov) == n_fields * nrow(ind),
      paste("field_coverage is not", n_fields, "fields per quarter"))
lowc <- cov[cov$asset_share < COVERAGE_MIN, ]
check(all(is.na(ind[cbind(match(lowc$RISDATE, ind$RISDATE),
                          match(lowc$field, names(ind)))])),
      "a mart value is summed over coverage below COVERAGE_MIN")
check(all(agg_ok), paste("FDIC aggregate sums disagree for",
                         paste(raw_sums$RISDATE[!agg_ok], collapse = ",")))
check(!any(q1_bad %in% recent), "Q1 NETINCQ != NETINC in the last 10 quarters")
check(ind$RISDATE[1] == newest && ind$n_banks[1] == nrow(filed),
      "industry newest quarter disagrees with snapshot")
# Balance sheet identity on the summed industry: assets = liabilities +
# equity (EQTOT includes minority interest), within 0.1%. Quarters where
# LIAB or EQTOT is NA by coverage are skipped and reported.
gap <- abs(ind$ASSET - (ind$LIAB + ind$EQTOT)) / ind$ASSET
if (anyNA(gap)) cat("Identity skipped (LIAB/EQTOT NA):", ind$RISDATE[is.na(gap)], "\n")
check(all(gap < 0.001, na.rm = TRUE), "industry assets != liabilities + equity")
# Industry delinquency and allowance as % of gross loans (Delinquency
# chart). These stay well under 10% even at their 1991 and 2010 peaks;
# outside (0, 10%) means a unit or sum error. NA (coverage) quarters skip.
for (k in c("P3LNLS", "NCLNLS", "LNATRES")) {
  r <- 100 * ind[[k]] / ind$LNLSGR
  check(all(r > 0 & r < 10, na.rm = TRUE),
        paste0("industry ", k, "/LNLSGR outside (0, 10%) in ",
               paste(utils::head(ind$RISDATE[which(!(r > 0 & r < 10))], 5), collapse = ",")))
}
# Quarter-over-quarter bank count moves ~1%; a big drop means a partial pull
n <- ind$n_banks
adj <- utils::tail(ind$RISDATE, -1) ==
  vapply(utils::head(ind$RISDATE, -1), prev_quarter_end, 1L)
check(all((utils::head(n, -1) >= 0.9 * utils::tail(n, -1))[adj]),
      "bank count fell more than 10% between quarters")

write_parquet(ind,  file.path(MARTS, "industry_quarterly.parquet"))
write_parquet(snap, file.path(MARTS, "latest_snapshot.parquet"), compression = "zstd")
write_parquet(cov,  file.path(MARTS, "field_coverage.parquet"))

cat(sprintf("Done: %d requests, %.0f s. Raw %.1f MB across %d quarters.\n",
            .n_requests, as.numeric(difftime(Sys.time(), t0, units = "secs")),
            sum(file.size(files)) / 1048576, length(files)))
cat(sprintf("Marts: industry_quarterly %d rows (%.0f KB); latest_snapshot %d banks, %d active, %d not yet filed (%.0f KB).\n",
            nrow(ind), file.size(file.path(MARTS, "industry_quarterly.parquet")) / 1024,
            nrow(snap), sum(snap$active), nrow(unfiled),
            file.size(file.path(MARTS, "latest_snapshot.parquet")) / 1024))
