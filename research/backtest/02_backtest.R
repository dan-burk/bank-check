# Backtest step 2: run the hidden-loss estimator on every quarter from
# 1997Q2 (the first quarter with the loan maturity buckets), label failures
# with no look-ahead, and score each ranking against them, era by era.
# Reads cache/ from 01_fetch.R. Run from the repo root:
#   Rscript research/backtest/02_backtest.R
# Writes (research/backtest/):
#   era_metrics.csv, era_compare.csv  - all eras, 4 scores (the headline)
#   rate_gap_by_quarter.csv           - falling-rate check: hidden gains if unfloored
#   failures.csv, failed_bank_ranks.csv, metrics.csv, btfp_2022q4.csv
#                                     - 2022-2026 detail (as in the first backtest)
#   summary.txt
# The bank-quarter panel goes to cache/panel.rds (large, not committed).

t_start <- Sys.time()
options(width = 200)
source("app/R/api.R")                              # prev_quarter_end() only
source("research/unrealized-losses/estimator.R")   # estimate()
DIR <- "research/backtest"
C   <- file.path(DIR, "cache")
TODAY <- as.Date("2026-11-25")   # data pulled on this date; fixes "observed so far"

# ---- Settings --------------------------------------------------------------
PUB_LAG <- 45      # days from quarter end until the call report is public
HORIZON <- 365     # "failed within the next 4 quarters" after it is public
TOP     <- c(0.01, 0.05)   # watch-list sizes: worst 1% and worst 5%
N_BOOT  <- 2000
# Eras, by the year a report became public. Kept apart because banks failed
# for different reasons in each.
ERA_BREAKS <- c(1996, 2007, 2012, 2021, 2030)
ERA_NAMES  <- c("1997-2007", "2008-2012", "2013-2021", "2022-2026")
# Cause of each 2022-2026 failure, from the closing regulator / Inspector
# General (sources in README.md). "rate+run" = the kind of failure the
# hidden-loss idea is about; the others it is not designed to see.
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

# ---- 1. Estimator on every quarter ------------------------------------------
qs <- as.integer(readLines(file.path(C, "quarters.txt")))
qs <- qs[qs >= 19970331]   # scored from 1997Q2, the first quarter with the loan buckets
KEEP <- c("CERT", "NAMEFULL", "RISDATE", "RSSDID", "ASSET", "EQTOT", "RBC1AAJ",
          "LNLSGR", "DEPUNINS", "DEPDOM", "uninsured_share", "hidden_loss", "loss_htm",
          "loss_loans", "loss_loans_sym", "loss_loans_cal", "loan_yield", "rate_gap_raw",
          "bucket_cov", "adj_equity_to_assets", "adj_equity_sym_to_assets",
          "adj_equity_cal_to_assets", "run_risk_flag", "run_risk_flag_cal",
          "cal_factor", "mtg_rate")
panel <- do.call(rbind, lapply(qs[-1], function(q) {
  d <- suppressWarnings(estimate(q, prev_quarter_end(q), cache = C))
  b <- as.matrix(d[c(LN_RES, LN_OTH)]); b[is.na(b)] <- 0
  d$bucket_cov <- rowSums(b) / d$LNLSGR   # share of loans the buckets cover
  d[KEEP]
}))
t_est <- Sys.time()
saveRDS(panel, file.path(C, "panel.rds"))

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
gap_tab <- rbind(gap_period(19970630, 20071231), gap_period(20080331, 20121231),
                 gap_period(20130331, 20181231), gap_period(20190331, 20211231),
                 gap_period(20220331, 20260930))

# ---- 3. Labels, no look-ahead -----------------------------------------------
fl <- readRDS(file.path(C, "failures_1997.rds"))
fl$fail_date <- as.Date(fl$FAILDATE, "%m/%d/%Y")
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
# loan buckets nor HTM fair values in the FDIC API, so they drop out here.
dropped <- panel[!ok, ]
panel <- panel[ok, ]   # same banks and quarters for every score

# share of banks in the same quarter at least as risky (0.01 = worst 1%)
pct_worst <- function(risk, q) ave(risk, q, FUN = function(r)
  rank(-r, ties.method = "average") / length(r))
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
stopifnot(all(is.finite(panel$adj_equity_cal_to_assets)))
fl_all <- fl
fl <- fl_all[fl_all$fail_date >= as.Date("2022-01-01"), ]
SC <- setdiff(names(LABEL), "adj_eq_sym")   # the scores of the first backtest
pos <- which(panel$y)
neg <- which(!panel$y)
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

# Secondary outcome: BTFP borrowers vs the 2022Q4 ranking.
# Minimal XLSX reader (an XLSX is a zip of XML): returns the sheet with the
# most rows as a character matrix. Avoids adding a package for one file.
read_xlsx_min <- function(path) {
  ex <- tempfile("xlsx_"); dir.create(ex); on.exit(unlink(ex, recursive = TRUE))
  utils::unzip(path, exdir = ex)
  rd <- function(f) paste(readLines(file.path(ex, f), warn = FALSE, encoding = "UTF-8"), collapse = "")
  ss <- rd("xl/sharedStrings.xml")
  si <- regmatches(ss, gregexpr("<si>.*?</si>", ss))[[1]]
  strs <- vapply(si, function(x) paste(gsub("<[^>]+>", "",
    regmatches(x, gregexpr("<t[^>]*>[^<]*</t>", x))[[1]]), collapse = ""), "")
  strs <- gsub("&amp;", "&", strs)
  sheets <- list.files(file.path(ex, "xl/worksheets"), pattern = "xml$")
  best <- NULL
  for (sh in sheets) {
    x <- rd(file.path("xl/worksheets", sh))
    cells <- regmatches(x, gregexpr("<c r=\"[A-Z]+[0-9]+\"[^>]*?(/>|>.*?</c>)", x))[[1]]
    if (length(cells) == 0) next
    ref <- sub("<c r=\"([A-Z]+[0-9]+)\".*", "\\1", cells)
    isS <- grepl("t=\"s\"", cells)
    v <- ifelse(grepl("<v>", cells), sub(".*<v>([^<]*)</v>.*", "\\1", cells), NA)
    v[isS] <- strs[as.integer(v[isS]) + 1]
    r <- as.integer(sub("[A-Z]+", "", ref)); cl <- sub("[0-9]+", "", ref)
    m <- matrix(NA_character_, max(r), length(unique(cl)),
                dimnames = list(NULL, sort(unique(cl))))
    m[cbind(r, match(cl, colnames(m)))] <- v
    if (is.null(best) || nrow(m) > nrow(best)) best <- m
  }
  colnames(best) <- best[1, ]
  best[-1, , drop = FALSE]
}
bt <- read_xlsx_min(file.path(C, "btfp.xlsx"))
btfp_rssd <- unique(as.numeric(bt[, "Borrower RSSD"]))
btfp_rssd <- btfp_rssd[!is.na(btfp_rssd)]
q4 <- panel[panel$RISDATE == 20221231, ]
q4$btfp <- q4$RSSDID %in% btfp_rssd
btfp_matched <- sum(btfp_rssd %in% q4$RSSDID)
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
write.csv(r4(era_metrics), file.path(DIR, "era_metrics.csv"), row.names = FALSE)
write.csv(r4(era_compare), file.path(DIR, "era_compare.csv"), row.names = FALSE)
write.csv(r4(gap_q), file.path(DIR, "rate_gap_by_quarter.csv"), row.names = FALSE)
write.csv(fl, file.path(DIR, "failures.csv"), row.names = FALSE)
write.csv(r4(fr), file.path(DIR, "failed_bank_ranks.csv"), row.names = FALSE)
write.csv(r4(metrics), file.path(DIR, "metrics.csv"), row.names = FALSE)
write.csv(r4(btfp_tab), file.path(DIR, "btfp_2022q4.csv"), row.names = FALSE)

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
  sprintf("Quarters scored: %d..%d (%d), %d bank-quarters, %d banks.",
          min(full$RISDATE), max(full$RISDATE), length(unique(full$RISDATE)),
          nrow(full), length(unique(full$CERT))),
  sprintf("Dropped for a missing input (mostly pre-2012 OTS thrift filers with no loan buckets or HTM fair values; since 2012 no domestic deposits): %d bank-quarters, %d of them pre-failure.",
          nrow(dropped), sum(dropped$y)),
  sprintf("Dropped because the report went public after the bank failed: %d.", sum(gone)),
  sprintf("Failure events 1997-2026 in the FDIC list: %d (%s). Failed banks with at least one scored pre-failure report: %d.",
          nrow(fl_all), paste(names(table(fl_all$RESTYPE)), table(fl_all$RESTYPE), collapse = ", "),
          length(unique(full$CERT[full$y]))),
  sprintf("Run time (02_backtest.R): estimator %.1fs, era metrics %.1fs, total %.1fs.",
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
  "", "Share of banks whose loan buckets cover < 50% of loans (data-quality check), by year-end:",
  capture.output(print(f3(gap_q[gap_q$RISDATE %% 10000 == 1231, c("RISDATE", "mtg_rate", "median_loan_yield",
    "share_banks_gap_negative", "loan_loss_symmetric_pct_equity", "share_banks_bucket_cov_lt50")]), row.names = FALSE)),
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
  "", sprintf("BTFP: %d distinct borrower RSSDs; %d matched exactly to a bank in the 2022Q4 panel (%d banks); the rest are mostly credit unions.",
              length(btfp_rssd), btfp_matched, nrow(q4)),
  capture.output(print(r4(btfp_tab), row.names = FALSE)))
writeLines(out, file.path(DIR, "summary.txt"))
cat(out, sep = "\n")
