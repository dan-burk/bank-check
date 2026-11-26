# Hidden losses: the headline numbers, read from the published marts. The
# estimate itself is pipeline/R/hidden_loss.R; this script fetches nothing
# and computes no losses. Run from the repo root after downloading:
#   gh release download data-marts --dir pipeline/out/marts --pattern 'hidden_loss_history.parquet'
#   gh release download data-marts --dir pipeline/out/marts --pattern 'bank_ids.parquet'
#   gh release download data-raw   --dir pipeline/out/raw   --pattern 'failures.parquet'
#   Rscript research/unrealized-losses/analyze.R
# Writes research/unrealized-losses/summary.txt. Dollars are $ thousands.

suppressPackageStartupMessages(library(nanoparquet))
options(width = 200)
OUT <- "research/unrealized-losses/summary.txt"
rd <- function(f) as.data.frame(read_parquet(file.path("pipeline", "out", f)))
h   <- rd("marts/hidden_loss_history.parquet")
ids <- rd("marts/bank_ids.parquet")
fl  <- rd("raw/failures.parquet")

LATEST <- max(h$RISDATE)
STRESS <- 20221231L   # the quarter before the 2023 run on SVB and others
# The 2023 failures, from the FDIC list (not a typed-in CERT list)
fl$fail_date <- as.Date(fl$FAILDATE, "%m/%d/%Y")
stopifnot(!anyNA(fl$fail_date))
failed23 <- fl$CERT[fl$RESTYPE == "FAILURE" & format(fl$fail_date, "%Y") == "2023"]

bn <- function(x) sprintf("$%.0fB", sum(x, na.rm = TRUE) / 1e6)
pc <- function(x) sprintf("%.1f%%", 100 * x)
summ <- function(d) {
  ok <- !is.na(d$adj_equity_to_assets)
  neg <- ok & d$adj_equity_to_assets < 0
  negc <- !is.na(d$adj_equity_cal_to_assets) & d$adj_equity_cal_to_assets < 0
  c(sprintf("== %d: %d filers, %d with an estimate (%d NA: %s); 30y mortgage %.2f%%, 10y Treasury %.2f%%",
            d$RISDATE[1], nrow(d), sum(ok), sum(!ok),
            paste(names(table(d$na_reason)), table(d$na_reason), sep = " x", collapse = ", "),
            100 * d$mtg_rate[1], 100 * d$t10_rate[1]),
    paste("Securities loss (reported): HTM", bn(d$loss_htm), "+ AFS", bn(d$loss_afs),
          "=", bn(d$loss_htm + d$loss_afs), "| our model on securities:", bn(d$loss_sec_model)),
    paste("Loan loss (model): 1-4 family", bn(d$loss_loans_res), "+ other",
          bn(d$loss_loans_oth), "=", bn(d$loss_loans)),
    sprintf("Hidden loss (HTM + loans): %s vs equity %s = %s", bn(d$hidden_loss),
            bn(d$EQTOT[ok]), pc(sum(d$hidden_loss[ok]) / sum(d$EQTOT[ok]))),
    sprintf("Median loan yield %s; median rate gap %s; %d yields imputed",
            pc(median(d$loan_yield)), pc(median(d$rate_gap)), sum(d$loan_yield_imputed)),
    sprintf("Adjusted equity < 0: %d banks (assets %s); with uninsured > 50%%: %d",
            sum(neg), bn(d$ASSET[neg]), sum(d$run_risk_flag, na.rm = TRUE)),
    if (is.na(d$cal_factor[1])) "Calibrated variant: NA this quarter (cal_factor not usable)"
    else sprintf("Calibrated (loans x %.2f): loans %s; adjusted equity < 0: %d banks (assets %s); flags %d",
                 d$cal_factor[1], bn(d$loss_loans_cal), sum(negc), bn(d$ASSET[negc]),
                 sum(d$run_risk_flag_cal, na.rm = TRUE)))
}
show <- function(d) {
  x <- data.frame(CERT = d$CERT, NAME = substr(ids$NAMEFULL[match(d$CERT, ids$CERT)], 1, 28),
                  ASSET_B = round(d$ASSET / 1e6, 1), hidden_M = round(d$hidden_loss / 1e3),
                  adjEq_A = round(d$adj_equity_to_assets, 3),
                  adjEqCal_A = round(d$adj_equity_cal_to_assets, 3),
                  unins = round(d$uninsured_share, 2), pct_worst = round(d$pct_worst, 4),
                  flag = d$run_risk_flag, flagCal = d$run_risk_flag_cal)
  capture.output(print(x, row.names = FALSE))
}

L <- h[h$RISDATE == LATEST, ]
B <- h[h$RISDATE == STRESS, ]
hi <- B[which(B$uninsured_share > 0.5), ]
hi$pct_in_high <- rank(hi$adj_equity_to_assets, ties.method = "max", na.last = "keep") /
  sum(!is.na(hi$adj_equity_to_assets))
f23 <- B[B$CERT %in% failed23, ]
out <- c(summ(L), "",
         "Worst 25 by adjusted equity / assets (pct_worst: share of banks at or below):",
         show(utils::head(L[order(L$adj_equity_to_assets), ], 25)), "",
         summ(B), "",
         sprintf("2023 failures at %d (%d banks with >50%% uninsured; pct_in_high = place among them):",
                 STRESS, nrow(hi)),
         capture.output(print(merge(
           data.frame(CERT = f23$CERT, NAME = substr(ids$NAMEFULL[match(f23$CERT, ids$CERT)], 1, 28),
                      hidden_B = round(f23$hidden_loss / 1e6, 2), adjEq_A = round(f23$adj_equity_to_assets, 4),
                      adjEqCal_A = round(f23$adj_equity_cal_to_assets, 4), unins = round(f23$uninsured_share, 2),
                      pct_worst = round(f23$pct_worst, 4), flag = f23$run_risk_flag, flagCal = f23$run_risk_flag_cal),
           data.frame(CERT = hi$CERT, pct_in_high = round(hi$pct_in_high, 3)), all.x = TRUE),
           row.names = FALSE)))
writeLines(out, OUT)
cat(out, sep = "\n")
