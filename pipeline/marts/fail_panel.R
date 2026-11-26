# fail_panel and failures_meta, the app's failures tab, built from the
# stored raw quarters and the failures list. No per-bank requests: the raw
# files already hold every bank since 1984.
#
#   fail_panel     one row per (CERT, quarter) for the 0-MAX_QTRS_BEFORE
#                  quarters before failure: the APP_FIELDS columns as stored
#                  in raw, plus label, fail_date, qtrs_before
#   failures_meta  one row per failed bank: label, region, size bucket,
#                  n_filings (the app hides banks with none)
#
# Which rows count as a failure: RESTYPE == "FAILURE" (the bank closed)
# with FAILYR >= FAIL_PANEL_FROM_YEAR. ASSISTANCE rows are open-bank
# assistance: the bank kept operating (in 2008-09, Citigroup and Bank of
# America's banks among them), so they have no failure date to align on
# and would pull the "failed banks" median toward the largest survivors.
# The research backtest keeps FAILURE + ASSISTANCE from 1997 for its own
# question; it filters the raw failures list itself.
#
# Survivorship gap: failed banks often stop filing 1-2 quarters before
# FAILDATE. qtrs_before comes from the filed RISDATEs, so missing quarters
# are absent, never forward-filled.

FAIL_PANEL_FROM_YEAR <- 2000L

FAIL_SIZE_BREAKS <- c(0, 1e5, 1e6, 1e7, Inf)   # QBFASSET, $ thousands
FAIL_SIZE_LABELS <- c("Under $100M", "$100M to $1B", "$1B to $10B", "Over $10B")

# Census regions. datasets::state.region calls the Midwest "North Central"
# (its pre-1984 name); DC and the territories are added explicitly.
FAIL_REGIONS <- local({
  r <- stats::setNames(as.character(datasets::state.region), datasets::state.abb)
  r[r == "North Central"] <- "Midwest"
  c(r, DC = "South", PR = "South", VI = "South",
    GU = "West", AS = "West", MP = "West")
})

# Quarter index of a date: year * 4 + quarter - 1
qidx <- function(d) {
  as.integer(format(d, "%Y")) * 4L + (as.integer(format(d, "%m")) - 1L) %/% 3L
}

title_case <- function(x) tools::toTitleCase(tolower(x))

# The failures the panel covers, with the app's picker metadata
panel_failures <- function(failures) {
  f <- failures[failures$RESTYPE == "FAILURE" &
                  as.integer(failures$FAILYR) >= FAIL_PANEL_FROM_YEAR, ]
  f$fail_date <- failure_date(f$FAILDATE)
  f <- f[order(f$fail_date, f$CERT), ]
  f$region <- unname(FAIL_REGIONS[f$PSTALP])
  f$size_bucket <- as.character(cut(f$QBFASSET, FAIL_SIZE_BREAKS,
                                    FAIL_SIZE_LABELS, right = FALSE))
  # Name, state, fail year; the city breaks ties
  yr <- format(f$fail_date, "%Y")
  f$label <- paste0(title_case(f$NAME), " (", f$PSTALP, " ", yr, ")")
  dup <- f$label %in% f$label[duplicated(f$label)]
  f$label[dup] <- paste0(title_case(f$NAME[dup]), ", ", title_case(f$CITY[dup]),
                         " (", f$PSTALP[dup], " ", yr[dup], ")")
  rownames(f) <- NULL
  f
}

# First raw quarter any panel row can come from
fail_panel_first_rd <- function() {
  (FAIL_PANEL_FROM_YEAR - MAX_QTRS_BEFORE %/% 4L) * 10000L + 331L
}

# The failed banks' rows from every raw quarter on or after first_rd,
# APP_FIELDS columns only
read_fail_history <- function(files, certs, first_rd = fail_panel_first_rd()) {
  keep <- strsplit(APP_FIELDS, ",")[[1]]
  parts <- lapply(files[raw_rds(files) >= first_rd], function(f) {
    q <- as.data.frame(read_parquet(f))
    q[q$CERT %in% certs, intersect(names(q), keep), drop = FALSE]
  })
  do.call(rbind, parts)
}

# Pure: failures (panel_failures()) + their raw rows -> list(panel, meta)
build_fail_panel <- function(fails, hist) {
  m <- match(hist$CERT, fails$CERT)
  hist <- hist[!is.na(m), , drop = FALSE]
  m <- m[!is.na(m)]
  hist$label     <- fails$label[m]
  hist$fail_date <- fails$fail_date[m]
  hist$qtrs_before <- qidx(hist$fail_date) -
    qidx(as.Date(as.character(hist$RISDATE), format = "%Y%m%d"))
  panel <- hist[hist$qtrs_before >= 0 & hist$qtrs_before <= MAX_QTRS_BEFORE, ]
  panel <- panel[order(panel$fail_date, panel$CERT, panel$RISDATE), ]
  rownames(panel) <- NULL

  meta <- fails[c("CERT", "label", "NAME", "CITY", "PSTALP", "fail_date",
                  "QBFASSET", "region", "size_bucket")]
  meta$n_filings <- tabulate(match(panel$CERT, fails$CERT), nrow(fails))
  list(panel = panel, meta = meta)
}
