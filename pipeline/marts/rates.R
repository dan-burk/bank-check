# Mart: rates_monthly. One row per FRED series and calendar month.
#   month_end     integer YYYYMMDD of the month's last day (equals RISDATE
#                 in quarter-end months, so it joins to FDIC quarters)
#   avg, last     mean and last of the month's observations (NA excluded)
#   n_obs         observations with a value; n_missing: blank days (holidays)
#   complete      FALSE for each series' newest month (month to date)
#   method_break  TRUE in the month of a known method change (FRED_BREAKS)
# Pure: depends only on the data, not on today's date.

month_end <- function(d) {
  lt <- as.POSIXlt(d)
  y <- lt$year + 1900L + (lt$mon == 11L)
  m <- (lt$mon + 1L) %% 12L + 1L
  as.integer(format(as.Date(sprintf("%04d-%02d-01", y, m)) - 1, "%Y%m%d"))
}

# fred: named list, series -> data.frame(date, value)
build_rates_monthly <- function(fred, breaks = FRED_BREAKS) {
  rows <- lapply(names(fred), function(s) {
    d <- fred[[s]]
    me <- month_end(d$date)
    months <- sort(unique(me))
    ok <- !is.na(d$value)
    g <- factor(me[ok], levels = months)
    last_i <- tapply(seq_along(d$value)[ok], g, max)   # NA if no values
    brk <- month_end(breaks$date[breaks$series == s])
    data.frame(
      series       = s,
      month_end    = months,
      avg          = as.vector(tapply(d$value[ok], g, mean)),
      last         = d$value[as.vector(last_i)],
      n_obs        = as.vector(table(g)),
      n_missing    = as.vector(table(factor(me[!ok], levels = months))),
      complete     = months < max(months),
      method_break = months %in% brk
    )
  })
  out <- do.call(rbind, rows)
  out <- out[order(out$series, out$month_end), ]
  rownames(out) <- NULL
  out
}
