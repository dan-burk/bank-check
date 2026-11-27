# HMDA mortgage book: pure functions, data frames in and out, shared with
# research/hmda-mortgage-rates. From that PR's 02_analyze.R. Two parts:
#   yearly   filter the loans, link lenders to banks, collapse the loans into
#            groups (mortgage_filter(), clean(), the grouping in value_book());
#            run by sources/hmda.R. Needs data.table (pipeline-only, not an app
#            dependency): its callers (sources/hmda.R, tests/run.R) attach it.
#   nightly  value the groups at a quarter end with the FRED rates
#            (run_book(), value_book()): hb_value(), base R only, because the
#            nightly job does not install data.table.
#
# HMDA codes are kept as the text the CFPB sends ("1", "NA", "Exempt"),
# so "not applicable" and "exempt" stay apart. Parsing happens here, and a
# value that does not parse is NA, never a default (spec trap 1: the
# research filled a missing term with 360).

# The LAR columns kept in hmda.lar.YYYY.parquet (names as in the 2018+
# snapshot files, "-" read as "_")
HMDA_LAR_COLS <- c("activity_year", "lei", "state_code", "action_taken",
                   "purchaser_type", "loan_type", "loan_purpose", "lien_status",
                   "reverse_mortgage", "open_end_line_of_credit",
                   "business_or_commercial_purpose", "loan_amount", "interest_rate",
                   "loan_term", "intro_rate_period", "total_units")

hmda_num <- function(x) suppressWarnings(as.numeric(x))   # "NA", "Exempt" -> NA

# The population the published count covers (data browser filters
# actions_taken=1, lien_statuses=1): originated first liens, any lender.
hmda_first_lien <- function(d) d$action_taken == "1" & d$lien_status == "1"

# What a bank books as a closed-end 1-4 family first-lien mortgage:
# originated, first lien, not a line of credit, not reverse, not business,
# 1-4 units, with an amount. Exempt flags ("1111") are not "1", so they
# stay in, as in the research. Returns a logical row index.
hmda_filter <- function(d) {
  hmda_first_lien(d) & d$open_end_line_of_credit != "1" &
    d$reverse_mortgage != "1" & d$business_or_commercial_purpose != "1" &
    d$total_units %in% c("1", "2", "3", "4") & !is.na(hmda_num(d$loan_amount))
}

# ---- Lender links: LEI -> RSSD -> CERT ---------------------------------------
# reporters  one HMDA year's reporters: activity_year, lei, respondent_rssd
#            (NA when the year has no panel row for the LEI), rssd_panel_year
# ids        CERT, RISDATE, RSSDID from the raw call reports (read_id_history())
# Returns reporters with CERT and link: "matched", "no_rssd" (no panel RSSD),
# "rssd_not_in_fdic" (the RSSD filed no call report that year).
#
# The join is dated: the CERT whose call report carried the RSSD in the
# HMDA year (newest quarter of that year that has it), not bank_ids'
# newest RSSD, because a CERT can change RSSD over time.
hmda_links <- function(reporters, ids) {
  y <- unique(reporters$activity_year)
  if (length(y) != 1) stop("hmda_links: one HMDA year at a time")
  h <- ids[ids$RISDATE %/% 10000L == y & !is.na(ids$RSSDID) & ids$RSSDID > 0, ]
  h <- h[order(-h$RISDATE), ]
  h <- h[!duplicated(h$RSSDID), ]
  m <- match(reporters$respondent_rssd, h$RSSDID)
  reporters$CERT <- h$CERT[m]
  reporters$link <- ifelse(!is.na(m), "matched",
                           ifelse(is.na(reporters$respondent_rssd), "no_rssd",
                                  "rssd_not_in_fdic"))
  reporters
}

# ---- Groups --------------------------------------------------------------------
# hmda.groups.parquet's columns: the key, then n and usd_k
HB_GROUP_COLS <- c("CERT", "year", "term_m", "coupon", "fixed", "reset_m", "kept", "n", "usd_k")

# lar: hmda.lar rows (hmda_filter() already applied, CERT attached).
# One row per (CERT, year, term_m, coupon, fixed, reset_m, kept) with the
# loan count n and summed usd_k ($ thousands). Each NA below is its own
# group, so the dollars are kept and counted, never filled:
#   kept     purchaser_type "0": not sold in the year it was made (overstates
#            retention: a December loan sold in January counts as kept)
#   coupon   interest_rate rounded to 1/8 point; NA when "Exempt", "NA" or
#            outside (0, 20)
#   term_m   loan_term rounded to whole years, in months; NA when missing,
#            exempt or outside 12-480 months
#   fixed    TRUE when intro_rate_period is "NA" (no intro period) or at
#            least the term; FALSE for an ARM; NA when exempt or unparsed
#   reset_m  the ARM's first reset (intro_rate_period months); NA if fixed
hmda_groups <- function(lar) {
  d <- data.table::as.data.table(lar)
  rate  <- hmda_num(d$interest_rate)
  term  <- hmda_num(d$loan_term)
  intro <- hmda_num(d$intro_rate_period)
  d[, `:=`(
    year    = as.integer(activity_year),
    usd_k   = hmda_num(loan_amount) / 1000,
    kept    = purchaser_type == "0",
    coupon  = ifelse(!is.na(rate) & rate > 0 & rate < 20, round(rate * 8) / 8, NA_real_),
    term_m  = ifelse(!is.na(term) & term >= 12 & term <= 480, round(term / 12) * 12, NA_real_),
    fixed   = ifelse(intro_rate_period == "NA", TRUE,
                ifelse(is.na(intro), NA,
                  !is.na(term) & intro >= term)),
    reset_m = ifelse(!is.na(intro) & !(!is.na(term) & intro >= term), intro, NA_real_))]
  if (anyNA(d$CERT) || anyNA(d$year) || anyNA(d$usd_k) || anyNA(d$kept)) {
    stop("hmda_groups: LAR rows without CERT, year, amount or purchaser_type")
  }
  g <- d[, .(n = .N, usd_k = sum(usd_k)),
         by = .(CERT, year, term_m, coupon, fixed, reset_m, kept)]
  data.table::setorder(g, CERT, year, -kept, term_m, coupon, reset_m, na.last = TRUE)
  g[, term_m := as.integer(term_m)][, reset_m := as.integer(reset_m)]
  as.data.frame(g)
}

# Per (CERT, year) summary of the groups: originated and kept dollars,
# kept_share, rate coverage (share of kept dollars with a coupon) and the
# dollar-weighted coupon of the kept loans. NA (not 0 or NaN) when the
# denominator is 0: a bank that kept nothing has no coverage.
hmda_group_summary <- function(g) {
  d <- data.table::as.data.table(g)
  ratio <- function(a, b) if (b > 0) a / b else NA_real_
  as.data.frame(d[, {
    k <- kept; r <- kept & !is.na(coupon)
    .(n = sum(n), usd_k = sum(usd_k), usd_kept_k = sum(usd_k[k]),
      kept_share    = ratio(sum(usd_k[k]), sum(usd_k)),
      rate_coverage = ratio(sum(usd_k[r]), sum(usd_k[k])),
      wac_kept      = ratio(sum(coupon[r] * usd_k[r]), sum(usd_k[r])))
  }, by = .(CERT, year)][order(CERT, year)])
}

# ---- Valuation (nightly) -------------------------------------------------------
# Each group is run forward as one loan made on 1 July of its HMDA year
# (the public file has no month), with a level monthly payment. Every
# month part of the balance prepays: at cpr_below a year while the coupon
# is at most refi_gap points above the going rate (only home sales), at
# cpr_above once it is more (borrowers refinance). Past months use the
# FRED monthly average, months after val_date today's rate. An ARM is
# fixed until its first reset, then repaid at par (it reprices). What is
# left at val_date is the balance; the payments after it, discounted at
# today's rate, are its value. Terms above long_m use MORTGAGE30US, the
# rest MORTGAGE15US.
#
# Only kept loans (purchaser_type 0) with a coupon, a term and a known
# fixed/ARM status are valued. The rest are counted (valued_share), never
# given a default (spec trap 1).
HB_PARAMS <- list(
  cpr_below = 0.06,       # a year: coupon below the going rate + refi_gap
  cpr_above = 0.20,       # a year: worth refinancing
  refi_gap  = 0.5,        # points
  long_m    = 180L,       # months: longer terms are priced off the 30-year rate
  shift     = 0.5,        # points: the parallel move for the effective duration
  method_version = "hb-1"
)

# "YYYYMMDD" month -> months since year 0 (July 2021 = 2021 * 12 + 6)
hb_month <- function(yyyymmdd) {
  (yyyymmdd %/% 10000L) * 12L + (yyyymmdd %/% 100L) %% 100L - 1L
}

# Today's rate (the last weekly reading of val_date's month) and the
# monthly history of the two mortgage series, from the rates_monthly mart
hb_market <- function(rates, val_date) {
  one <- function(s) {
    r <- rates[rates$series == s & !is.na(rates$avg), ]
    i <- which(r$month_end == val_date)
    if (length(i) != 1 || !isTRUE(r$complete[i])) {
      stop("rates_monthly has no complete ", s, " month for ", val_date)
    }
    list(now = r$last[i], idx = hb_month(r$month_end), avg = r$avg)
  }
  list(r30 = one("MORTGAGE30US"), r15 = one("MORTGAGE15US"), val_idx = hb_month(val_date))
}

# Per $1 of original balance of each loan type u (year, term_m, coupon,
# reset_m; reset_m NA for a fixed loan): balance left at val_date (bal),
# value of the later payments (pv) and the discount rate used (now, points).
# shift moves today's rate, for the discounting and the refinance trigger.
hb_cashflows <- function(u, mk, params = HB_PARAMS, shift = 0) {
  start <- u$year * 12L + 6L
  age   <- mk$val_idx - start                       # months since origination
  long  <- u$term_m > params$long_m
  now   <- ifelse(long, mk$r30$now, mk$r15$now) + shift
  c_m   <- u$coupon / 1200
  reset <- ifelse(is.na(u$reset_m), Inf, u$reset_m)
  smm   <- function(cpr) 1 - (1 - cpr)^(1 / 12)
  bal   <- rep(1, nrow(u)); pv <- numeric(nrow(u)); bal_now <- rep(NA_real_, nrow(u))
  for (m in seq_len(max(u$term_m))) {
    alive  <- m <= u$term_m & bal > 0
    idx    <- start + m
    r_hist <- ifelse(long, mk$r30$avg[match(idx, mk$r30$idx)], mk$r15$avg[match(idx, mk$r15$idx)])
    r_mkt  <- ifelse(m <= age, r_hist, now)
    cpr    <- ifelse(u$coupon > r_mkt + params$refi_gap, params$cpr_above, params$cpr_below)
    # level payment recomputed on what is left: prepayments shrink the
    # payment, they do not shorten the loan. A coupon rounded to 0% ($51M
    # of loans, 2018-2025) pays balance / months left, the formula's limit.
    left     <- pmax(u$term_m - m + 1, 1)
    interest <- bal * c_m
    sched    <- bal * ifelse(c_m > 0, c_m / (1 - (1 + c_m)^(-left)), 1 / left) - interest
    prepay   <- (bal - sched) * smm(cpr)
    cf       <- ifelse(alive, interest + sched + prepay, 0)
    newbal   <- ifelse(alive, bal - sched - prepay, 0)
    hit <- alive & m == reset                        # ARM reset: repaid at par
    cf[hit] <- cf[hit] + newbal[hit]; newbal[hit] <- 0
    bal_now[m == age] <- newbal[m == age]
    fut <- m > age
    pv[fut] <- pv[fut] + cf[fut] / (1 + now[fut] / 1200)^(m - age[fut])
    bal <- newbal
  }
  # No month m == age: the loan matured before val_date, so nothing is left
  # (a real 0, not a missing value)
  bal_now[is.na(bal_now)] <- 0
  data.frame(bal = bal_now, pv = pv, now = now)
}

# The groups (hmda.groups rows, any years) valued at val_date (YYYYMMDD, a
# quarter end), one row per `by` key (CERT, or CERT and year for vintages).
# Groups made after val_date are left out. Dollars are $ thousands, rates
# and losses decimals:
#   kept_k         kept dollars originated (all kept groups)
#   valued_share   share of kept_k with a coupon, term and fixed/ARM status
#   bal_k, pv_k    balance left at val_date and its value (valued loans)
#   wac            balance-weighted coupon of what is left (the book rate)
#   mkt_rate       balance-weighted rate it is discounted at
#   duration       effective duration in years (+/- shift points)
#   loss_pv        1 - pv_k / bal_k
#   loss_dur       duration x (mkt_rate - wac): the shortcut that checks it
#   hmda_year_max  newest HMDA year with any loans (kept or sold)
#   na_reason      why wac and the losses are NA
# The valuation is linear in the dollars, so each loan type is run once,
# for $1, and scaled.
hb_value <- function(groups, rates, val_date, params = HB_PARAMS, by = "CERT") {
  mk <- hb_market(rates, val_date)
  g <- groups[groups$year * 12L + 6L < mk$val_idx, ]
  ok <- g$kept & !is.na(g$coupon) & !is.na(g$term_m) & !is.na(g$fixed)
  type <- c("year", "term_m", "coupon", "reset_m")
  u <- unique(g[ok, type])
  if (!nrow(u)) stop("hb_value: no kept loans with a rate, term and fixed/ARM status")
  first <- min(u$year) * 12L + 7L
  for (s in list(mk$r30, mk$r15)) {
    if (!all(first:mk$val_idx %in% s$idx)) stop("rates_monthly has gaps before ", val_date)
  }
  cfs <- lapply(c(base = 0, up = params$shift, dn = -params$shift),
                function(s) hb_cashflows(u, mk, params, shift = s))
  m <- match(do.call(paste, g[type]), do.call(paste, u))    # NA for rows not valued
  f <- function(run, col) ifelse(ok, g$usd_k * cfs[[run]][[col]][m], 0)
  bal <- f("base", "bal")
  x <- cbind(kept_k = ifelse(g$kept, g$usd_k, 0), valued_k = ifelse(ok, g$usd_k, 0),
             bal_k = bal, pv_k = f("base", "pv"), pv_up = f("up", "pv"), pv_dn = f("dn", "pv"),
             cw = ifelse(ok, g$coupon * bal, 0), mw = ifelse(ok, cfs$base$now[m] * bal, 0))
  key <- do.call(paste, g[by])
  s <- rowsum(x, key, reorder = FALSE)
  out <- g[match(rownames(s), key), by, drop = FALSE]
  out$kept_k <- s[, "kept_k"]
  out$valued_share <- ifelse(s[, "kept_k"] > 0, s[, "valued_k"] / s[, "kept_k"], NA_real_)
  out$bal_k <- s[, "bal_k"]
  out$pv_k <- s[, "pv_k"]
  has <- s[, "bal_k"] > 0
  na <- function(v) ifelse(has, v, NA_real_)
  out$wac <- na(s[, "cw"] / s[, "bal_k"] / 100)
  out$mkt_rate <- na(s[, "mw"] / s[, "bal_k"] / 100)
  out$duration <- na((s[, "pv_dn"] - s[, "pv_up"]) / (s[, "pv_k"] * 2 * params$shift / 100))
  out$loss_pv <- na(1 - s[, "pv_k"] / s[, "bal_k"])
  out$loss_dur <- out$duration * (out$mkt_rate - out$wac)
  out$hmda_year_max <- as.integer(tapply(g$year, factor(key, rownames(s)), max))
  out$na_reason <- ifelse(has, NA_character_,
    ifelse(s[, "kept_k"] == 0, "kept no loans",
      ifelse(s[, "valued_k"] == 0, "no kept loans with a rate, term and fixed/ARM status",
             "no kept balance left")))
  out <- out[do.call(order, out[by]), ]
  rownames(out) <- NULL
  out
}
