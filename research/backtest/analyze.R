# Backtest: score the hidden-loss estimate against every failure since 1997,
# era by era, with no look-ahead. The estimate is the hidden_loss_history
# mart (pipeline/R/hidden_loss.R); this script fetches nothing and computes
# no losses. Run from the repo root after downloading:
#   gh release download data-marts --dir pipeline/out/marts --pattern 'hidden_loss_history.parquet'
#   gh release download data-marts --dir pipeline/out/marts --pattern 'bank_ids.parquet'
#   gh release download data-raw   --dir pipeline/out/raw   --pattern 'risdate.*.parquet'
#   gh release download data-raw   --dir pipeline/out/raw   --pattern 'failures.*'
#   Rscript research/backtest/analyze.R
# The BTFP borrowers are the committed pipeline/static/btfp.borrowers.csv.
# Writes summary.txt here, and the CSVs chart.R reads (plus the full
# tables) to research/backtest/out/ (gitignored). Dollars are $ thousands.

t_start <- Sys.time()
suppressPackageStartupMessages(library(nanoparquet))
options(width = 200)
source("pipeline/sources/btfp.R")        # btfp_read(), btfp_source(), check_btfp()
DIR <- "research/backtest"
dir.create(file.path(DIR, "out"), showWarnings = FALSE)
rd <- function(f, ...) as.data.frame(read_parquet(file.path("pipeline", "out", f), ...))

# ---- Settings --------------------------------------------------------------
PUB_LAG <- 45      # days from quarter end until the call report is public
HORIZON <- 365     # "failed within the next 4 quarters" after it is public
TOP     <- c(0.01, 0.05)   # watch-list sizes: worst 1% and worst 5%
N_BOOT  <- 2000
# Eras, by the year a report became public. Kept apart because banks failed
# for different reasons in each.
ERA_BREAKS <- c(1996, 2007, 2012, 2021, 2030)
ERA_NAMES  <- c("1997-2007", "2008-2012", "2013-2021", "2022-2026")
# "Failure" for this backtest (spec trap 5): FAILURE plus open-bank
# ASSISTANCE, from 1997. The app's failures tab uses FAILURE from 2000.
FAIL_TYPES <- c("FAILURE", "ASSISTANCE")
FAIL_FROM  <- 1997
# Cause of each 2022-2026 failure, from the closing regulator / Inspector
# General (sources in README.md). "rate+run" = the kind of failure the
# hidden-loss idea is about; the others it is not designed to see. A new
# failure stops the script until it is added here.
CAUSE <- data.frame(
  CERT = c(24735, 57053, 59017, 25851, 8758, 27332, 4134, 28611, 5520,
           57488, 25796, 28722, 25744),
  group = c("rate+run", "rate+run", "rate+run", "fraud", "credit",
            "rate+run", "fraud", "fraud", "fraud",
            "credit", "credit", "credit", "credit"),
  cause = c("Uninsured run after securities losses",
            "Contagion run; poor management, fast growth",
            "Uninsured run; low-rate mortgage and securities losses",
            "CEO wired funds into a crypto scam",
            "Bad commercial (trucking) loans",
            "Underwater HTM securities; failed recapitalization",
            "Falsified records, fraud by ex-CEO",
            "Missing deposit liabilities (suspected fraud)",
            "Hidden loan losses, misreporting (suspected fraud)",
            "Impaired capital, problem loan",
            "Problem SBA loans under consent order",
            "Unsafe practices, losses; critically undercapitalized",
            "Ongoing operating losses; critically undercapitalized"))

# ---- 1. Inputs ---------------------------------------------------------------
KEEP <- c("CERT", "RISDATE", "ASSET", "EQTOT", "LNLSGR", "DEPUNINS", "DEPDOM",
          "uninsured_share", "hidden_loss", "loss_htm", "loss_loans", "loss_loans_sym",
          "loss_loans_cal", "loan_yield", "rate_gap_raw", "bucket_cov",
          "adj_equity_to_assets", "adj_equity_sym_to_assets", "adj_equity_cal_to_assets",
          "run_risk_flag", "run_risk_flag_cal", "cal_factor", "mtg_rate", "na_reason",
          "method_version")
panel <- rd("marts/hidden_loss_history.parquet", col_select = KEEP)
ids <- rd("marts/bank_ids.parquet", col_select = c("CERT", "NAMEFULL", "RSSD"))
panel$NAMEFULL <- ids$NAMEFULL[match(panel$CERT, ids$CERT)]
qs <- sort(unique(panel$RISDATE))
# Tier 1 leverage ratio (a baseline score) is not an estimator input: take it
# from each raw quarter
t1 <- do.call(rbind, lapply(qs, function(q)
  rd(sprintf("raw/risdate.%d.parquet", q), col_select = c("CERT", "RISDATE", "RBC1AAJ"))))
panel$RBC1AAJ <- as.numeric(t1$RBC1AAJ)[match(paste(panel$CERT, panel$RISDATE),
                                              paste(t1$CERT, t1$RISDATE))]
stopifnot(nrow(t1) == nrow(panel), !anyNA(panel$NAMEFULL))
rm(t1)
# "Observed so far" = the day the failures list was pulled
TODAY <- as.Date(substr(utils::read.csv("pipeline/out/raw/failures.manifest.csv")$pulled_at, 1, 10))
t_est <- Sys.time()

# ---- 2. Falling rates: how often the gap is negative, and how big the -------
#         hidden GAINS would be without the floor (all banks, before filters)
gap_q <- do.call(rbind, lapply(split(panel, panel$RISDATE), function(d) {
  neg <- d$rate_gap_raw < 0
  data.frame(RISDATE = d$RISDATE[1], mtg_rate = d$mtg_rate[1],
             median_loan_yield = median(d$loan_yield),
             share_banks_gap_negative = mean(neg),
             share_loans_gap_negative = sum(d$LNLSGR[neg], na.rm = TRUE) /
               sum(d$LNLSGR, na.rm = TRUE),
             loan_loss_floored_bn = sum(d$loss_loans, na.rm = TRUE) / 1e6,
             loan_loss_symmetric_bn = sum(d$loss_loans_sym, na.rm = TRUE) / 1e6,
             htm_loss_bn = sum(d$loss_htm, na.rm = TRUE) / 1e6,
             equity_bn = sum(d$EQTOT, na.rm = TRUE) / 1e6,
             share_banks_no_buckets = mean(is.na(d$loss_loans)),
             share_banks_bucket_cov_lt50 = mean(d$bucket_cov < 0.5, na.rm = TRUE))
}))
gap_q$loan_loss_floored_pct_equity   <- gap_q$loan_loss_floored_bn / gap_q$equity_bn
gap_q$loan_loss_symmetric_pct_equity <- gap_q$loan_loss_symmetric_bn / gap_q$equity_bn
rownames(gap_q) <- NULL
gap_period <- function(from, to) {
  g <- gap_q[gap_q$RISDATE >= from & gap_q$RISDATE <= to, ]
  p <- panel[panel$RISDATE >= from & panel$RISDATE <= to, ]
  data.frame(period = paste0(from %/% 10000, "-", to %/% 10000),
             quarters = nrow(g),
             mortgage_rate = sprintf("%.1f%% -> %.1f%%", 100 * g$mtg_rate[1], 100 * tail(g$mtg_rate, 1)),
             share_bankqtrs_gap_negative = round(mean(p$rate_gap_raw < 0), 3),
             avg_symmetric_pct_equity = round(mean(g$loan_loss_symmetric_pct_equity), 3),
             most_negative_pct_equity = round(min(g$loan_loss_symmetric_pct_equity), 3),
             most_negative_bn = round(min(g$loan_loss_symmetric_bn)),
             avg_floored_pct_equity = round(mean(g$loan_loss_floored_pct_equity), 3))
}
last_q <- max(qs)
gap_tab <- rbind(gap_period(19970630, 20071231), gap_period(20080331, 20121231),
                 gap_period(20130331, 20181231), gap_period(20190331, 20211231),
                 gap_period(20220331, last_q))

# ---- 3. Labels, no look-ahead -----------------------------------------------
fl <- rd("raw/failures.parquet")
fl$fail_date <- as.Date(fl$FAILDATE, "%m/%d/%Y")
stopifnot(!anyNA(fl$fail_date))   # spec trap 14: a format change must not drop labels
fl <- fl[fl$RESTYPE %in% FAIL_TYPES & as.integer(format(fl$fail_date, "%Y")) >= FAIL_FROM, ]
fl$CERT <- as.integer(fl$CERT)
fl$CITYST <- paste0(fl$CITY, ", ", fl$PSTALP)
fl <- merge(fl[c("CERT", "NAME", "CITYST", "fail_date", "RESTYPE", "RESTYPE1", "QBFASSET")],
            CAUSE, by = "CERT", all.x = TRUE)
fl <- fl[order(fl$fail_date), ]
stopifnot(!anyNA(fl$group[fl$fail_date >= as.Date("2022-01-01")]))

panel$qend <- as.Date(as.character(panel$RISDATE), "%Y%m%d")
panel$pub  <- panel$qend + PUB_LAG
# A CERT can have more than one event (open-bank ASSISTANCE in 2008-09, and
# the bank kept filing). So label each report by events relative to it:
#   gone: a failure between quarter end and publication (the report could
#         not have warned anyone) -> dropped
#   y:    a failure within HORIZON after publication
panel$gone <- FALSE; panel$y <- FALSE
panel$fail_date <- as.Date(NA)
rows_by_cert <- split(seq_len(nrow(panel)), panel$CERT)
for (i in seq_len(nrow(fl))) {
  ix <- rows_by_cert[[as.character(fl$CERT[i])]]
  if (is.null(ix)) next
  fd <- fl$fail_date[i]
  panel$gone[ix] <- panel$gone[ix] | (fd > panel$qend[ix] & fd <= panel$pub[ix])
  hit <- fd > panel$pub[ix] & fd <= panel$pub[ix] + HORIZON
  panel$fail_date[ix[hit]] <- fd
  panel$y[ix] <- panel$y[ix] | hit
}
gone <- panel$gone
panel <- panel[!gone, ]
panel$complete <- panel$pub + HORIZON <= TODAY
panel$era <- cut(as.integer(format(panel$pub, "%Y")), ERA_BREAKS, labels = ERA_NAMES)

# ---- 4. Scores (higher = riskier) and within-quarter ranks -------------------
panel$t1lev <- ifelse(panel$RBC1AAJ > 0, panel$RBC1AAJ, NA)   # 0 = not reported
panel$eq_ta <- panel$EQTOT / panel$ASSET
ok <- with(panel, is.finite(eq_ta) & is.finite(t1lev) & is.finite(adj_equity_to_assets) &
             is.finite(adj_equity_sym_to_assets) & is.finite(uninsured_share) &
             !(LNLSGR > 0 & bucket_cov %in% 0))
# Before 2012 the savings institutions that filed the OTS Thrift Financial
# Report (~10% of banks, ~17% of loans; WaMu, IndyMac, ...) have neither the
# loan buckets nor HTM fair values in the FDIC API, so the mart has NA for
# them (na_reason) and they drop out here.
dropped <- panel[!ok, ]
panel <- panel[ok, ]   # same banks and quarters for every score
drop_why <- table(ifelse(is.na(dropped$na_reason),
                         "estimate present, another input missing (Tier 1, uninsured share, or zero buckets)",
                         dropped$na_reason))

# share of banks in the same quarter at least as risky (0.01 = worst 1%).
# Every score here is finite on the panel; an NA (the calibrated variant in
# a quarter without a cal_factor) stays NA, never "safest" (spec trap 8).
pct_worst <- function(risk, q) ave(risk, q, FUN = function(r)
  rank(-r, ties.method = "average", na.last = "keep") / sum(!is.na(r)))
q <- panel$RISDATE
p_adj     <- pct_worst(-panel$adj_equity_to_assets, q)
p_adj_cal <- pct_worst(-panel$adj_equity_cal_to_assets, q)
p_eq      <- pct_worst(-panel$eq_ta, q)
p_unins   <- pct_worst(panel$uninsured_share, q)
SCORES <- list(   # name -> within-quarter percentile from the worst end
  eq_ta            = p_eq,
  tier1_leverage   = pct_worst(-panel$t1lev, q),
  adj_eq           = p_adj,
  adj_eq_sym       = pct_worst(-panel$adj_equity_sym_to_assets, q),
  adj_eq_cal       = p_adj_cal,
  eq_ta_plus_unins = pct_worst(-(p_eq + p_unins), q),         # control
  adj_plus_unins   = pct_worst(-(p_adj + p_unins), q),
  adj_cal_plus_unins = pct_worst(-(p_adj_cal + p_unins), q))
LABEL <- c(eq_ta = "Baseline: reported equity / assets",
           tier1_leverage = "Baseline: Tier 1 leverage ratio",
           adj_eq = "Ours: adjusted equity / assets (base, floored)",
           adj_eq_sym = "Ours: adjusted equity / assets (symmetric, no floor)",
           adj_eq_cal = "Ours: adjusted equity / assets (calibrated)",
           eq_ta_plus_unins = "Control: reported equity rank + uninsured rank",
           adj_plus_unins = "Ours + uninsured: adj. equity rank + uninsured rank (base)",
           adj_cal_plus_unins = "Ours + uninsured: adj. equity rank + uninsured rank (calibrated)")
for (s in names(SCORES)) panel[[paste0("p_", s)]] <- SCORES[[s]]
rm(SCORES, p_adj, p_adj_cal, p_eq, p_unins, q)

# For each positive bank-quarter: share of negative bank-quarters ranked
# safer than it (ties count half). AUC = the average of these.
auc_parts <- function(p, y) {
  pn <- sort(p[!y]); x <- p[y]
  hi <- findInterval(x, pn); lo <- findInterval(x, pn, left.open = TRUE)
  (length(pn) - hi + 0.5 * (hi - lo)) / length(pn)
}

# ---- 5. Era metrics (the headline) -------------------------------------------
CORE <- c("eq_ta", "tier1_leverage", "adj_eq", "adj_eq_sym")
era_res <- lapply(ERA_NAMES, function(e) {
  ix <- which(panel$era == e)
  y <- panel$y[ix]
  f <- factor(panel$CERT[ix][y]); nb <- nlevels(f)
  cnt <- tabulate(f, nb)
  set.seed(20261125)   # one resample of failed banks, shared by all scores (paired)
  bm <- matrix(sample.int(nb, nb * N_BOOT, replace = TRUE), nb)
  den <- colSums(matrix(cnt[bm], nb))
  k_chance <- sum(1 - (1 - 0.05)^cnt)   # random 5% list
  per <- lapply(CORE, function(s) {
    p <- panel[[paste0("p_", s)]][ix]
    u <- auc_parts(p, y)
    su <- as.numeric(tapply(u, f, sum))
    list(auc = mean(u), boot = colSums(matrix(su[bm], nb)) / den,
         caught5 = sum(tapply(p[y] <= 0.05, f, any)),
         caught1 = sum(tapply(p[y] <= 0.01, f, any)),
         auc_complete = mean(auc_parts(p[panel$complete[ix]], y[panel$complete[ix]])))
  })
  names(per) <- CORE
  list(era = e, n_bankqtrs = length(ix), n_pos = sum(y), n_fail = nb,
       chance5 = k_chance, per = per)
})
era_metrics <- do.call(rbind, lapply(era_res, function(r) do.call(rbind, lapply(CORE, function(s) {
  m <- r$per[[s]]
  data.frame(era = r$era, score = s, failed_banks = r$n_fail, pos_bankqtrs = r$n_pos,
             bankqtrs = r$n_bankqtrs, auc = m$auc,
             auc_lo90 = unname(quantile(m$boot, 0.05)), auc_hi90 = unname(quantile(m$boot, 0.95)),
             auc_complete_windows = m$auc_complete,
             caught_worst5pct = m$caught5, caught_worst1pct = m$caught1,
             catch_rate_worst5pct = m$caught5 / r$n_fail,
             random_list_catches_5pct = r$chance5)
}))))
# Paired differences (same resampled failed banks): 90% range and share > 0
PAIRS <- list(c("adj_eq", "eq_ta"), c("adj_eq", "tier1_leverage"),
              c("adj_eq_sym", "eq_ta"), c("adj_eq_sym", "adj_eq"),
              c("tier1_leverage", "eq_ta"))
era_compare <- do.call(rbind, lapply(era_res, function(r) do.call(rbind, lapply(PAIRS, function(pr) {
  d <- r$per[[pr[1]]]$boot - r$per[[pr[2]]]$boot
  data.frame(era = r$era, comparison = paste(pr[1], "minus", pr[2]),
             auc_diff = r$per[[pr[1]]]$auc - r$per[[pr[2]]]$auc,
             diff_lo90 = unname(quantile(d, 0.05)), diff_hi90 = unname(quantile(d, 0.95)),
             share_boot_above_0 = mean(d > 0))
}))))
t_era <- Sys.time()

# ---- 6. 2022-2026 detail (same tables as the first backtest) -----------------
full <- panel
panel <- full[full$era == "2022-2026", ]
stopifnot(all(is.finite(panel$adj_equity_cal_to_assets)))   # cal_factor exists 2021Q4 on
fl_all <- fl
fl <- fl_all[fl_all$fail_date >= as.Date("2022-01-01"), ]
SC <- setdiff(names(LABEL), "adj_eq_sym")   # the scores of the first backtest
pos <- which(panel$y)
pos_cert <- panel$CERT[pos]
certs <- unique(pos_cert)
set.seed(20261125)
boot_ix <- replicate(N_BOOT, sample(certs, replace = TRUE), simplify = FALSE)
boot_auc <- function(u) vapply(boot_ix, function(b)
  mean(unlist(lapply(b, function(cc) u[pos_cert == cc]))), numeric(1))
U  <- lapply(SC, function(s) auc_parts(panel[[paste0("p_", s)]], panel$y)); names(U) <- SC
UC <- lapply(SC, function(s) {
  cm <- panel$complete | panel$y   # complete windows for negatives
  auc_parts(panel[[paste0("p_", s)]][cm], panel$y[cm])
}); names(UC) <- SC
BA <- lapply(U, boot_auc)
rr <- pos_cert %in% fl$CERT[fl$group == "rate+run"]

caught <- function(p, k) sum(tapply(p[pos] <= k, pos_cert, any))
metrics <- do.call(rbind, lapply(SC, function(s) {
  p <- panel[[paste0("p_", s)]]
  row <- data.frame(score = s, label = LABEL[[s]],
    auc = mean(U[[s]]),
    auc_lo90 = unname(quantile(BA[[s]], 0.05)), auc_hi90 = unname(quantile(BA[[s]], 0.95)),
    auc_complete_windows = mean(UC[[s]][panel$complete[pos]]),
    auc_rate_run_only = mean(U[[s]][rr]),
    auc_other_failures = mean(U[[s]][!rr]),
    share_boot_beats_eq_ta = mean(BA[[s]] > BA$eq_ta),
    share_boot_beats_tier1 = mean(BA[[s]] > BA$tier1_leverage))
  for (k in TOP) {
    tag <- paste0("top", 100 * k, "pct")
    flagged <- p <= k
    row[[paste0(tag, "_failures_caught")]] <- caught(p, k)
    row[[paste0(tag, "_bankqtrs_flagged")]] <- sum(flagged)
    row[[paste0(tag, "_false_bankqtrs")]] <- sum(flagged & !panel$y)
    row[[paste0(tag, "_false_banks")]] <- length(unique(panel$CERT[flagged & !panel$y &
                                                         !(panel$CERT %in% fl$CERT)]))
  }
  row
}))
rownames(metrics) <- NULL

flag_tab <- do.call(rbind, lapply(c("run_risk_flag", "run_risk_flag_cal"), function(f) {
  fg <- panel[[f]] %in% TRUE
  data.frame(flag = f, failures_caught = sum(tapply(fg[pos], pos_cert, any)),
             bankqtrs_flagged = sum(fg), false_bankqtrs = sum(fg & !panel$y),
             distinct_banks_flagged = length(unique(panel$CERT[fg])))
}))

fr <- panel[pos, c("CERT", "NAMEFULL", "RISDATE", "fail_date", "ASSET", "eq_ta", "t1lev",
                   "adj_equity_to_assets", "adj_equity_sym_to_assets",
                   "adj_equity_cal_to_assets", "uninsured_share",
                   "run_risk_flag", "run_risk_flag_cal", paste0("p_", names(LABEL)))]
fr <- fr[order(fr$fail_date, fr$CERT, -fr$RISDATE), ]
fr$qtrs_before <- ave(fr$RISDATE, fr$CERT, FUN = seq_along)   # 1 = last report
fr$group <- fl$group[match(fr$CERT, fl$CERT)]
n_q <- table(panel$RISDATE)
fr$n_banks <- as.integer(n_q[as.character(fr$RISDATE)])
by_bank_n <- table(pos_cert)
chance <- vapply(TOP, function(k) sum(1 - (1 - k)^as.numeric(by_bank_n)), numeric(1))

# Secondary outcome: BTFP borrowers vs the 2022Q4 ranking. check_btfp()
# reports how many borrowers are banks (RSSD through bank_ids). bank_ids
# holds each bank's newest RSSD, so for a dated quarter the match uses that
# quarter's raw RSSDID (pipeline/README.md, bank_ids).
bt <- btfp_read()
bt_join <- check_btfp(bt, btfp_source(), ids)
q4 <- panel[panel$RISDATE == 20221231, ]
r4q <- rd("raw/risdate.20221231.parquet", col_select = c("CERT", "RSSDID"))
q4$btfp <- as.integer(r4q$RSSDID[match(q4$CERT, r4q$CERT)]) %in% bt$RSSD
auc_simple <- function(p, yy) {   # p = pct from worst; low p = risky
  r <- rank(-p); n1 <- sum(yy); n0 <- sum(!yy)
  (sum(r[yy]) - n1 * (n1 + 1) / 2) / (n1 * n0)
}
btfp_tab <- do.call(rbind, lapply(names(LABEL), function(s) {
  p <- q4[[paste0("p_", s)]]
  data.frame(score = s, auc = auc_simple(p, q4$btfp),
             borrowers_in_worst5pct = sum(q4$btfp & p <= 0.05),
             worst5pct_size = sum(p <= 0.05))
}))

# ---- 7. Write outputs ----------------------------------------------------------
r4 <- function(d) { for (v in names(d)) if (is.double(d[[v]])) d[[v]] <- round(d[[v]], 4); d }
wr <- function(d, f) write.csv(d, file.path(DIR, "out", f), row.names = FALSE)
wr(r4(era_metrics), "era_metrics.csv")         # chart.R
wr(r4(fr), "failed_bank_ranks.csv")            # chart.R
wr(fl, "failures.csv")                         # chart.R (the 2022+ rows)
wr(r4(era_compare), "era_compare.csv")
wr(r4(gap_q), "rate_gap_by_quarter.csv")
wr(r4(metrics), "metrics.csv")
wr(r4(btfp_tab), "btfp_2022q4.csv")

pc <- function(x, d = 1) sprintf(paste0("%.", d, "f%%"), 100 * x)
f3 <- function(d) { for (v in names(d)) if (is.double(d[[v]])) d[[v]] <- round(d[[v]], 3); d }
era_wide <- do.call(rbind, lapply(era_res, function(r) data.frame(
  era = r$era, failed_banks = r$n_fail, random_5pct_list = round(r$chance5, 1),
  t(sapply(CORE, function(s) sprintf("%.2f (%.2f-%.2f) %d/%d", r$per[[s]]$auc,
    quantile(r$per[[s]]$boot, 0.05), quantile(r$per[[s]]$boot, 0.95),
    r$per[[s]]$caught5, r$n_fail))))))
fails_in <- unique(fr$CERT)
t_end <- Sys.time()
secs <- function(a, b) round(as.numeric(difftime(b, a, units = "secs")), 1)
out <- c(
  sprintf("Inputs: hidden_loss_history (%s), bank_ids, raw RBC1AAJ, failures list pulled %s, BTFP %s.",
          paste(unique(full$method_version), collapse = ", "), TODAY, basename(BTFP_CSV)),
  sprintf("Quarters scored: %d..%d (%d), %d bank-quarters, %d banks.",
          min(full$RISDATE), max(full$RISDATE), length(unique(full$RISDATE)),
          nrow(full), length(unique(full$CERT))),
  sprintf("Dropped for a missing input (mostly pre-2012 OTS thrift filers with no loan buckets or HTM fair values; since 2012 no domestic deposits): %d bank-quarters, %d of them pre-failure.",
          nrow(dropped), sum(dropped$y)),
  paste0("  by reason: ", paste(sprintf("%s x%d", names(drop_why), drop_why), collapse = "; ")),
  sprintf("Dropped because the report went public after the bank failed: %d.", sum(gone)),
  sprintf("Failure events %d-%d in the FDIC list (%s): %d (%s). Failed banks with at least one scored pre-failure report: %d.",
          FAIL_FROM, max(as.integer(format(fl_all$fail_date, "%Y"))), paste(FAIL_TYPES, collapse = " + "),
          nrow(fl_all), paste(names(table(fl_all$RESTYPE)), table(fl_all$RESTYPE), collapse = ", "),
          length(unique(full$CERT[full$y]))),
  sprintf("Run time (analyze.R): reading inputs %.1fs, era metrics %.1fs, total %.1fs.",
          secs(t_start, t_est), secs(t_est, t_era), secs(t_start, t_end)),
  "", "ERAS (by the year the report became public). Each cell: AUC (90% bootstrap range) caught-in-worst-5%/failed banks.",
  "A bank whose 4 pre-failure reports straddle an era boundary counts in both eras.",
  capture.output(print(era_wide, row.names = FALSE)),
  "", "Paired AUC differences (same resampled failed banks):",
  capture.output(print(f3(era_compare), row.names = FALSE)),
  "", "AUC restricted to complete 1-year windows:",
  capture.output(print(f3(era_metrics[c("era", "score", "auc", "auc_complete_windows")]), row.names = FALSE)),
  "", "FALLING RATES: rate gap = 30y mortgage rate - bank's own loan yield. Floored = max(0, gap); symmetric keeps negatives (hidden gains).",
  "pct_equity = industry loan loss (negative = gain) / industry equity.",
  capture.output(print(gap_tab, row.names = FALSE)),
  "", "Data-quality check by year-end: share of banks with no loan loss estimate (buckets not reported, NA in the mart),",
  "and, of those with one, share whose buckets cover < 50% of loans:",
  capture.output(print(f3(gap_q[gap_q$RISDATE %% 10000 == 1231, c("RISDATE", "mtg_rate", "median_loan_yield",
    "share_banks_gap_negative", "loan_loss_symmetric_pct_equity", "share_banks_no_buckets",
    "share_banks_bucket_cov_lt50")]), row.names = FALSE)),
  "", "================ 2022-2026 detail (same as the first backtest) ================",
  sprintf("Failures: %d. Positives: %d bank-quarters from %d banks.", nrow(fl), length(pos), length(fails_in)),
  capture.output(print(fl[c("CERT", "NAME", "fail_date", "RESTYPE", "group", "cause")], row.names = FALSE)),
  "", "Metrics (AUC: 0.5 = coin flip, 1 = perfect; 90% interval resamples the failed banks):",
  capture.output(print(f3(metrics[c("score", "auc", "auc_lo90", "auc_hi90", "auc_complete_windows",
                                    "auc_rate_run_only", "auc_other_failures",
                                    "share_boot_beats_eq_ta", "share_boot_beats_tier1")]),
                       row.names = FALSE)),
  "", sprintf("Watch lists (of %d failed banks; a random list would catch about %.1f (1%%) and %.1f (5%%)):",
              length(fails_in), chance[1], chance[2]),
  capture.output(print(metrics[c("score", grep("^top", names(metrics), value = TRUE))], row.names = FALSE)),
  "", "Binary run-risk flags:", capture.output(print(flag_tab, row.names = FALSE)),
  "", "Each failed bank: % of banks ranked at least as risky (1 = last report before failure):",
  capture.output(print(transform(fr[c("NAMEFULL", "group", "RISDATE", "qtrs_before",
                                      "p_eq_ta", "p_tier1_leverage", "p_adj_eq", "p_adj_eq_sym",
                                      "p_adj_eq_cal")],
                                 NAMEFULL = substr(NAMEFULL, 1, 26),
                                 p_eq_ta = pc(p_eq_ta), p_tier1_leverage = pc(p_tier1_leverage),
                                 p_adj_eq = pc(p_adj_eq), p_adj_eq_sym = pc(p_adj_eq_sym),
                                 p_adj_eq_cal = pc(p_adj_eq_cal)),
                       row.names = FALSE)),
  "", sprintf("BTFP: %d distinct borrower RSSDs; %d are FDIC banks in bank_ids; %d matched to a bank in the 2022Q4 panel by its 2022Q4 RSSDID (%d banks); the rest are mostly credit unions.",
              nrow(bt), sum(!is.na(bt_join$CERT)), sum(q4$btfp), nrow(q4)),
  capture.output(print(r4(btfp_tab), row.names = FALSE)))
writeLines(out, file.path(DIR, "summary.txt"))
cat(out, sep = "\n")
