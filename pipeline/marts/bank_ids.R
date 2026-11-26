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
