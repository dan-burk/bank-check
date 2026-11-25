# Step 2: per-bank "hidden loss" estimate. Reads cache/ from 01_fetch.R.
# Run from the repo root:  Rscript research/unrealized-losses/02_estimate.R
# Writes results_latest.csv, top25_latest.csv, backtest_2022q4.csv,
# summary.txt (all in research/unrealized-losses/).
#
# Dollar fields are $ thousands (FDIC convention).

options(width = 200)
DIR <- "research/unrealized-losses"
C   <- file.path(DIR, "cache")

# ---- Assumptions (all in one place) ---------------------------------------
# Effective duration (years) for each remaining-maturity / next-repricing
# bucket: roughly "how many % a loan's value drops per 1 point rise in
# rates". Below the bucket midpoint because loans pay down principal
# monthly. The long buckets assume slow prepayment, which is what happens
# when borrowers hold below-market mortgages.
DUR <- c(b3m = 0.1, b3to12m = 0.5, b1to3y = 1.8, b3to5y = 3.5,
         b5to15y = 5.5, bover15y = 7.5)
LN_RES <- c("LNRS3LES", "LNRS3T12", "LNRS1T3", "LNRS3T5", "LNRS5T15", "LNRSOV15")
LN_OTH <- c("LNOT3LES", "LNOT3T12", "LNOT1T3", "LNOT3T5", "LNOT5T15", "LNOTOV15")
SC_NM  <- c("SCNM3LES", "SCNM3T12", "SCNM1T3", "SCNM3T5", "SCNM5T15", "SCNMOV15")
SC_PT  <- c("SCPT3LES", "SCPT3T12", "SCPT1T3", "SCPT3T5", "SCPT5T15", "SCPTOV15")
DUR_SCO <- c(SCO3YLES = 1.5, SCOOV3Y = 5)   # other MBS (CMOs), two buckets
MAX_DROP <- 0.5        # cap on any modeled price drop
UNINS_HIGH <- 0.50     # "high" uninsured-deposit share for the run flag
YIELD_BOUNDS <- c(0.01, 0.15)  # implausible loan yields -> industry median
# ---------------------------------------------------------------------------

num <- function(x) as.numeric(x)

# Quarter-end market rate: average of the FRED series over the quarter's
# last calendar month (the balance sheet date).
fred_month_avg <- function(series, risdate) {
  f <- read.csv(file.path(C, paste0("fred_", series, ".csv")))
  names(f) <- c("date", "v")
  f$v <- suppressWarnings(as.numeric(f$v))
  ym <- substr(as.character(risdate), 1, 6)
  mean(f$v[gsub("-", "", substr(f$date, 1, 7)) == ym], na.rm = TRUE) / 100
}

bucket_loss <- function(d, cols, gap) {
  m <- as.matrix(d[cols]); m[is.na(m)] <- 0
  drop <- pmin(outer(gap, unname(DUR)), MAX_DROP)  # bank x bucket price drop
  rowSums(m * drop)
}

estimate <- function(risdate, prev_risdate) {
  d  <- readRDS(file.path(C, paste0("fdic_", risdate, ".rds")))
  dp <- readRDS(file.path(C, paste0("fdic_", prev_risdate, ".rds")))
  for (v in setdiff(names(d), c("NAMEFULL", "STALP"))) d[[v]] <- num(d[[v]])
  d$LNLSGR_PREV <- num(dp$LNLSGR[match(d$CERT, dp$CERT)])
  d$SC_PREV     <- num(dp$SC[match(d$CERT, dp$CERT)])

  mtg  <- fred_month_avg("MORTGAGE30US", risdate)
  t10  <- fred_month_avg("DGS10", risdate)

  # Bank's own average loan yield: quarterly loan interest x 4 / average loans
  avg_ln <- ifelse(is.na(d$LNLSGR_PREV), d$LNLSGR, (d$LNLSGR + d$LNLSGR_PREV) / 2)
  y <- 4 * d$ILNLSQ / avg_ln
  bad <- is.na(y) | !is.finite(y) | y < YIELD_BOUNDS[1] | y > YIELD_BOUNDS[2]
  med_y <- median(y[!bad])
  d$loan_yield_imputed <- bad
  d$loan_yield <- ifelse(bad, med_y, y)

  # Rate gap: what a new mortgage pays today minus what this bank earns.
  d$rate_gap <- pmax(0, mtg - d$loan_yield)
  d$loss_loans_res <- bucket_loss(d, LN_RES, d$rate_gap)
  d$loss_loans_oth <- bucket_loss(d, LN_OTH, d$rate_gap)
  d$loss_loans <- d$loss_loans_res + d$loss_loans_oth

  # Reported securities losses (positive = loss)
  d$loss_htm <- d$SCHA - d$SCHF
  d$loss_afs <- d$SCAA - d$SCAF

  # Model check: apply the SAME duration method to securities, using the
  # bank's securities yield vs the 10-year Treasury, and compare with the
  # reported fair values above.
  avg_sc <- ifelse(is.na(d$SC_PREV), d$SC, (d$SC + d$SC_PREV) / 2)
  sy <- 4 * d$ISCQ / avg_sc
  sbad <- is.na(sy) | !is.finite(sy) | sy < 0.002 | sy > 0.12
  sy[sbad] <- median(sy[!sbad])
  sgap <- pmax(0, t10 - sy)
  sco <- as.matrix(d[names(DUR_SCO)]); sco[is.na(sco)] <- 0
  d$loss_sec_model <- bucket_loss(d, SC_NM, sgap) + bucket_loss(d, SC_PT, sgap) +
    rowSums(sco * pmin(outer(sgap, unname(DUR_SCO)), MAX_DROP))

  # Outputs
  d$hidden_loss <- d$loss_htm + d$loss_loans          # NOT in reported equity
  d$hidden_to_equity <- d$hidden_loss / d$EQTOT
  d$adj_equity <- d$EQTOT - d$hidden_loss             # AFS loss already in EQTOT
  d$adj_equity_to_assets <- d$adj_equity / d$ASSET
  # Tier 1 view: most banks opted out of counting AFS losses in regulatory
  # capital, so for Tier 1 all three losses are "hidden". We do not know
  # each bank's opt-out status; this assumes everyone opted out.
  d$all_loss_to_tier1 <- (d$loss_htm + d$loss_afs + d$loss_loans) / d$RBCT1J
  d$uninsured_share <- d$DEPUNINS / d$DEPDOM
  d$run_risk_flag <- d$adj_equity < 0 & d$uninsured_share > UNINS_HIGH

  d$mtg_rate <- mtg
  d$t10_rate <- t10
  d <- d[!is.na(d$EQTOT) & d$EQTOT > 0 & d$ASSET > 0, ]   # drops a few odd filers

  # Calibrated variant: securities are the one place we know the right
  # answer, so scale the loan loss by how much the same method under- or
  # over-shoots on securities industry-wide (reported / modeled).
  d$cal_factor <- sum(d$loss_htm + d$loss_afs, na.rm = TRUE) /
    sum(d$loss_sec_model, na.rm = TRUE)
  d$loss_loans_cal <- d$loss_loans * d$cal_factor
  d$adj_equity_cal_to_assets <- (d$EQTOT - d$loss_htm - d$loss_loans_cal) / d$ASSET
  d$run_risk_flag_cal <- d$adj_equity_cal_to_assets < 0 & d$uninsured_share > UNINS_HIGH
  # Ranks (1 = worst)
  d$rank_hidden_to_equity <- rank(-d$hidden_to_equity, ties.method = "min")
  d$rank_adj_equity_ratio <- rank(d$adj_equity_to_assets, ties.method = "min")
  d$rank_uninsured_share  <- rank(-d$uninsured_share, ties.method = "min", na.last = "keep")
  # Rank on adjusted equity among only the banks with high uninsured share
  hi <- which(d$uninsured_share > UNINS_HIGH)
  d$rank_adj_eq_in_high_unins <- NA_integer_
  d$rank_adj_eq_in_high_unins[hi] <- rank(d$adj_equity_to_assets[hi], ties.method = "min")
  d
}

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
