# The run simulator as functions, no side effects. Sourced by 02_run.R.
# Dollar fields are $ thousands (FDIC convention).

source("app/R/api.R")                              # prev_quarter_end()
source("research/unrealized-losses/estimator.R")   # estimate(), MAX_DROP

BT_CACHE <- "research/backtest/cache"     # estimator fields + RBC1AAJ, all quarters
RS_CACHE <- "research/run-stress/cache"   # extra fields (01_fetch.R)

# ---- Assumptions (all in one place) ---------------------------------------
CASH_FLOOR   <- 0.02   # cash kept back for daily operations, share of assets
FIRE_HAIRCUT <- 0      # extra discount on loan sales beyond the rate mark
FHLB_CAP     <- 0.25   # when FHLB is ON: total FHLB borrowing up to 25% of assets
AFS_IN_TIER1 <- FALSE  # FALSE = AOCI opt-out: AFS losses are NOT yet in Tier 1,
                       # so selling AFS realizes them into Tier 1 (true for
                       # all but the very largest banks)
PCA_CRIT     <- 0.02   # critically undercapitalized: tangible equity < 2% of assets
PCA_UNDER    <- 0.04   # undercapitalized: Tier 1 leverage < 4%
S_GRID       <- c(0.05, 0.10, 0.20, 0.30, 0.50)
S_FINE       <- seq(0, 1, by = 0.005)  # grid for the breaking point
# ---------------------------------------------------------------------------

SIM_FIELDS <- c("CHBAL", "FREPO", "TRADE", "SCAF", "SCAA", "SCHA", "SCHF",
                "LNLSNET", "DEP", "DEPUNINS", "RBCT1J", "ASSET")

# One quarter, all banks: estimator output + the extra fields. Banks missing
# any simulator input are dropped (and counted), never filled with 0. The one
# exception is OTHBFHLB (existing FHLB advances): missing = none.
load_quarter <- function(risdate) {
  d <- suppressWarnings(estimate(risdate, prev_quarter_end(risdate), cache = BT_CACHE))
  x <- readRDS(file.path(RS_CACHE, paste0("extra_", risdate, ".rds")))
  for (v in names(x)) x[[v]] <- suppressWarnings(as.numeric(x[[v]]))
  stopifnot(!any(setdiff(names(x), "CERT") %in% names(d)))
  d <- merge(d, x, by = "CERT")
  d$OTHBFHLB[is.na(d$OTHBFHLB)] <- 0
  ok <- stats::complete.cases(d[SIM_FIELDS]) & d$ASSET > 0 & d$DEP > 0
  attr_drop <- sum(!ok)
  d <- d[ok, ]
  # Loan discount = the estimator's rate loss as a share of gross loans
  d$loan_disc <- pmin(MAX_DROP, pmax(0, ifelse(d$LNLSGR > 0, d$loss_loans / d$LNLSGR, 0)))
  d$loan_disc[is.na(d$loan_disc)] <- 0   # no loan book -> no loan mark
  d$t1_ratio <- d$RBCT1J / d$ASSET
  attr(d, "dropped") <- attr_drop
  d
}

# Simulate a run of size s on every bank at once.
#   base = "unins": s of UNINSURED deposits leave; "all": s of ALL deposits.
# Returns one row per bank: where the cash came from, realized loss, Tier 1
# and assets after, ratio after, and the outcomes.
run_sim <- function(d, s, base = c("unins", "all"), fhlb = FALSE,
                    haircut = FIRE_HAIRCUT, floor = CASH_FLOOR, cap = FHLB_CAP,
                    afs_in_t1 = AFS_IN_TIER1) {
  base <- match.arg(base)
  need <- s * if (base == "unins") d$DEPUNINS else d$DEP
  ln_px <- pmax(0, 1 - d$loan_disc - haircut)     # cash per $1 of loan book
  rate <- function(num, den) ifelse(den > 0, num / den, 0)
  # Pecking order. avail = cash it can raise; loss = Tier 1 loss per $1 raised;
  # aloss = book value written off per $1 raised (beyond the $1 paid out).
  src <- list(
    cash  = list(avail = pmax(0, d$CHBAL - floor * d$ASSET), loss = 0, aloss = 0),
    ffrp  = list(avail = d$FREPO, loss = 0, aloss = 0),
    fhlb  = list(avail = if (fhlb) pmax(0, cap * d$ASSET - d$OTHBFHLB) else 0 * d$ASSET,
                 loss = 0, aloss = 0),
    trade = list(avail = d$TRADE, loss = 0, aloss = 0),
    # AFS sits on the books at fair value already: no asset write-off. Its
    # loss is in equity but (opt-out) not in Tier 1 until it is sold.
    afs   = list(avail = d$SCAF,
                 loss = if (afs_in_t1) 0 else rate(d$SCAA - d$SCAF, d$SCAF), aloss = 0),
    # HTM sits at amortized cost: selling at fair value writes off the gap.
    htm   = list(avail = d$SCHF, loss = rate(d$SCHA - d$SCHF, d$SCHF),
                 aloss = rate(d$SCHA - d$SCHF, d$SCHF)),
    loans = list(avail = d$LNLSNET * ln_px, loss = rate(1 - ln_px, ln_px),
                 aloss = rate(1 - ln_px, ln_px)),
    # Last resort: the operating cash floor itself. A bank "can't pay" only
    # once everything above is gone too.
    floor = list(avail = pmin(d$CHBAL, floor * d$ASSET), loss = 0, aloss = 0)
  )
  left <- need; t1_loss <- 0; a_loss <- 0
  out <- data.frame(CERT = d$CERT, need = need)
  for (k in names(src)) {
    take <- pmin(pmax(0, src[[k]]$avail), left)
    out[[paste0("from_", k)]] <- take
    left <- left - take
    t1_loss <- t1_loss + take * src[[k]]$loss
    a_loss  <- a_loss + take * src[[k]]$aloss
  }
  out$shortfall <- left
  out$loss <- t1_loss
  out$t1_after <- d$RBCT1J - t1_loss
  # Assets shrink by the cash paid out and the book write-offs; FHLB cash
  # comes in before it goes out, so it adds back.
  paid <- need - left
  out$asset_after <- d$ASSET - paid + out$from_fhlb - a_loss
  out$ratio_after <- ifelse(out$asset_after > 0, out$t1_after / out$asset_after, -Inf)
  out$cant_pay <- left > 1e-6 * pmax(1, need)
  out$crit  <- out$ratio_after < PCA_CRIT
  out$under <- out$ratio_after < PCA_UNDER
  out$fails <- out$crit | out$cant_pay
  out
}

# Breaking point: the smallest run (on S_FINE) that leaves the bank below 2%
# or unable to pay. NA = survives even a 100% run. Also returns the lowest
# ratio the bank hits on the way, used to order the banks that never break.
breaking_point <- function(d, ...) {
  bp <- rep(NA_real_, nrow(d)); lo <- rep(Inf, nrow(d)); how <- rep(NA_character_, nrow(d))
  for (s in S_FINE) {
    r <- run_sim(d, s, ...)
    lo <- pmin(lo, r$ratio_after)
    f <- r$fails & is.na(bp)
    bp[f] <- s
    how[f] <- ifelse(r$cant_pay[f], "can't pay", "below 2%")
  }
  data.frame(CERT = d$CERT, bp = bp, min_ratio = lo, how = how)
}

# Rank, 1 = most fragile: by breaking point, then (for banks that never
# break, and for ties) by the lowest ratio reached.
bp_rank <- function(b) {
  o <- order(ifelse(is.na(b$bp), 2, b$bp), b$min_ratio)
  r <- integer(nrow(b)); r[o] <- seq_along(o); r
}
