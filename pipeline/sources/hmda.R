# HMDA: the CFPB/FFIEC yearly national snapshot of every mortgage
# application (the LAR), cut down to the closed-end 1-4 family first-lien
# loans that FDIC-insured banks originated. Yearly: the snapshot for year Y
# comes out in the summer of Y+1. The pull runs in its own workflow
# (hmda.yml), so it can never block or delay the FDIC marts; the nightly
# registry (R/sources.R) only checks the stored groups (SOURCE_HMDA below).
# Spec: docs/specs/research-pipeline.md.
#
#   Rscript pipeline/sources/hmda.R due          # prints the snapshot years not
#                                                # stored yet that exist, or "none"
#   Rscript pipeline/sources/hmda.R 2018:2025    # pull those years, rebuild the groups
#
# Needs data.table (pipeline-only), the raw call reports for the HMDA years
# in pipeline/out/raw/ (for the dated RSSD -> CERT join) and the stored
# hmda.* files there, if any. Downloads go to pipeline/out/cache/hmda/
# (gitignored, never uploaded); each LAR zip is deleted once its year is
# stored. The multi-GB CSV is streamed (unzip -p, HMDA_CHUNK lines at a
# time), so memory stays bounded.
#
# Raw files, in RAW (release data-raw, all with the "hmda." prefix):
#   hmda.lar.YYYY.parquet  HMDA_LAR_COLS as sent (text) plus CERT: the loans
#                          hmda_filter() keeps, by lenders linked to a CERT
#   hmda.panel.parquet     one row per (year, reporter LEI): transmittal sheet
#                          fields, the panel RSSD and the panel year it came
#                          from, CERT, link status, and the year's filtered
#                          originations (n_loans, usd_k) for every lender
#   hmda.groups.parquet    hmda_groups() over every stored year (R/hmda_book.R)
#   hmda.manifest.csv      one row per year: URLs, size, sha256, the counts
#                          the checks compared, pulled_at
#
# Each year is checked before it is stored: rows read within 0.1% of the
# transmittal sheets' LAR count, unzip exiting cleanly, originated first liens within 10% of the CFPB data
# browser's published count, and at least 90% of bank-originated dollars
# linked to a CERT. A failed year stops the run; years stored before it in
# the same run stay on disk, but hmda.yml uploads nothing unless the whole
# run passed.

HMDA_FIRST_YEAR <- 2018L   # interest_rate, loan_term and intro_rate_period start in 2018
HMDA_BASE  <- "https://files.ffiec.cfpb.gov/static-data/snapshot"
HMDA_AGG   <- "https://ffiec.cfpb.gov/v2/data-browser-api/view/nationwide/aggregations"
HMDA_CACHE <- file.path("pipeline", "out", "cache", "hmda")
HMDA_CHUNK <- 250000L      # LAR lines parsed at a time
HMDA_TS_TOL    <- 0.001    # LAR rows read vs the transmittal sheets' lar_count
HMDA_COUNT_TOL <- 0.10     # first liens vs the published count
HMDA_MATCH_MIN <- 0.90     # share of bank-originated dollars linked to a CERT
HMDA_BANK_AGENCIES <- c("1", "2", "3")   # OCC, FRS, FDIC: banks and savings associations

hmda_url <- function(y, kind) sprintf("%s/%d/%d_public_%s_csv.zip", HMDA_BASE, y, y, kind)
hmda_path <- function(what) file.path(RAW, paste0("hmda.", what))

# The nightly registry entry (R/sources.R), for the hmda_book mart's deps.
# The nightly job pulls nothing from HMDA: pipeline.yml downloads the stored
# hmda.groups.parquet (never hmda.lar.*), and run() only checks that the
# copy is there with the group columns. A missing or broken file fails this
# source alone, so hmda_book is skipped (there is no older copy to fall
# back on: last_pull() is NA), the FDIC marts publish and build.R exits 2.
SOURCE_HMDA <- list(
  name = "hmda", critical = FALSE, cadence = "yearly", max_age_days = Inf,
  run = function(ctx) {
    p <- hmda_path("groups.parquet")
    if (!file.exists(p)) stop("no stored hmda.groups.parquet (hmda.yml has not published one)")
    miss <- setdiff(HB_GROUP_COLS, nanoparquet::read_parquet_schema(p)$name)
    if (length(miss)) stop("hmda.groups.parquet lacks ", paste(miss, collapse = ","))
    p
  },
  last_pull = function() NA)

# HTTP status of a HEAD request (one request, throttled like every other)
hmda_head <- function(url) {
  polite(sub("^[a-z]+://([^/]+).*$", "\\1", url), "HMDA",
         function() curlGetHeaders(url, redirect = TRUE))
}
hmda_status <- function(url) attr(hmda_head(url), "status")

hmda_download <- function(url, dest) {
  polite(sub("^[a-z]+://([^/]+).*$", "\\1", url), "HMDA", function() {
    status <- suppressWarnings(utils::download.file(url, dest, quiet = TRUE, mode = "wb"))
    if (status != 0) stop("download.file returned status ", status)
  })
  dest
}

# The one CSV inside a snapshot zip. Names vary (2020's TS is
# 2020_ts_csv.csv) and the 2025 zips carry __MACOSX entries.
hmda_member <- function(zip) {
  m <- utils::unzip(zip, list = TRUE)$Name
  m <- m[grepl("\\.csv$", m) & !grepl("^__MACOSX/", m)]
  if (length(m) != 1) stop("HMDA ", basename(zip), ": expected one CSV, found ", length(m))
  m
}

# A small zipped CSV (transmittal sheet, panel) as text columns
hmda_small_csv <- function(url) {
  zip <- hmda_download(url, file.path(HMDA_CACHE, basename(url)))
  d <- data.table::fread(cmd = paste("unzip -p", shQuote(zip), shQuote(hmda_member(zip))),
                         colClasses = "character", na.strings = "", showProgress = FALSE)
  data.table::setnames(d, gsub("-", "_", names(d)))
  if ("lei" %in% names(d)) d$lei <- toupper(d$lei)   # see hmda_stream()
  as.data.frame(d)
}

need_cols <- function(d, cols, what) {
  miss <- setdiff(cols, names(d))
  if (length(miss)) stop("HMDA ", what, ": missing columns ", paste(miss, collapse = ","))
  d[cols]
}

# The CFPB data browser's count of originated first liens, all lenders
hmda_published_count <- function(y) {
  txt <- polite_get(sprintf("%s?years=%d&actions_taken=1&lien_statuses=1", HMDA_AGG, y), "HMDA")
  a <- jsonlite::fromJSON(txt)$aggregations
  if (!is.data.frame(a) || nrow(a) != 1) stop("HMDA data browser: no aggregate for ", y)
  as.numeric(a$count)
}

# Year y's reporters: every transmittal sheet (TS) row, with the panel's
# RSSD. The panel exists for 2018-2023 only (checked 2026-11). For a year
# without one, each LEI takes the RSSD of its newest earlier panel year
# (an LEI never changes; a lender that is new since then has none).
hmda_reporters <- function(y, stored_panel) {
  ts <- need_cols(hmda_small_csv(hmda_url(y, "ts")),
                  c("activity_year", "lei", "agency_code", "respondent_name", "lar_count"), "TS")
  if (anyDuplicated(ts$lei)) stop("HMDA TS ", y, ": duplicate LEI")
  if (hmda_status(hmda_url(y, "panel")) == 200L) {
    p <- need_cols(hmda_small_csv(hmda_url(y, "panel")),
                   c("lei", "respondent_rssd", "other_lender_code"), "panel")
    p$rssd_panel_year <- y
  } else {
    if (is.null(stored_panel)) stop("HMDA ", y, ": no panel file and no stored panel to carry from")
    p <- stored_panel[stored_panel$activity_year < y & !is.na(stored_panel$respondent_rssd),
                      c("lei", "respondent_rssd", "other_lender_code", "rssd_panel_year")]
    p <- p[order(-p$rssd_panel_year), ]
    if (!nrow(p)) stop("HMDA ", y, ": no panel, and no earlier panel year stored to carry")
    message("  HMDA ", y, ": no panel file; RSSDs carried from panel years ",
            paste(range(p$rssd_panel_year), collapse = "-"))
  }
  p <- p[!duplicated(p$lei), ]
  m <- match(ts$lei, p$lei)
  rssd <- suppressWarnings(as.integer(p$respondent_rssd[m]))
  data.frame(activity_year = as.integer(ts$activity_year), lei = ts$lei,
             respondent_name = ts$respondent_name, agency_code = ts$agency_code,
             lar_count = as.integer(ts$lar_count),
             other_lender_code = p$other_lender_code[m],
             respondent_rssd = ifelse(!is.na(rssd) & rssd > 0, rssd, NA_integer_),
             rssd_panel_year = ifelse(!is.na(rssd) & rssd > 0, p$rssd_panel_year[m], NA_integer_))
}

# Stream one LAR zip. Returns the kept loans (filtered, lender in keep),
# filtered originations per LEI for every lender, and the counts checked.
hmda_stream <- function(zip, member, keep, chunk = HMDA_CHUNK) {
  con <- pipe(paste("unzip -p", shQuote(zip), shQuote(member)), open = "r")
  done <- FALSE
  on.exit(if (!done) close(con))
  cols <- gsub("-", "_", strsplit(readLines(con, n = 1), ",", fixed = TRUE)[[1]])
  miss <- setdiff(HMDA_LAR_COLS, cols)
  if (length(miss)) stop("HMDA LAR: missing columns ", paste(miss, collapse = ","))
  hdr <- paste(cols, collapse = ",")
  kept <- list(); lenders <- list(); n_lines <- 0; n_first_lien <- 0
  repeat {
    lines <- readLines(con, n = chunk)
    if (!length(lines)) break
    d <- data.table::fread(text = c(hdr, lines), select = HMDA_LAR_COLS, sep = ",",
                           colClasses = "character", na.strings = "", showProgress = FALSE)
    if (nrow(d) != length(lines)) {
      stop("HMDA LAR: ", length(lines), " lines parsed into ", nrow(d), " rows")
    }
    # LEIs are upper case by standard, but the 2018 files disagree on case
    # for 84 lenders (lower in one file, upper in another), so every LEI
    # read is upper-cased
    d$lei <- toupper(d$lei)
    n_lines <- n_lines + length(lines)
    n_first_lien <- n_first_lien + sum(hmda_first_lien(d) %in% TRUE)
    f <- d[hmda_filter(d) %in% TRUE]
    lenders[[length(lenders) + 1]] <- f[, .(n_loans = .N, usd_k = sum(hmda_num(loan_amount)) / 1000),
                                        by = lei]
    kept[[length(kept) + 1]] <- f[lei %in% keep]
  }
  done <- TRUE
  status <- close(con)
  if (!is.null(status) && status != 0) stop("unzip -p exited with status ", status)
  lenders <- data.table::rbindlist(lenders)[, .(n_loans = sum(n_loans), usd_k = sum(usd_k)), by = lei]
  list(lar = data.table::rbindlist(kept), lenders = as.data.frame(lenders),
       n_lines = n_lines, n_first_lien = n_first_lien)
}

# stop()s on a bad year, before anything of it is stored. Returns the
# bank-dollar match share.
check_hmda_year <- function(y, s, reporters, published, fdic_rssd) {
  fail <- function(msg) stop("HMDA check failed: ", y, " ", msg)
  # Not exact: the 2018 snapshot LAR has 562 fewer rows than its own
  # transmittal sheets count (15,119,651 vs 15,120,213; every line of the
  # file was read). A truncated stream fails unzip's exit status instead.
  ts_n <- sum(reporters$lar_count)
  if (abs(s$n_lines / ts_n - 1) > HMDA_TS_TOL) {
    fail(sprintf("read %d LAR rows, the transmittal sheets count %d", s$n_lines, ts_n))
  }
  ratio <- s$n_first_lien / published
  if (!is.finite(ratio) || abs(ratio - 1) > HMDA_COUNT_TOL) {
    fail(sprintf("%d originated first liens, the data browser publishes %d", s$n_first_lien, published))
  }
  r <- reporters[match(s$lenders$lei, reporters$lei), ]
  if (anyNA(r$lei)) fail(paste(sum(is.na(r$lei)), "LAR lenders missing from the transmittal sheets"))
  # A bank lender: supervised by a bank regulator, or an RSSD that files
  # call reports. Large banks report to the CFPB (agency 9), so the RSSD
  # test catches them; credit unions and mortgage companies have neither.
  bank <- r$agency_code %in% HMDA_BANK_AGENCIES | r$link == "matched" |
    r$respondent_rssd %in% fdic_rssd
  share <- sum(s$lenders$usd_k[bank & r$link == "matched"]) / sum(s$lenders$usd_k[bank])
  if (!is.finite(share) || share < HMDA_MATCH_MIN) {
    fail(sprintf("only %.1f%% of bank-originated dollars link to a CERT", 100 * share))
  }
  if (anyNA(s$lar$CERT)) fail("kept loans without a CERT")
  share
}

# Pull, check and store one year. Returns the year's panel rows.
hmda_year <- function(y, ids, stored_panel) {
  t1 <- Sys.time()
  reporters <- hmda_links(hmda_reporters(y, stored_panel), ids)
  links <- reporters[reporters$link == "matched", ]
  url <- hmda_url(y, "lar")
  head <- hmda_head(url)
  if (attr(head, "status") != 200L) stop("HMDA ", y, ": LAR snapshot not found at ", url)
  hval <- function(h) {
    v <- grep(paste0("^", h, ":"), head, ignore.case = TRUE, value = TRUE)
    if (length(v)) trimws(sub("^[^:]+:", "", v[length(v)])) else NA_character_
  }
  zip <- file.path(HMDA_CACHE, basename(url))
  if (!file.exists(zip) || file.size(zip) != as.numeric(hval("content-length"))) {
    message("  HMDA ", y, ": downloading ", url)
    hmda_download(url, zip)
  }
  if (file.size(zip) != as.numeric(hval("content-length"))) stop("HMDA ", y, ": short download")
  message("  HMDA ", y, ": streaming ", basename(zip))
  s <- hmda_stream(zip, hmda_member(zip), links$lei)
  s$lar$CERT <- links$CERT[match(s$lar$lei, links$lei)]
  published <- hmda_published_count(y)
  fdic_rssd <- unique(ids$RSSDID[!is.na(ids$RSSDID) & ids$RSSDID > 0])
  share <- check_hmda_year(y, s, reporters, published, fdic_rssd)

  m <- match(reporters$lei, s$lenders$lei)
  reporters$n_loans <- ifelse(is.na(m), 0L, s$lenders$n_loans[m])   # a TS with no such loans
  reporters$usd_k   <- ifelse(is.na(m), 0, s$lenders$usd_k[m])
  nanoparquet::write_parquet(as.data.frame(s$lar), hmda_path(sprintf("lar.%d.parquet", y)),
                             compression = "zstd")
  man <- data.frame(
    year = y, lar_url = url, lar_bytes = file.size(zip),
    lar_last_modified = hval("last-modified"),
    lar_sha256 = unname(tools::sha256sum(zip)),
    rssd_panel_years = paste(unique(range(links$rssd_panel_year)), collapse = "-"),
    lar_rows = s$n_lines, ts_lar_count = sum(reporters$lar_count), first_liens = s$n_first_lien, published_first_liens = published,
    filtered_all_lenders = sum(s$lenders$n_loans), bank_rows = nrow(s$lar),
    bank_usd_linked = round(share, 4), reporters = nrow(reporters),
    linked_leis = nrow(links), linked_certs = length(unique(links$CERT)),
    seconds = round(as.numeric(difftime(Sys.time(), t1, units = "secs"))),
    pulled_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"))
  message(sprintf("  HMDA %d: %d rows (TS %+d), %d first liens vs %d published (%+.1f%%), %d kept by %d banks, %.1f%% of bank dollars linked, %.0f s",
                  y, s$n_lines, man$ts_lar_count - s$n_lines, s$n_first_lien, published, 100 * (s$n_first_lien / published - 1),
                  nrow(s$lar), man$linked_certs, 100 * share, man$seconds))
  unlink(zip)   # the parquet is the useful part; the zip is GBs
  list(panel = reporters, manifest = man)
}

# ---- Groups over every stored year -------------------------------------------
check_hmda_groups <- function(g, years) {
  fail <- function(msg) stop("HMDA groups check failed: ", msg)
  key <- c("CERT", "year", "term_m", "coupon", "fixed", "reset_m", "kept")
  if (anyDuplicated(g[key])) fail("duplicate group key")
  if (!setequal(unique(g$year), years)) fail("years differ from the stored LAR files")
  if (any(g$n <= 0) || any(!(g$usd_k > 0))) fail("a group with no loans or dollars")
  s <- hmda_group_summary(g)
  if (anyNA(s$kept_share) || any(s$kept_share < 0 | s$kept_share > 1)) {
    fail("kept_share outside [0, 1]")
  }
  s
}

# Reported, not failed: per year, how much is kept and how much of it has
# a coupon, a term and a known fixed/ARM status.
report_hmda_groups <- function(g) {
  for (y in sort(unique(g$year))) {
    d <- g[g$year == y, ]; k <- d[d$kept, ]
    message(sprintf("  groups %d: %6d rows, %4d banks, $%5.0fB originated, kept %4.1f%%; of kept $: coupon %5.1f%%, term %5.1f%%, fixed/ARM known %5.1f%%",
                    y, nrow(d), length(unique(d$CERT)), sum(d$usd_k) / 1e6,
                    100 * sum(k$usd_k) / sum(d$usd_k),
                    100 * sum(k$usd_k[!is.na(k$coupon)]) / sum(k$usd_k),
                    100 * sum(k$usd_k[!is.na(k$term_m)]) / sum(k$usd_k),
                    100 * sum(k$usd_k[!is.na(k$fixed)]) / sum(k$usd_k)))
  }
}

hmda_lar_years <- function() {
  f <- list.files(RAW, pattern = "^hmda\\.lar\\.\\d{4}\\.parquet$")
  sort(as.integer(sub("^hmda\\.lar\\.(\\d{4})\\.parquet$", "\\1", f)))
}

# One LAR file at a time, so memory holds one year of loans
hmda_build_groups <- function() {
  years <- hmda_lar_years()
  g <- do.call(rbind, lapply(years, function(y) {
    hmda_groups(nanoparquet::read_parquet(hmda_path(sprintf("lar.%d.parquet", y))))
  }))
  check_hmda_groups(g, years)
  report_hmda_groups(g)
  nanoparquet::write_parquet(g, hmda_path("groups.parquet"), compression = "zstd")
  message(sprintf("Wrote hmda.groups.parquet: %d rows, %.0f KB", nrow(g),
                  file.size(hmda_path("groups.parquet")) / 1024))
}

# ---- Entry points ------------------------------------------------------------
hmda_stored <- function() {
  p <- hmda_path("manifest.csv")
  if (file.exists(p)) utils::read.csv(p) else NULL
}

# Snapshot years that exist but are not stored. In a normal month this is
# one HEAD request (for max(stored) + 1, which is not out yet).
hmda_due <- function() {
  man <- hmda_stored()
  y <- if (is.null(man)) HMDA_FIRST_YEAR else max(man$year) + 1L
  due <- integer(0)
  while (hmda_status(hmda_url(y, "lar")) == 200L) { due <- c(due, y); y <- y + 1L }
  due
}

hmda_run <- function(years) {
  dir.create(HMDA_CACHE, recursive = TRUE, showWarnings = FALSE)
  if (any(years < HMDA_FIRST_YEAR)) stop("HMDA years start in ", HMDA_FIRST_YEAR)
  ids <- read_id_history(raw_files())
  have <- unique(ids$RISDATE %/% 10000L)
  if (!all(years %in% have)) {
    stop("no raw call reports on hand for ", paste(setdiff(years, have), collapse = ","))
  }
  panel_path <- hmda_path("panel.parquet")
  panel <- if (file.exists(panel_path)) as.data.frame(nanoparquet::read_parquet(panel_path))
  man <- hmda_stored()
  for (y in sort(years)) {
    r <- hmda_year(y, ids, panel)
    panel <- rbind(panel[panel$activity_year != y, ], r$panel)
    panel <- panel[order(panel$activity_year, panel$lei), ]
    rownames(panel) <- NULL
    man <- rbind(man[man$year != y, ], r$manifest)
    man <- man[order(man$year), ]
    nanoparquet::write_parquet(panel, panel_path)
    utils::write.csv(man, hmda_path("manifest.csv"), row.names = FALSE)
  }
  hmda_build_groups()
}

# "2018:2025,2027" -> 2018:2025, 2027
hmda_parse_years <- function(arg) {
  parts <- strsplit(strsplit(arg, ",", fixed = TRUE)[[1]], ":", fixed = TRUE)
  y <- unlist(lapply(parts, function(p) {
    p <- as.integer(p)
    if (anyNA(p) || length(p) > 2) stop("bad years argument: ", arg)
    if (length(p) == 2) p[1]:p[2] else p
  }))
  sort(unique(y))
}

if (sys.nframe() == 0L) {
  suppressPackageStartupMessages({ library(nanoparquet); library(data.table) })
  options(timeout = 3600)
  OUT <- normalizePath(file.path("pipeline", "out"), mustWork = FALSE)
  RAW <- file.path(OUT, "raw")
  source(file.path("app", "R", "api.R"))
  for (f in c("R/http.R", "R/store.R", "marts/bank_ids.R", "R/hmda_book.R")) {
    source(file.path("pipeline", f))
  }
  arg <- commandArgs(trailingOnly = TRUE)[1]
  if (is.na(arg)) stop("usage: Rscript pipeline/sources/hmda.R due | YEARS (e.g. 2018:2025)")
  if (arg == "due") {
    due <- hmda_due()
    cat(if (length(due)) paste(range(due), collapse = ":") else "none", "\n", sep = "")
  } else {
    t0 <- Sys.time()
    hmda_run(hmda_parse_years(arg))
    # Peak resident memory of this R process (Linux; NA elsewhere)
    hwm <- tryCatch(grep("^VmHWM", readLines("/proc/self/status"), value = TRUE),
                    error = function(e) character(0))
    message(sprintf("HMDA done: %d requests, %.0f s, peak RSS %s", .n_requests,
                    as.numeric(difftime(Sys.time(), t0, units = "secs")),
                    if (length(hwm)) trimws(sub("VmHWM:", "", hwm)) else "NA"))
  }
}
