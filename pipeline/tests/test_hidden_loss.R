# R/hidden_loss.R, marts/hidden_loss.R and checks/hidden_loss.R: a hand-built
# 5-bank quarter with hand-computed answers, real banks cut from raw
# (fixtures/hidden_loss_banks.rds), and the builder plus checks on temp files.
suppressPackageStartupMessages(library(nanoparquet))   # as in build.R
# Equal within tol, NA only where NA is expected
near <- function(a, b, tol = 1e-9) {
  length(a) == length(b) && identical(is.na(a), is.na(b)) &&
    all(abs(a - b)[!is.na(b)] <= tol)
}

expect(all(HL_FIELDS %in% strsplit(RAW_FIELDS, ",")[[1]]), "every field the estimator reads is pulled into raw")

# ---- Hand-built quarter -------------------------------------------------------
# Every HL field 0 unless set. Rates: 30y mortgage 7%, 10y Treasury 4%.
bank <- function(CERT, ...) {
  d <- as.data.frame(as.list(stats::setNames(rep(0, length(HL_FIELDS)), HL_FIELDS)))
  d$CERT <- CERT; d$RISDATE <- "20191231"
  for (v in names(list(...))) d[[v]] <- list(...)[[v]]
  d
}
no_buckets <- stats::setNames(as.list(rep(NA_real_, 20)), c(HL_LN_RES, HL_LN_OTH, HL_SC_NM, HL_SC_O))
cur <- rbind(
  # A: yield 4 * 10 / 1000 = 4%, gap 3 points. Loans: 100 x min(0.03 x 7.5, 0.5)
  #    + 500 x 0.03 x 0.1 = 22.5 + 1.5 = 24. HTM 20, AFS 10. Hidden 44.
  #    Securities model: yield 4 * 1.5 / 300 = 2%, gap 2 points, 100 x 0.02 x 7.5 = 15
  bank(1L, ASSET = 1500, EQTOT = 100, LNLSGR = 1000, ILNLSQ = 10, LNRSOV15 = 100,
       LNOT3LES = 500, SCHA = 200, SCHF = 180, SCAA = 100, SCAF = 90,
       SC = 300, ISCQ = 1.5, SCNMOV15 = 100, DEPUNINS = 60, DEPDOM = 100),
  # B: yield 8% > 7%: gap floored at 0, loss 0; unfloored gap -1 point on
  #    200 in the >15y bucket = a 15 gain in the symmetric variant
  bank(2L, ASSET = 100, EQTOT = 10, LNLSGR = 500, ILNLSQ = 10, LNOTOV15 = 200),
  # C: a thrift with no buckets, no HTM fair value, no loan income: NA, not 0
  do.call(bank, c(list(3L, ASSET = 50, EQTOT = 5, LNLSGR = 40, ILNLSQ = NA, SCHF = NA),
                  no_buckets)),
  # D: negative equity, yield 4 * 5 / 400 = 5%, gap 2 points on the short
  #    bucket: 400 x 0.02 x 0.1 = 0.8; adjusted (-5 - 0.8) / 100 = -5.8%
  bank(4L, ASSET = 100, EQTOT = -5, LNLSGR = 400, ILNLSQ = 5, LNOT3LES = 400),
  # E: insured branch of a foreign bank: no equity, but its HTM loss of 2 counts
  do.call(bank, c(list(5L, ASSET = 80, EQTOT = NA, SCHA = 10, SCHF = 8), no_buckets))
)
prev <- cur[c("CERT", "LNLSGR", "SC")]       # flat balances: average = current
prev$RISDATE <- "20190930"
rates <- data.frame(series = rep(c("MORTGAGE30US", "DGS10"), each = 3),
                    month_end = rep(c(20190930L, 20191231L, 20200331L), 2),
                    avg = rep(c(7, 4), each = 3))

h <- hidden_loss(cur, prev, rates)
expect(identical(h$CERT, 1:5), "every filer is a row, in order")
expect(near(h$loan_yield, c(0.04, 0.08, 0.05, 0.05, 0.05)) &&
         identical(h$loan_yield_imputed, c(FALSE, FALSE, TRUE, FALSE, TRUE)),
       "loan yields; missing ones (C: no income, E: no loans) get the median of the good ones (5%), flagged")
expect(near(h$loss_loans, c(24, 0, NA, 0.8, NA)),
       "loan loss: 24 for A, floored 0 for B, NA (not 0) without buckets")
expect(near(h$loss_loans_sym[2], -15), "symmetric variant: B shows a 15 gain")
expect(near(h$hidden_loss, c(44, 0, NA, 0.8, NA)) &&
         near(h$adj_equity_to_assets, c(56 / 1500, 0.1, NA, -0.058, NA)),
       "hidden loss: A 44 = HTM 20 + loans 24 (AFS 10 already in equity); negative-equity D kept at -5.8%")
expect(near(h$pct_worst, c(2 / 3, 1, NA, 1 / 3, NA)),
       "pct_worst: D worst (1/3); the NA banks are not ranked, so never 'safest'")
expect(identical(h$na_reason, c(NA, NA, "no securities fair value; no loan maturity buckets", NA,
                                "no equity or assets; no loan maturity buckets")),
       "na_reason names each input that was not reported")
expect(near(h$loss_sec_model, c(15, 0, NA, 0, NA)) && near(h$cal_factor, rep(2, 5)) &&
         near(h$loss_loans_cal[1], 48),
       "calibration: reported 30 / modeled 15 = 2, over banks with both")
expect(near(h$uninsured_share[1], 0.6) && is.na(h$uninsured_share[2]) &&
         identical(uninsured_share(5, 0), NA_real_), "uninsured share = DEPUNINS / DEPDOM, NA without DEPDOM")
expect(near(sum(h$loss_htm + h$loss_afs, na.rm = TRUE), 32), "E's HTM loss is in the industry sum")

low <- rates; low$avg[low$series == "DGS10"] <- 1   # 10y below every securities yield
expect(all(is.na(hidden_loss(cur, prev, low)$cal_factor)),
       "calibration NA, not Inf, when the modeled securities loss is 0")
expect(near(hidden_loss(cur, NULL, rates)$loan_yield[1:2], c(0.04, 0.08)),
       "without a previous quarter the yield uses this quarter's balance")
grow <- prev; grow$LNLSGR[1] <- 600   # average (1000 + 600) / 2 = 800
expect(near(hidden_loss(cur, grow, rates)$loan_yield[1], 0.05), "yield on the average balance")
expect_error(hidden_loss(cur, prev, rates[rates$month_end != 20191231L, ]),
             "no MORTGAGE30US for 20191231", "a missing rate month stops, never 0")

# ---- Real banks, cut from raw -----------------------------------------------------
fx <- readRDS(file.path("pipeline", "tests", "fixtures", "hidden_loss_banks.rds"))
svb <- hidden_loss(fx$svb$cur, fx$svb$prev, fx$rates)
expect(svb$loss_htm == 15159000 && round(svb$hidden_loss) == 15332059 &&
         round(100 * svb$adj_equity_to_assets, 1) == 0.1 && round(svb$loan_yield, 4) == 0.0612,
       "SVB 2022Q4: HTM loss $15.16B, hidden $15.33B, adjusted equity +0.1% of assets")
sd <- hidden_loss(fx$sd$cur, fx$sd$prev, fx$rates)
sd <- sd[match(c(17437L, 3973L), sd$CERT), ]
expect(identical(round(sd$hidden_loss), c(30420, 73579)) &&
         identical(round(sd$loss_htm + sd$loss_afs + sd$loss_loans), c(77173, 90836)),
       "2026Q3: Dacotah / First B&T hidden loss $30.4M / $73.6M; with AFS $77.2M / $90.8M")

# ---- Builder and checks, on temp raw files --------------------------------------
dir <- file.path(tempdir(), "hl_raw"); dir.create(dir, showWarnings = FALSE)
q0 <- cur; q0$RISDATE <- "20190930"; q0$LNRS3LES <- NA      # no bank has buckets yet
q1 <- cur; q1$ILNLSQ[c(3, 5)] <- c(0.4, 1); q1$LNLSGR[5] <- 100   # no yield imputed
q2 <- q1; q2$RISDATE <- "20200331"
files <- file.path(dir, paste0("risdate.", c(20200331, 20190930, 20191231), ".parquet"))
for (q in list(q2, q0, q1)) nanoparquet::write_parquet(q, file.path(dir, paste0("risdate.", q$RISDATE[1], ".parquet")))
b <- build_hidden_loss_history(files, rates)
expect(identical(sort(unique(b$history$RISDATE)), c(20191231L, 20200331L)) &&
         all(b$audit$has_prev),
       "builder: starts at the first quarter with buckets, the one before still gives balances")
expect(is.null(check_hidden_loss(b$history, b$audit, 20200331L)), "checks pass on the built history")
app <- hidden_loss_app(b$history, n = 1)
expect(identical(names(app), HL_APP_COLS) && all(app$RISDATE == 20200331L),
       "the app mart: newest quarters, app columns")

hist <- b$history
bad <- hist; bad$pct_worst[bad$CERT == 3] <- 0.5
expect_error(check_hidden_loss(bad, b$audit, 20200331L), "pct_worst set", "check: a ranked NA bank fails")
bad <- hist; bad$na_reason[bad$CERT == 3] <- NA
expect_error(check_hidden_loss(bad, b$audit, 20200331L), "without an na_reason", "check: an unexplained NA fails")
bad <- hist; bad$cal_factor[bad$RISDATE == 20200331L] <- Inf
expect_error(check_hidden_loss(bad, b$audit, 20200331L), "cal_factor out of range", "check: Inf cal_factor fails")
expect_error(check_hidden_loss(hist[hist$CERT != 5, ], b$audit, 20200331L), "rows != raw filers",
             "check: a lost bank fails")
expect_error(check_hidden_loss(hist[hist$RISDATE == 20191231L, ], b$audit[1, ], 20200331L),
             "lacks the newest", "check: a missing newest quarter fails")
bad <- hist; bad$loss_htm[1] <- bad$loss_htm[1] + 1
expect_error(check_hidden_loss(bad, b$audit, 20200331L), "do not sum to raw", "check: securities sum off raw fails")
unlink(dir, recursive = TRUE)
