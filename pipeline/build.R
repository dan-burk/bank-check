# Data pipeline: pull the last N quarters for every bank, store one parquet
# file per quarter, log any FDIC revisions against the copy already on disk,
# build the marts the app reads, and check them. Stops with an error (and
# writes no marts) if any check fails. Design: see pipeline/README.md.
#
# Run from the repo root:
#   Rscript.exe pipeline/build.R          # last 10 quarters
#   Rscript.exe pipeline/build.R 40       # last 40 quarters
#
# Output (gitignored), under pipeline/out/:
#   raw/risdate.YYYYMMDD.parquet   every bank, one quarter, APP_FIELDS + CITY
#   raw/manifest.csv               one row per quarter pulled in this run
#   revisions.csv                  appended: every value FDIC changed since
#                                  the last pull (quarter, CERT, field, old, new)
#   marts/industry_quarterly.parquet  statement lines summed, one row per quarter
#   marts/latest_snapshot.parquet     newest quarter, one row per bank, plus
#                                     the active directory (NAME, active flag)
#
# API etiquette: one request at a time, at least 2 s apart, 3 retries with
# growing waits, then stop. Loops over quarters, never over banks.

suppressPackageStartupMessages(library(nanoparquet))

N_QUARTERS  <- as.integer(commandArgs(trailingOnly = TRUE)[1])
if (is.na(N_QUARTERS)) N_QUARTERS <- 10L
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
while (length(quarters) < N_QUARTERS) {
  quarters <- c(quarters, prev_quarter_end(quarters[length(quarters)]))
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

manifest <- do.call(rbind, manifest)
utils::write.csv(manifest, file.path(RAW, "manifest.csv"), row.names = FALSE)

rev_path <- file.path(OUT, "revisions.csv")
if (length(revisions)) {
  rev <- do.call(rbind, revisions)
  utils::write.table(rev, rev_path, sep = ",", row.names = FALSE,
                     col.names = !file.exists(rev_path),
                     append = file.exists(rev_path))
  cat("Revisions logged:", nrow(rev), "->", rev_path, "\n")
}

# ---- Mart: industry_quarterly ---------------------------------------------
# Built from every raw quarter on disk (not just this run), with the app's
# own industry_totals() so the numbers match the Industry tab exactly.
files <- sort(list.files(RAW, pattern = "^risdate\\.\\d{8}\\.parquet$",
                         full.names = TRUE), decreasing = TRUE)
ind <- do.call(rbind, lapply(files, function(f) {
  industry_totals(as.data.frame(read_parquet(f)))
}))
ind$RISDATE <- as.integer(ind$RISDATE)

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
check(all(ind$ASSET > 1e10), "industry assets below $10T")   # $ thousands
check(ind$RISDATE[1] == newest && ind$n_banks[1] == nrow(filed),
      "industry newest quarter disagrees with snapshot")
# Balance sheet identity on the summed industry: assets = liabilities +
# equity (EQTOT includes minority interest), within 0.1%
gap <- abs(ind$ASSET - (ind$LIAB + ind$EQTOT)) / ind$ASSET
check(all(gap < 0.001), "industry assets != liabilities + equity")
# Quarter-over-quarter bank count moves ~1%; a big drop means a partial pull
n <- ind$n_banks
check(all(utils::head(n, -1) >= 0.9 * utils::tail(n, -1)),
      "bank count fell more than 10% between quarters")

write_parquet(ind,  file.path(MARTS, "industry_quarterly.parquet"))
write_parquet(snap, file.path(MARTS, "latest_snapshot.parquet"), compression = "zstd")

cat(sprintf("Done: %d requests, %.0f s. Raw %.1f MB across %d quarters.\n",
            .n_requests, as.numeric(difftime(Sys.time(), t0, units = "secs")),
            sum(file.size(files)) / 1048576, length(files)))
cat(sprintf("Marts: industry_quarterly %d rows (%.0f KB); latest_snapshot %d banks, %d active, %d not yet filed (%.0f KB).\n",
            nrow(ind), file.size(file.path(MARTS, "industry_quarterly.parquet")) / 1024,
            nrow(snap), sum(snap$active), nrow(unfiled),
            file.size(file.path(MARTS, "latest_snapshot.parquet")) / 1024))
