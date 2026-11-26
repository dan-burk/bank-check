# The deposit-run simulator: how big a run breaks each bank. A run of size
# s takes s of the bank's uninsured (or all) deposits; the bank pays it by
# selling assets in a fixed order, and the losses it realizes come out of
# Tier 1. Broken = Tier 1 below 2% of assets (critically undercapitalized)
# or nothing left to sell ("can't pay"). Pure: data frames in, data frame
# out, so the run_stress mart and research/run-stress call the same code.
# Moved from research/run-stress/simulate.R (method and SVB walk-through in
# research/run-stress/README.md). Dollar fields are $ thousands.
#
# Missing is NA, never 0. A bank without an input a run needs gets NA for
# that run and an na_reason, and no percentile: it is not "never breaks".
# The loan sale price comes from the hidden_loss estimate (R/hidden_loss.R).

# The raw columns run_stress() reads (all in RAW_FIELDS)
RS_FIELDS <- c("CERT", "RISDATE", "ASSET", "RBCT1J", "DEP", "DEPDOM", "DEPUNINS",
               "CHBAL", "FREPO", "TRADE", "SCAA", "SCAF", "SCHA", "SCHF",
               "LNLSNET", "LNLSGR", "OTHBFHLB")

# Assumptions, all in one place: the research defaults
RS_PARAMS <- list(
  cash_floor   = 0.02,  # cash kept back for daily operations, share of assets
  fire_haircut = 0,     # extra discount on loan sales beyond the rate mark
  fhlb_cap     = 0.25,  # FHLB on: total FHLB borrowing up to 25% of assets
  afs_in_t1    = FALSE, # FALSE = AOCI opt-out: selling AFS realizes its loss
                        # into Tier 1 (true for all but the largest banks)
  pca_crit     = 0.02,  # critically undercapitalized: below 2% of assets
  pca_under    = 0.04,  # undercapitalized: below 4%
  s_fine       = seq(0, 1, by = 0.005),  # run sizes for the breaking point
  max_drop     = HL_PARAMS$max_drop,     # cap on the loan discount
  method_version = "rs-1"
)

# The four runs: on uninsured or all deposits, FHLB borrowing off or on
RS_CONFIGS <- list(unins      = list(base = "unins", fhlb = FALSE),
                   unins_fhlb = list(base = "unins", fhlb = TRUE),
                   all        = list(base = "all",   fhlb = FALSE),
                   all_fhlb   = list(base = "all",   fhlb = TRUE))

# One quarter's simulator inputs: the raw columns plus, from hidden_loss,
# the loan discount (modeled rate loss / gross loans, capped at max_drop).
#   cur  raw quarter frame with RS_FIELDS
#   hl   hidden_loss rows (CERT, loss_loans_res, loss_loans_oth) for that quarter
# Every filer stays a row. ok_core: inputs every run needs; ok_unins and
# ok_fhlb: the extra input of those runs. need_why: what is missing.
rs_inputs <- function(cur, hl, params = RS_PARAMS) {
  d <- data.frame(CERT = as.integer(cur$CERT), RISDATE = as.integer(cur$RISDATE))
  for (v in setdiff(RS_FIELDS, c("CERT", "RISDATE"))) d[[v]] <- as.numeric(cur[[v]])
  m <- match(d$CERT, hl$CERT)
  loss_loans <- hl$loss_loans_res[m] + hl$loss_loans_oth[m]
  # No loan book: nothing to sell, so the discount is moot (0). A loan book
  # without a loss estimate (no maturity buckets) is NA, not 0.
  d$loan_disc <- ifelse(!is.na(d$LNLSGR) & d$LNLSGR == 0, 0,
                        pmin(params$max_drop, pmax(0, loss_loans / d$LNLSGR)))
  d$t1_ratio <- ifelse(d$ASSET > 0, d$RBCT1J / d$ASSET, NA_real_)
  d$unins_share <- uninsured_share(d$DEPUNINS, d$DEPDOM)

  sell <- c("CHBAL", "FREPO", "TRADE", "SCAA", "SCAF", "SCHA", "SCHF", "LNLSNET")
  why <- cbind(
    ifelse(is.na(d$ASSET) | !(d$ASSET > 0), "no assets", NA),
    ifelse(is.na(d$RBCT1J), "no Tier 1 capital", NA),
    ifelse(is.na(d$DEP) | !(d$DEP > 0), "no deposits", NA),
    ifelse(!stats::complete.cases(d[sell]), "assets to sell not reported", NA),
    ifelse(is.na(d$loan_disc), "no loan loss estimate", NA))
  d$ok_core  <- rowSums(!is.na(why)) == 0
  d$ok_unins <- !is.na(d$DEPUNINS)
  d$ok_fhlb  <- !is.na(d$OTHBFHLB)
  why <- cbind(why, ifelse(d$ok_unins, NA, "no uninsured deposits reported (uninsured runs)"),
               ifelse(d$ok_fhlb, NA, "no FHLB advances reported (FHLB-on runs)"))
  d$need_why <- apply(why, 1, function(w) if (all(is.na(w))) NA_character_
                                          else paste(w[!is.na(w)], collapse = "; "))
  d
}

# A run of size s on every bank in d (rows from rs_inputs() with complete
# inputs for this run). base "unins": s of uninsured deposits leave; "all":
# s of all deposits (DEP, foreign offices included). Returns one row per
# bank: where the cash came from (from_*), the shortfall, the realized
# loss, Tier 1 and assets after, the ratio after, and the outcomes.
run_sim <- function(d, s, base = c("unins", "all"), fhlb = FALSE, params = RS_PARAMS) {
  base <- match.arg(base)
  p <- params
  need <- s * if (base == "unins") d$DEPUNINS else d$DEP
  ln_px <- pmax(0, 1 - d$loan_disc - p$fire_haircut)    # cash per $1 of loan book
  # Loss per $1 raised; 0 where there is nothing to sell (avail is 0 then)
  rate <- function(num, den) ifelse(den > 0, num / den, 0)
  # Pecking order. avail = cash it can raise; loss = Tier 1 loss per $1
  # raised; aloss = book value written off per $1 raised (beyond the $1 paid)
  src <- list(
    cash  = list(avail = pmax(0, d$CHBAL - p$cash_floor * d$ASSET), loss = 0, aloss = 0),
    ffrp  = list(avail = d$FREPO, loss = 0, aloss = 0),
    fhlb  = list(avail = if (fhlb) pmax(0, p$fhlb_cap * d$ASSET - d$OTHBFHLB) else 0 * d$ASSET,
                 loss = 0, aloss = 0),
    trade = list(avail = d$TRADE, loss = 0, aloss = 0),
    # AFS is on the books at fair value: no write-off. Its loss is in equity
    # but (opt-out) not in Tier 1 until it is sold.
    afs   = list(avail = d$SCAF,
                 loss = if (p$afs_in_t1) 0 else rate(d$SCAA - d$SCAF, d$SCAF), aloss = 0),
    # HTM is at amortized cost: selling at fair value writes off the gap
    htm   = list(avail = d$SCHF, loss = rate(d$SCHA - d$SCHF, d$SCHF),
                 aloss = rate(d$SCHA - d$SCHF, d$SCHF)),
    loans = list(avail = d$LNLSNET * ln_px, loss = rate(1 - ln_px, ln_px),
                 aloss = rate(1 - ln_px, ln_px)),
    # Last resort: the operating cash floor itself
    floor = list(avail = pmin(d$CHBAL, p$cash_floor * d$ASSET), loss = 0, aloss = 0)
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
  # Assets shrink by the cash paid out and the write-offs; FHLB cash comes
  # in before it goes out, so it adds back
  out$asset_after <- d$ASSET - (need - left) + out$from_fhlb - a_loss
  out$ratio_after <- ifelse(out$asset_after > 0, out$t1_after / out$asset_after, -Inf)
  out$cant_pay <- left > 1e-6 * pmax(1, need)
  out$crit  <- out$ratio_after < p$pca_crit
  out$under <- out$ratio_after < p$pca_under
  out$fails <- out$crit | out$cant_pay
  out
}

# Breaking point: the smallest run on s_fine that breaks the bank, and how
# ("below 2%" or "can't pay"); "never" if not even a 100% run does. Also the
# lowest ratio reached on the way, which orders the banks that never break.
breaking_point <- function(d, base, fhlb, params = RS_PARAMS) {
  bp <- rep(NA_real_, nrow(d)); lo <- rep(Inf, nrow(d)); how <- rep("never", nrow(d))
  for (s in params$s_fine) {
    r <- run_sim(d, s, base, fhlb, params)
    lo <- pmin(lo, r$ratio_after)
    f <- r$fails & is.na(bp)
    bp[f] <- s
    how[f] <- ifelse(r$cant_pay[f], "can't pay", "below 2%")
  }
  data.frame(CERT = d$CERT, bp = bp, min_ratio = lo, how = how)
}

# Rank, 1 = most fragile: by breaking point (never = after every break),
# then by the lowest ratio reached. NA where `ranked` is FALSE: missing
# inputs never rank as safe.
rs_rank <- function(bp, min_ratio, ranked) {
  r <- rep(NA_integer_, length(bp))
  i <- which(ranked)
  o <- i[order(ifelse(is.na(bp[i]), 2, bp[i]), min_ratio[i])]
  r[o] <- seq_along(o)
  r
}

# One quarter, every filer: breaking point, how, lowest ratio and
# percentile (pct_worst: share of ranked banks at least as fragile, small =
# worse) for each of RS_CONFIGS. Banks with no loans and no securities are
# not ranked: they "can't pay" any large run whatever their capital (trust
# companies; spec trap 15).
run_stress <- function(cur, hl, params = RS_PARAMS) {
  d <- rs_inputs(cur, hl, params)
  out <- d[c("CERT", "RISDATE", "ASSET", "RBCT1J", "t1_ratio", "unins_share", "loan_disc")]
  sellable <- d$LNLSNET + d$SCAF + d$SCHF > 0
  for (k in names(RS_CONFIGS)) {
    cf <- RS_CONFIGS[[k]]
    ok <- d$ok_core & (cf$base != "unins" | d$ok_unins) & (!cf$fhlb | d$ok_fhlb)
    b <- breaking_point(d[ok, ], cf$base, cf$fhlb, params)
    bp <- rep(NA_real_, nrow(d)); how <- rep(NA_character_, nrow(d)); lo <- bp
    bp[ok] <- b$bp; how[ok] <- b$how; lo[ok] <- b$min_ratio
    r <- rs_rank(bp, lo, ok & sellable)
    out[[paste0("bp_", k)]] <- bp
    out[[paste0("how_", k)]] <- how
    out[[paste0("min_ratio_", k)]] <- lo
    out[[paste0("pct_worst_", k)]] <- r / sum(!is.na(r))
  }
  out$na_reason <- ifelse(d$ok_core & !sellable,
                          ifelse(is.na(d$need_why), "no loans or securities: not ranked",
                                 paste0(d$need_why, "; no loans or securities: not ranked")),
                          d$need_why)
  out$method_version <- params$method_version
  rownames(out) <- NULL
  out
}
