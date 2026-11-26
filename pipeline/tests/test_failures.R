# sources/failures.R: the pull check and the revision diff
f <- data.frame(
  CERT     = c(NA, 24735L, 57053L, 59017L),
  NAME     = c("OLD BANK", "SILICON VALLEY BANK", "SIGNATURE BANK", "FIRST REPUBLIC BANK"),
  FAILDATE = c("4/19/1934", "3/10/2023", "3/12/2023", "5/1/2023"),
  RESTYPE  = "FAILURE",
  QBFASSET = c(1435, 209026000, 110363000, 229100000))

expect(check_failures(f, NULL), "a good pull passes (no CERT before 1984 is allowed)")
bad <- f; bad$FAILDATE[2] <- "2023-03-10"
expect_error(check_failures(bad, NULL), "did not parse", "a changed FAILDATE format fails")
bad <- f; bad$CERT[2] <- NA
expect_error(check_failures(bad, NULL), "no CERT", "a failure since 1984 with no CERT fails")
expect_error(check_failures(f[c(1:4, 2), ], NULL), "duplicate", "a repeated CERT + FAILDATE fails")
expect_error(check_failures(f[-1, ], f), "shrank", "the list losing a row fails")
expect_error(check_failures(f[-3, ], NULL), "Signature", "a missing anchor failure fails")
bad <- f; bad$FAILDATE[4] <- "5/1/2024"
expect_error(check_failures(bad, NULL), "First Republic", "an anchor with the wrong year fails")

new <- f
new$QBFASSET[2] <- 209000000                    # restated
new <- rbind(new[-1, ], data.frame(CERT = 1L, NAME = "NEW BANK", FAILDATE = "7/17/2026",
                                   RESTYPE = "FAILURE", QBFASSET = 5000))
r <- diff_failures(f, new, "seen")
# OLD BANK gone (keyed by name: it has no CERT), SVB restated; NEW BANK is not a revision
expect(nrow(r) == 2 && identical(r$field, c("<row>", "QBFASSET")) &&
         identical(r$new, c("absent", "2.09e+08")) && identical(r$CERT, c(NA, 24735L)),
       "diff logs a vanished row and a changed value, not a new failure")
expect(is.null(diff_failures(f, f, "seen")), "no changes -> no revisions")
expect(is.null(diff_failures(NULL, f, "seen")), "first pull -> no revisions")
