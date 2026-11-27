# The nightly HMDA valuation (R/hmda_book.R hb_value(), marts/hmda_book.R,
# checks/hmda_book.R, SOURCE_HMDA) on hand-built groups and flat rates with
# closed-form answers, plus the four research banks (fixture cut from the
# stored groups, rates_monthly and raw 2026-09-30) against research #20.

VAL <- 20260930L
# rates_monthly rows for both mortgage series, Jan 2018 to Sep 2026: every
# month's average at hist30/hist15, and the val month's last reading at now30/now15
flat_rates <- function(hist30, hist15 = hist30, now30 = hist30, now15 = hist15) {
  me <- month_end(seq(as.Date("2018-01-01"), as.Date("2026-09-01"), by = "month"))
  one <- function(s, h, now) data.frame(series = s, month_end = me, avg = h,
                                        last = ifelse(me == VAL, now, h), complete = TRUE)
  rbind(one("MORTGAGE30US", hist30, now30), one("MORTGAGE15US", hist15, now15))
}
grp <- function(CERT = 1L, year = 2021L, term_m = 360L, coupon = 3, fixed = TRUE,
                reset_m = NA_integer_, kept = TRUE, usd_k = 100) {
  data.frame(CERT = CERT, year = year, term_m = term_m, coupon = coupon, fixed = fixed,
             reset_m = reset_m, kept = kept, n = 1L, usd_k = usd_k)
}
no_prepay <- utils::modifyList(HB_PARAMS, list(cpr_below = 0, cpr_above = 0))
near <- function(a, b, tol = 1e-9) isTRUE(all(abs(a - b) <= tol))

# Closed forms per $1 of a level-payment loan: scheduled balance after k
# months, and the value of payments k+1..n at monthly rate r
c3 <- 0.03 / 12; r7 <- 0.07 / 12; n <- 360; k <- 62    # 1 Jul 2021 -> 30 Sep 2026
sched_bal <- function(c, n, k) ((1 + c)^n - (1 + c)^k) / ((1 + c)^n - 1)
pmt <- function(c, n) c / (1 - (1 + c)^(-n))
annuity <- function(r, m) (1 - (1 + r)^(-m)) / r

# ---- One 3% 30-year loan from 2021 valued at 7% (spec golden test) ------------
v <- hb_value(grp(), flat_rates(7), VAL, no_prepay)
B <- sched_bal(c3, n, k); PV <- pmt(c3, n) * annuity(r7, n - k)
expect(near(v$bal_k, 100 * B, 1e-7) && near(v$pv_k, 100 * PV, 1e-7) &&
         near(v$loss_pv, 1 - PV / B, 1e-12),
       sprintf("3%% 30y 2021 loan at 7%%, no prepayment: balance %.4f, value %.4f, loss %.2f%% (closed form)",
               B, PV, 100 * (1 - PV / B)))
pv_at <- function(r) pmt(c3, n) * annuity(r / 1200, n - k)
expect(near(v$duration, (pv_at(6.5) - pv_at(7.5)) / (pv_at(7) * 0.01), 1e-9) &&
         near(v$wac, 0.03) && near(v$mkt_rate, 0.07) &&
         near(v$loss_dur, v$duration * 0.04),
       "duration: +/- 0.5 point bump of the closed form; WAC, rate, shortcut")

# ---- Prepayment: refinance above the going rate + 0.5, home sales below --------
smm <- function(cpr) 1 - (1 - cpr)^(1 / 12)
c8 <- 0.08 / 12; s <- smm(0.20)
j <- 0:n
Bj <- sched_bal(c8, n, j) * (1 - s)^j                  # pool balance with constant SMM
cf <- c8 * Bj[-length(Bj)] + Bj[-length(Bj)] - Bj[-1]  # payment in month 1..n
pv8 <- sum(cf[(k + 1):n] / (1 + r7)^(1:(n - k)))
v <- hb_value(grp(coupon = 8), flat_rates(7), VAL)
expect(near(v$bal_k / 100, Bj[k + 1], 1e-12) && near(v$pv_k / 100, pv8, 1e-12),
       "8% loan with rates at 7%: prepays at cpr_above all its life (closed form)")
v <- hb_value(grp(coupon = 5), flat_rates(3, now30 = 7), VAL)
expect(near(v$bal_k / 100, sched_bal(0.05 / 12, n, k) * (1 - s)^k, 1e-12),
       "5% loan, past rates 3%: refinanced at cpr_above in past months (FRED history, not today's rate)")
v6 <- hb_value(grp(coupon = 5), flat_rates(7), VAL)
expect(near(v6$bal_k / 100, sched_bal(0.05 / 12, n, k) * (1 - smm(0.06))^k, 1e-12),
       "5% loan, rates 7%: only home sales (cpr_below)")

# ---- ARMs, 15-year rate, a 0% coupon --------------------------------------------
v <- hb_value(grp(coupon = 7, fixed = FALSE, reset_m = 84L), flat_rates(7), VAL, no_prepay)
expect(near(v$loss_pv, 0, 1e-12) && v$bal_k > 0,
       "7/1 ARM at the market rate: payments to the reset plus par at the reset are worth the balance")
v <- hb_value(grp(coupon = 3, fixed = FALSE, reset_m = 60L), flat_rates(7), VAL)
expect(v$bal_k == 0 && is.na(v$wac) && is.na(v$loss_pv) && v$na_reason == "no kept balance left",
       "5/1 ARM from 2021: reset (repaid at par) before 2026-09, nothing left, NA with a reason")
v <- hb_value(grp(term_m = 180L, coupon = 6), flat_rates(7, 6), VAL, no_prepay)
expect(near(v$loss_pv, 0, 1e-12) && near(v$mkt_rate, 0.06),
       "a 15-year loan is priced off MORTGAGE15US")
v <- hb_value(grp(coupon = 0), flat_rates(7), VAL, no_prepay)
expect(near(v$bal_k / 100, 1 - k / n, 1e-12) && v$loss_pv > 0,
       "a coupon rounded to 0%: straight-line balance, not NaN")

# ---- Per-bank sums: kept, valued, NA groups counted, never filled -----------------
g <- rbind(grp(CERT = 1L, usd_k = 100),                        # valued
           grp(CERT = 1L, coupon = 5, usd_k = 200, kept = FALSE), # sold: not valued
           grp(CERT = 1L, coupon = NA, usd_k = 30),              # no coupon: counted
           grp(CERT = 1L, year = 2019L, term_m = NA, usd_k = 20),  # no term: never 360
           grp(CERT = 2L, kept = FALSE),                         # sold everything
           grp(CERT = 3L, fixed = NA, year = 2024L))             # fixed/ARM unknown
v <- hb_value(g, flat_rates(7), VAL)
one <- hb_value(grp(), flat_rates(7), VAL)
expect(identical(v$CERT, 1:3) && near(v$kept_k, c(150, 0, 100)) &&
         near(v$valued_share[c(1, 3)], c(100 / 150, 0)) && is.na(v$valued_share[2]),
       "per bank: kept dollars and the share valued; a bank that kept nothing has NA share")
expect(near(v$bal_k[1], one$bal_k) && near(v$wac[1], one$wac) && near(v$loss_pv[1], one$loss_pv),
       "per bank: unvalued and sold groups add nothing to the valuation")
expect(identical(v$na_reason, c(NA, "kept no loans", "no kept loans with a rate, term and fixed/ARM status")) &&
         identical(v$hmda_year_max, c(2021L, 2021L, 2024L)),
       "per bank: na_reason for each NA, newest HMDA year")
vy <- hb_value(g[g$CERT == 1L, ], flat_rates(7), VAL, by = c("CERT", "year"))
expect(identical(vy$year, c(2019L, 2021L)) && vy$na_reason[1] == "no kept loans with a rate, term and fixed/ARM status",
       "by vintage (research tables): one row per CERT and year")
r <- flat_rates(7)
expect_error(hb_value(g, r[!(r$series == "MORTGAGE15US" & r$month_end == 20220131L), ], VAL), "gaps",
             "a missing rates month after the first valued vintage stops")
expect(nrow(hb_value(g, r[r$month_end >= 20210101L, ], VAL)) == 3,
       "rates before the first valued vintage are not needed")
r <- flat_rates(7); r$complete[r$month_end == VAL] <- FALSE
expect_error(hb_value(g, r, VAL), "no complete MORTGAGE30US month", "an incomplete val month stops")

# ---- Mart: call-report book, dropped CERTs, na_reason ------------------------------
cur <- data.frame(CERT = c(1L, 3L), RISDATE = VAL)
for (b in HL_LN_RES) cur[[b]] <- c(50, 10)
cur$LNRS3LES[2] <- NA
m <- build_hmda_book(g, cur, flat_rates(7))
hb <- m$mart
expect(identical(m$dropped, 2L) && identical(hb$CERT, c(1L, 3L)),
       "mart: a CERT with groups but no filing is dropped and counted")
expect(hb$book_k[1] == 300 && near(hb$hmda_share[1], one$bal_k / 300, 1e-5) &&
         is.na(hb$na_reason[1]) && hb$RISDATE[1] == VAL && hb$method_version[1] == "hb-1",
       "mart: book = the LNRS buckets, hmda_share = balance left / book")
expect(is.na(hb$book_k[2]) && is.na(hb$hmda_share[2]) &&
         hb$na_reason[2] == "no kept loans with a rate, term and fixed/ARM status; no 1-4 family first-lien buckets in the call report",
       "mart: an unreported bucket is NA (not 0), with every reason")
pooled <- hmda_book_pooled(g, flat_rates(7), VAL)
expect(is.null(check_hmda_book(hb, m$dropped, pooled, g, VAL)), "check passes on the fixture")
bad <- hb; bad$na_reason[2] <- NA
expect_error(check_hmda_book(bad, m$dropped, pooled, g, VAL), "without an na_reason",
             "check: an NA without a reason fails")
bad <- hb; bad$wac[1] <- 0.3
expect_error(check_hmda_book(bad, m$dropped, pooled, g, VAL), "wac outside", "check: wac out of range fails")
expect_error(check_hmda_book(hb, integer(0), pooled, g, VAL), "neither a row nor counted",
             "check: a lost CERT fails")
bad <- pooled; bad$loss_dur <- bad$loss_pv + 0.011
expect_error(check_hmda_book(hb, m$dropped, bad, g, VAL), "more than 1 point apart",
             "check: pooled PV loss and duration shortcut more than 1 point apart fails")

# ---- The four research banks (#20, valuation date 2026-09-30) ----------------------
fx <- readRDS(file.path("pipeline", "tests", "fixtures", "hmda_book_banks.rds"))
m <- build_hmda_book(fx$groups, fx$cur, fx$rates)
hb <- m$mart[match(c(30012L, 27981L, 5296L, 17437L), m$mart$CERT), ]
# research/hmda-mortgage-rates/results/book_summary.csv (deleted in this PR)
r20 <- data.frame(wac = c(4.1356, 4.0107, 4.1150, 6.0537), mkt = c(6.9226, 6.9344, 7.0081, 6.7728),
                  dur = c(4.4964, 4.8718, 3.8277, 1.9896), loss = c(0.1234, 0.1382, 0.1106, 0.0231))
same <- 1:3   # Third Federal, Capitol Federal, Associated
expect(near(100 * hb$wac[same], r20$wac[same], 1e-3) && near(100 * hb$mkt_rate[same], r20$mkt[same], 1e-3) &&
         near(hb$duration[same], r20$dur[same], 1e-3) && near(hb$loss_pv[same], r20$loss[same], 1e-4),
       "research banks: Third Federal, Capitol Federal, Associated reproduce #20 (WAC, rate, duration, loss)")
# Dacotah moved: its $0.67M of kept loans with no term (#20 filled 360) are not valued
expect(near(100 * hb$wac[4], 6.041, 1e-3) && near(hb$loss_pv[4], 0.02351, 1e-5) && hb$valued_share[4] < 1,
       "research banks: Dacotah 6.04% / 2.35% (#20: 6.05% / 2.31%, NA terms no longer read as 30 years)")
expect(near(hb$hmda_share, c(0.58490, 0.69196, 0.94643, 0.23701), 1e-5),
       "research banks: share of the LNRS first-lien book")
pooled <- hmda_book_pooled(fx$groups, fx$rates, VAL)
expect(is.null(check_hmda_book(m$mart, m$dropped, pooled, fx$groups, VAL)), "check passes on the research banks")

# ---- SOURCE_HMDA: the nightly check of the stored groups ---------------------------
old_raw <- if (exists("RAW")) RAW
RAW <<- tempfile("raw_"); dir.create(RAW)
expect_error(SOURCE_HMDA$run(list()), "no stored hmda.groups.parquet", "source: no stored groups fails")
nanoparquet::write_parquet(g[setdiff(names(g), "usd_k")], file.path(RAW, "hmda.groups.parquet"))
expect_error(SOURCE_HMDA$run(list()), "lacks usd_k", "source: groups without usd_k fail")
nanoparquet::write_parquet(g, file.path(RAW, "hmda.groups.parquet"))
expect(file.exists(SOURCE_HMDA$run(list())) && is.na(SOURCE_HMDA$last_pull()),
       "source: stored groups pass; no older copy to fall back on")
unlink(RAW, recursive = TRUE)
RAW <<- old_raw
