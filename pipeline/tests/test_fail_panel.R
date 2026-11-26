# marts/fail_panel.R and checks/fail_panel.R on a hand-built fixture:
# which rows count as failures, the quarters-before window, labels, size
# buckets, regions and n_filings
raw_fail <- data.frame(
  CERT     = c(24735L, 2L, 3L, 4L, 5L, 6L),
  NAME     = c("SILICON VALLEY BANK", "TWIN BANK", "TWIN BANK", "OPEN BANK",
               "OLD BANK", "GHOST BANK"),
  CITY     = c("SANTA CLARA", "ALPHA", "BETA", "X", "X", "X"),
  PSTALP   = c("CA", "DC", "DC", "SD", "SD", "SD"),
  FAILDATE = c("3/10/2023", "1/15/2010", "6/30/2010", "1/16/2009", "5/1/1999", "2/1/2015"),
  FAILYR   = c("2023", "2010", "2010", "2009", "1999", "2015"),
  RESTYPE  = c("FAILURE", "FAILURE", "FAILURE", "ASSISTANCE", "FAILURE", "FAILURE"),
  QBFASSET = c(209026000, 100000, 99999, 5e8, 1000, 5e5))
fails <- panel_failures(raw_fail)

expect(identical(fails$CERT, c(2L, 3L, 6L, 24735L)),
       "FAILURE from 2000 only (assistance and 1999 dropped), ordered by fail date")
expect(identical(fails$size_bucket, c("$100M to $1B", "Under $100M", "$100M to $1B", "Over $10B")),
       "size buckets: $100M exactly is the upper bucket ($ thousands, right-open)")
expect(identical(fails$region, c("South", "South", "Midwest", "West")),
       "regions: DC is South, SD is Midwest (not North Central)")
expect(identical(fails$label, c("Twin Bank, Alpha (DC 2010)", "Twin Bank, Beta (DC 2010)",
                                "Ghost Bank (SD 2015)", "Silicon Valley Bank (CA 2023)")),
       "labels: name, state, year; the city breaks ties")

hist <- data.frame(
  CERT    = c(24735L, 24735L, 24735L, 24735L, 2L, 2L, 3L, 4L, 99L),
  RISDATE = c("20230630", "20221231", "20180331", "20171231", "20091231", "20100331",
              "20100630", "20090331", "20100331"),
  ASSET   = c(1, 2, 3, 4, 5, 6, 7, 8, 9))
fp <- build_fail_panel(fails, hist)
p <- fp$panel
expect(identical(paste(p$CERT, p$RISDATE, p$qtrs_before),
                 c("2 20091231 1", "2 20100331 0", "3 20100630 0",
                   "24735 20180331 20", "24735 20221231 1")),
       "window is 0-20 quarters inclusive; after failure, 21 back and non-failures are dropped")
expect(identical(p$label[p$CERT == 3L], "Twin Bank, Beta (DC 2010)") &&
         identical(p$fail_date[1], as.Date("2010-01-15")),
       "panel rows carry the label and fail date")
expect(identical(fp$meta$n_filings, c(2L, 1L, 0L, 2L)), "n_filings per failure, 0 kept for the picker to hide")

# Check: every quarter from the window start to the newest is on hand
newest <- 20230930L
rds <- newest
while (rds[length(rds)] > fail_panel_first_rd()) rds <- c(rds, prev_quarter_end(rds[length(rds)]))
ok_fails <- fails[fails$CERT != 6L, ]
ok_fp <- build_fail_panel(ok_fails, hist)
expect(is.null(check_fail_panel(ok_fp, ok_fails, rds, newest)), "a good panel passes")
expect_error(check_fail_panel(ok_fp, ok_fails, rds[-50], newest), "raw quarters missing",
             "a missing raw quarter in the window fails")
expect_error(check_fail_panel(fp, fails, rds, newest), "have a filing",
             "too many failures without filings fails (1 of 4)")
bad <- ok_fp; bad$panel <- rbind(bad$panel, bad$panel[1, ])
expect_error(check_fail_panel(bad, ok_fails, rds, newest), "duplicate CERT-quarters",
             "a duplicated bank-quarter fails")
bad <- ok_fp; bad$panel <- bad$panel[bad$panel$RISDATE != "20221231", ]
expect_error(check_fail_panel(bad, ok_fails, rds, newest), "n_filings disagrees",
             "meta out of step with the panel fails")
bad$meta$n_filings <- tabulate(match(bad$panel$CERT, bad$meta$CERT), nrow(bad$meta))
expect_error(check_fail_panel(bad, ok_fails, rds, newest), "SVB",
             "SVB's last filing not at 2022 Q4 fails (date arithmetic anchor)")
