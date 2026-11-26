# Checks on run_stress. stop()s on the first failure.
#   rs      build_run_stress()$mart
#   inputs  its $inputs (rs_inputs(): one row per filer, same order)
#   newest  newest FDIC quarter

RS_CHECK_S <- c(0.05, 0.10, 0.20, 0.30, 0.50, 1)   # runs re-simulated for the identities

check_run_stress <- function(rs, inputs, newest, params = RS_PARAMS) {
  check(all(rs$RISDATE == newest), paste("run_stress is not for the newest quarter", newest))
  check(identical(rs$CERT, inputs$CERT) && !anyDuplicated(rs$CERT),
        "run_stress rows != raw filers (or duplicate CERTs)")
  check(all(rs$method_version == params$method_version), "mixed method_version")
  grid <- round(params$s_fine, 3)
  for (k in names(RS_CONFIGS)) {
    cf <- RS_CONFIGS[[k]]
    bp <- rs[[paste0("bp_", k)]]; how <- rs[[paste0("how_", k)]]
    pct <- rs[[paste0("pct_worst_", k)]]
    brk <- how %in% c("below 2%", "can't pay")
    check(all(how[!is.na(how)] %in% c("below 2%", "can't pay", "never")), paste("bad how_", k))
    check(identical(!is.na(bp), brk), paste0("bp_", k, " set without a break (or missing for one)"))
    check(all(bp[brk] %in% grid), paste0("bp_", k, " off the run-size grid"))

    # Missing stays missing: an NA run has a reason, and is never ranked
    check(all(!is.na(rs$na_reason[is.na(how)])), paste0("how_", k, " NA without an na_reason"))
    check(all(!is.na(how[!is.na(pct)])), paste0("pct_worst_", k, " set for a bank without a run"))
    check(all(!is.na(pct[!is.na(how) & is.na(rs$na_reason)])),
          paste0("pct_worst_", k, " missing for a bank with a run"))
    check(all(pct[!is.na(pct)] > 0 & pct[!is.na(pct)] <= 1), paste0("pct_worst_", k, " outside (0, 1]"))

    # Every dollar of the run is paid from a source or is shortfall, and
    # Tier 1 rises only by securities gains sold (a security worth more than
    # its cost realizes a gain, so the spec's t1_after <= RBCT1J is too strict)
    ok <- !is.na(how)
    d <- inputs[ok, ]
    gains <- pmax(0, d$SCAF - d$SCAA) + pmax(0, d$SCHF - d$SCHA)
    for (s in RS_CHECK_S) {
      r <- run_sim(d, s, cf$base, cf$fhlb, params)
      paid <- rowSums(r[grep("^from_", names(r))]) + r$shortfall
      check(all(abs(paid - r$need) <= 1e-6 * pmax(1, r$need)),
            sprintf("%s run of %.0f%%: sources + shortfall != need", k, 100 * s))
      check(all(r$t1_after <= d$RBCT1J + gains + 1e-6),
            sprintf("%s run of %.0f%%: Tier 1 rose by more than the securities gains", k, 100 * s))
    }
    # The breaking point breaks the bank, and a "never" bank survives 100%
    b <- brk[ok]
    if (any(b)) check(all(run_sim(d[b, ], bp[ok][b], cf$base, cf$fhlb, params)$fails),
                      paste0("bp_", k, " does not break the bank"))
    nv <- how[ok] == "never"
    if (any(nv)) check(!any(run_sim(d[nv, ], 1, cf$base, cf$fhlb, params)$fails),
                       paste0("how_", k, " 'never' but a 100% run breaks the bank"))
  }
}
