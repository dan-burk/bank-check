# The hidden-loss estimator: what a bank's securities and loans would lose
# if marked to today's rates, and how much of that its reported equity does
# not show. Pure: data frames in, data frame out. No files, network or
# today's date, so the pipeline mart and any research script that calls it
# get the same numbers. Moved from research/unrealized-losses/estimator.R
# (method write-up in research/unrealized-losses/README.md).
# Dollar fields are $ thousands (FDIC convention).
#
# Missing is NA, never 0. A bank that does not report the loan maturity
# buckets (OTS thrifts before 2012) or the securities fair values gets an NA
# loss and an na_reason, and an NA percentile: it is not "safest". Every
# filer is a row, so industry sums match raw. The one fill is the loan
# yield: implausible or missing yields get the quarter's median and are
# flagged in loan_yield_imputed.

HL_BUCKETS <- c("3LES", "3T12", "1T3", "3T5", "5T15", "OV15")
HL_LN_RES  <- paste0("LNRS", HL_BUCKETS)   # closed-end first-lien 1-4 family (RC-C memo 2.a)
HL_LN_OTH  <- paste0("LNOT", HL_BUCKETS)   # all other loans and leases (memo 2.b)
HL_SC_NM   <- paste0("SCNM", HL_BUCKETS)   # securities by remaining maturity (RC-B memo 2)
HL_SC_PT   <- paste0("SCPT", HL_BUCKETS)   # pass-through MBS by repricing
HL_SC_O    <- c("SCO3YLES", "SCOOV3Y")      # other MBS, two buckets

# The raw columns hidden_loss() reads (all in RAW_FIELDS)
HL_FIELDS <- c("CERT", "RISDATE", "ASSET", "EQTOT", "RBCT1J", "DEPDOM", "DEPUNINS",
               "SCAA", "SCAF", "SCHA", "SCHF", "SC", "ISCQ", "LNLSGR", "ILNLSQ",
               HL_LN_RES, HL_LN_OTH, HL_SC_NM, HL_SC_PT, HL_SC_O)

# Assumptions, all in one place: the research defaults.
HL_PARAMS <- list(
  # Effective duration (years) per remaining-maturity / repricing bucket,
  # below each bucket's midpoint because loans amortize
  dur = c(0.1, 0.5, 1.8, 3.5, 5.5, 7.5),
  dur_sco = c(1.5, 5),
  max_drop = 0.5,                    # cap on any modeled price drop
  yield_bounds = c(0.01, 0.15),      # loan yields outside -> quarter median
  sec_yield_bounds = c(0.002, 0.12), # same for the securities yield
  unins_high = 0.5,                  # "high" uninsured share for the run flag
  cal_max = 5,                       # calibration factor above this -> NA
  method_version = "hl-1"
)

# The one definition of uninsured share (spec trap 4): DEPUNINS counts
# domestic deposits, so divide by DEPDOM. NA when there are none.
uninsured_share <- function(depunins, depdom) {
  ifelse(!is.na(depdom) & depdom > 0, depunins / depdom, NA_real_)
}

# Quarter-end market rates, as decimals: the average of each FRED series
# over the quarter's last month (rates_monthly mart).
hl_rates <- function(rates, risdate) {
  get <- function(s) {
    v <- rates$avg[rates$series == s & rates$month_end == risdate]
    if (length(v) != 1 || is.na(v)) stop("rates_monthly has no ", s, " for ", risdate)
    v / 100
  }
  c(mtg = get("MORTGAGE30US"), t10 = get("DGS10"))
}

# Sum over buckets of balance x min(gap x duration, cap). NA if a bucket is
# NA: a bank that did not report its buckets has an unknown loss, not 0.
bucket_loss <- function(d, cols, gap, dur, cap) {
  rowSums(as.matrix(d[cols]) * pmin(outer(gap, dur), cap))
}

# Annualized yield on the average of this and last quarter's balance
# (this quarter's alone for a bank with no previous filing), with values
# outside `bounds` (or missing) replaced by the median. Returns the yield
# and the imputed flag.
avg_yield <- function(income_q, bal, bal_prev, bounds) {
  avg <- ifelse(is.na(bal_prev), bal, (bal + bal_prev) / 2)
  y <- 4 * income_q / avg
  bad <- is.na(y) | !is.finite(y) | y < bounds[1] | y > bounds[2]
  y[bad] <- stats::median(y[!bad])
  list(y = y, imputed = bad)
}

# One quarter, every bank.
#   cur, prev  raw quarter frames with HL_FIELDS (prev = the quarter before,
#              for average balances; NULL if not on hand)
#   rates      the rates_monthly mart
# Returns one row per filer in `cur`.
hidden_loss <- function(cur, prev, rates, params = HL_PARAMS) {
  p <- params
  rd <- as.integer(cur$RISDATE[1])
  r <- hl_rates(rates, rd)
  d <- data.frame(CERT = as.integer(cur$CERT), RISDATE = rd)
  for (v in setdiff(HL_FIELDS, c("CERT", "RISDATE"))) d[[v]] <- as.numeric(cur[[v]])
  pm <- if (!is.null(prev)) match(d$CERT, prev$CERT)   # NA: bank new this quarter
  prev_of <- function(v) if (is.null(prev)) rep(NA_real_, nrow(d)) else as.numeric(prev[[v]])[pm]

  # Loans: the bank's own yield against today's 30-year mortgage rate
  ly <- avg_yield(d$ILNLSQ, d$LNLSGR, prev_of("LNLSGR"), p$yield_bounds)
  d$loan_yield <- ly$y
  d$loan_yield_imputed <- ly$imputed
  d$mtg_rate <- unname(r["mtg"])
  d$t10_rate <- unname(r["t10"])
  d$rate_gap_raw <- d$mtg_rate - d$loan_yield
  d$rate_gap <- pmax(0, d$rate_gap_raw)
  d$loss_loans_res <- bucket_loss(d, HL_LN_RES, d$rate_gap, p$dur, p$max_drop)
  d$loss_loans_oth <- bucket_loss(d, HL_LN_OTH, d$rate_gap, p$dur, p$max_drop)
  d$loss_loans <- d$loss_loans_res + d$loss_loans_oth
  # Symmetric variant (research): no floor, so a high-yield book shows a gain
  d$loss_loans_sym <- bucket_loss(d, HL_LN_RES, d$rate_gap_raw, p$dur, p$max_drop) +
    bucket_loss(d, HL_LN_OTH, d$rate_gap_raw, p$dur, p$max_drop)
  d$bucket_cov <- ifelse(d$LNLSGR > 0,
                         rowSums(as.matrix(d[c(HL_LN_RES, HL_LN_OTH)])) / d$LNLSGR, NA_real_)

  # Securities: reported (positive = loss)
  d$loss_htm <- d$SCHA - d$SCHF
  d$loss_afs <- d$SCAA - d$SCAF

  # Model check: the same duration method on securities, yield vs the
  # 10-year Treasury, for the calibration factor
  sy <- avg_yield(d$ISCQ, d$SC, prev_of("SC"), p$sec_yield_bounds)$y
  sgap <- pmax(0, d$t10_rate - sy)
  d$loss_sec_model <- bucket_loss(d, HL_SC_NM, sgap, p$dur, p$max_drop) +
    bucket_loss(d, HL_SC_PT, sgap, p$dur, p$max_drop) +
    bucket_loss(d, HL_SC_O, sgap, p$dur_sco, p$max_drop)

  # Outputs. AFS losses are already in EQTOT (AOCI); HTM and loans are not.
  # Every filer stays a row. Without equity or assets (insured US branches
  # of foreign banks) the ratios are NA; zero or negative equity is kept:
  # those are the banks this is about.
  d$hidden_loss <- d$loss_htm + d$loss_loans
  no_eq <- is.na(d$EQTOT) | is.na(d$ASSET) | !(d$ASSET > 0)
  asset <- ifelse(no_eq, NA_real_, d$ASSET)
  d$adj_equity_to_assets <- (d$EQTOT - d$hidden_loss) / asset
  d$adj_equity_sym_to_assets <- (d$EQTOT - d$loss_htm - d$loss_loans_sym) / asset
  d$uninsured_share <- uninsured_share(d$DEPUNINS, d$DEPDOM)
  d$run_risk_flag <- d$adj_equity_to_assets < 0 & d$uninsured_share > p$unins_high

  # Calibrated variant: industry reported / modeled securities loss, over
  # banks with both. NA (not Inf or huge) when the modeled loss is about 0,
  # as in the low-rate quarters of 2020-21 (spec trap 2).
  both <- !is.na(d$loss_sec_model) & !is.na(d$loss_htm) & !is.na(d$loss_afs)
  f <- sum(d$loss_htm[both] + d$loss_afs[both]) / sum(d$loss_sec_model[both])
  d$cal_factor <- if (is.finite(f) && f > 0 && f <= p$cal_max) f else NA_real_
  d$loss_loans_cal <- d$loss_loans * d$cal_factor
  d$adj_equity_cal_to_assets <- (d$EQTOT - d$loss_htm - d$loss_loans_cal) / asset
  d$run_risk_flag_cal <- d$adj_equity_cal_to_assets < 0 & d$uninsured_share > p$unins_high

  # Percentile, 1 = worst: share of banks with a value whose adjusted
  # equity / assets is at or below this bank's. NA stays NA (trap 8).
  x <- d$adj_equity_to_assets
  d$pct_worst <- rank(x, ties.method = "max", na.last = "keep") / sum(!is.na(x))

  # Why a value is NA: each input that was not reported
  why <- cbind(ifelse(no_eq, "no equity or assets", NA),
               ifelse(is.na(d$loss_htm) | is.na(d$loss_afs), "no securities fair value", NA),
               ifelse(is.na(d$loss_loans), "no loan maturity buckets", NA))
  d$na_reason <- apply(why, 1, function(w) if (all(is.na(w))) NA_character_
                                           else paste(w[!is.na(w)], collapse = "; "))
  d$method_version <- p$method_version
  rownames(d) <- NULL
  d
}
