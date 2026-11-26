# marts/bank_ids.R and checks/bank_ids.R on a hand-built id history
hist <- data.frame(
  CERT     = c(1L, 1L, 2L, 2L, 3L, 3L, 4L),
  RISDATE  = c(20201231L, 20210331L, 20201231L, 20210331L, 20201231L, 20210331L, 20191231L),
  NAMEFULL = c("OLD NAME", "NEW NAME", "B", "B", "C", "C", "D"),
  RSSDID   = c(100L, NA, 200L, 201L, 0L, NA, 100L))
ids <- build_bank_ids(hist, active_certs = c(1L, 2L, 3L))
expect(identical(ids$CERT, 1:4), "one row per CERT, sorted")
expect(identical(ids$NAMEFULL[1], "NEW NAME") && ids$first_risdate[1] == 20201231L &&
         ids$last_risdate[1] == 20210331L, "name from the newest filing; first and last quarter")
expect(ids$RSSD[1] == 100L && ids$rssd_risdate[1] == 20201231L,
       "RSSD from the newest filing that has one, with its quarter")
expect(ids$RSSD[2] == 201L && ids$n_rssd[2] == 2L, "a CERT whose RSSD changed: newest, n_rssd 2")
expect(is.na(ids$RSSD[3]) && is.na(ids$rssd_source[3]) && ids$n_rssd[3] == 0L,
       "RSSDID 0 (placeholder) or none in any filing: NA, never 0")
expect(identical(ids$active, c(TRUE, TRUE, TRUE, FALSE)) &&
         identical(ids$rssd_source[1], "fdic_financials"), "active flag and link source")

ok <- ids[ids$CERT != 3L, ]
expect(is.null(check_bank_ids(ok, 20210331L, n_filed = 2L)),
       "passes: an RSSD shared with an inactive CERT is reported, not failed")
expect_error(check_bank_ids(ids, 20210331L, n_filed = 3L), "active filers have an RSSD",
             "under 99% of active filers with an RSSD fails")
bad <- ok; bad$active[bad$CERT == 4L] <- TRUE
expect_error(check_bank_ids(bad, 20210331L, n_filed = 2L), "two active CERTs",
             "an RSSD on two active CERTs fails")
expect_error(check_bank_ids(rbind(ok, ok[1, ]), 20210331L, n_filed = 3L), "duplicate CERT",
             "a duplicated CERT fails")
expect_error(check_bank_ids(ok, 20210331L, n_filed = 5L), "disagree with latest_snapshot",
             "newest-quarter filers out of step with the snapshot fails")
