# BTFP: the Fed's Bank Term Funding Program borrower disclosure. Static:
# the program stopped lending in March 2024 and the Fed published the final
# transaction file in March 2025, so this runs once, by hand, and is not in
# the nightly registry (R/sources.R). It can therefore never block or delay
# a publish.
#
#   Rscript pipeline/sources/btfp.R    # needs pipeline/out/marts/bank_ids.parquet
#
# It downloads the XLSX into pipeline/out/cache/btfp/ (gitignored), parses
# it, checks it, and writes two small committed files:
#   pipeline/static/btfp.borrowers.csv  one row per borrower RSSD
#   pipeline/static/btfp.source.txt     URL, download date, sha256 of the XLSX
#                                       and the CSV, the counts checked
# Committed to git, not the data-raw release (spec open question 6): the
# file is final, about 1,800 rows, and research reads it without a
# download step or a nightly job carrying it.
#
# Advances are in $ thousands, the FDIC unit, so they compare with call
# report fields directly.

BTFP_URL <- paste0("https://www.federalreserve.gov/publications/files/",
                   "section-11s-btfp-transaction-specific-disclosures-03-12-25.xlsx")
BTFP_STATIC <- file.path("pipeline", "static")
BTFP_CSV    <- file.path(BTFP_STATIC, "btfp.borrowers.csv")
BTFP_SOURCE <- file.path(BTFP_STATIC, "btfp.source.txt")
# The file as first parsed (2026-11-26). It is final, so a re-download that
# differs means the Fed replaced it: look before updating these. The XLSX
# states no totals; the borrower count matches the independent parse in
# research PR #21 (1,806 RSSDs).
BTFP_EXPECT <- list(
  sha256 = "15588b715493654fcfce099979b90debbb70303752c9d5499da4028f1554ea82",
  n_advances = 9812L, n_borrowers = 1806L)
# Share of borrower RSSDs that are FDIC-insured banks in bank_ids. The rest
# are credit unions, branches of foreign banks and other eligible lenders.
BTFP_MIN_BANK_SHARE <- 0.6

BTFP_COLS <- c("RSSD", "name", "city", "state", "n_advances", "advances",
               "first_advance", "last_advance", "last_repayment")

# Minimal XLSX reader (an XLSX is a zip of XML), so one file needs no
# package. Returns the first sheet whose header row has `need` as a
# character matrix (header = colnames). Handles shared, inline and formula
# strings; numbers stay text, so the caller parses them (spec trap 11).
read_xlsx_min <- function(path, need) {
  ex <- tempfile("xlsx_"); dir.create(ex); on.exit(unlink(ex, recursive = TRUE))
  utils::unzip(path, exdir = ex)
  rd <- function(f) paste(readLines(file.path(ex, f), warn = FALSE, encoding = "UTF-8"), collapse = "")
  unxml <- function(x) {
    for (e in c(lt = "<", gt = ">", quot = "\"", apos = "'", amp = "&")) {
      x <- gsub(paste0("&", names(e), ";"), e, x, fixed = TRUE)
    }
    x
  }
  text_of <- function(x) vapply(x, function(s) paste(gsub("<[^>]+>", "",
    regmatches(s, gregexpr("<t[^>]*>[^<]*</t>", s))[[1]]), collapse = ""), "", USE.NAMES = FALSE)
  strs <- if (file.exists(file.path(ex, "xl/sharedStrings.xml"))) {
    ss <- rd("xl/sharedStrings.xml")
    unxml(text_of(regmatches(ss, gregexpr("<si>.*?</si>", ss))[[1]]))
  }
  for (sh in sort(list.files(file.path(ex, "xl/worksheets"), pattern = "xml$"))) {
    x <- rd(file.path("xl/worksheets", sh))
    cells <- regmatches(x, gregexpr("<c r=\"[A-Z]+[0-9]+\"[^>]*?(/>|>.*?</c>)", x))[[1]]
    if (length(cells) == 0) next
    ref <- sub("<c r=\"([A-Z]+[0-9]+)\".*", "\\1", cells)
    type <- ifelse(grepl("^<c [^>]*t=\"", cells), sub("^<c [^>]*t=\"([a-zA-Z]+)\".*", "\\1", cells), "n")
    v <- ifelse(grepl("<v>", cells), unxml(sub(".*<v>([^<]*)</v>.*", "\\1", cells)), NA)
    v[type == "s"] <- strs[as.integer(v[type == "s"]) + 1]
    v[type == "inlineStr"] <- unxml(text_of(cells[type == "inlineStr"]))
    r <- as.integer(sub("[A-Z]+", "", ref)); cl <- sub("[0-9]+", "", ref)
    lev <- unique(cl)[order(nchar(unique(cl)), unique(cl))]   # A..Z, AA..
    m <- matrix(NA_character_, max(r), length(lev))
    m[cbind(r, match(cl, lev))] <- v
    hdr <- which(apply(m, 1, function(row) need %in% trimws(row)))[1]
    if (is.na(hdr)) next
    out <- m[-seq_len(hdr), , drop = FALSE]
    colnames(out) <- trimws(m[hdr, ])
    return(out[rowSums(!is.na(out)) > 0, , drop = FALSE])
  }
  stop("no sheet in ", basename(path), " has a '", need, "' column")
}

# The advances (one row per BTFP loan) as typed columns. stop()s on any
# value that does not parse: a borrower with no RSSD or a loan with no
# amount is a broken file, not a zero.
btfp_advances <- function(m) {
  xl_date <- function(v) as.Date(as.numeric(v), origin = "1899-12-30")
  tx <- data.frame(RSSD = as.integer(m[, "Borrower RSSD"]),
                   name = trimws(m[, "Borrower Name"]),
                   city = trimws(m[, "Borrower City"]),
                   state = trimws(m[, "Borrower State"]),
                   amount_usd = as.numeric(m[, "Advance Amount"]),
                   advance_date = xl_date(m[, "Date Of Advance"]),
                   repayment_date = xl_date(m[, "Repayment Date"]))
  bad <- vapply(tx, anyNA, NA)
  if (any(bad)) stop("BTFP: unparsed values in ", paste(names(tx)[bad], collapse = ", "))
  if (any(tx$amount_usd <= 0)) stop("BTFP: advances that are not positive")
  tx
}

# One row per borrower RSSD. The name, city and state are those of its
# latest advance (8 borrowers were renamed during the program).
btfp_borrowers <- function(tx) {
  tx <- tx[order(tx$RSSD, tx$advance_date), ]
  last <- !duplicated(tx$RSSD, fromLast = TRUE)
  b <- tx[last, c("RSSD", "name", "city", "state")]
  g <- match(tx$RSSD, b$RSSD)
  b$n_advances <- tabulate(g, nrow(b))
  b$advances <- as.numeric(tapply(tx$amount_usd, g, sum)) / 1000   # $ thousands
  b$first_advance <- as.Date(tapply(tx$advance_date, g, min))
  b$last_advance <- as.Date(tapply(tx$advance_date, g, max))
  b$last_repayment <- as.Date(tapply(tx$repayment_date, g, max))
  rownames(b) <- NULL
  b[BTFP_COLS]
}

# stop()s on a bad borrower table. src = the btfp.source.txt fields (the
# counts and total recorded with the file); ids = the bank_ids mart.
# Returns the join report: borrowers that are FDIC banks, by RSSD.
check_btfp <- function(b, src, ids) {
  fail <- function(msg) stop("btfp check failed: ", msg)
  if (!identical(names(b), BTFP_COLS)) fail("columns are not BTFP_COLS")
  if (anyNA(b$RSSD) || anyDuplicated(b$RSSD)) fail("RSSD missing or duplicated")
  if (nrow(b) != as.integer(src$n_borrowers)) {
    fail(sprintf("%d borrowers, source says %s", nrow(b), src$n_borrowers))
  }
  if (sum(b$n_advances) != as.integer(src$n_advances)) {
    fail(sprintf("%d advances, source says %s", sum(b$n_advances), src$n_advances))
  }
  if (abs(sum(b$advances) - as.numeric(src$advances_total)) > 1) {
    fail(sprintf("advances total %.0f, source says %s", sum(b$advances), src$advances_total))
  }
  bank <- b$RSSD %in% ids$RSSD[!is.na(ids$RSSD)]
  share <- mean(bank)
  cat(sprintf("BTFP: %d borrowers, %d advances, $%.1fB; %d (%.1f%%) are FDIC banks in bank_ids (%.1f%% of dollars)\n",
              nrow(b), sum(b$n_advances), sum(b$advances) / 1e6, sum(bank), 100 * share,
              100 * sum(b$advances[bank]) / sum(b$advances)))
  if (share < BTFP_MIN_BANK_SHARE) {
    fail(sprintf("only %.1f%% of borrowers join to bank_ids (min %.0f%%)",
                 100 * share, 100 * BTFP_MIN_BANK_SHARE))
  }
  invisible(data.frame(RSSD = b$RSSD, CERT = ids$CERT[match(b$RSSD, ids$RSSD)]))
}

# The committed file and its source record (for research and the tests)
btfp_read <- function() {
  b <- utils::read.csv(BTFP_CSV, colClasses = c(RSSD = "integer", name = "character",
                                               city = "character", state = "character"))
  for (v in c("first_advance", "last_advance", "last_repayment")) b[[v]] <- as.Date(b[[v]])
  b
}
btfp_source <- function() as.list(as.data.frame(read.dcf(BTFP_SOURCE), stringsAsFactors = FALSE))

# Download, parse, check, write. By hand only.
btfp_build <- function(ids, cache = file.path("pipeline", "out", "cache", "btfp")) {
  dir.create(cache, recursive = TRUE, showWarnings = FALSE)
  xlsx <- file.path(cache, "btfp.xlsx")
  if (!file.exists(xlsx)) utils::download.file(BTFP_URL, xlsx, quiet = TRUE, mode = "wb")
  sha <- unname(tools::sha256sum(xlsx))
  if (sha != BTFP_EXPECT$sha256) stop("BTFP XLSX sha256 ", sha, " is not the recorded file")
  tx <- btfp_advances(read_xlsx_min(xlsx, "Borrower RSSD"))
  b <- btfp_borrowers(tx)
  if (nrow(tx) != BTFP_EXPECT$n_advances || nrow(b) != BTFP_EXPECT$n_borrowers) {
    stop(sprintf("BTFP: %d advances / %d borrowers, expected %d / %d", nrow(tx), nrow(b),
                 BTFP_EXPECT$n_advances, BTFP_EXPECT$n_borrowers))
  }
  src <- list(url = BTFP_URL, downloaded = format(as.Date(file.mtime(xlsx))),
              xlsx_sha256 = sha, n_advances = nrow(tx), n_borrowers = nrow(b),
              advances_total = sprintf("%.3f", sum(tx$amount_usd) / 1000),
              advance_dates = paste(format(range(tx$advance_date)), collapse = " to "),
              units = "advances in $ thousands; dates ISO")
  check_btfp(b, src, ids)
  dir.create(BTFP_STATIC, showWarnings = FALSE)
  utils::write.csv(b, BTFP_CSV, row.names = FALSE)
  src$csv_sha256 <- unname(tools::sha256sum(BTFP_CSV))
  write.dcf(as.data.frame(src), BTFP_SOURCE, width = 200)
  cat("Wrote", BTFP_CSV, "and", BTFP_SOURCE, "\n")
}

if (sys.nframe() == 0L) {
  suppressPackageStartupMessages(library(nanoparquet))
  btfp_build(as.data.frame(read_parquet(file.path("pipeline", "out", "marts", "bank_ids.parquet"))))
}
