# Checks on fail_panel + failures_meta. stop()s on the first failure.
#   fp     build_fail_panel() result
#   fails  panel_failures() result (the failures the panel must cover)
#   rds    every raw quarter on hand (integer YYYYMMDD)
FAIL_MIN_WITH_FILINGS <- 0.95   # share of failures with at least one filing

# SVB failed 2023-03-10; its last filing is 2022 Q4, one quarter before
FAIL_ANCHOR <- list(CERT = 24735L, last_rd = "20221231", qtrs_before = 1L)

check_fail_panel <- function(fp, fails, rds, newest) {
  p <- fp$panel; m <- fp$meta
  # Every quarter the window can draw on is on hand, or rows would be
  # silently missing
  want <- newest
  while (want[length(want)] > fail_panel_first_rd()) {
    want <- c(want, prev_quarter_end(want[length(want)]))
  }
  miss <- setdiff(want, rds)
  check(!length(miss), paste("fail_panel: raw quarters missing:",
                             paste(utils::head(miss, 5), collapse = ",")))

  check(nrow(m) == nrow(fails) && !anyDuplicated(m$CERT),
        "failures_meta is not one row per failure (a CERT failed twice?)")
  for (col in c("label", "region", "size_bucket", "fail_date")) {
    check(!anyNA(m[[col]]), paste("failures_meta has NA", col))
  }
  check(!anyDuplicated(m$label), "failures_meta labels are not unique")
  check(mean(m$n_filings > 0) >= FAIL_MIN_WITH_FILINGS,
        sprintf("only %.0f%% of failures have a filing in the window",
                100 * mean(m$n_filings > 0)))

  check(!anyDuplicated(p[c("CERT", "RISDATE")]), "duplicate CERT-quarters in fail_panel")
  check(all(p$CERT %in% m$CERT), "fail_panel has banks that are not in failures_meta")
  check(all(p$qtrs_before >= 0 & p$qtrs_before <= MAX_QTRS_BEFORE),
        "fail_panel qtrs_before outside the window")
  check(identical(m$n_filings, tabulate(match(p$CERT, m$CERT), nrow(m))),
        "failures_meta n_filings disagrees with fail_panel")
  check(!anyNA(p$ASSET), "fail_panel rows with no ASSET")

  a <- p[p$CERT == FAIL_ANCHOR$CERT, ]
  check(nrow(a) > 0 && max(a$RISDATE) == FAIL_ANCHOR$last_rd &&
          min(a$qtrs_before) == FAIL_ANCHOR$qtrs_before,
        "SVB's last filing is not 2022 Q4, one quarter before failure")
}
