# Step 2: per-bank "hidden loss" estimate. Reads cache/ from 01_fetch.R.
# Run from the repo root:  Rscript research/unrealized-losses/02_estimate.R
# Writes results_latest.csv, top25_latest.csv, backtest_2022q4.csv,
# summary.txt (all in research/unrealized-losses/).
#
# Dollar fields are $ thousands (FDIC convention).

options(width = 200)
DIR <- "research/unrealized-losses"
C   <- file.path(DIR, "cache")

# Assumptions (durations, caps, thresholds) and the estimate() function
# live in estimator.R so the backtest can reuse them unchanged.
source(file.path(DIR, "estimator.R"))

OUTCOLS <- c("CERT", "NAMEFULL", "STALP", "RISDATE", "ASSET", "EQTOT", "RBCT1J",
             "loan_yield", "loan_yield_imputed", "rate_gap",
             "loss_htm", "loss_afs", "loss_loans_res", "loss_loans_oth", "loss_loans",
             "loss_sec_model", "hidden_loss", "hidden_to_equity", "adj_equity",
             "adj_equity_to_assets", "all_loss_to_tier1", "DEPUNINS", "DEPDOM",
             "uninsured_share", "run_risk_flag", "loss_loans_cal",
             "adj_equity_cal_to_assets", "run_risk_flag_cal", "rank_hidden_to_equity",
             "rank_adj_equity_ratio", "rank_uninsured_share", "rank_adj_eq_in_high_unins")

RATIO_COLS <- c("loan_yield", "rate_gap", "hidden_to_equity", "adj_equity_to_assets",
                "all_loss_to_tier1", "uninsured_share", "adj_equity_cal_to_assets")
rnd <- function(d) {
  for (v in names(d)) if (is.double(d[[v]])) {
    d[[v]] <- if (v %in% RATIO_COLS) round(d[[v]], 4) else round(d[[v]])
  }
  d
}

latest <- as.integer(readLines(file.path(C, "latest_risdate.txt")))
source("app/R/api.R")   # prev_quarter_end() only; no network calls here
L <- estimate(latest, prev_quarter_end(latest))
B <- estimate(20221231L, 20220930L)

L <- L[order(L$rank_adj_equity_ratio), ]
write.csv(rnd(L[OUTCOLS]), file.path(DIR, "results_latest.csv"), row.names = FALSE)
top <- L[order(-L$hidden_to_equity), ][1:25, OUTCOLS]
write.csv(rnd(top), file.path(DIR, "top25_latest.csv"), row.names = FALSE)

FAILED <- c(24735, 57053, 59017)
bt <- B[B$CERT %in% FAILED, OUTCOLS]
write.csv(rnd(bt), file.path(DIR, "backtest_2022q4.csv"), row.names = FALSE)

# ---- Summary ---------------------------------------------------------------
bn <- function(x) sprintf("$%.0fB", sum(x, na.rm = TRUE) / 1e6)
pc <- function(x) sprintf("%.1f%%", 100 * x)
summ <- function(d, label) {
  big <- d$ASSET >= 1e8   # >= $100B
  c(sprintf("== %s (%d banks; 30y mortgage %.2f%%, 10y Treasury %.2f%%)",
            label, nrow(d), 100 * d$mtg_rate[1], 100 * d$t10_rate[1]),
    paste("HTM securities loss (reported):", bn(d$loss_htm)),
    paste("AFS securities loss (reported):", bn(d$loss_afs)),
    paste("Securities total (reported):   ", bn(d$loss_htm + d$loss_afs)),
    paste("Securities total (our model):  ", bn(d$loss_sec_model),
          sprintf("(bank-level correlation with reported: %.2f)",
                  cor(d$loss_sec_model, d$loss_htm + d$loss_afs, use = "complete.obs"))),
    paste("Loan MTM loss (model): 1-4 fam", bn(d$loss_loans_res),
          "+ other", bn(d$loss_loans_oth), "=", bn(d$loss_loans)),
    paste("Hidden loss (HTM + loans):     ", bn(d$hidden_loss),
          "vs total equity", bn(d$EQTOT),
          sprintf("= %s", pc(sum(d$hidden_loss) / sum(d$EQTOT)))),
    sprintf("Median bank loan yield %s; median rate gap %s; %d banks with yield imputed",
            pc(median(d$loan_yield)), pc(median(d$rate_gap)), sum(d$loan_yield_imputed)),
    sprintf("Banks with adjusted equity < 0: %d (assets %s)",
            sum(d$adj_equity < 0), bn(d$ASSET[d$adj_equity < 0])),
    sprintf("Banks with adjusted equity < 0, $100B+: %d", sum(d$adj_equity < 0 & big)),
    sprintf("Run-risk flags (adj equity < 0 AND uninsured > %s): %d",
            pc(UNINS_HIGH), sum(d$run_risk_flag, na.rm = TRUE)),
    sprintf("Calibrated variant (loan loss x %.2f): loans %s; adj equity < 0: %d banks (assets %s); run-risk flags: %d",
            d$cal_factor[1], bn(d$loss_loans_cal),
            sum(d$adj_equity_cal_to_assets < 0), bn(d$ASSET[d$adj_equity_cal_to_assets < 0]),
            sum(d$run_risk_flag_cal, na.rm = TRUE)),
    sprintf("Banks with uninsured share > %s: %d", pc(UNINS_HIGH),
            sum(d$uninsured_share > UNINS_HIGH, na.rm = TRUE)))
}
show <- function(d) {
  x <- d[c("CERT", "NAMEFULL", "ASSET", "hidden_to_equity", "adj_equity_to_assets",
           "adj_equity_cal_to_assets", "uninsured_share", "run_risk_flag",
           "run_risk_flag_cal", "rank_hidden_to_equity", "rank_adj_equity_ratio",
           "rank_uninsured_share", "rank_adj_eq_in_high_unins")]
  names(x) <- c("CERT", "NAME", "ASSET_B", "hid/eq", "adjEq/A", "adjEqCal/A",
                "unins", "flag", "flagCal", "rk_hid", "rk_adjEq", "rk_unins", "rk_inHiUnins")
  x$NAME <- substr(x$NAME, 1, 28)
  x$ASSET_B <- round(x$ASSET_B / 1e6, 1)
  for (v in c("hid/eq", "adjEq/A", "adjEqCal/A", "unins"))
    x[[v]] <- round(x[[v]], 3)
  capture.output(print(x, row.names = FALSE))
}
out <- c(summ(L, paste("Latest", latest)), "",
         "Top 25 by hidden loss / equity (ASSET in $B):", show(L[order(-L$hidden_to_equity), ][1:25, ]), "",
         "Flagged run-risk banks, latest:", show(L[which(L$run_risk_flag), ]), "",
         summ(B, "Backtest 20221231"), "",
         sprintf("Backtest: ranks out of %d banks (1 = worst)", nrow(B)),
         show(B[B$CERT %in% FAILED, ]), "",
         "Backtest: run-risk flagged banks at 2022Q4:", show(B[which(B$run_risk_flag), ]), "",
         "Backtest: top 15 by hidden loss / equity at 2022Q4:",
         show(B[order(-B$hidden_to_equity), ][1:15, ]), "",
         "Backtest: among banks with uninsured share > 50%, lowest 15 adjusted equity / assets:",
         show(head(B[order(B$rank_adj_eq_in_high_unins, na.last = NA), ], 15)))
writeLines(out, file.path(DIR, "summary.txt"))
cat(out, sep = "\n")
