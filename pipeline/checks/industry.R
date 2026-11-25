# Checks on industry_quarterly and field_coverage, including two
# cross-checks against FDIC's own numbers. stop()s on the first failure.
#   m        build_industry() result: list(ind, cov, raw_sums)
#   files    the raw quarter files the marts were built from
#   manifest the merged raw manifest
#   n_filed  banks in latest_snapshot that filed for the newest quarter
#   sample   TRUE for an explicit quarter sample: holes reported, not failed

RECENT <- 10L   # quarters where any gap fails the run

# The industry ratios the app charts, as % of the summed denominator (num
# may be arithmetic on mart columns). Bounds are wide on purpose: outside
# them means a unit, sign or sum error, not a bad quarter. Observed range
# 1984-2026 in the comment. Component <= total is the hi = 100 rows.
# Flows are one quarter, not annualized. NA (coverage) quarters skip.
IND_BOUNDS <- utils::read.table(header = TRUE, text = "
  num                  den     lo     hi  # observed
  P3LNLS               LNLSGR  0.01   10  # 0.6-2.8
  NCLNLS               LNLSGR  0.01   10  # 0.6-5.5
  LNATRES              LNLSGR  0.01   10  # 0.9-3.7
  NALNLS               NCLNLS  0     100  # 53-87
  RSLNLS               ASSET   0       5  # 0.02-0.67
  NTLNLSQ              LNLSGR -1       3  # 0.05-0.75
  ELNATQ               ASSET  -1       3  # -0.06-0.55
  NETINCQ              ASSET  -2       2  # -0.27-0.35
  NETINC               ASSET  -5       5  # year to date
  EQ                   EQTOT  90   100.1  # 98-100
  LNLSNET              DEP    20     150  # 56-95
  COREDEP              DEP     0     100  # 67-87
  BRO                  DEP     0      25  # 1.3-8.6
  DEPUNINS             DEP     0      80  # 15-44
  VOLIAB               ASSET   0      60  # 11-37
  OTHBFHLB             OTHBOR  0     100  # 31-61
  SCAF-SCAA+SCHF-SCHA  EQ    -60      30  # -32-6
  LNAG                 ASSET   0      20  # 0.3-0.5
  LNRECONS             ASSET   0      20  # 1.4-4.9
  LNRENRES             ASSET   0      30  # 4.8-8.3
  LNRE                 LNLSGR  0     100
  LNCI                 LNLSGR  0     100
  LNREMULT             LNRE    0     100
", comment.char = "#")

check_industry <- function(m, files, newest, manifest, n_filed, sample) {
  ind <- m$ind; cov <- m$cov; raw_sums <- m$raw_sums

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

  # Cross-check 2: in Q1, the quarterly flow is the year to date (net
  # income, net charge-offs)
  q1 <- raw_sums$RISDATE %% 10000L == 331L
  q1_bad <- integer(0)
  for (k in list(c("NETINCQ", "NETINC"), c("NTLNLSQ", "NTLNLS"))) {
    q1_gap <- abs(raw_sums[[k[1]]] - raw_sums[[k[2]]]) / pmax(1, abs(raw_sums[[k[2]]]))
    bad <- raw_sums$RISDATE[q1 & q1_gap > 0.001]
    if (length(bad)) cat("Q1", k[1], "!=", k[2], "(>0.1%):", bad, "\n")
    q1_bad <- union(q1_bad, bad)
  }

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

  check(nrow(ind) == length(files), "industry_quarterly row per raw quarter")
  check(!anyDuplicated(ind$RISDATE), "duplicate quarters in industry_quarterly")
  check(all(ind$ASSET > 1e9), "industry assets below $1T")   # $ thousands; 1984 was $3.7T
  check(sample || length(holes) == 0,
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
  check(!any(q1_bad %in% recent), "Q1 quarterly flow != year to date in the last 10 quarters")
  check(all(AGG_FIELDS %in% names(ind)), "industry_quarterly lacks a summed field")
  check(ind$RISDATE[1] == newest && ind$n_banks[1] == n_filed,
        "industry newest quarter disagrees with snapshot")
  # Balance sheet identity on the summed industry: assets = liabilities +
  # equity (EQTOT includes minority interest), within 0.1%. Quarters where
  # LIAB or EQTOT is NA by coverage are skipped and reported.
  gap <- abs(ind$ASSET - (ind$LIAB + ind$EQTOT)) / ind$ASSET
  if (anyNA(gap)) cat("Identity skipped (LIAB/EQTOT NA):", ind$RISDATE[is.na(gap)], "\n")
  check(all(gap < 0.001, na.rm = TRUE), "industry assets != liabilities + equity")
  # Net loans + allowance = gross loans, summed (exact to the dollar 1984-2026)
  gap <- abs(ind$LNLSNET + ind$LNATRES - ind$LNLSGR) / ind$LNLSGR
  check(all(gap < 0.001, na.rm = TRUE), "industry LNLSNET + LNATRES != LNLSGR")
  for (i in seq_len(nrow(IND_BOUNDS))) {
    b <- IND_BOUNDS[i, ]
    r <- 100 * eval(str2lang(b$num), ind) / ind[[b$den]]
    out <- which(!(r >= b$lo & r <= b$hi))
    check(all(c(all.vars(str2lang(b$num)), b$den) %in% names(ind)) && length(out) == 0,
          paste0("industry ", b$num, " / ", b$den, " outside [", b$lo, ", ", b$hi,
                 "%] in ", paste(utils::head(ind$RISDATE[out], 5), collapse = ",")))
  }
  # Quarter-over-quarter bank count moves ~1%; a big drop means a partial pull
  n <- ind$n_banks
  adj <- utils::tail(ind$RISDATE, -1) ==
    vapply(utils::head(ind$RISDATE, -1), prev_quarter_end, 1L)
  check(all((utils::head(n, -1) >= 0.9 * utils::tail(n, -1))[adj]),
        "bank count fell more than 10% between quarters")
}
