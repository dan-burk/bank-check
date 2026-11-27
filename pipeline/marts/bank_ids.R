# Mart: bank_ids, the ID crosswalk every non-FDIC source joins through.
# One row per CERT that filed in any raw quarter. This is the FDIC part:
# RSSD (the Fed's ID) from the call report's own RSSDID field. HMDA LEIs
# (and later tickers) are added by their source PRs, each link with its
# source column. Never matched on names.
#
#   CERT, NAMEFULL      name at the bank's newest filing
#   first_risdate, last_risdate   first and newest raw quarter it filed in
#   RSSD                RSSDID from its newest filing that has one
#   rssd_source         "fdic_financials" (NA when no filing has an RSSDID)
#   rssd_risdate        the quarter RSSD was taken from
#   n_rssd              distinct RSSDIDs over its filings (> 1 is reported)
#   active              in the FDIC directory of active banks (latest_snapshot)
#   LEI                 HMDA reporter LEI from the bank's newest HMDA year
#                       with a link (NA when it never reported HMDA)
#   lei_source          "hmda_panel" (NA without an LEI)
#   lei_year            the HMDA year LEI was taken from
#   n_lei               distinct LEIs linked to the CERT over all HMDA years
#
# The LEI columns come from the stored raw hmda.panel.parquet, which the
# yearly HMDA job writes (sources/hmda.R: LEI -> panel RSSD -> the CERT
# whose call report carried that RSSD in the HMDA year). Every LEI per
# year is in that file; this keeps one per CERT. Without the file the
# columns are NA.
#
# RSSD is the newest link. Within a quarter RSSDIDs are unique, but a CERT
# can change RSSD over time (186 did in a 5-quarter sample), so a source
# dated in the past should join on that quarter's raw RSSDID, not here.

# CERT, RISDATE, NAMEFULL, RSSDID from every raw file. A file still on the
# old schema (no RSSDID column) gives NA RSSDs.
read_id_history <- function(files) {
  do.call(rbind, lapply(files, function(f) {
    cols <- intersect(c("CERT", "NAMEFULL", "RSSDID"), read_parquet_schema(f)$name)
    q <- as.data.frame(read_parquet(f, col_select = cols))
    data.frame(CERT = q$CERT, RISDATE = raw_rds(f), NAMEFULL = q$NAMEFULL,
               RSSDID = if (is.null(q$RSSDID)) NA_integer_ else as.integer(q$RSSDID))
  }))
}

# Pure: id history + the active CERTs -> bank_ids
build_bank_ids <- function(hist, active_certs) {
  h <- hist[order(hist$CERT, -hist$RISDATE), ]
  newest <- h[!duplicated(h$CERT), ]
  ids <- data.frame(CERT = newest$CERT, NAMEFULL = newest$NAMEFULL,
                    first_risdate = NA_integer_, last_risdate = newest$RISDATE)
  oldest <- h[!duplicated(h$CERT, fromLast = TRUE), ]
  ids$first_risdate <- oldest$RISDATE[match(ids$CERT, oldest$CERT)]
  # RSSDID 0 is a placeholder (about ten 1984-85 thrifts), not an ID: as
  # an ID it would join unrelated banks, so it counts as none
  zero <- !is.na(h$RSSDID) & h$RSSDID <= 0
  if (any(zero)) cat("bank_ids:", sum(zero), "filings with RSSDID 0 treated as no RSSD\n")
  r <- h[!is.na(h$RSSDID) & !zero, ]
  r1 <- r[!duplicated(r$CERT), ]                  # newest filing with an RSSD
  m <- match(ids$CERT, r1$CERT)
  ids$RSSD <- r1$RSSDID[m]
  ids$rssd_source <- ifelse(is.na(m), NA_character_, "fdic_financials")
  ids$rssd_risdate <- r1$RISDATE[m]
  u <- unique(r[c("CERT", "RSSDID")])
  ids$n_rssd <- tabulate(match(u$CERT, ids$CERT), nrow(ids))
  ids$active <- ids$CERT %in% active_certs
  rownames(ids) <- NULL
  ids
}

# The stored HMDA reporter panel, or NULL before the first HMDA run
read_hmda_panel <- function(path = file.path(RAW, "hmda.panel.parquet")) {
  if (!file.exists(path)) return(NULL)
  as.data.frame(read_parquet(path, col_select = c("activity_year", "lei", "CERT", "link", "usd_k")))
}

# Pure: bank_ids + the HMDA panel -> bank_ids with the LEI columns. Per
# CERT, the LEI of its newest linked HMDA year; two LEIs in that year
# (rare: a bank that changed LEI mid-year) -> the one with more filtered
# dollars. Every other column is unchanged.
add_lei_links <- function(ids, panel) {
  ids$LEI <- NA_character_
  ids$lei_source <- NA_character_
  ids$lei_year <- NA_integer_
  ids$n_lei <- 0L
  if (is.null(panel)) return(ids)
  p <- panel[panel$link == "matched", ]
  lost <- setdiff(p$CERT, ids$CERT)
  if (length(lost)) stop("HMDA panel links CERTs not in bank_ids: ", paste(utils::head(lost, 5), collapse = ","))
  p <- p[order(p$CERT, -p$activity_year, -p$usd_k), ]
  top <- p[!duplicated(p$CERT), ]
  m <- match(ids$CERT, top$CERT)
  ids$LEI <- top$lei[m]
  ids$lei_source[!is.na(m)] <- "hmda_panel"
  ids$lei_year <- as.integer(top$activity_year[m])
  u <- unique(p[c("CERT", "lei")])
  ids$n_lei <- tabulate(match(u$CERT, ids$CERT), nrow(ids))
  ids
}
