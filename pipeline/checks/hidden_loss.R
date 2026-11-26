# Checks on hidden_loss_history (and so on hidden_loss, cut from it).
# stop()s on the first failure.
#   hist    build_hidden_loss_history()$history
#   audit   its $audit: per quarter, filers in raw and the raw securities gap
#   newest  newest FDIC quarter

# Unrealized securities losses (AFS + HTM) the FDIC Quarterly Banking
# Profile published, $ thousands. Add a quarter when its QBP comes out.
HL_QBP_SEC_LOSS <- c(
  "20221231" = 620.4e6,   # QBP Q4 2022: $620.4B
  "20260930" = 486.0e6    # QBP Q3 2026: $486B
)
HL_QBP_TOL <- 0.02
HL_IMPUTED_MAX <- 0.05   # share of banks with the median loan yield

check_hidden_loss <- function(hist, audit, newest, params = HL_PARAMS) {
  check(newest %in% hist$RISDATE, paste("hidden_loss lacks the newest quarter", newest))
  check(!anyDuplicated(hist[c("CERT", "RISDATE")]), "duplicate CERT-quarters in hidden_loss")
  qs <- sort(unique(hist$RISDATE))
  want <- newest   # the same number of quarters, back to back, ending at newest
  while (length(want) < length(qs)) want <- c(prev_quarter_end(want[1]), want)
  check(identical(qs, as.integer(want)), "hidden_loss_history has a gap in its quarters")

  # Every filer is a row, and the reported securities losses sum to the
  # raw fair-value gaps (no bank lost or double-counted)
  n <- table(hist$RISDATE)
  check(all(n[as.character(audit$RISDATE)] == audit$n_filers), "hidden_loss rows != raw filers")
  sec <- tapply(hist$loss_htm + hist$loss_afs, hist$RISDATE, sum, na.rm = TRUE)
  gap <- abs(sec[as.character(audit$RISDATE)] - audit$raw_sec_gap)
  check(all(gap < 0.5), paste("securities losses do not sum to raw in",
                              paste(audit$RISDATE[gap >= 0.5], collapse = ",")))
  for (q in intersect(names(HL_QBP_SEC_LOSS), names(sec))) {
    off <- sec[[q]] / HL_QBP_SEC_LOSS[[q]] - 1
    check(abs(off) <= HL_QBP_TOL, sprintf("securities loss %s is %.1f%% off the FDIC QBP", q, 100 * off))
  }

  # The app quarters: loan yield imputed for at most 5% of banks
  recent <- hist[hist$RISDATE %in% utils::tail(qs, HL_APP_QUARTERS), ]
  imp <- tapply(recent$loan_yield_imputed, recent$RISDATE, mean)
  check(all(imp <= HL_IMPUTED_MAX), sprintf("loan yield imputed for %.1f%% of banks in %s",
                                            100 * max(imp), names(imp)[which.max(imp)]))

  # The calibration factor: NA or finite in (0, cal_max], one per quarter
  cf <- hist$cal_factor[!is.na(hist$cal_factor)]
  check(all(is.finite(cf) & cf > 0 & cf <= params$cal_max), "cal_factor out of range")
  check(all(tapply(hist$cal_factor, hist$RISDATE, function(x) length(unique(x))) == 1),
        "cal_factor varies within a quarter")

  # Missing stays missing: no NA without a reason, NA banks never ranked
  check(all(!is.na(hist$na_reason[is.na(hist$hidden_loss) | is.na(hist$adj_equity_to_assets)])),
        "hidden_loss NA without an na_reason")
  check(identical(is.na(hist$pct_worst), is.na(hist$adj_equity_to_assets)),
        "pct_worst set for a bank without adjusted equity (or missing for one with it)")
  p <- hist$pct_worst[!is.na(hist$pct_worst)]
  check(all(p > 0 & p <= 1), "pct_worst outside (0, 1]")
  check(all(!is.na(hist$mtg_rate) & hist$mtg_rate > 0 & hist$mtg_rate < 0.25),
        "mtg_rate missing or out of range")
  check(all(hist$method_version == params$method_version), "mixed method_version")
}
