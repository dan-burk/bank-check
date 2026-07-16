# Data integrity test: the charts are data displayed pretty, so wrong
# arithmetic shows up as a wrong picture with no error. This script samples
# a roster of banks, recomputes every number the charts display straight
# from the raw FDIC columns with its own arithmetic, and cross-checks that
# against (a) derive()'s columns and (b) the y-values inside the built
# plotly traces. Run from the repo root:
#   Rscript.exe app/tests/integrity.R
#
# Roster: 3 small + 2 medium + 3 large banks sampled from the shipped
# cross-section (INTEGRITY_SEED env var, default 20260716, makes any run
# reproducible), plus two pinned oddballs: CERT 35164 (Capital Bank and
# Trust — $500k deposits on $226M assets, zero loans ever; the bank that
# exposed the Funding Mix mislabel) and one auto-screened extreme case.
#
# Phase 1 runs offline against the shipped cross-section. Phase 2 fetches
# each roster bank's full history from the live FDIC API (cached in
# data-cache/, so reruns are offline-fast) and self-skips when the API is
# unreachable or INTEGRITY_SKIP_LIVE=1.
#
# Hard failure (stopifnot) = the chart would show a wrong number: a built
# trace disagrees with the raw-column recompute, an identity breaks, Inf
# reaches a chart, a builder crashes on a real bank. Genuine data oddity
# (a trust company with no loans, FDIC ratio drift, filing gaps) goes to
# the WEIRDNESS REPORT for human eyes instead.

library(shiny)
library(bslib)
library(plotly)
library(dplyr)

setwd("app")
source("R/api.R")
source("R/theme.R")
source("R/data.R")
source("R/plots.R")

INTEGRITY_SEED <- Sys.getenv("INTEGRITY_SEED", "20260716")

# ---- helpers ---------------------------------------------------------------

WEIRD <- character(0)
weird <- function(cert, msg) {
  WEIRD <<- c(WEIRD, sprintf("CERT %s: %s", cert, msg))
}

# Trace values as plotted, NULL-safe (a NULL in a built list is a gap)
num_y <- function(y) {
  if (is.list(y)) y <- lapply(y, function(v) if (is.null(v)) NA else v)
  as.numeric(unlist(y))
}
built_traces <- function(p) plotly::plotly_build(p)$x$data

# got (plotted) vs want (recomputed): scalar/vector, same length, same
# finite pattern, equal where both exist. For phase 1's derive() checks.
expect_near <- function(nm, got, want, tol = 1e-8) {
  if (length(got) != length(want)) {
    stop(nm, ": length ", length(got), " plotted vs ", length(want),
         " recomputed")
  }
  fg <- is.finite(got); fw <- is.finite(want)
  if (!identical(fg, fw)) {
    stop(nm, ": finite-pattern mismatch at position ",
         paste(utils::head(which(fg != fw), 3), collapse = ","))
  }
  d <- abs(got[fg] - want[fg])
  if (length(d) > 0 && max(d) > tol) {
    j <- which(fg)[which.max(d)]
    stop(nm, ": plotted ", got[j], " but raw columns say ", want[j],
         " (position ", j, ", diff ", max(d), ")")
  }
  cat("ok:", nm, "\n")
}

# One built trace vs the recompute, matched on x rather than position:
# plotly_build prunes missing points (leading/trailing NA on line traces,
# every NA row on bars and stacked areas), so positions don't line up.
# `keys` is the expected x for every window row (dates or quarter labels),
# `want` the recomputed y. Asserts every plotted point equals the raw-column
# recompute at its x, and every finite recomputed value made it onto the
# chart — a real number silently missing from a chart is also a bug.
expect_trace <- function(nm, traces, trname, keys, want, tol = 1e-8) {
  tr <- Filter(function(t) identical(t$name, trname), traces)
  if (length(tr) == 0) {
    # plotly drops a trace whose every point is missing; that's only a bug
    # if the raw columns actually hold real values for it
    if (any(is.finite(want))) {
      stop(nm, ": trace absent from the chart but raw columns have real values")
    }
    cat("ok:", nm, "(no real values, legitimately empty)\n")
    return(invisible())
  }
  stopifnot(length(tr) == 1)
  px <- tr[[1]]$x
  if (is.list(px)) px <- unlist(lapply(px, function(v) if (is.null(v)) NA else v))
  px <- as.character(px)
  py <- num_y(tr[[1]]$y)
  keys <- as.character(keys)
  stopifnot(!anyDuplicated(keys), length(keys) == length(want))
  keep <- !is.na(px)          # line traces keep interior gaps as (NA, NA)
  px <- px[keep]; py <- py[keep]
  stray <- setdiff(px, keys)
  if (length(stray) > 0) {
    stop(nm, ": plotted x outside the expected window: ",
         paste(utils::head(stray, 3), collapse = ","))
  }
  w <- unname(stats::setNames(want, keys)[px])
  fg <- is.finite(py); fw <- is.finite(w)
  if (!identical(fg, fw)) {
    stop(nm, ": finite-pattern mismatch at ",
         paste(utils::head(px[fg != fw], 3), collapse = ","))
  }
  d <- abs(py[fg] - w[fg])
  if (length(d) > 0 && max(d) > tol) {
    j <- which(fg)[which.max(d)]
    stop(nm, ": plotted ", py[j], " at ", px[j], " but raw columns say ",
         w[j], " (diff ", max(d), ")")
  }
  hidden <- setdiff(keys[is.finite(want)], px)
  if (length(hidden) > 0) {
    stop(nm, ": chart omits real values at ",
         paste(utils::head(hidden, 3), collapse = ","))
  }
  cat("ok:", nm, "\n")
}

# Inf on a chart is a broken axis (hard); NaN plotly draws as a gap (weird)
scan_traces <- function(traces, tag, cert) {
  for (t in traces) {
    y <- num_y(t$y)
    if (any(is.infinite(y))) {
      stop(tag, ": trace '", t$name, "' carries Inf onto the chart")
    }
    if (any(is.nan(y))) {
      weird(cert, paste0(tag, ": trace '", t$name, "' has ",
                         sum(is.nan(y)), " NaN quarters (drawn as gaps)"))
    }
  }
}

# Independent in-year differencing of a YTD flow field. Base-R on purpose:
# shares no code with add_nco_q/prov_nco_bars (dplyr lag), so a bug there
# cannot hide here. First filing of a calendar year = the YTD value as-is,
# matching the app's lag(default = 0) semantics.
qflow <- function(risdate, ytd) {
  yr <- as.numeric(risdate) %/% 10000
  out <- ytd
  for (y in unique(yr)) {
    i <- which(yr == y)
    if (length(i) > 1) out[i[-1]] <- ytd[i[-1]] - ytd[i[-length(i)]]
  }
  out
}

# Mirror of usd_axis_unit's divisor decision, written independently
usd_div <- function(vals) {
  vals <- vals[is.finite(vals)]
  if (length(vals) > 0 && max(abs(vals)) >= 1e6) 1e6 else 1e3
}

# ---- roster: 3 small + 2 medium + 3 large + 2 weird ------------------------

inst   <- fetch_institutions_cached()
xs_raw <- readRDS(file.path("data", paste0("xs_", XS_RISDATE, ".rds")))
xs_raw$CERT <- as.integer(xs_raw$CERT)

# Weird #1 is pinned; #2 is screened deterministically (no seed): the
# largest bank whose latest filing is extreme — no loan book, deposits
# under 0.5% of assets, or a near-all-equity balance sheet
WEIRD1 <- 35164L
ln_book  <- xs_raw$LNLSNET + xs_raw$LNATRES
scr <- data.frame(
  CERT     = xs_raw$CERT,
  ASSET    = xs_raw$ASSET,
  ln0      = !is.na(ln_book) & ln_book == 0,
  dep_tiny = !is.na(xs_raw$DEP) & !is.na(xs_raw$ASSET) &
             xs_raw$DEP < 0.005 * xs_raw$ASSET,
  eq_heavy = !is.na(xs_raw$EQ) & !is.na(xs_raw$ASSET) &
             xs_raw$EQ >= 0.9 * xs_raw$ASSET
)
scr <- scr[(scr$ln0 | scr$dep_tiny | scr$eq_heavy) &
             scr$CERT != WEIRD1 & !is.na(scr$ASSET), ]
stopifnot(nrow(scr) > 0)
w2 <- scr[which.max(scr$ASSET), ]
WEIRD2 <- w2$CERT
cat("weird #2 screen: CERT", WEIRD2,
    paste(c("zero loan book", "deposits < 0.5% of assets",
            "equity >= 90% of assets")[c(w2$ln0, w2$dep_tiny, w2$eq_heavy)],
          collapse = " + "), "\n")

pool <- inst |>
  dplyr::filter(!is.na(ASSET), CERT %in% xs_raw$CERT,
                !CERT %in% c(WEIRD1, WEIRD2))
set.seed(as.integer(INTEGRITY_SEED))
pick <- function(lo, hi, n) {
  certs <- pool$CERT[pool$ASSET >= lo & pool$ASSET < hi]
  stopifnot(length(certs) >= n)
  sample(certs, n)
}
roster <- data.frame(
  CERT   = c(pick(0, 1e5, 3), pick(1e5, 1e6, 2), pick(1e6, Inf, 3),
             WEIRD1, WEIRD2),
  bucket = c(rep("small", 3), rep("medium", 2), rep("large", 3),
             rep("weird", 2))
)
cat("roster (seed ", INTEGRITY_SEED, "):\n", sep = "")
for (i in seq_len(nrow(roster))) {
  a <- inst$ASSET[inst$CERT == roster$CERT[i]][1]
  cat(sprintf("  %-6s CERT %-6d %-9s %s\n", roster$bucket[i], roster$CERT[i],
              fmt_value(a, "usd_k"), bank_label(roster$CERT[i], inst)))
}

# ---- phase 1: offline single-quarter checks against the cross-section -----

xs <- derive(xs_raw)
cat("\n== phase 1: cross-section", XS_RISDATE, "==\n")
for (cert in roster$CERT) {
  raw <- xs_raw[xs_raw$CERT == cert, ]
  r   <- xs[xs$CERT == cert, ]
  stopifnot(nrow(raw) == 1, nrow(r) == 1)
  tag <- function(nm) paste0(nm, " CERT ", cert)
  gross <- raw$LNLSNET + raw$LNATRES

  # derive() vs our own arithmetic on the raw columns
  expect_near(tag("gross_lns"), r$gross_lns, gross)
  expect_near(tag("p3_pct"), r$p3_pct, 100 * raw$P3LNLS / gross)
  expect_near(tag("bro_pct_dep"), r$bro_pct_dep, 100 * raw$BRO / raw$DEP)
  expect_near(tag("core_pct_dep"), r$core_pct_dep,
              if (!is.na(raw$DEP) && raw$DEP > 0)
                100 * raw$COREDEP / raw$DEP else NA_real_)
  expect_near(tag("alw_cover"), r$alw_cover,
              if (!is.na(raw$NCLNLS) && raw$NCLNLS > 0)
                raw$LNATRES / raw$NCLNLS else NA_real_)
  expect_near(tag("unrl_pct_eq"), r$unrl_pct_eq,
              100 * ((raw$SCAF - raw$SCAA) + (raw$SCHF - raw$SCHA)) / raw$EQ)
  stopifnot(identical(r$date, as.Date(as.character(XS_RISDATE), "%Y%m%d")))

  # Component orderings: violations are upstream FDIC data, faithfully
  # displayed — report, don't fail ($1k tolerance for FDIC rounding)
  ords <- list(c("COREDEP", "DEP"), c("BRO", "DEP"), c("DEPUNINS", "DEP"))
  for (o in ords) {
    a <- raw[[o[1]]]; b <- raw[[o[2]]]
    if (!is.na(a) && !is.na(b) && a > b + 1) {
      weird(cert, sprintf("%s ($%sk) exceeds %s ($%sk)", o[1], a, o[2], b))
    }
  }
  for (nm in c("NCLNLS", "P3LNLS")) {
    v <- raw[[nm]]
    if (!is.na(v) && !is.na(gross) && v > gross + 1) {
      weird(cert, sprintf("%s ($%sk) exceeds gross loans ($%sk)", nm, v, gross))
    }
  }

  # Loan-mix identity: the 7 chart components must rebuild the whole book
  # unless the builder's pmax() clipped a negative residual
  parts <- c(raw$LNAG, raw$LNRECONS, raw$LNRENRES, raw$LNREMULT,
             raw$LNRE, raw$LNCI)
  if (anyNA(parts) || is.na(gross)) {
    weird(cert, "loan-mix component NA in the cross-section, identity unchecked")
  } else {
    re_resid <- raw$LNRE - raw$LNRECONS - raw$LNRENRES - raw$LNREMULT
    ln_resid <- gross - raw$LNAG - raw$LNCI - raw$LNRE
    if (re_resid < 0 || ln_resid < 0) {
      weird(cert, sprintf(
        "loan components exceed book (re_resid %s, ln_resid %s $k) — chart silently clips",
        re_resid, ln_resid))
    } else {
      total <- raw$LNAG + raw$LNRECONS + raw$LNRENRES + raw$LNREMULT +
        re_resid + raw$LNCI + ln_resid
      stopifnot(abs(total - gross) < 1e-6)
      cat("ok:", tag("loan-mix identity"), "\n")
    }
  }

  # FDIC's own shipped ratios vs the raw dollar fields (their denominators
  # differ subtly, e.g. period averages — drift is review-worthy, not wrong)
  recon <- list(
    c("NCLNLSR",  100 * raw$NCLNLS / gross),
    c("LNATRESR", 100 * raw$LNATRES / gross),
    c("COREDEPR", 100 * raw$COREDEP / raw$ASSET),
    c("BROR",     100 * raw$BRO / raw$ASSET)
  )
  for (rc in recon) {
    shipped <- raw[[rc[1]]]; ours <- as.numeric(rc[2])
    if (is.finite(shipped) && is.finite(ours) && abs(shipped - ours) > 0.15) {
      weird(cert, sprintf("FDIC %s = %.2f but raw fields say %.2f",
                          rc[1], shipped, ours))
    }
  }

  # Economic weirdness screens (never fail — this is the human-review feed)
  if (!is.na(raw$DEP) && raw$DEP == 0) weird(cert, "zero deposits")
  if (!is.na(gross) && gross == 0) weird(cert, "zero loan book")
  if (!is.na(raw$EQ) && raw$EQ <= 0) weird(cert, "non-positive equity")
  if (is.finite(r$alw_cover) && r$alw_cover > 50) {
    weird(cert, sprintf("allowance covers noncurrent %.0fx", r$alw_cover))
  }
  if (is.finite(r$unrl_pct_eq) && abs(r$unrl_pct_eq) > 200) {
    weird(cert, sprintf("unrealized losses %.0f%% of equity", r$unrl_pct_eq))
  }
  if (!anyNA(c(raw$ASSET, raw$LIAB, raw$EQ)) &&
      abs(raw$ASSET - (raw$LIAB + raw$EQ)) > 0.01 * raw$ASSET) {
    weird(cert, sprintf("balance sheet gap: ASSET %s vs LIAB+EQ %s ($k)",
                        raw$ASSET, raw$LIAB + raw$EQ))
  }
  cat("phase 1 ok: CERT", cert, "\n")
}

# Whole-cross-section sweep: how many of all ~4,350 banks would put a
# non-finite value on a chart (the class of bank that exposed CERT 35164)
sweep <- c(
  p3_pct        = sum(!is.na(xs$p3_pct) & !is.finite(xs$p3_pct)),
  bro_pct_dep   = sum(!is.na(xs$bro_pct_dep) & !is.finite(xs$bro_pct_dep)),
  core_pct_dep  = sum(!is.na(xs$core_pct_dep) & !is.finite(xs$core_pct_dep)),
  unrl_pct_eq   = sum(!is.na(xs$unrl_pct_eq) & !is.finite(xs$unrl_pct_eq)),
  uninsured_share = sum({
    u <- 100 * xs_raw$DEPUNINS / xs_raw$DEP   # funding_share computes this
    !is.na(u) & !is.finite(u)                 # inline with no DEP > 0 guard
  })
)
for (nm in names(sweep)) {
  if (sweep[[nm]] > 0) {
    weird("sweep", sprintf("%d of %d banks have non-finite %s in the cross-section",
                           sweep[[nm]], nrow(xs), nm))
  }
}
cat("cross-section sweep done:", nrow(xs), "banks\n")

# ---- phase 2: live full-history checks (self-skips offline) ----------------

run_live <- Sys.getenv("INTEGRITY_SKIP_LIVE", "") != "1"
if (run_live) {
  probe <- tryCatch(fetch_bank_financials(WEIRD1, years = 2024:2026),
                    error = function(e) NULL)
  run_live <- !is.null(probe) && nrow(probe) > 0
}

if (!run_live) {
  cat("\nSKIPPED: FDIC API unreachable (or INTEGRITY_SKIP_LIVE=1) —",
      "live-history phase not run\n")
} else {
  cat("\n== phase 2: full histories from the FDIC API ==\n")
  for (cert in roster$CERT) {
    lbl <- bank_label(cert, inst)
    dfd <- tryCatch(fetch_bank_cached(cert), error = function(e)
      stop("CERT ", cert, ": fetch/derive crashed — the app would break on ",
           "this bank: ", conditionMessage(e)))
    if (is.null(dfd)) stop("CERT ", cert, ": no FDIC filings returned")
    raw <- readRDS(file.path(CACHE_DIR, paste0("cert_", cert, ".rds")))
    raw <- raw[order(as.numeric(raw$RISDATE)), ]
    rdate <- as.Date(as.character(raw$RISDATE), format = "%Y%m%d")
    stopifnot(nrow(dfd) == nrow(raw), identical(dfd$date, rdate))
    tag <- function(nm) paste0(nm, " CERT ", cert)

    # Panel integrity: strictly increasing quarter-end dates, no dups
    stopifnot(!anyDuplicated(raw$RISDATE),
              !is.unsorted(as.numeric(raw$RISDATE), strictly = TRUE),
              all(as.integer(format(rdate, "%m")) %in% c(3, 6, 9, 12)),
              all(format(rdate + 1, "%d") == "01"))
    qidx <- as.integer(format(rdate, "%Y")) * 4 +
      (as.integer(format(rdate, "%m")) - 1) %/% 3
    if (any(diff(qidx) > 1)) {
      weird(cert, sprintf("%d gap(s) in the quarterly filing history",
                          sum(diff(qidx) > 1)))
    }

    # A builder that crashes on a real bank is a hard fail (the app page
    # would error); Inf in any built trace likewise
    build <- function(nm, expr) {
      p <- tryCatch(expr, error = function(e)
        stop("builder ", nm, " crashed on CERT ", cert, ": ",
             conditionMessage(e)))
      bt <- built_traces(p)
      scan_traces(bt, nm, cert)
      list(p = p, bt = bt)
    }

    gross_full <- raw$LNLSNET + raw$LNATRES

    # Funding Mix: three shares of the same deposit denominator, 1dp,
    # window >= 2015 (Core NA-guarded on DEP, exactly as derive() does)
    w <- rdate >= as.Date("2015-01-01")
    fs <- build("funding_share", funding_share(dfd))
    dep <- raw$DEP[w]
    fund_want <- list(
      "Core"      = round(ifelse(dep > 0, 100 * raw$COREDEP[w] / dep,
                                 NA_real_), 1),
      "Brokered"  = round(100 * raw$BRO[w] / dep, 1),
      "Uninsured" = round(100 * raw$DEPUNINS[w] / dep, 1)
    )
    for (nm in names(fund_want)) {
      expect_trace(tag(paste("funding", nm)), fs$bt, nm, rdate[w],
                   fund_want[[nm]])
      v <- fund_want[[nm]]
      if (any(is.finite(v) & (v < -1 | v > 101))) {
        weird(cert, paste0("funding ", nm, " share outside [0,100]: ",
                           paste(range(v[is.finite(v)]), collapse = "..")))
      }
    }

    # Loan mix: 7 components rebuild the book, both modes, 2dp, >= 2010
    w10 <- rdate >= as.Date("2010-01-01")
    grossw <- gross_full[w10]
    re_resid <- raw$LNRE[w10] - raw$LNRECONS[w10] - raw$LNRENRES[w10] -
      raw$LNREMULT[w10]
    ln_resid <- grossw - raw$LNAG[w10] - raw$LNCI[w10] - raw$LNRE[w10]
    comp <- list(
      "Agriculture"            = raw$LNAG[w10],
      "Construction"           = raw$LNRECONS[w10],
      "Commercial real estate" = raw$LNRENRES[w10],
      "Apartments"             = raw$LNREMULT[w10],
      "Other real estate"      = pmax(re_resid, 0),
      "Business loans"         = raw$LNCI[w10],
      "Everything else"        = pmax(ln_resid, 0)
    )
    lm_pct <- build("loan_mix pct", loan_mix(dfd))
    sum_pct <- rep(0, sum(w10))
    for (nm in names(comp)) {
      want <- round(100 * comp[[nm]] / grossw, 2)
      expect_trace(tag(paste("loan_mix pct", nm)), lm_pct$bt, nm,
                   rdate[w10], want)
      sum_pct <- sum_pct + want
    }
    unclip <- is.finite(re_resid) & re_resid >= 0 &
      is.finite(ln_resid) & ln_resid >= 0 & is.finite(grossw) & grossw > 0
    stopifnot(all(abs(sum_pct[unclip] - 100) < 0.1))
    if (any(!unclip & is.finite(grossw) & grossw > 0)) {
      weird(cert, sprintf("loan components exceed book in %d quarter(s) — chart silently clips",
                          sum(!unclip & is.finite(grossw) & grossw > 0)))
    }
    lm_usd <- build("loan_mix usd", loan_mix(dfd, mode = "usd"))
    div <- usd_div(grossw)
    for (nm in names(comp)) {
      expect_trace(tag(paste("loan_mix usd", nm)), lm_usd$bt, nm,
                   rdate[w10], round(comp[[nm]] / div, 2))
    }

    # Risk vs cushion: NTLNLS differenced on the FULL history, then
    # windowed to >= 2019 (the builder's order), 2dp
    nco_full <- qflow(raw$RISDATE, raw$NTLNLS)
    w19 <- rdate >= as.Date("2019-01-01")
    nco19 <- nco_full[w19]; gross19 <- gross_full[w19]
    rc_pct <- build("risk_cushion pct", risk_cushion(dfd))
    expect_trace(tag("risk_cushion pct Charge-offs"), rc_pct$bt, "Charge-offs",
                 rdate[w19], round(100 * nco19 / gross19, 2))
    expect_trace(tag("risk_cushion pct Allowance"), rc_pct$bt, "Allowance",
                 rdate[w19], round(raw$LNATRESR[w19], 2))
    expect_trace(tag("risk_cushion pct Noncurrent"), rc_pct$bt, "Noncurrent",
                 rdate[w19], round(raw$NCLNLSR[w19], 2))
    rc_usd <- build("risk_cushion usd", risk_cushion(dfd, mode = "usd"))
    div <- usd_div(c(raw$LNATRES[w19], raw$NCLNLS[w19], nco19))
    expect_trace(tag("risk_cushion usd Charge-offs"), rc_usd$bt, "Charge-offs",
                 rdate[w19], round(nco19 / div, 2))
    expect_trace(tag("risk_cushion usd Allowance"), rc_usd$bt, "Allowance",
                 rdate[w19], round(raw$LNATRES[w19] / div, 2))
    expect_trace(tag("risk_cushion usd Noncurrent"), rc_usd$bt, "Noncurrent",
                 rdate[w19], round(raw$NCLNLS[w19] / div, 2))

    # Provision vs charge-offs: window FIRST (>= 20220101), then difference
    # (the builder's order), 3dp pct / 2dp usd
    w22 <- as.numeric(raw$RISDATE) >= 20220101
    prov22 <- qflow(raw$RISDATE[w22], raw$ELNATR[w22])
    nco22  <- qflow(raw$RISDATE[w22], raw$NTLNLS[w22])
    gross22 <- gross_full[w22]
    # The bars are keyed by quarter label, recomputed here from RISDATE
    rd22 <- as.character(raw$RISDATE[w22])
    qlab22 <- paste0("Q", (as.integer(substr(rd22, 5, 6)) - 1) %/% 3 + 1,
                     "'", substr(rd22, 3, 4))
    pn_usd <- build("prov_nco_bars usd", prov_nco_bars(dfd))
    div <- usd_div(c(prov22, nco22))
    expect_trace(tag("prov_nco usd Provision"), pn_usd$bt, "Provision",
                 qlab22, round(prov22 / div, 2))
    expect_trace(tag("prov_nco usd Charge-offs"), pn_usd$bt, "Charge-offs",
                 qlab22, round(nco22 / div, 2))
    pn_pct <- build("prov_nco_bars pct", prov_nco_bars(dfd, mode = "pct"))
    expect_trace(tag("prov_nco pct Provision"), pn_pct$bt, "Provision",
                 qlab22, round(100 * prov22 / gross22, 3))
    expect_trace(tag("prov_nco pct Charge-offs"), pn_pct$bt, "Charge-offs",
                 qlab22, round(100 * nco22 / gross22, 3))

    # Delinquency pipeline: three ratios, 2dp, >= 2019
    pl <- build("pipeline_lines", pipeline_lines(dfd))
    expect_trace(tag("pipeline 30-89"), pl$bt, "30-89 days late",
                 rdate[w19], round(100 * raw$P3LNLS[w19] / gross19, 2))
    expect_trace(tag("pipeline Noncurrent"), pl$bt, "Noncurrent",
                 rdate[w19], round(raw$NCLNLSR[w19], 2))
    expect_trace(tag("pipeline Allowance"), pl$bt, "Allowance",
                 rdate[w19], round(raw$LNATRESR[w19], 2))

    # metric_ts spot checks: $ level with the shared-axis divisor, a
    # %-of-assets rescale, and a native FDIC pct passed through untouched
    bl <- stats::setNames(list(dfd), lbl)
    cl <- stats::setNames("#2C5F8A", lbl)
    mt <- build("metric_ts ASSET", metric_ts(bl, "ASSET", FIELDS_META, cl))
    div <- usd_div(raw$ASSET)
    expect_trace(tag("metric_ts ASSET"), mt$bt, lbl, rdate,
                 round(raw$ASSET / div, 2))
    ttl <- plotly::plotly_build(mt$p)$x$layout$yaxis$title
    if (is.list(ttl)) ttl <- ttl$text
    stopifnot(grepl(if (div == 1e6) "($B)" else "($M)", ttl, fixed = TRUE))
    mt2 <- build("metric_ts DEPUNINS pct_assets",
                 metric_ts(bl, "DEPUNINS", FIELDS_META, cl,
                           display = "pct_assets"))
    expect_trace(tag("metric_ts DEPUNINS %assets"), mt2$bt, lbl, rdate,
                 round(100 * raw$DEPUNINS / raw$ASSET, 2))
    mt3 <- build("metric_ts NCLNLSR", metric_ts(bl, "NCLNLSR", FIELDS_META, cl))
    expect_trace(tag("metric_ts NCLNLSR"), mt3$bt, lbl, rdate,
                 round(raw$NCLNLSR, 2))

    # qflow self-consistency: quarters of a 4-filing year telescope back to
    # the Q4 YTD, and a year's first filing passes through as-is
    yr <- as.numeric(raw$RISDATE) %/% 10000
    for (y in unique(yr)) {
      i <- which(yr == y)
      stopifnot(isTRUE(all.equal(nco_full[i[1]], raw$NTLNLS[i[1]])))
      if (length(i) == 4 && all(is.finite(raw$NTLNLS[i]))) {
        stopifnot(abs(sum(nco_full[i]) - raw$NTLNLS[i[4]]) < 1e-6)
      }
    }

    # FDIC's own annualized quarterly NCO rate as an external yardstick
    # (their denominator is average loans; 1pp tolerance, review not fail)
    if (!is.null(raw$NTLNLSQR)) {
      ours <- 4 * 100 * nco19 / gross19
      theirs <- raw$NTLNLSQR[w19]
      n_off <- sum(is.finite(ours) & is.finite(theirs) &
                     abs(ours - theirs) > 1)
      if (n_off > 0) {
        weird(cert, sprintf("annualized NCO rate differs from FDIC NTLNLSQR by >1pp in %d quarter(s)",
                            n_off))
      }
    }

    # Economic weirdness in the windows the charts draw
    if (sum(is.finite(nco19) & nco19 < 0) > 0) {
      weird(cert, sprintf("%d quarter(s) of net recoveries (negative charge-offs)",
                          sum(is.finite(nco19) & nco19 < 0)))
    }
    pr <- 100 * prov22 / gross22
    if (any(is.finite(pr) & pr > 5)) {
      weird(cert, sprintf("provision spike: %.1f%% of loans in one quarter",
                          max(pr[is.finite(pr)])))
    }
    if (any(!is.na(dep) & dep == 0)) weird(cert, "zero deposits in the funding window")
    if (any(!is.na(gross19) & gross19 == 0)) weird(cert, "zero loan book in the chart window")

    cat("phase 2 ok: CERT ", cert, " (", lbl, ")\n", sep = "")
  }
}

# ---- summary ----------------------------------------------------------------

if (length(WEIRD) > 0) {
  cat("\n==== WEIRDNESS REPORT (", length(WEIRD),
      " items, human review — none are failures) ====\n", sep = "")
  for (wd in WEIRD) cat(" -", wd, "\n")
} else {
  cat("\n==== WEIRDNESS REPORT: none ====\n")
}
cat("integrity test passed\n")
