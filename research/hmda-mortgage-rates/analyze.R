# HMDA mortgage book: the tables behind README.md, from the published
# releases. The valuation is pipeline/R/hmda_book.R (the hmda_book mart
# calls the same hb_value()); this script fetches nothing. It reads the
# mart for the four study banks, checks that hb_value() on the stored
# groups gives the same numbers, and runs what stays research: the
# prepayment sensitivity, the vintage table, the South Dakota benchmark and
# the industry ranking. Run from the repo root after downloading:
#   gh release download data-marts --dir pipeline/out/marts --pattern 'hmda_book.parquet'
#   gh release download data-marts --dir pipeline/out/marts --pattern 'rates_monthly.parquet'
#   gh release download data-raw   --dir pipeline/out/raw   --pattern 'hmda.groups.parquet'
#   gh release download data-raw   --dir pipeline/out/raw   --pattern 'hmda.lar.*.parquet'   # SD benchmark, ~80 MB
#   gh release download data-raw   --dir pipeline/out/raw   --pattern 'risdate.2026*.parquet'  # the valuation quarter and the one before
#   Rscript research/hmda-mortgage-rates/analyze.R
# Writes research/hmda-mortgage-rates/summary.txt. Needs data.table (for
# hmda_groups(), as in the pipeline's HMDA job). Dollars are $ thousands.

suppressPackageStartupMessages({ library(nanoparquet); library(data.table) })
options(width = 200)
source("app/R/api.R")                    # prev_quarter_end()
for (f in c("R/hidden_loss.R", "R/hmda_book.R")) source(file.path("pipeline", f))
OUT <- "research/hmda-mortgage-rates/summary.txt"
rd <- function(f, ...) as.data.frame(read_parquet(file.path("pipeline", "out", f), ...))

# The study banks (all open), picked from FDIC data on 2026-11-25
BANKS <- data.frame(CERT  = c(30012L, 27981L, 5296L, 17437L),
                    label = c("Third Federal S&L (OH)", "Capitol Federal (KS)",
                              "Associated Bank (WI)", "Dacotah Bank (SD)"))
BENCH_STATE <- "SD"                      # every FDIC bank's loans on this state's homes
CPR_SENS <- c(0.04, 0.06, 0.10)          # sensitivity runs for HB_PARAMS$cpr_below

mart   <- rd("marts/hmda_book.parquet")
rates  <- rd("marts/rates_monthly.parquet")
groups <- rd("raw/hmda.groups.parquet")
VAL <- mart$RISDATE[1]                   # the newest quarter the mart was valued at
cr <- rd(sprintf("raw/risdate.%d.parquet", VAL), col_select = c("CERT", "NAMEFULL", "EQTOT", "LNLSGR", "ILNLSQ"))
cr_prev <- rd(sprintf("raw/risdate.%d.parquet", prev_quarter_end(VAL)), col_select = c("CERT", "LNLSGR"))
mk <- hb_market(rates, VAL)
r2 <- function(x, d = 2) round(x, d)

# ---- The four banks: the mart, and the same function on the groups ---------
g4 <- groups[groups$CERT %in% BANKS$CERT, ]
m4 <- mart[match(BANKS$CERT, mart$CERT), ]
v4 <- hb_value(g4, rates, VAL)
v4 <- v4[match(BANKS$CERT, v4$CERT), ]
stopifnot(all(abs(v4$loss_pv - m4$loss_pv) < 1e-5), all(abs(v4$wac - m4$wac) < 1e-5))
i <- match(BANKS$CERT, cr$CERT); j <- match(BANKS$CERT, cr_prev$CERT)
sens <- sapply(CPR_SENS, function(cpr) {
  v <- hb_value(g4, rates, VAL, utils::modifyList(HB_PARAMS, list(cpr_below = cpr)))
  100 * v$loss_pv[match(BANKS$CERT, v$CERT)]
})
book <- data.frame(
  bank = BANKS$label, wac = r2(100 * m4$wac, 3), mkt = r2(100 * m4$mkt_rate, 3), dur = r2(m4$duration, 1),
  loss_pv = r2(100 * m4$loss_pv, 1), loss_dur = r2(100 * m4$loss_dur, 1),
  setNames(as.data.frame(r2(sens, 1)), sprintf("cpr%02d", round(100 * CPR_SENS))),
  valued = r2(m4$valued_share, 3), bal_M = round(m4$bal_k / 1e3), book_M = round(m4$book_k / 1e3),
  share = r2(m4$hmda_share), est_loss_M = round(m4$loss_pv * m4$book_k / 1e3),
  pct_equity = round(100 * m4$loss_pv * m4$book_k / cr$EQTOT[i]),
  cr_yield = r2(100 * 4 * cr$ILNLSQ[i] / ((cr$LNLSGR[i] + cr_prev$LNLSGR[j]) / 2)))

# ---- Vintages: what each bank made and kept, and what is left of it ---------
gs <- hmda_group_summary(g4)
vy <- hb_value(g4, rates, VAL, by = c("CERT", "year"))
vint <- merge(gs, vy[c("CERT", "year", "bal_k", "wac", "loss_pv")], by = c("CERT", "year"), all.x = TRUE)
vint <- data.frame(bank = BANKS$label[match(vint$CERT, BANKS$CERT)], year = vint$year,
                   orig_M = round(vint$usd_k / 1e3), kept_sh = r2(vint$kept_share),
                   rate_kept = r2(vint$wac_kept), cov = r2(vint$rate_coverage),
                   bal_now_M = round(vint$bal_k / 1e3), wac_now = r2(100 * vint$wac),
                   loss = r2(100 * vint$loss_pv, 1))
vint <- vint[order(match(vint$bank, BANKS$label), vint$year), ]

# ---- Benchmark: every FDIC bank's loans on South Dakota homes, as one book --
years <- sort(as.integer(sub("^hmda\\.lar\\.(\\d{4})\\.parquet$", "\\1",
                             list.files("pipeline/out/raw", "^hmda\\.lar\\.\\d{4}\\.parquet$"))))
cols <- c("activity_year", "state_code", "purchaser_type", "loan_amount", "interest_rate",
          "loan_term", "intro_rate_period")
sd <- do.call(rbind, lapply(years, function(y) {
  d <- rd(sprintf("raw/hmda.lar.%d.parquet", y), col_select = cols)
  d[d$state_code %in% BENCH_STATE, ]
}))
sd$CERT <- 0L
gsd <- hmda_groups(sd)
bench <- sapply(CPR_SENS, function(cpr) {
  v <- hb_value(gsd, rates, VAL, utils::modifyList(HB_PARAMS, list(cpr_below = cpr)))
  c(wac = 100 * v$wac, mkt = 100 * v$mkt_rate, dur = v$duration, loss_pv = 100 * v$loss_pv,
    loss_dur = 100 * v$loss_dur, valued = v$valued_share)
})
sds <- hmda_group_summary(gsd)

# ---- Every HMDA bank: pooled, spread, and the 20 largest losses vs equity ----
ok <- !is.na(mart$loss_pv)
w <- function(x) sum(x[ok] * mart$bal_k[ok]) / sum(mart$bal_k[ok])
q <- stats::quantile(mart$loss_pv[ok], c(0.1, 0.25, 0.5, 0.75, 0.9))
k <- match(mart$CERT, cr$CERT)
rank_d <- data.frame(CERT = mart$CERT, NAME = substr(cr$NAMEFULL[k], 1, 34),
                     bal_M = round(mart$bal_k / 1e3), share = r2(mart$hmda_share),
                     wac = r2(100 * mart$wac), loss_pv = r2(100 * mart$loss_pv, 1),
                     pct_equity = r2(100 * mart$loss_pv * mart$book_k / cr$EQTOT[k], 1))
# Scaled to the whole first-lien book only where HMDA explains most of it,
# and not much more (a share well above 1 means "kept" loans were sold later)
rank_d <- rank_d[ok & mart$bal_k >= 1e5 & mart$hmda_share >= 0.5 & mart$hmda_share <= 1.1 &
                   cr$EQTOT[k] > 0, ]
rank_d <- utils::head(rank_d[order(-rank_d$pct_equity), ], 20)

out <- c(
  sprintf("Valuation date %d, method %s. Today's rates: 30y %.2f%%, 15y %.2f%% (MORTGAGE30US/15US, last weekly reading). HMDA %d-%d.",
          VAL, HB_PARAMS$method_version, mk$r30$now, mk$r15$now, min(years), max(years)),
  "",
  "== The four banks (hmda_book mart; hb_value() on the stored groups gives the same numbers)",
  "   loss_pv: 1 - value / balance left; loss_dur: duration x (mkt - wac); cprNN: loss_pv with cpr_below = NN%;",
  "   valued: share of kept dollars with a rate, term and fixed/ARM status; book: LNRS first liens (call report);",
  "   share = bal / book; est_loss = loss_pv x book; pct_equity = est_loss / EQTOT; cr_yield: all loans, ILNLSQ x 4 / average LNLSGR",
  capture.output(print(book, row.names = FALSE)),
  "",
  "== Vintages (kept_sh, rate_kept and cov from the groups; bal_now, wac_now and loss at the valuation date)",
  capture.output(print(vint, row.names = FALSE)),
  "",
  sprintf("== All FDIC banks, %s homes, one book: %d loans, $%.0fM kept of $%.0fM made %d-%d", BENCH_STATE,
          sum(sds$n), sum(sds$usd_kept_k) / 1e3, sum(sds$usd_k) / 1e3, min(sds$year), max(sds$year)),
  capture.output(print(data.frame(cpr_below = 100 * CPR_SENS, r2(t(bench), 3)),
                       row.names = FALSE)),
  sprintf("   rate coverage of kept dollars by year: %s",
          paste(sprintf("%d %.0f%%", sds$year, 100 * sds$rate_coverage), collapse = ", ")),
  "",
  sprintf("== Every HMDA bank (%d rows, %d valued): balance $%.0fB, WAC %.2f%%, loss %.1f%% (balance-weighted)",
          nrow(mart), sum(ok), sum(mart$bal_k) / 1e6, 100 * w(mart$wac), 100 * w(mart$loss_pv)),
  sprintf("   loss_pv across banks: p10 %.1f%%, p25 %.1f%%, median %.1f%%, p75 %.1f%%, p90 %.1f%%",
          100 * q[1], 100 * q[2], 100 * q[3], 100 * q[4], 100 * q[5]),
  sprintf("   banks with no valued loans: %d (%s)", sum(!ok),
          paste(names(table(mart$na_reason[!ok])), table(mart$na_reason[!ok]), sep = " x", collapse = "; ")),
  "   Largest est_loss / equity, banks with >= $100M left and HMDA share 0.5-1.1:",
  capture.output(print(rank_d, row.names = FALSE)))
writeLines(out, OUT)
cat(out, sep = "\n")
