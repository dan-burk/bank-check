# Backtest step 2: run the hidden-loss estimator on every quarter, label
# failures with no look-ahead, and score each ranking against them.
# Reads cache/ from 01_fetch.R. Run from the repo root:
#   Rscript research/backtest/02_backtest.R
# Writes (research/backtest/): failures.csv, failed_bank_ranks.csv,
# metrics.csv, btfp_2022q4.csv, summary.txt. The bank-quarter panel goes
# to cache/panel.rds (large, not committed).

options(width = 200)
source("app/R/api.R")                              # prev_quarter_end() only
source("research/unrealized-losses/estimator.R")   # estimate(), unchanged
DIR <- "research/backtest"
C   <- file.path(DIR, "cache")
TODAY <- as.Date("2026-11-25")   # data pulled on this date; fixes "observed so far"

# ---- Settings --------------------------------------------------------------
PUB_LAG <- 45      # days from quarter end until the call report is public
HORIZON <- 365     # "failed within the next 4 quarters" after it is public
TOP     <- c(0.01, 0.05)   # watch-list sizes: worst 1% and worst 5%
N_BOOT  <- 2000
# Cause of each failure, from the closing regulator / Inspector General
# (sources in README.md). "rate+run" = the kind of failure the hidden-loss
# idea is about; the others it is not designed to see.
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
KEEP <- c("CERT", "NAMEFULL", "RISDATE", "RSSDID", "ASSET", "EQTOT", "RBC1AAJ",
          "DEPUNINS", "DEPDOM", "uninsured_share", "hidden_loss", "loss_htm",
          "loss_loans", "loss_loans_cal", "adj_equity_to_assets",
          "adj_equity_cal_to_assets", "run_risk_flag", "run_risk_flag_cal",
          "cal_factor", "mtg_rate")
panel <- do.call(rbind, lapply(qs[-1], function(q) {
  d <- estimate(q, prev_quarter_end(q), cache = C)
  d[KEEP]
}))
saveRDS(panel, file.path(C, "panel.rds"))

# ---- 2. Labels, no look-ahead -----------------------------------------------
fl <- readRDS(file.path(C, "failures.rds"))
fl$fail_date <- as.Date(fl$FAILDATE, "%m/%d/%Y")
fl <- merge(fl[c("CERT", "NAME", "CITYST", "fail_date", "RESTYPE", "RESTYPE1", "QBFASSET")],
            CAUSE, by = "CERT", all.x = TRUE)
fl <- fl[order(fl$fail_date), ]
stopifnot(!anyNA(fl$group))   # every failure in the window has a cause

panel$qend <- as.Date(as.character(panel$RISDATE), "%Y%m%d")
panel$pub  <- panel$qend + PUB_LAG
panel$fail_date <- fl$fail_date[match(panel$CERT, fl$CERT)]
# A report that only became public after the bank had already failed can
# not have warned anyone: drop it.
gone <- !is.na(panel$fail_date) & panel$fail_date <= panel$pub
panel <- panel[!gone, ]
panel$y <- !is.na(panel$fail_date) & panel$fail_date <= panel$pub + HORIZON
# Quarters whose one-year window has fully passed by TODAY
panel$complete <- panel$pub + HORIZON <= TODAY

# ---- 3. Scores (higher = riskier) and within-quarter ranks -------------------
panel$t1lev <- ifelse(panel$RBC1AAJ > 0, panel$RBC1AAJ, NA)   # 0 = not reported
panel$eq_ta <- panel$EQTOT / panel$ASSET
ok <- with(panel, is.finite(eq_ta) & is.finite(t1lev) & is.finite(adj_equity_to_assets) &
             is.finite(adj_equity_cal_to_assets) & is.finite(uninsured_share))
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
  adj_eq_cal       = p_adj_cal,
  eq_ta_plus_unins = pct_worst(-(p_eq + p_unins), q),         # control
  adj_plus_unins   = pct_worst(-(p_adj + p_unins), q),
  adj_cal_plus_unins = pct_worst(-(p_adj_cal + p_unins), q))
LABEL <- c(eq_ta = "Baseline: reported equity / assets",
           tier1_leverage = "Baseline: Tier 1 leverage ratio",
           adj_eq = "Ours: adjusted equity / assets (base)",
           adj_eq_cal = "Ours: adjusted equity / assets (calibrated)",
           eq_ta_plus_unins = "Control: reported equity rank + uninsured rank",
           adj_plus_unins = "Ours + uninsured: adj. equity rank + uninsured rank (base)",
           adj_cal_plus_unins = "Ours + uninsured: adj. equity rank + uninsured rank (calibrated)")
for (s in names(SCORES)) panel[[paste0("p_", s)]] <- SCORES[[s]]

# ---- 4. Metrics ---------------------------------------------------------------
pos <- which(panel$y)
neg <- which(!panel$y)
# For each positive bank-quarter: share of negative bank-quarters ranked
# safer than it (ties count half). AUC = the average of these.
u_pos <- function(p, neg_idx = neg) {
  pn <- sort(p[neg_idx])
  vapply(p[pos], function(x) {
    (length(pn) - findInterval(x, pn) + 0.5 * (findInterval(x, pn) -
       findInterval(x, pn, left.open = TRUE))) / length(pn)
  }, numeric(1))
}
pos_cert <- panel$CERT[pos]
certs <- unique(pos_cert)
set.seed(20261125)
boot_ix <- replicate(N_BOOT, sample(certs, replace = TRUE), simplify = FALSE)
boot_auc <- function(u) vapply(boot_ix, function(b)
  mean(unlist(lapply(b, function(cc) u[pos_cert == cc]))), numeric(1))

U  <- lapply(SCORES, u_pos)
UC <- lapply(SCORES, u_pos, neg_idx = neg[panel$complete[neg]])  # complete windows
BA <- lapply(U, boot_auc)
rr <- pos_cert %in% fl$CERT[fl$group == "rate+run"]

caught <- function(p, k) {   # distinct failed banks flagged in any pre-failure quarter
  hit <- tapply(p[pos] <= k, pos_cert, any)
  sum(hit)
}
metrics <- do.call(rbind, lapply(names(SCORES), function(s) {
  p <- SCORES[[s]]
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

# Binary run-risk flags from the estimator (adj. equity < 0 AND uninsured > 50%)
flag_tab <- do.call(rbind, lapply(c("run_risk_flag", "run_risk_flag_cal"), function(f) {
  fg <- panel[[f]] %in% TRUE
  data.frame(flag = f, failures_caught = sum(tapply(fg[pos], pos_cert, any)),
             bankqtrs_flagged = sum(fg), false_bankqtrs = sum(fg & !panel$y),
             distinct_banks_flagged = length(unique(panel$CERT[fg])))
}))

# Per failed bank: percentile under each score, each quarter before failure
fr <- panel[pos, c("CERT", "NAMEFULL", "RISDATE", "fail_date", "ASSET", "eq_ta", "t1lev",
                   "adj_equity_to_assets", "adj_equity_cal_to_assets", "uninsured_share",
                   "run_risk_flag", "run_risk_flag_cal", paste0("p_", names(SCORES)))]
fr <- fr[order(fr$fail_date, fr$CERT, -fr$RISDATE), ]
fr$qtrs_before <- ave(fr$RISDATE, fr$CERT, FUN = seq_along)   # 1 = last report
fr$group <- fl$group[match(fr$CERT, fl$CERT)]
n_q <- table(panel$RISDATE)
fr$n_banks <- as.integer(n_q[as.character(fr$RISDATE)])

# Expected "caught" for a random list: P(at least one of a bank's quarters
# lands in the worst k) summed over failed banks
by_bank_n <- table(pos_cert)
chance <- vapply(TOP, function(k) sum(1 - (1 - k)^as.numeric(by_bank_n)), numeric(1))

# ---- 5. Secondary outcome: BTFP borrowers vs the 2022Q4 ranking -------------
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
btfp_tab <- do.call(rbind, lapply(names(SCORES), function(s) {
  p <- q4[[paste0("p_", s)]]
  data.frame(score = s, auc = auc_simple(p, q4$btfp),
             borrowers_in_worst5pct = sum(q4$btfp & p <= 0.05),
             worst5pct_size = sum(p <= 0.05))
}))

# ---- 6. Write outputs ----------------------------------------------------------
r4 <- function(d) { for (v in names(d)) if (is.double(d[[v]])) d[[v]] <- round(d[[v]], 4); d }
write.csv(fl, file.path(DIR, "failures.csv"), row.names = FALSE)
write.csv(r4(fr), file.path(DIR, "failed_bank_ranks.csv"), row.names = FALSE)
write.csv(r4(metrics), file.path(DIR, "metrics.csv"), row.names = FALSE)
write.csv(r4(btfp_tab), file.path(DIR, "btfp_2022q4.csv"), row.names = FALSE)

pc <- function(x, d = 1) sprintf(paste0("%.", d, "f%%"), 100 * x)
fails_in <- unique(fr$CERT)
out <- c(
  sprintf("Quarters scored: %d..%d (%d), %d bank-quarters, %d banks.",
          min(panel$RISDATE), max(panel$RISDATE), length(unique(panel$RISDATE)),
          nrow(panel), length(unique(panel$CERT))),
  sprintf("Dropped for a missing input (mostly no domestic deposits or no Tier 1 ratio): %d bank-quarters, %d of them pre-failure.",
          nrow(dropped), sum(dropped$y)),
  sprintf("Dropped because the report went public after the bank failed: %d.", sum(gone)),
  sprintf("Failures in window: %d (all RESTYPE %s). Positives: %d bank-quarters from %d banks.",
          nrow(fl), paste(unique(fl$RESTYPE), collapse = "/"), length(pos), length(fails_in)),
  sprintf("Quarters with incomplete 1-year follow-up (after %s): labels are 'failed so far'.",
          max(panel$RISDATE[panel$complete])),
  "", "Failures:",
  capture.output(print(fl[c("CERT", "NAME", "fail_date", "RESTYPE", "group", "cause")], row.names = FALSE)),
  "", "Metrics (AUC: 0.5 = coin flip, 1 = perfect; 90% interval resamples the failed banks):",
  capture.output(print(transform(metrics[c("score", "auc", "auc_lo90", "auc_hi90", "auc_complete_windows",
                                           "auc_rate_run_only", "auc_other_failures",
                                           "share_boot_beats_eq_ta", "share_boot_beats_tier1")],
                                 auc = round(auc, 3), auc_lo90 = round(auc_lo90, 3),
                                 auc_hi90 = round(auc_hi90, 3),
                                 auc_complete_windows = round(auc_complete_windows, 3),
                                 auc_rate_run_only = round(auc_rate_run_only, 3),
                                 auc_other_failures = round(auc_other_failures, 3),
                                 share_boot_beats_eq_ta = round(share_boot_beats_eq_ta, 2),
                                 share_boot_beats_tier1 = round(share_boot_beats_tier1, 2)),
                       row.names = FALSE)),
  "", sprintf("Watch lists (of %d failed banks; a random list would catch about %.1f (1%%) and %.1f (5%%)):",
              length(fails_in), chance[1], chance[2]),
  capture.output(print(metrics[c("score", grep("^top", names(metrics), value = TRUE))], row.names = FALSE)),
  "", "Binary run-risk flags:", capture.output(print(flag_tab, row.names = FALSE)),
  "", "Each failed bank: % of banks ranked at least as risky (1 = last report before failure):",
  capture.output(print(transform(fr[c("NAMEFULL", "group", "RISDATE", "qtrs_before",
                                      "p_eq_ta", "p_tier1_leverage", "p_adj_eq", "p_adj_eq_cal",
                                      "p_adj_cal_plus_unins")],
                                 NAMEFULL = substr(NAMEFULL, 1, 26),
                                 p_eq_ta = pc(p_eq_ta), p_tier1_leverage = pc(p_tier1_leverage),
                                 p_adj_eq = pc(p_adj_eq), p_adj_eq_cal = pc(p_adj_eq_cal),
                                 p_adj_cal_plus_unins = pc(p_adj_cal_plus_unins)),
                       row.names = FALSE)),
  "", sprintf("BTFP: %d distinct borrower RSSDs; %d matched exactly to a bank in the 2022Q4 panel (%d banks); the rest are mostly credit unions.",
              length(btfp_rssd), btfp_matched, nrow(q4)),
  capture.output(print(r4(btfp_tab), row.names = FALSE)))
writeLines(out, file.path(DIR, "summary.txt"))
cat(out, sep = "\n")
