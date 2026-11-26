# Marts: hidden_loss_history and hidden_loss, from the estimator in
# R/hidden_loss.R run on every raw quarter that has the loan maturity
# buckets (1997 Q2 on), with rates from the rates_monthly mart.
#
#   hidden_loss_history  (CERT, quarter), every quarter. Research and the
#                        backtest; not shipped to the app
#   hidden_loss          (CERT, quarter), the newest HL_APP_QUARTERS, the
#                        HL_APP_COLS the app may show
#
# Columns ($ thousands; ratios as decimals):
#   loss_htm, loss_afs        reported securities losses (amortized cost -
#                             fair value); AFS is already in EQTOT
#   loss_loans_res/_oth       modeled loan losses, 1-4 family / other
#   hidden_loss               loss_htm + loans: what EQTOT does not show
#   adj_equity_to_assets      (EQTOT - hidden_loss) / ASSET
#   pct_worst                 share of the quarter's banks at or below this
#                             bank's adj_equity_to_assets (small = worse)
#   loan_yield(_imputed), rate_gap, mtg_rate, bucket_cov   the inputs
#   na_reason                 why a loss is NA (inputs not reported)
#   method_version            HL_PARAMS$method_version
# History also has the research variants: _sym (no floor), _cal (scaled by
# cal_factor), loss_sec_model, uninsured_share and the run-risk flags.

HL_APP_QUARTERS <- 20L
HL_APP_COLS <- c("CERT", "RISDATE", "loss_htm", "loss_afs", "loss_loans_res",
                 "loss_loans_oth", "hidden_loss", "adj_equity_to_assets", "pct_worst",
                 "loan_yield", "loan_yield_imputed", "rate_gap", "mtg_rate",
                 "bucket_cov", "na_reason", "method_version")
HL_HISTORY_COLS <- c(
  "CERT", "RISDATE", "ASSET", "EQTOT", "RBCT1J", "LNLSGR", "DEPUNINS", "DEPDOM",
  "loss_htm", "loss_afs", "loss_loans_res", "loss_loans_oth", "loss_loans",
  "loss_loans_sym", "loss_loans_cal", "loss_sec_model", "cal_factor",
  "hidden_loss", "adj_equity_to_assets", "adj_equity_sym_to_assets",
  "adj_equity_cal_to_assets", "pct_worst", "uninsured_share", "run_risk_flag",
  "run_risk_flag_cal", "loan_yield", "loan_yield_imputed", "rate_gap",
  "rate_gap_raw", "mtg_rate", "t10_rate", "bucket_cov", "na_reason", "method_version")

# Rounded to what the inputs carry, so the files compress (full doubles do
# not: 7 MB for the app mart, 151 MB for the history). Dollar losses to
# whole $ thousands, the raw unit; ratios to 5 decimals. Inputs, rates and
# cal_factor stay as they are.
HL_DOLLARS <- c("loss_htm", "loss_afs", "loss_loans_res", "loss_loans_oth", "loss_loans",
                "loss_loans_sym", "loss_loans_cal", "loss_sec_model", "hidden_loss")
HL_RATIOS  <- c("adj_equity_to_assets", "adj_equity_sym_to_assets", "adj_equity_cal_to_assets",
                "pct_worst", "uninsured_share", "loan_yield", "rate_gap", "rate_gap_raw",
                "bucket_cov")
hl_round <- function(d) {
  for (v in HL_DOLLARS) d[[v]] <- round(d[[v]])
  for (v in HL_RATIOS)  d[[v]] <- round(d[[v]], 5)
  d
}

# The estimator's columns of one raw file, or NULL when the file is on the
# old schema (pulled before RESEARCH_FIELDS)
read_hl_quarter <- function(f) {
  if (!all(HL_FIELDS %in% read_parquet_schema(f)$name)) return(NULL)
  as.data.frame(read_parquet(f, col_select = HL_FIELDS))
}

# files: raw quarter paths (any order). Estimates every quarter in which
# some bank reports the loan buckets (they start in 1997 Q2; found from
# the data, not a fixed date). Returns list(history, audit): audit has one
# row per quarter with the filers in raw, the rows written, and the
# industry securities gap summed straight from raw, for check_hidden_loss().
build_hidden_loss_history <- function(files, rates, params = HL_PARAMS) {
  files <- files[order(raw_rds(files))]
  out <- list(); audit <- list(); prev <- NULL
  for (f in files) {
    rd <- raw_rds(f)
    cur <- read_hl_quarter(f)
    # Average balances need the quarter just before; a gap means none
    p <- if (!is.null(prev) && as.integer(prev$RISDATE[1]) == prev_quarter_end(rd)) prev
    prev <- cur
    if (is.null(cur) || all(is.na(cur$LNRS3LES))) next
    d <- hidden_loss(cur, p, rates, params)
    out[[length(out) + 1]] <- hl_round(d[HL_HISTORY_COLS])
    audit[[length(audit) + 1]] <- data.frame(
      RISDATE = rd, n_filers = nrow(cur), n_rows = nrow(d), has_prev = !is.null(p),
      raw_sec_gap = sum(as.numeric(cur$SCHA) - as.numeric(cur$SCHF) +
                          as.numeric(cur$SCAA) - as.numeric(cur$SCAF), na.rm = TRUE))
  }
  hist <- do.call(rbind, out)
  hist <- hist[order(-hist$RISDATE, hist$CERT), ]
  rownames(hist) <- NULL
  list(history = hist, audit = do.call(rbind, audit))
}

# The app mart: the newest n quarters of the history, app columns only
hidden_loss_app <- function(hist, n = HL_APP_QUARTERS) {
  qs <- utils::head(sort(unique(hist$RISDATE), decreasing = TRUE), n)
  out <- hist[hist$RISDATE %in% qs, HL_APP_COLS]
  rownames(out) <- NULL
  out
}

# One line per run: the newest quarter's headline and what was not computed
report_hidden_loss <- function(hist) {
  nq <- max(hist$RISDATE)
  d <- hist[hist$RISDATE == nq, ]
  bn <- function(x) sum(x, na.rm = TRUE) / 1e6
  cat(sprintf(paste0("hidden_loss %d: %d filers; ",
                     "HTM $%.0fB + AFS $%.0fB, loans $%.0fB; hidden $%.0fB; ",
                     "%d NA (%s); %d yields imputed; cal_factor %.2f\n"),
              nq, nrow(d),
              bn(d$loss_htm), bn(d$loss_afs), bn(d$loss_loans), bn(d$hidden_loss),
              sum(is.na(d$hidden_loss)),
              paste(unique(stats::na.omit(d$na_reason)), collapse = " | "),
              sum(d$loan_yield_imputed), d$cal_factor[1]))
  cat(sprintf(paste0("hidden_loss_history: %d quarters %d-%d, %d rows; %d bank-quarters NA; ",
                     "cal_factor NA (net securities gain, or above cal_max) in %d quarters\n"),
              length(unique(hist$RISDATE)), min(hist$RISDATE), nq, nrow(hist),
              sum(is.na(hist$hidden_loss)), length(unique(hist$RISDATE[is.na(hist$cal_factor)]))))
}
