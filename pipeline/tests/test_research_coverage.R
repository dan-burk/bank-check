# marts/research_coverage.R and checks/research_coverage.R on a hand-built
# quarter: asset weights without foreign-bank branches, a field the raw
# file lacks, and the checks
q <- function(rd, f1, lnrs) data.frame(
  CERT = 1:4, RISDATE = as.character(rd),
  ASSET = c(100, 300, 600, 1000), LIAB = c(90, 270, 540, 1000),
  EQTOT = c(10, 30, 60, NA),                      # CERT 4: a foreign-bank branch
  F1 = f1, LNRS3LES = lnrs)
fields <- c("F1", "LNRS3LES", "GONE")
c1 <- research_coverage(q(20260930, c(0, NA, 5, 7), c(1, 2, 3, NA)), fields)
expect(isTRUE(all.equal(c1$asset_share[1], 0.7)) && c1$n_reported[1] == 3L,
       "share of assets without the branch (a reported 0 counts); n_reported counts the branch")
expect(c1$asset_share[2] == 1 && c1$n_branches[1] == 1L, "a field every bank reports is 100%")
expect(!c1$in_raw[3] && is.na(c1$asset_share[3]) && is.na(c1$n_reported[3]),
       "a field the raw file lacks: in_raw FALSE, share NA (not 0)")

good <- rbind(research_coverage(q(20260930, c(1, 1, 1, NA), c(1, 2, 3, NA)), fields[1:2]),
              research_coverage(q(20111231, c(1, 1, 1, NA), c(NA, NA, 3, NA)), fields[1:2]))
expect(is.null(check_research_coverage(good, 20260930L, fields[1:2])),
       "passes: bucket gaps before 2012 are reported, not failed")
expect_error(check_research_coverage(c1, 20260930L, fields), "missing or never reported.*GONE",
             "a research field the newest quarter lacks fails (misspelled: the API drops it)")
bad <- research_coverage(q(20260930, c(NA, NA, NA, 1), c(1, 2, 3, NA)), fields[1:2])
expect_error(check_research_coverage(bad, 20260930L, fields[1:2]), "never reported.*F1",
             "a field nobody reports in the newest quarter fails")
bad <- research_coverage(q(20260930, c(1, 1, 1, NA), c(1, NA, NA, NA)), fields[1:2])
expect_error(check_research_coverage(bad, 20260930L, fields[1:2]), "bucket fields below 95%",
             "a bucket field under 95% of assets since 2012 fails")
expect_error(check_research_coverage(rbind(good, good[1, ]), 20260930L, fields[1:2]), "duplicate",
             "a duplicated quarter-field fails")
