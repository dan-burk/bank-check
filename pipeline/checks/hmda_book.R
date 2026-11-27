# Checks on hmda_book. stop()s on the first failure.
#   hb       build_hmda_book()$mart
#   dropped  its $dropped (CERTs with groups that did not file in `newest`)
#   pooled   hb_value() of every bank's groups as one book (CERT = 0)
#   groups   the hmda.groups it was built from
#
# The #20 cross-check, PV loss vs the duration shortcut within 1 point, is
# made on the pooled book. Per bank it is reported, not failed: in a book
# that mixes below-market loans (2020-21) with above-market ones (2023-25)
# the shortcut overstates the gain on the above-market loans, which prepay
# at cpr_above (negative convexity), and a single duration x gap ignores
# how the gap varies across the book. 17% of banks are more than 1 point
# apart at 2026 Q3, nearly all of them such mixed books.
HB_DUR_TOL <- 0.01

check_hmda_book <- function(hb, dropped, pooled, groups, newest, params = HB_PARAMS) {
  check(nrow(hb) > 0 && all(hb$RISDATE == newest), paste("hmda_book is not for the newest quarter", newest))
  check(!anyDuplicated(hb$CERT), "hmda_book: duplicate CERT")
  check(setequal(c(hb$CERT, dropped), unique(groups$CERT)) && !any(dropped %in% hb$CERT),
        "hmda_book: a CERT with groups is neither a row nor counted as dropped")
  check(all(hb$method_version == params$method_version), "hmda_book: mixed method_version")
  check(all(hb$hmda_year_max <= max(groups$year)), "hmda_book: hmda_year_max past the stored years")

  # Missing stays missing: every NA has a reason, and a value has none
  v <- !is.na(hb$loss_pv)
  check(identical(v, !is.na(hb$wac)) && identical(v, !is.na(hb$duration)),
        "hmda_book: wac, duration and loss_pv not NA together")
  check(all(!is.na(hb$na_reason[!v | is.na(hb$hmda_share)])), "hmda_book: an NA without an na_reason")
  check(all(is.na(hb$na_reason[v & !is.na(hb$hmda_share)])), "hmda_book: an na_reason on a full row")

  # Sensible ranges
  inr <- function(x, lo, hi) all(x[!is.na(x)] >= lo & x[!is.na(x)] <= hi)
  check(inr(hb$wac, 0, 0.20), "hmda_book: wac outside [0, 20%]")
  check(inr(hb$mkt_rate, 0.01, 0.25), "hmda_book: mkt_rate outside [1, 25%]")
  check(inr(hb$duration, 0, 30), "hmda_book: duration outside [0, 30] years")
  check(inr(hb$loss_pv, -0.5, 0.6), "hmda_book: loss_pv outside [-50%, 60%]")
  check(inr(hb$valued_share, 0, 1), "hmda_book: valued_share outside [0, 1]")
  check(all(hb$bal_k >= 0 & hb$pv_k >= 0) && inr(hb$hmda_share, 0, Inf),
        "hmda_book: a negative balance, value or share")
  # Amortizing loans never owe more than they were made for
  # (valued_share is rounded to 5 decimals, hence the slack)
  check(all(hb$bal_k <= hb$kept_k * (hb$valued_share + 1e-5) + 1, na.rm = TRUE),
        "hmda_book: balance left above the dollars valued")

  check(nrow(pooled) == 1 && !is.na(pooled$loss_pv) &&
          abs(pooled$loss_pv - pooled$loss_dur) <= HB_DUR_TOL,
        sprintf("hmda_book: pooled PV loss %.2f%% vs duration shortcut %.2f%%, more than 1 point apart",
                100 * pooled$loss_pv, 100 * pooled$loss_dur))
}
