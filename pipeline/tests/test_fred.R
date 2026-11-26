# sources/fred.R: parsing, the pull check, the revision diff
d <- function(x) as.Date(x)

txt <- "observation_date,DGS10\n2024-01-02,4.00\n2024-01-03,\n2024-01-04,.\n2024-01-05,4.10\n"
p <- parse_fred(txt, "DGS10")
expect(nrow(p) == 4 && identical(p$value, c(4, NA, NA, 4.1)),
       "blank and '.' parse to NA, never 0")
expect_error(parse_fred("DATE,DGS10\n2024-01-02,4\n", "DGS10"), "unexpected header",
             "a changed header fails")
expect_error(parse_fred("observation_date,DGS10\n2024-01-02,n/a\n", "DGS10"), "did not parse",
             "a non-numeric value fails")

today <- d("2024-01-08")
expect(check_fred(p, NULL, "DGS10", 7, today), "a good pull passes")
expect_error(check_fred(p, NULL, "DGS10", 2, today), "older than",
             "a series that stopped updating fails (FRED never refreshing)")
bad <- p; bad$value[1] <- 40
expect_error(check_fred(bad, NULL, "DGS10", 7, today), "outside", "a value above 25% fails")
expect_error(check_fred(p[c(1, 1, 4), ], NULL, "DGS10", 7, today), "duplicate",
             "duplicate dates fail")
old <- data.frame(date = seq(d("2023-12-01"), by = "day", length.out = 10), value = 4)
expect_error(check_fred(p, old, "DGS10", 7, today), "shrank", "history losing > 5 rows fails")
expect_error(check_fred(p[2:3, ], NULL, "DGS10", 7, today), "no observations",
             "an all-NA series fails")

old <- data.frame(date = d(c("2024-01-01", "2024-01-02", "2024-01-03")),
                  value = c(3.9, 4.0, 4.05))
r <- diff_fred(old, p, "DGS10", "seen")
# 01-01 dropped, 01-02 unchanged, 01-03 4.05 -> NA; 01-04/05 are new, not revisions
expect(nrow(r) == 2 && identical(r$date, c("2024-01-01", "2024-01-03")) &&
         identical(r$new, c("absent", "")) && identical(r$old, c("3.9", "4.05")),
       "diff logs changed and dropped dates, not new ones")
expect(is.null(diff_fred(old, old, "DGS10", "seen")), "no changes -> no revisions")
expect(is.null(diff_fred(NULL, p, "DGS10", "seen")), "first pull -> no revisions")
