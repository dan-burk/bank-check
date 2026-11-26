# marts/rates.R and checks/rates.R on a hand-built two-series fixture
d <- function(x) as.Date(x)

expect(identical(month_end(d(c("2024-02-10", "2024-12-31", "2023-11-01"))),
                 c(20240229L, 20241231L, 20231130L)), "month_end handles leap years and December")

fred <- list(
  DGS10 = data.frame(date = d(c("2024-01-30", "2024-01-31", "2024-02-01", "2024-02-02")),
                     value = c(4.0, NA, 5.0, 6.0)),
  MORTGAGE30US = data.frame(date = d(c("2022-10-27", "2022-11-17", "2022-11-24")),
                            value = c(7.08, 6.61, 6.58))
)
m <- build_rates_monthly(fred)
g <- m[m$series == "DGS10", ]
expect(identical(g$month_end, c(20240131L, 20240229L)) &&
         identical(g$avg, c(4, 5.5)) && identical(g$last, c(4, 6)) &&
         identical(g$n_obs, c(1L, 2L)) && identical(g$n_missing, c(1L, 0L)),
       "DGS10: average and last skip the blank day, which is counted in n_missing")
expect(identical(g$complete, c(TRUE, FALSE)), "the newest month is flagged incomplete")
mm <- m[m$series == "MORTGAGE30US", ]
expect(identical(mm$avg, c(7.08, (6.61 + 6.58) / 2)) &&
         identical(mm$method_break, c(FALSE, TRUE)),
       "MORTGAGE30US: Nov 2022 flagged as the PMMS method break")
expect(!any(m$method_break[m$series == "DGS10"]), "no break flagged on DGS10")

# The check: every month of the FDIC window present for the required series
mk <- function(series, from, to) {
  dates <- seq(d(from), d(to), by = "week")
  data.frame(date = dates, value = 5)
}
full <- build_rates_monthly(list(DGS10 = mk("DGS10", "2023-10-01", "2024-07-05"),
                                 MORTGAGE30US = mk("MORTGAGE30US", "2023-10-01", "2024-07-05"),
                                 MORTGAGE15US = mk("MORTGAGE15US", "2023-10-01", "2024-07-05")))
expect(is.null(check_rates_monthly(full, 20231231L, 20240630L)),
       "check passes with every month from Oct 2023 to Jun 2024")
expect_error(check_rates_monthly(full, 20230930L, 20240630L), "missing months: 20230731",
             "check fails when the first quarter's months are missing")
holed <- full[!(full$series == "DGS10" & full$month_end == 20240331L), ]
expect_error(check_rates_monthly(holed, 20231231L, 20240630L), "DGS10 missing months: 20240331",
             "check fails on a hole in DGS10")
expect_error(check_rates_monthly(full[full$series != "MORTGAGE15US", ], 20231231L, 20240630L),
             "lacks a series", "check fails when a series is absent")
