# Checks on rates_monthly. stop()s on the first failure.
#   m         build_rates_monthly() result
#   first_rd  oldest FDIC quarter on hand; newest: newest quarter
RATES_REQUIRED <- c("MORTGAGE30US", "DGS10")   # the hidden-loss inputs

check_rates_monthly <- function(m, first_rd, newest) {
  check(all(FRED_SERIES$series %in% m$series), "rates_monthly lacks a series")
  check(!anyDuplicated(m[c("series", "month_end")]), "duplicate series-months in rates_monthly")
  ok <- !is.na(m$avg)
  check(all(m$avg[ok] >= FRED_MIN & m$avg[ok] <= FRED_MAX), "rates_monthly average out of range")
  check(all(m$n_obs[ok] > 0) && all(m$n_obs[!ok] == 0), "rates_monthly n_obs disagrees with avg")
  # Every month from the first FDIC quarter's first month to the newest
  # quarter's last month has a value
  q_start <- as.Date(sprintf("%04d-%02d-01", first_rd %/% 10000L,
                             first_rd %/% 100L %% 100L - 2L))
  want <- month_end(seq(q_start, as.Date(as.character(newest), "%Y%m%d"), by = "month"))
  for (s in RATES_REQUIRED) {
    miss <- setdiff(want, m$month_end[m$series == s & ok])
    check(length(miss) == 0, paste0("rates_monthly ", s, " missing months: ",
                                    paste(utils::head(miss, 5), collapse = ",")))
  }
}
