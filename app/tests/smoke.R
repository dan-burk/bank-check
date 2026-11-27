# Smoke test for the app: every plot builder returns a plotly object and
# every server output renders. Run from the repo root:
#   Rscript app/tests/smoke.R
# Needs the pipeline marts in app/data/ (see pipeline/README.md); runs
# without network to FDIC.

library(shiny)
library(bslib)
library(plotly)
library(dplyr)

setwd("app")
source("R/api.R")
source("R/theme.R")
source("R/data.R")
source("R/plots.R")
source("R/statements.R")
source("R/stress.R")

# Two-bank fixture (Dacotah 1984+, First B&T) in raw API columns, so the
# test exercises derive() just as a live fetch would
BASE <- readRDS("tests/fixtures/sd_banks.rds") |> derive()
snap <- load_snapshot()
inst <- snapshot_institutions(snap)
PEER <- peer_stats(snapshot_cross_section(snap), FIELDS_META)
stopifnot(nrow(inst) > 3000, !anyNA(inst$NAME))
ind <- load_industry()
stopifnot(!is.unsorted(rev(ind$RISDATE)), !anyDuplicated(ind$RISDATE),
          ind$RISDATE[1] == max(snap$RISDATE, na.rm = TRUE),
          min(ind$RISDATE) == 19840331,
          nrow(ind) >= 170)  # floor, not exact: grows by one each quarter
# Full history, contiguous: every quarter-end from 1984 Q1 to the newest
want <- max(ind$RISDATE)
while (want[length(want)] > 19840331) want <- c(want, prev_quarter_end(want[length(want)]))
gaps <- setdiff(want, ind$RISDATE)
if (length(gaps)) stop("industry_quarterly is missing quarters: ", paste(gaps, collapse = ", "))
cat("marts: snapshot", nrow(snap), "banks,", nrow(inst), "active; industry",
    nrow(ind), "quarters\n")
stopifnot(nrow(PEER) >= 15, all(c("p25", "p50", "p75") %in% names(PEER)))
cat("peer stats:", nrow(PEER), "metrics\n")

FAIL_PANEL <- load_fail_panel()
FAIL_META  <- load_fail_meta()
stopifnot(nrow(FAIL_META) > 500, !any(is.na(FAIL_META$region)),
          all(FAIL_META$n_filings > 0))
cat("fail panel:", nrow(FAIL_PANEL), "rows,", nrow(FAIL_META), "banks\n")

ok <- function(nm, p) {
  stopifnot(inherits(p, "plotly"))
  cat("ok:", nm, "\n")
}

dac <- BASE |> filter(label == "Dacotah (SD)")
fbt <- BASE |> filter(label == "First B&T (SD)")
banks <- list("Dacotah (SD)" = dac, "First B&T (SD)" = fbt)
cols  <- c("Dacotah (SD)" = "#2C5F8A", "First B&T (SD)" = "#0072B2")

# Every metric through the shared time-series builder, band included
for (code in FIELDS_META$code) {
  ok(paste("metric_ts", code),
     metric_ts(banks, code, FIELDS_META, cols, peer = peer_for(code, PEER)))
}
ok("metric_ts pct_assets",
   metric_ts(banks, "DEPUNINS", FIELDS_META, cols, display = "pct_assets"))
ok("metric_ts pct_loans",
   metric_ts(banks, "OTHBFHLB", FIELDS_META, cols, display = "pct_loans"))

# One axis, one unit: two banks straddling the $1B line must share one
# divisor (the regression behind the BankStar-vs-Dacotah 1000x inflation)
big   <- data.frame(date = dac$date, ASSET = dac$ASSET)        # ~$4.9B
small <- data.frame(date = dac$date, ASSET = dac$ASSET / 10)   # ~$490M
pb <- plotly::plotly_build(
  metric_ts(list(Big = big, Small = small), "ASSET", FIELDS_META,
            c(Big = "#2C5F8A", Small = "#E69F00"))
)
line_traces <- Filter(function(t) identical(t$mode, "lines"), pb$x$data)
stopifnot(length(line_traces) == 2)
maxes <- sapply(line_traces, function(t) max(unlist(t$y), na.rm = TRUE))
ratio <- max(maxes) / min(maxes)
stopifnot(abs(ratio - 10) < 0.5)   # true 10x asset gap survives on the axis
ttl <- pb$x$layout$yaxis$title
if (is.list(ttl)) ttl <- ttl$text
stopifnot(grepl("($B)", ttl, fixed = TRUE))
cat("ok: shared $ axis unit across mixed-size banks\n")

# Statements: every block adds up to FDIC's own total, and both tables
# render in every unit / comparison mode
for (d in list(dac, fbt)) {
  L <- statement_lines(d[nrow(d), ])
  r <- d[nrow(d), ]
  blk <- function(sec, from, to) {
    x <- L[L$section == sec, ]
    sum(x$value[(which(x$label == from) + 1):(which(x$label == to) - 1)],
        na.rm = TRUE)
  }
  stopifnot(abs(blk("bs", "Assets", "Total assets") - r$ASSET) < 1,
            abs(blk("bs", "Liabilities", "Total liabilities") - r$LIAB) < 1,
            abs(r$ASSET - r$LIAB - r$EQTOT) < 1)
  I <- L[L$section == "is", ]
  below_rev <- I$value[I$kind == "line" & seq_len(nrow(I)) > which(I$label == "Revenue")]
  stopifnot(abs(I$value[I$label == "Revenue"] + sum(below_rev) - r$NETINCQ) < 1,
            abs(I$pct[I$label == "Revenue"] - 100) < 1e-9)
  for (sec in c("bs", "is")) for (u in c("usd", "pct")) for (cm in c("qoq", "yoy")) {
    stopifnot(inherits(statement_table(d, sec, u, cm), "shiny.tag"))
  }
}
two <- statement_table(banks, "bs", "pct", cols = cols)
two_html <- as.character(two)
stopifnot(grepl("Dacotah (SD)", two_html, fixed = TRUE),
          grepl("First B&amp;T (SD)", two_html, fixed = TRUE),
          !grepl("vs Q", two_html, fixed = TRUE))   # no change column
cat("ok: statements add up and render in all modes, 1 or 2 banks\n")

# Industry totals: a summed cross-section is just another "bank" row
mini_xs <- dplyr::bind_rows(lapply(banks, function(d) d[which.max(d$RISDATE), ]))
tot <- industry_totals(mini_xs)
stopifnot(tot$n_banks == 2, abs(tot$ASSET - sum(mini_xs$ASSET)) < 1e-6,
          abs(tot$NETINCQ - sum(mini_xs$NETINCQ)) < 1e-6,
          inherits(statement_table(tot, "is", "pct", links = FALSE), "shiny.tag"))
cat("ok: industry totals sum the banks and render\n")

# No silent zeros: a field reported by banks holding < COVERAGE_MIN of
# assets is NA, never a partial sum; its line and "Other" show "–" while
# the totals still show
gap_xs <- mini_xs
gap_xs$SC[which.max(gap_xs$ASSET)] <- NA
gtot <- industry_totals(gap_xs)
stopifnot(is.na(gtot$SC), !is.na(gtot$ASSET),
          field_coverage(gap_xs)$asset_share[field_coverage(gap_xs)$field == "SC"] < COVERAGE_MIN)
gl <- statement_lines(gtot)
stopifnot(is.na(gl$value[gl$label == "Bonds"]),
          is.na(gl$value[gl$section == "bs" & gl$label == "Other"][1]),
          !is.na(gl$value[gl$label == "Total assets"]))
gh <- as.character(statement_table(gtot, "bs", links = FALSE))
stopifnot(grepl("–", gh, fixed = TRUE))
# Oldest industry quarter has no prior quarter: change column is "–"
old <- ind[ind$RISDATE == min(ind$RISDATE), ]
stopifnot(inherits(statement_table(old, "bs", links = FALSE), "shiny.tag"))
# History charts: a quarter with a forced NA field is a gap, not 0
ind_gap <- ind; ind_gap$SC[nrow(ind_gap)] <- NA
ind_long <- industry_long(ind)
for (sec in c("bs", "is")) for (u in c("usd", "pct")) {
  ok(paste("industry_history", sec, u), industry_history(ind_long, sec, u))
}
bt <- Filter(function(t) identical(t$name, "+ Bonds"),
             plotly::plotly_build(industry_history(industry_long(ind_gap), "bs"))$x$data)[[1]]
by <- unlist(bt$y)
stopifnot(sum(!is.na(by)) == sum(!is.na(ind$SC)) - 1, !any(by == 0, na.rm = TRUE))
cat("ok: missing coverage is NA (\"–\" in tables, gaps in charts), never 0\n")
# Only the totals are drawn, listed first; every legend name has its
# operator; subtracted lines are drawn positive, swing lines keep their sign
for (u in c("usd", "pct")) {
  tr <- plotly::plotly_build(industry_history(ind_long, "is", u))$x$data
  shown <- vapply(tr, function(t) isTRUE(t$visible), TRUE)
  stopifnot(identical(vapply(tr[shown], `[[`, "", "name"),
                      c("+ Revenue", "− Expenses", "− Loan loss provision", "= Net income")),
            all(vapply(tr[!shown], `[[`, "", "visible") == "legendonly"))
  for (sec in c("is", "bs")) {  # both CECL lines (2020, 2023) on both charts
    xs <- as.Date(vapply(plotly::plotly_build(industry_history(ind_long, sec, u))$x$layout$shapes, function(s) as.character(s$x0), ""))
    stopifnot(all(as.Date(c("2020-01-01", "2023-01-01")) %in% xs))
  }
  bs <- plotly::plotly_build(industry_history(ind_long, "bs", u))$x$data
  stopifnot(identical(vapply(Filter(function(t) isTRUE(t$visible), bs), `[[`, "", "name"),
                      c("= Total assets", "= Total liabilities", "= Equity (assets − liabilities)")),
            length(bs) == 11)
  for (t in c(tr, bs)) stopifnot(substr(t$name, 1, 1) %in% c("+", "−", "="),
                                 !grepl("subtracted|\\*", t$name),
                                 startsWith(t$hovertemplate[1], paste0(t$name, ": ")))
  for (sec in c("is", "bs")) {
    l <- ind_long[ind_long$section == sec, ]
    div <- if (u == "pct") 1 else usd_axis_unit(l$value)$div
    trs <- if (sec == "is") tr else bs
    chk <- if (sec == "bs") c(`− Allowance` = "− Allowance*") else
      c(`− Expenses` = "Expenses", `− Loan loss provision` = "Loan loss provision",
        `− Taxes` = "Taxes", `+ Bond gains/losses` = "Bond gains/losses", `+ Other` = "Other")
    for (nm in names(chk)) {
      y <- unlist(Filter(function(t) t$name == nm, trs)[[1]]$y)
      want <- l[l$label == chk[[nm]], if (u == "pct") "pct" else "value"] / div
      if (substr(nm, 1, 1) == "−") want <- -want
      stopifnot(isTRUE(all.equal(as.numeric(y[!is.na(y)]), want[!is.na(want)])))   # plotly drops leading NA points
    }
  }
  ex <- unlist(Filter(function(t) t$name == "− Expenses", tr)[[1]]$y)
  stopifnot(all(ex > 0, na.rm = TRUE))
}
cat("ok: industry history shows only totals; operators in names; subtracted drawn positive\n")

# industry_long() (one vectorized statement_lines() call) equals the old
# per-quarter loop, NA gaps and quarters missing from the mart included
loop_long <- function(ind) {
  q <- max(ind$RISDATE)
  while (q[length(q)] > min(ind$RISDATE)) q <- c(q, prev_quarter_end(q[length(q)]))
  l <- do.call(rbind, lapply(q, function(rd) {
    l <- statement_lines(ind[ind$RISDATE == rd, ][1, ])
    l$label[l$section == "bs" & l$label == "Other"] <- c("Other assets", "Other liabilities")
    l$date <- as.Date(as.character(rd), "%Y%m%d")
    l[l$kind != "head", ]
  }))
  l <- l[order(l$date), ]
  rownames(l) <- NULL
  l
}
ind_odd <- ind_gap[-c(5, 80), ]                       # two quarters missing
ind_odd$NIMQ[3] <- -ind_odd$NONIIQ[3] - 1              # revenue < 0: is pct NA
for (x in list(ind, ind_odd)) stopifnot(identical(industry_long(x), loop_long(x)))
cat("ok: industry_long matches the per-quarter loop\n")

sel <- data.frame(
  label = names(banks),
  asset = sapply(banks, function(d) utils::tail(d$ASSET[!is.na(d$ASSET)], 1)),
  col   = unname(cols)
)
ok("scale_strip", scale_strip(inst, sel))
ok("pipeline_lines", pipeline_lines(dac))
ok("pipeline_lines df2", pipeline_lines(dac, df2 = fbt))
# Industry lines: summed dollars / summed gross loans, one per series, and
# none with a comparison bank. A mart without P3LNLS/NCLNLS (built before
# they were summed) drops just those two. ind_dq makes sure both exist.
ind_dq <- ind
if (is.null(ind_dq$P3LNLS)) ind_dq$P3LNLS <- 0.005 * ind_dq$LNLSGR
if (is.null(ind_dq$NCLNLS)) ind_dq$NCLNLS <- 0.010 * ind_dq$LNLSGR
pl_names <- function(p) vapply(plotly::plotly_build(p)$x$data, function(t) t$name, "")
ind_lines <- paste(c("30-89 days late", "Noncurrent", "Allowance"), "- All banks")
pl <- plotly::plotly_build(pipeline_lines(dac, ind = ind_dq))$x$data
stopifnot(identical(vapply(pl, `[[`, "", "name")[4:6], ind_lines))
w <- ind_dq[ind_dq$RISDATE >= 20190101, ]; w <- w[order(w$RISDATE), ]
for (k in 1:3) {
  stopifnot(isTRUE(all.equal(as.numeric(unlist(pl[[3 + k]]$y)),
    round(100 * w[[c("P3LNLS", "NCLNLS", "LNATRES")[k]]] / w$LNLSGR, 2))))
}
stopifnot(!any(grepl("All banks", pl_names(pipeline_lines(dac, df2 = fbt, ind = ind_dq)))),
          identical(grep("All banks", pl_names(pipeline_lines(
            dac, ind = ind[setdiff(names(ind), c("P3LNLS", "NCLNLS"))])), value = TRUE),
            "Allowance - All banks"))
# No bank: the same three industry lines alone, same values, solid
pl0 <- plotly::plotly_build(pipeline_lines(NULL, ind = ind_dq))$x$data
stopifnot(identical(vapply(pl0, `[[`, "", "name"), ind_lines),
          identical(lapply(pl0, `[[`, "y"), lapply(pl[4:6], `[[`, "y")),
          all(vapply(pl0, function(t) t$line$dash, "") == "solid"))
cat("ok: pipeline_lines industry lines (columns present, absent, hidden with df2, no bank)\n")

# industry_series on a hand-computed mini mart (newest first, like the mart)
mm <- data.frame(RISDATE = c(20241231L, 20240930L, 20240630L, 20240331L, 20231231L),
                 ASSET = c(140, 130, 120, 110, 100), LNLSGR = 50,
                 NETINC = c(4, 3, 2, 1, 9), NETINCQ = c(1, 1, 1, 1, 2),
                 SCAF = 8, SCAA = 10, SCHF = 4, SCHA = 5)
s_at <- function(s, rd) s$y[s$date == as.Date(as.character(rd), "%Y%m%d")]
stopifnot(
  isTRUE(all.equal(s_at(industry_series(mm, "NETINC", "ASSET", "ann_ytd"), 20240630),
                   100 * 2 * 4 / 2 / mean(c(100, 110, 120)))),
  isTRUE(all.equal(s_at(industry_series(mm, "NETINC", "ASSET", "ann_ytd"), 20241231),
                   100 * 4 / mean(c(100, 110, 120, 130, 140)))),
  isTRUE(all.equal(s_at(industry_series(mm, "NETINCQ", "ASSET", "ann_q"), 20240331),
                   100 * 4 / mean(c(110, 100)))),
  is.na(s_at(industry_series(mm, "NETINCQ", "ASSET", "ann_q"), 20231231)),  # no prior quarter
  is.na(s_at(industry_series(mm[-3, ], "NETINC", "ASSET", "ann_ytd"), 20240930)),  # hole: NA, not a shorter mean
  isTRUE(all.equal(s_at(industry_series(mm, "LNLSGR", "ASSET", "x"), 20241231), 50 / 140)),
  isTRUE(all.equal(s_at(industry_series(mm, "SCAF - SCAA + SCHF - SCHA", "ASSET"), 20241231),
                   100 * -3 / 140)),
  is.null(industry_series(mm, "NCLNLS", "LNLSGR")),         # column not in the mart
  is.null(industry_series(NULL, "ASSET", "ASSET")),
  !is.unsorted(industry_series(mm, "ASSET", "LNLSGR")$date))
# Every fields_meta industry formula names summed fields and a known scale
SF <- strsplit(STATEMENT_FIELDS, ",")[[1]]
im <- FIELDS_META[!is.na(FIELDS_META$ind_num), ]
for (i in seq_len(nrow(im))) {
  v <- c(all.vars(str2lang(im$ind_num[i])), stats::na.omit(im$ind_den[i]))
  if (!all(v %in% SF)) stop(im$code[i], ": industry fields not summed: ", setdiff(v, SF))
  stopifnot(if (im$units[i] == "usd_k") is.na(im$ind_den[i]) else
              im$ind_scale[i] %in% c("pct", "x", "ann_q", "ann_ytd"))
}
cat("ok: industry_series (pct, x, ann_q, ann_ytd, formula, gaps, missing columns)\n")

# metric_ts "All banks" line. ind_full = the mart with any field it predates
# filled in, so the drawing is tested whatever mart is on disk.
ind_full <- ind
for (f in setdiff(SF, names(ind_full))) ind_full[[f]] <- 0.01 * ind_full$ASSET
for (code in im$code) {
  for (disp in if (FIELDS_META$units[FIELDS_META$code == code] == "usd_k")
                 c("level", "pct_assets", "pct_loans") else "level") {
    iv <- industry_metric(code, FIELDS_META, ind_full, disp)
    stopifnot(is.null(iv) == (disp == "level" &&
                              FIELDS_META$units[FIELDS_META$code == code] == "usd_k"))
    tr <- plotly::plotly_build(metric_ts(banks, code, FIELDS_META, cols, disp,
                                         peer_for(code, PEER), ind = iv))$x$data
    stopifnot(sum(vapply(tr, function(t) identical(t$name, "All banks"), NA)) == !is.null(iv))
  }
}
iv <- industry_metric("NCLNLSR", FIELDS_META, ind_full)
# Values matched on x: plotly prunes leading/trailing NA points
trace_at <- function(tr) {
  y <- vapply(tr$y, function(v) if (is.null(v)) NA_real_ else v, 0)
  stats::setNames(y, as.character(as.Date(unlist(tr$x))))
}
f15 <- fbt[fbt$date >= as.Date("2015-01-01"), ]
tr <- Filter(function(t) identical(t$name, "All banks"), plotly::plotly_build(
  metric_ts(list(F = f15), "NCLNLSR", FIELDS_META, c(F = "#000"), ind = iv))$x$data)[[1]]
got <- trace_at(tr)
stopifnot(identical(tr$line$dash, "dash"),
          min(as.Date(names(got))) == min(f15$date),                 # clipped to the bank's span
          isTRUE(all.equal(unname(got), round(iv$y[match(as.Date(names(got)), iv$date)], 2))))
tr0 <- plotly::plotly_build(metric_ts(list(), "NCLNLSR", FIELDS_META, NULL, ind = iv))$x$data
got0 <- trace_at(tr0[[1]])
stopifnot(length(tr0) == 1, identical(tr0[[1]]$line$dash, "solid"),
          max(as.Date(names(got0))) == max(iv$date),                  # alone: full history
          all(iv$date[is.finite(iv$y)] %in% as.Date(names(got0))))
cat("ok: metric_ts All banks line (every metric, $ mode hidden, clipped, alone)\n")
ok("risk_cushion pct", risk_cushion(dac))
ok("risk_cushion usd", risk_cushion(dac, mode = "usd"))
ok("risk_cushion pct df2", risk_cushion(dac, df2 = fbt))
ok("risk_cushion usd df2", risk_cushion(dac, mode = "usd", df2 = fbt))
ok("prov_nco_bars usd", prov_nco_bars(dac))
ok("prov_nco_bars pct", prov_nco_bars(dac, mode = "pct"))
ok("loan_mix pct", loan_mix(dac))
ok("loan_mix usd", loan_mix(dac, mode = "usd"))
ok("funding_share", funding_share(dac))
ok("funding_share df2", funding_share(dac, df2 = fbt))

# Fixed charts' "All banks" lines (ind_full: present whatever mart is on
# disk): which modes draw them, with a comparison bank or alone, values
# = summed dollars / summed denominator at the chart's rounding
nm_all <- function(p) grep("All banks", pl_names(p), value = TRUE)
fx <- list(
  list(f = function(...) risk_cushion(...), digits = 2, den = "LNLSGR",
       lines = c("Charge-offs" = "NTLNLSQ", "Allowance" = "LNATRES", "Noncurrent" = "NCLNLS"),
       from = as.Date("2019-01-01"), df2 = TRUE, usd = TRUE),
  list(f = function(...) prov_nco_bars(...), digits = 3, den = "LNLSGR",
       lines = c("Provision" = "ELNATQ", "Charge-offs" = "NTLNLSQ"),
       from = as.Date("2022-01-01"), df2 = FALSE, usd = TRUE),
  list(f = function(df, mode = "pct", ...) funding_share(df, ...), digits = 1, den = "DEP",
       lines = c("Core" = "COREDEP", "Brokered" = "BRO", "Uninsured" = "DEPUNINS"),
       from = as.Date("2015-01-01"), df2 = TRUE, usd = FALSE)
)
for (x in fx) {
  want <- paste(names(x$lines), "- All banks")
  stopifnot(identical(nm_all(x$f(dac, mode = "pct", ind = ind_full)), want),
            identical(nm_all(x$f(NULL, mode = "pct", ind = ind_full)), want),
            length(nm_all(x$f(dac, mode = "pct"))) == 0)            # no mart, no lines
  if (x$usd) stopifnot(length(nm_all(x$f(dac, mode = "usd", ind = ind_full))) == 0)
  if (x$df2) stopifnot(length(nm_all(x$f(dac, mode = "pct", df2 = fbt, ind = ind_full))) == 0)
  # Values, alone (solid) and beside a bank (dashed): same numbers
  w <- ind_full[order(ind_full$RISDATE), ]
  w <- w[as.Date(as.character(w$RISDATE), "%Y%m%d") >= x$from, ]
  for (alone in c(TRUE, FALSE)) {
    tr <- plotly::plotly_build(x$f(if (alone) NULL else dac, mode = "pct", ind = ind_full))$x$data
    for (k in names(x$lines)) {
      t <- Filter(function(t) identical(t$name, paste(k, "- All banks")), tr)[[1]]
      stopifnot(identical(t$line$dash, if (alone) "solid" else "dash"),
                isTRUE(all.equal(as.numeric(unlist(t$y)),
                                 round(100 * w[[x$lines[[k]]]] / w[[x$den]], x$digits))))
    }
  }
}
# Provision: lines share the bars' category axis, ordered by date
pp <- plotly::plotly_build(prov_nco_bars(dac, mode = "pct", ind = ind_full))
ca <- pp$x$layout$xaxis$categoryarray
stopifnot(all(unlist(pp$x$data[[3]]$x) %in% ca), all(dac$qlab[dac$RISDATE >= 20220101] %in% ca),
          identical(ca[1], "Q1'22"))
cat("ok: risk_cushion, prov_nco_bars, funding_share All banks lines\n")
# Loan Mix: industry bands (dashed edges beside a bank, filled alone), % only;
# each band = summed field / summed gross loans
lm_all <- function(...) Filter(function(t) grepl("- All banks$", t$name),
                               plotly::plotly_build(loan_mix(...))$x$data)
lb <- lm_all(dac, ind = ind_full); la <- lm_all(NULL, ind = ind_full)
w <- ind_full[order(ind_full$RISDATE), ]
w <- w[as.Date(as.character(w$RISDATE), "%Y%m%d") >= as.Date("2010-01-01"), ]
stopifnot(length(lb) == 7, length(la) == 7,
          identical(lb[[1]]$line$dash, "dash"), identical(la[[1]]$fillcolor, "#009E73"),
          isTRUE(all.equal(as.numeric(unlist(la[[6]]$y)), round(100 * w$LNCI / w$LNLSGR, 2))),
          length(lm_all(dac, mode = "usd", ind = ind_full)) == 0,
          length(lm_all(dac)) == 0)
cat("ok: loan_mix All banks bands\n")
# Funding Mix Core line = COREDEP/DEP, sharing the deposits denominator
# with Brokered and Uninsured (FDIC's COREDEPR is % of ASSETS, not deposits)
pf_core <- plotly::plotly_build(funding_share(dac))
core_tr <- Filter(function(t) identical(t$name, "Core"), pf_core$x$data)
stopifnot(length(core_tr) == 1)
dd15 <- dac[dac$date >= as.Date("2015-01-01"), ]
expect_core <- round(100 * dd15$COREDEP / dd15$DEP, 1)
got_core <- unlist(core_tr[[1]]$y)
stopifnot(length(got_core) == length(expect_core),
          all(abs(got_core - expect_core) < 1e-6, na.rm = TRUE),
          # and it is NOT the %-of-assets series it used to plot
          any(abs(got_core - round(dd15$COREDEPR, 1)) > 0.5, na.rm = TRUE))
cat("ok: funding core = COREDEP/DEP, not COREDEPR\n")

# Failure trajectories: baseline sanity, picked banks, baseline-only
bl <- fail_median(FAIL_PANEL, "NCLNLSR")
stopifnot(all(bl$qtrs_before >= 0), all(bl$qtrs_before <= 20),
          all(bl$n >= 5), all(is.finite(bl$med)))
cat("fail_median: ", nrow(bl), "quarters, n range",
    min(bl$n), "-", max(bl$n), "\n")

sub <- FAIL_PANEL |> filter(CERT %in% head(unique(FAIL_PANEL$CERT), 3))
tcols <- setNames(TRAJ_PALETTE[seq_along(unique(sub$label))],
                  unique(sub$label))
ok("trajectory_plot banks+baseline",
   trajectory_plot(sub, "NCLNLSR", FIELDS_META, baseline = bl, cols = tcols,
                   ref_df = dac, ref_label = "Dacotah (SD)"))
ok("trajectory_plot baseline only",
   trajectory_plot(sub[0, ], "NCLNLSR", FIELDS_META, baseline = bl))
# The reference bank draws its own last 21 quarters (t-20..0), not a flat
# line at its current value
pr <- plotly::plotly_build(
  trajectory_plot(sub, "NCLNLSR", FIELDS_META, baseline = bl, cols = tcols,
                  ref_df = dac, ref_label = "Dacotah (SD)")
)
ref_tr <- Filter(function(t) identical(t$line$dash, "dash"), pr$x$data)
stopifnot(length(ref_tr) == 1)
rx <- unlist(ref_tr[[1]]$x); ry <- unlist(ref_tr[[1]]$y)
stopifnot(length(rx) == 21, min(rx) == -20, max(rx) == 0,
          length(unique(ry[is.finite(ry)])) > 1)   # a history, not a constant
cat("ok: trajectory ref line = last 21 quarters\n")
# Dollar metric: scaled from $ thousands and unit-labeled, jointly with
# the baseline and reference line
pt <- plotly::plotly_build(
  trajectory_plot(sub, "ASSET", FIELDS_META,
                  baseline = fail_median(FAIL_PANEL, "ASSET"), cols = tcols,
                  ref_df = dac, ref_label = "Dacotah (SD)")
)
ttl <- pt$x$layout$yaxis$title
if (is.list(ttl)) ttl <- ttl$text
stopifnot(grepl("($", ttl, fixed = TRUE))
cat("ok: trajectory_plot usd scaled + labeled\n")

# Stress card (R/stress.R) on hand-built rows: equity from the bank's own
# history, NA in words (never $0), the stale-quarter label, each run cell
hl_fx <- data.frame(CERT = 1L, RISDATE = c(20260930L, 20260630L),
                    hidden_loss = c(2500, 3000), adj_equity_to_assets = c(0.05, 0.07),
                    pct_worst = c(0.10, 0.30), na_reason = NA_character_)
hist_fx <- data.frame(RISDATE = c("20260630", "20260930"), EQTOT = c(0, 5000),
                      ASSET = 50000)
d <- hl_bank(hl_fx, "1", hist_fx)
stopifnot(identical(d$RISDATE, c(20260630L, 20260930L)),          # oldest first
          isTRUE(all.equal(d$eq_to_assets, c(0, 0.1))),
          isTRUE(all.equal(d$loss_to_equity, c(NA, 0.5))),         # no equity: NA
          hl_has_series(d), nrow(hl_bank(hl_fx, "2", hist_fx)) == 0,
          is.null(hl_bank(NULL, "1", hist_fx)), is.null(stress_hidden_ui(NULL, 20260930)),
          is.null(rs_bank(NULL, "1")), is.null(stress_run_ui(NULL, 20260930)))
h <- as.character(stress_hidden_ui(d, 20260930))
stopifnot(grepl("$2.5M", h, fixed = TRUE), grepl("50% of equity", h, fixed = TRUE),
          grepl(">5% of assets<", h, fixed = TRUE), grepl("Reported: 10%", h, fixed = TRUE),
          grepl(">10th<", h, fixed = TRUE), grepl("vs. all banks", h, fixed = TRUE),
          grepl("Hidden losses, Q3 2026<", h, fixed = TRUE),
          !grepl("not latest", h, fixed = TRUE),
          grepl("Q3 2026 (not latest)",
                as.character(stress_hidden_ui(d, 20261231)), fixed = TRUE),
          grepl("No estimate.",
                as.character(stress_hidden_ui(d[0, ], 20260930)), fixed = TRUE))
d_na <- d[2, ]
d_na$hidden_loss <- NA; d_na$adj_equity_to_assets <- NA; d_na$pct_worst <- NA
d_na$na_reason <- "no loan maturity buckets"
h <- as.character(stress_hidden_ui(d_na, 20260930))
stopifnot(!hl_has_series(d_na), grepl('title="no loan maturity buckets"', h, fixed = TRUE),
          lengths(regmatches(h, gregexpr(">Not reported<", h, fixed = TRUE))) == 3,
          !grepl("$0", h, fixed = TRUE))
pe <- plotly::plotly_build(hidden_equity_lines(d))$x$data
stopifnot(identical(vapply(pe, `[[`, "", "name"), c("Reported", "After losses")),
          isTRUE(all.equal(as.numeric(unlist(pe[[1]]$y)), c(0, 10))),
          isTRUE(all.equal(as.numeric(unlist(pe[[2]]$y)), c(7, 5))))
rs_fx <- data.frame(CERT = 1L, RISDATE = 20260930L,
                    bp_unins = NA, how_unins = "never",
                    bp_unins_fhlb = NA, how_unins_fhlb = NA,
                    bp_all = 0.605, how_all = "below 2%",
                    bp_all_fhlb = 0.33, how_all_fhlb = "can't pay",
                    na_reason = "no FHLB advances reported (FHLB-on runs)")
h <- as.character(stress_run_ui(rs_bank(rs_fx, 1), 20260930))
stopifnot(grepl(">Survives<", h, fixed = TRUE),
          grepl("Fails at 60.5%<", h, fixed = TRUE),
          grepl("Fails at 33%<", h, fixed = TRUE),
          !grepl("(", sub(".*<tbody>", "", h), fixed = TRUE),     # no reasons in cells
          grepl('title="no FHLB advances reported">Not reported<', h, fixed = TRUE),
          grepl("Deposit run<", h, fixed = TRUE),
          grepl("Deposit run, Q3 2026 (not latest)",
                as.character(stress_run_ui(rs_fx, 20261231)), fixed = TRUE),
          grepl("No estimate.",
                as.character(stress_run_ui(rs_fx[0, ], 20260930)), fixed = TRUE),
          identical(run_na_why("no Tier 1 capital; no FHLB advances reported (FHLB-on runs)", "unins"),
                    "no Tier 1 capital"),
          identical(run_na_why("no uninsured deposits reported (uninsured runs)", "all"),
                    "inputs not reported"),
          identical(run_na_why(NA, "all"), "inputs not reported"))
# The shipped marts: every column the card reads, and no unexplained NA
stopifnot(is.null(read_mart_optional("no_such_mart")))
st <- load_stress()
if (is.null(st$hl) || is.null(st$rs)) {
  stop("hidden_loss and run_stress marts are missing from app/data: ",
       "gh release download data-marts --dir app/data --clobber")
}
stopifnot(all(c("CERT", "RISDATE", "hidden_loss", "adj_equity_to_assets", "pct_worst",
                "na_reason") %in% names(st$hl)),
          all(c("CERT", "RISDATE", "na_reason", paste0(rep(c("bp_", "how_"), each = 4),
                c("unins", "unins_fhlb", "all", "all_fhlb"))) %in% names(st$rs)),
          !any(is.na(st$hl$hidden_loss) & is.na(st$hl$na_reason)),
          all(st$rs$how_unins %in% c("never", "below 2%", "can't pay", NA)),
          length(unique(st$rs$RISDATE)) == 1, max(st$hl$RISDATE) >= st$rs$RISDATE[1])
cat("ok: stress card (hand-built rows, NA in words, stale label, runs; marts have its columns)\n")
cat("all builders ok\n")

# Server outputs via testServer, with a comparison bank active
setwd("..")
shiny::testServer(app = "app", {
  # Empty state: no bank picked yet, outputs carry the sidebar prompt
  err <- tryCatch({ output$kpis; NULL }, error = function(e) e)
  stopifnot(!is.null(err),
            grepl("Search for a bank", conditionMessage(err)))
  cat("ok: empty state before any pick\n")
  # ...except the Delinquency chart, which shows the industry lines alone
  pp <- jsonlite::fromJSON(output$pipeline_plot, simplifyVector = FALSE)
  pp_names <- vapply(pp$x$data, `[[`, "", "name")
  # Allowance always; the other two only if the mart has P3LNLS/NCLNLS
  stopifnot("Allowance - All banks" %in% pp_names, all(grepl("- All banks$", pp_names)),
            grepl("All FDIC-insured banks", output$pipeline_note$html))
  cat("ok: pipeline_plot industry-only before any pick\n")
  # Explorers and Sensitivity: the industry line alone, prompt in the
  # footnote; a metric with no industry line (Tier 1) keeps the prompt on
  # the chart. A mart predating a metric's fields falls back to the prompt.
  session$setInputs(earn_metric = "ROA", cap_metric = "RBC1AAJ")
  no_bank <- function(plot, caveat, needs) {
    if (all(needs %in% names(ind))) {
      pj <- jsonlite::fromJSON(output[[plot]], simplifyVector = FALSE)
      stopifnot(identical(vapply(pj$x$data, `[[`, "", "name"), "All banks"),
                grepl("All FDIC-insured banks", output[[caveat]]$html))
    } else {
      e <- tryCatch({ output[[plot]]; NULL }, error = function(e) e)
      stopifnot(grepl("Search for a bank", conditionMessage(e)))
    }
  }
  no_bank("earn_plot", "earn_caveat", c("NETINC", "ASSET"))
  no_bank("sens_plot", "sens_caveat", c("SCAF", "SCAA", "SCHF", "SCHA", "EQ"))
  e <- tryCatch({ output$cap_plot; NULL }, error = function(e) e)
  stopifnot(grepl("Search for a bank", conditionMessage(e)),
            !grepl("All banks", output$cap_caveat$html))
  cat("ok: explorers and sens_plot industry-only before any pick\n")
  # Reserves and Funding Mix: industry lines alone on the % views (if the
  # mart has their columns); rc and funding carry the prompt in their note
  session$setInputs(rc_mode = "pct", prov_mode = "pct")
  fixed_nb <- list(list("rc_plot", "rc_note", c("NTLNLSQ", "LNATRES", "NCLNLS", "LNLSGR"), TRUE),
                   list("prov_plot", "prov_note", c("ELNATQ", "NTLNLSQ", "LNLSGR"), FALSE),
                   list("funding_share_plot", "funding_note", c("COREDEP", "BRO", "DEPUNINS", "DEP"), TRUE))
  for (f in fixed_nb) {
    if (all(f[[3]] %in% names(ind))) {
      pj <- jsonlite::fromJSON(output[[f[[1]]]], simplifyVector = FALSE)
      stopifnot(all(grepl("- All banks$", vapply(pj$x$data, `[[`, "", "name"))),
                grepl("All FDIC-insured banks", output[[f[[2]]]]$html),
                grepl("Search for a bank", output[[f[[2]]]]$html) == f[[4]])
    } else if (f[[4]]) {
      e <- tryCatch({ output[[f[[1]]]]; NULL }, error = function(e) e)
      stopifnot(grepl("Search for a bank", conditionMessage(e)))
    }
  }
  session$setInputs(rc_mode = "usd")       # $ view: no industry, prompt on the chart
  e <- tryCatch({ output$rc_plot; NULL }, error = function(e) e)
  stopifnot(grepl("Search for a bank", conditionMessage(e)), is.null(output$rc_note$html))
  session$setInputs(rc_mode = "pct")
  cat("ok: rc, prov, funding industry-only before any pick\n")

  traj_picks <- as.character(head(FAIL_META$CERT, 3))
  session$setInputs(
    bank_pick = "17437", compare = "3973",
    rc_mode = "pct", mix_mode = "pct", prov_mode = "pct",
    traj_metric = "NCLNLSR",
    traj_region = c("Midwest", "Northeast", "South", "West"),
    traj_size = c("Under $100M", "$100M to $1B", "$1B to $10B", "Over $10B"),
    traj_banks = traj_picks,
    cap_metric = "RBC1AAJ", aq_metric = "NCLNLSR",
    earn_metric = "ROA", liq_metric = "LNLSDEPR"
  )
  outs <- c("kpis", "scale_plot", "overview_grid", "bs_table", "is_table",
            "ind_caption", "ind_bs_table", "ind_is_table",
            "ind_bs_plot", "ind_is_plot",
            "cap_plot", "cap_caveat", "cap_chip",
            "aq_plot", "earn_plot", "liq_plot",
            "pipeline_plot", "rc_plot", "prov_plot", "mix_plot",
            "funding_share_plot", "sens_plot", "sens_caveat",
            "traj_title", "traj_plot", "dict_table", "dict_full",
            "legal_docs")
  for (o in outs) {
    stopifnot(!is.null(output[[o]]))
    cat("ok output:", o, "\n")
  }
  stopifnot(length(sel_banks()) == 2)
  # Label comes from the live directory now, not a hand-written short name
  # in a shipped file, so assert against what bank_label() actually yields
  stopifnot(!is.null(cmp()), cmp()$label[1] == bank_label(3973, inst))
  cat("comparison bank active: yes\n")

  # With banks: the earnings explorer adds the All banks line (if the mart
  # has the fields) and keys it in the footnote; $ mode drops it
  ej <- jsonlite::fromJSON(output$earn_plot, simplifyVector = FALSE)
  has_roa <- all(c("NETINC", "ASSET") %in% names(ind))
  stopifnot(("All banks" %in% vapply(ej$x$data, function(t) t$name %||% "", "")) == has_roa,
            grepl("All banks\\*", output$earn_caveat$html) == has_roa)
  session$setInputs(liq_metric = "DEPUNINS", liq_display = "level")
  lj <- jsonlite::fromJSON(output$liq_plot, simplifyVector = FALSE)
  stopifnot(!"All banks" %in% vapply(lj$x$data, function(t) t$name %||% "", ""))
  session$setInputs(liq_display = "pct_assets")
  lj <- jsonlite::fromJSON(output$liq_plot, simplifyVector = FALSE)
  stopifnot(("All banks" %in% vapply(lj$x$data, function(t) t$name %||% "", "")) ==
              ("DEPUNINS" %in% names(ind)))
  cat("ok output: explorer All banks line with banks; hidden in $ mode\n")

  session$setInputs(fs_unit = "pct", fs_cmp = "yoy")
  stopifnot(grepl("% of total assets", output$bs_table$html, fixed = TRUE),
            grepl("% of revenue", output$is_table$html, fixed = TRUE))
  cat("ok output: statements in % vs 1 year ago\n")

  # Industry tables are cached (bindCache): each must keep its own section
  for (u in c("usd", "pct")) {
    session$setInputs(ind_unit = u, ind_cmp = "qoq")
    stopifnot(grepl("Net income", output$ind_is_table$html, fixed = TRUE),
              !grepl("Net income", output$ind_bs_table$html, fixed = TRUE))
  }
  cat("ok output: industry tables keep their own section under the cache\n")

  session$setInputs(prov_mode = "usd")
  stopifnot(!is.null(output$prov_plot))
  cat("ok output: prov_plot usd\n")

  # Industry lines (and their footer note) only without a comparison bank
  stopifnot(!grepl("Dashed", output$pipeline_note$html),
            is.null(output$rc_note$html), is.null(output$funding_note$html))
  session$setInputs(compare = character(0))
  stopifnot(is.null(cmp()), !is.null(output$pipeline_plot),
            grepl("Dashed = all FDIC-insured banks", output$pipeline_note$html))
  if ("NTLNLSQ" %in% names(ind)) {
    session$setInputs(rc_mode = "pct", prov_mode = "pct")
    rj <- jsonlite::fromJSON(output$rc_plot, simplifyVector = FALSE)
    stopifnot(sum(grepl("All banks", vapply(rj$x$data, function(t) t$name %||% "", ""))) == 3,
              grepl("Dashed = all FDIC-insured banks", output$rc_note$html),
              grepl("Dashed = all FDIC-insured banks", output$prov_note$html))
  }
  cat("ok output: pipeline_note shown only without a comparison bank\n")

  # Directory modal: table renders with one row per active bank, and a
  # row pick runs without error (inst here is the same INSTITUTIONS the
  # app loads: both come from snapshot_institutions)
  dir_payload <- jsonlite::fromJSON(output$dir_table)
  stopifnot(nrow(dir_payload$x$data) == nrow(inst))
  session$setInputs(browse_all = 1, dir_table_rows_selected = 2L)
  cat("ok output: dir_table + row pick\n")

  # Region filter shrinks the baseline set
  session$setInputs(traj_region = "Midwest")
  stopifnot(nrow(traj_meta_r()) < nrow(FAIL_META),
            all(traj_meta_r()$region == "Midwest"))
  stopifnot(!is.null(output$traj_plot))
  cat("ok output: traj_plot filtered to Midwest\n")

  # Stress card with both marts: caveat, both halves, the chart
  session$setInputs(bank_pick = "17437")
  sc <- output$stress_card$html
  stopifnot(grepl("Estimates.", sc, fixed = TRUE),
            grepl("Hidden losses, ", sc, fixed = TRUE),
            grepl("Deposit run", sc, fixed = TRUE),
            grepl("stress_plot", sc, fixed = TRUE))
  sp <- jsonlite::fromJSON(output$stress_plot, simplifyVector = FALSE)
  stopifnot(identical(vapply(sp$x$data, `[[`, "", "name"), c("Reported", "After losses")))
  cat("ok output: stress_card and stress_plot\n")
})

# Missing research marts: the app still runs and hides only what it lacks.
# The files are renamed aside (same folder: a rename across devices fails)
# and always put back.
mart_file <- function(m) file.path("app/data", paste0(m, ".parquet"))
aside <- function(m) paste0(mart_file(m), ".smoke-aside")
for (gone in list(c("hidden_loss", "run_stress"), "hidden_loss", "run_stress")) {
  stopifnot(file.rename(mart_file(gone), aside(gone)))
  tryCatch(shiny::testServer(app = "app", {
    session$setInputs(bank_pick = "17437")
    stopifnot(!is.null(output$kpis), !is.null(output$overview_grid))
    sc <- output$stress_card$html
    sc <- if (is.null(sc)) "" else as.character(sc)
    has_hl <- !"hidden_loss" %in% gone; has_rs <- !"run_stress" %in% gone
    stopifnot(grepl("Stress Test", sc, fixed = TRUE) == (has_hl || has_rs),
              grepl("Hidden losses, ", sc, fixed = TRUE) == has_hl,
              grepl("stress_plot", sc, fixed = TRUE) == has_hl,
              grepl("Deposit run", sc, fixed = TRUE) == has_rs,
              grepl("FHLB: loans up to", sc, fixed = TRUE) == has_rs)
    if (!has_hl) {
      e <- tryCatch({ output$stress_plot; NULL }, error = function(e) e)
      stopifnot(inherits(e, "error"))   # req() halts: no chart
    }
  }), finally = stopifnot(file.rename(aside(gone), mart_file(gone))))
  cat("ok output: stress card without", paste(gone, collapse = " + "), "\n")
}
cat("smoke test passed\n")
