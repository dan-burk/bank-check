# R/run_stress.R, marts/run_stress.R and checks/run_stress.R: a hand-built
# 5-bank quarter with hand-computed answers, real banks cut from raw plus
# their hidden_loss_history rows (fixtures/run_stress_banks.rds: SVB and
# Republic First 2022Q4, First B&T and Dacotah 2026Q3), and the builder
# plus checks on a temp raw file.
suppressPackageStartupMessages(library(nanoparquet))   # as in build.R
near <- function(a, b, tol = 1e-9) {
  length(a) == length(b) && identical(is.na(a), is.na(b)) &&
    all(abs(a - b)[!is.na(b)] <= tol)
}

expect(all(RS_FIELDS %in% strsplit(RAW_FIELDS, ",")[[1]]), "every field the simulator reads is pulled into raw")

# ---- Hand-built quarter -------------------------------------------------------
bank <- function(CERT, ...) {
  d <- as.data.frame(as.list(stats::setNames(rep(0, length(RS_FIELDS)), RS_FIELDS)))
  d$CERT <- CERT; d$RISDATE <- "20191231"
  for (v in names(list(...))) d[[v]] <- list(...)[[v]]
  d
}
# A: cash 60 (40 above the 2% floor), fed funds 10, AFS 200 at fair value
#    (cost 220: 10% loss per $1 sold), HTM 250 fair value (book 300: 20%
#    loss and write-off per $1), loans 300 at a 10% discount (loss 30).
A <- list(ASSET = 1000, RBCT1J = 80, DEP = 900, DEPDOM = 900, DEPUNINS = 400, CHBAL = 60,
          FREPO = 10, SCAA = 220, SCAF = 200, SCHA = 300, SCHF = 250, LNLSNET = 300, LNLSGR = 300)
cur <- rbind(
  do.call(bank, c(list(1L), A)),
  # B: A without uninsured deposits or FHLB advances reported
  do.call(bank, c(list(2L), utils::modifyList(A, list(DEPUNINS = NA, OTHBFHLB = NA)))),
  # C: trust company, no loans or securities: cash 3 (1 above the floor), deposits 5
  bank(3L, ASSET = 100, RBCT1J = 90, DEP = 5, DEPDOM = 5, DEPUNINS = 5, CHBAL = 3),
  # D: a loan book without a loss estimate (no maturity buckets)
  do.call(bank, c(list(4L), A)),
  # E: no deposits
  bank(5L, ASSET = 50, RBCT1J = 40, CHBAL = 50)
)
hl <- data.frame(CERT = 1:5, RISDATE = 20191231L, loss_loans_res = c(20, 20, 0, NA, 0),
                 loss_loans_oth = c(10, 10, 0, NA, 0))

d <- rs_inputs(cur, hl)
expect(near(d$loan_disc, c(0.1, 0.1, 0, NA, 0)), "loan discount 30 / 300; 0 with no loan book; NA (not 0) without an estimate")
expect(identical(d$ok_core, c(TRUE, TRUE, TRUE, FALSE, FALSE)) &&
         identical(d$ok_unins, c(TRUE, FALSE, TRUE, TRUE, TRUE)) &&
         identical(d$ok_fhlb, c(TRUE, FALSE, TRUE, TRUE, TRUE)),
       "inputs: D and E unusable, B lacks the uninsured and FHLB inputs")

# A, 50% uninsured run: need 200 = cash 40 + fed funds 10 + AFS 150 (loss
# 15). Tier 1 65, assets 1000 - 200 = 800, ratio 8.125%.
r <- run_sim(d[1, ], 0.5, "unins")
expect(near(c(r$need, r$from_cash, r$from_ffrp, r$from_afs, r$from_htm, r$loss, r$asset_after),
            c(200, 40, 10, 150, 0, 15, 800)) && near(r$ratio_after, 65 / 800),
       "A, 50% uninsured run: cash, fed funds, then AFS; ratio 8.125%")
# A, 50% all-deposit run: need 450 = 40 + 10 + AFS 200 (loss 20) + HTM 200
# (loss 40, written off 40). Tier 1 20, assets 1000 - 450 - 40 = 510.
r <- run_sim(d[1, ], 0.5, "all")
expect(near(c(r$from_afs, r$from_htm, r$loss, r$asset_after), c(200, 200, 60, 510)) &&
         near(r$ratio_after, 20 / 510) && r$under && !r$crit,
       "A, 50% all-deposit run: HTM sale writes off its loss; 3.9%, under 4% but not 2%")
# FHLB on: 25% x 1000 = 250 borrowed before any sale, so only 100 of AFS
r <- run_sim(d[1, ], 1, "unins", fhlb = TRUE)
expect(near(c(r$from_fhlb, r$from_afs, r$loss, r$asset_after), c(250, 100, 10, 850)),
       "FHLB on: borrowing comes before sales and adds back to assets")
# All-deposit breaking point. After cash, fed funds, AFS and HTM (s = 5/9)
# Tier 1 is 10 and assets 450. Each $1 from loans then costs 1/9 of Tier 1
# and 10/9 of assets: below 2% once 10 - y/9 < 0.02 (450 - 10y/9), y > 11.25,
# s > 511.25 / 900 = 0.568, so the first step is 0.570.
expect(near(run_sim(d[1, ], 0.570, "all")$ratio_after, (10 - 13 / 9) / (450 - 130 / 9)) &&
         !run_sim(d[1, ], 0.565, "all")$fails && run_sim(d[1, ], 0.570, "all")$fails,
       "A breaks at 57.0% of all deposits (56.5% survives)")
# C: 1 above the floor, then the 2 of floor cash, then nothing: a run of
# 3 / 5 = 60% is paid, 60.5% is not
expect(!run_sim(d[3, ], 0.6, "all")$cant_pay && run_sim(d[3, ], 0.605, "all")$cant_pay,
       "C can't pay past 60%")

rs <- run_stress(cur, hl)
expect(identical(rs$CERT, 1:5), "every filer is a row, in order")
expect(near(rs$bp_all, c(0.57, 0.57, 0.605, NA, NA)) &&
         identical(rs$how_all, c("below 2%", "below 2%", "can't pay", NA, NA)),
       "all-deposit run: A and B at 57%, C can't pay at 60.5%, D and E NA (not 'never')")
expect(identical(rs$how_unins, c("never", NA, "can't pay", NA, NA)) &&
         near(rs$bp_unins, c(NA, NA, 0.605, NA, NA)),
       "uninsured run: A never breaks; B (no DEPUNINS) is NA, not 'never'; C's deposits are all uninsured")
expect(near(rs$min_ratio_unins[1], 30 / 570), "A's lowest ratio, at a 100% uninsured run: 30 / 570")
expect(near(rs$pct_worst_all, c(0.5, 1, NA, NA, NA)) && near(rs$pct_worst_unins, c(1, NA, NA, NA, NA)),
       "percentiles: C (no loans or securities) and the NA banks are not ranked")
expect(identical(rs$na_reason, c(NA, "no uninsured deposits reported (uninsured runs); no FHLB advances reported (FHLB-on runs)",
                                 "no loans or securities: not ranked", "no loan loss estimate",
                                 "no deposits")),
       "na_reason names each missing input, and why C is not ranked")
expect(near(rs$unins_share, c(400 / 900, NA, 1, 400 / 900, NA)), "uninsured share = DEPUNINS / DEPDOM")
expect(identical(rs_rank(c(0.5, NA, 0.2, NA), c(0, 0.05, 0, 0.03), c(TRUE, TRUE, TRUE, FALSE)),
                 c(2L, 3L, 1L, NA)), "rank: smallest breaking point first, never after, NA unranked")

# ---- Real banks, cut from raw ------------------------------------------------------
fx <- readRDS(file.path("pipeline", "tests", "fixtures", "run_stress_banks.rds"))
q22 <- run_stress(fx$q2022$cur, fx$q2022$hl)
svb_in <- rs_inputs(fx$q2022$cur, fx$q2022$hl)
svb_in <- svb_in[svb_in$CERT == 24735, ]
r <- run_sim(svb_in, 0.4, "unins")
b <- function(x) round(x / 1e6, 1)
expect(identical(b(c(svb_in$ASSET, svb_in$DEP, svb_in$DEPUNINS, svb_in$RBCT1J)), c(209.0, 175.4, 151.6, 17.0)) &&
         identical(b(c(r$need, r$from_cash, r$from_ffrp, r$from_trade, r$from_afs, r$from_htm, r$from_loans)),
                   c(60.6, 8.3, 0.7, 0.1, 26.0, 25.5, 0)) &&
         identical(b(c(r$loss, r$t1_after, r$asset_after)), c(7.6, 9.4, 143.3)) &&
         round(100 * r$ratio_after, 2) == 6.56,
       "SVB 2022Q4, 40% uninsured run: the README walk-through (need 60.6, loss 7.6, ratio 6.56%)")
expect(near(q22$bp_unins, c(0.65, 0.38)[match(q22$CERT, c(24735L, 27332L))], 1e-9) &&
         all(q22$how_unins == "below 2%"),
       "2022Q4 uninsured run: SVB breaks at 65%, Republic First at 38%")
expect(near(q22$bp_unins_fhlb[q22$CERT == 24735], 0.895, 1e-9), "SVB with FHLB on: 89.5%")
expect(near(round(q22$unins_share, 3), c(0.939, 0.639)[match(q22$CERT, c(24735L, 27332L))]),
       "SVB uninsured share 93.9% of domestic deposits (86.4% of all deposits before trap 4)")
q26 <- run_stress(fx$q2026$cur, fx$q2026$hl)
expect(all(unlist(q26[paste0("how_", names(RS_CONFIGS))]) == "never"),
       "2026Q3: Dacotah and First B&T never break, in any of the four runs")

# ---- Builder and checks, on a temp raw file -----------------------------------
dir <- file.path(tempdir(), "rs_raw"); dir.create(dir, showWarnings = FALSE)
f <- file.path(dir, "risdate.20191231.parquet")
nanoparquet::write_parquet(cur, f)
bt <- build_run_stress(f, rbind(hl, transform(hl, RISDATE = 20190930L, loss_loans_res = 999)))
expect(near(bt$mart$bp_all, rs$bp_all) && near(bt$mart$loan_disc, rs$loan_disc),
       "builder: uses the newest quarter's hidden_loss rows only")
expect(is.null(check_run_stress(bt$mart, bt$inputs, 20191231L)), "checks pass on the built mart")
m <- bt$mart
bad <- m; bad$pct_worst_all[4] <- 0.5
expect_error(check_run_stress(bad, bt$inputs, 20191231L), "set for a bank without a run", "check: a ranked NA bank fails")
bad <- m; bad$na_reason[5] <- NA
expect_error(check_run_stress(bad, bt$inputs, 20191231L), "NA without an na_reason", "check: an unexplained NA fails")
bad <- m; bad$bp_all[1] <- 0.571
expect_error(check_run_stress(bad, bt$inputs, 20191231L), "off the run-size grid", "check: a breaking point off the grid fails")
bad <- m; bad$bp_all[1] <- 0.5
expect_error(check_run_stress(bad, bt$inputs, 20191231L), "does not break", "check: a wrong breaking point fails")
bad <- m; bad$how_unins[1] <- "below 2%"
expect_error(check_run_stress(bad, bt$inputs, 20191231L), "set without a break", "check: a break without a breaking point fails")
expect_error(check_run_stress(m, bt$inputs, 20200331L), "not for the newest", "check: an old quarter fails")
expect_error(check_run_stress(m[-2, ], bt$inputs, 20191231L), "rows != raw filers", "check: a lost bank fails")
expect_error(build_run_stress(f, transform(hl, RISDATE = 20190930L)), "no rows for 20191231",
             "builder: hidden_loss without the quarter stops")
unlink(dir, recursive = TRUE)
