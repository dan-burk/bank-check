# 02_analyze.R -- from cached HMDA loans to an estimated mortgage-book coupon and
# an estimated mark-to-market loss, per bank.
#
# Run from the repo root (after 01_fetch.R):
#   Rscript research/hmda-mortgage-rates/02_analyze.R
# Writes small CSVs to research/hmda-mortgage-rates/results/.

suppressMessages({
  library(data.table)
  library(jsonlite)
})

DIR <- "research/hmda-mortgage-rates"
RAW <- file.path(DIR, "raw")
OUT <- file.path(DIR, "results")
dir.create(OUT, showWarnings = FALSE)
source(file.path(DIR, "config.R"))

# ---- Market rates (FRED, weekly -> monthly average) --------------------------
read_fred <- function(id) {
  d <- fread(file.path(RAW, paste0("fred_", id, ".csv")))
  setnames(d, c("date", "rate"))
  d <- d[!is.na(suppressWarnings(as.numeric(rate)))]
  d[, `:=`(date = as.Date(date), rate = as.numeric(rate))]
  d
}
f30 <- read_fred("MORTGAGE30US")
f15 <- read_fred("MORTGAGE15US")
# "Today" = the last weekly reading on or before the valuation date.
mkt_on <- function(d, at) d[date <= at][.N, rate]
MKT30 <- mkt_on(f30, VAL_DATE)
MKT15 <- mkt_on(f15, VAL_DATE)
message(sprintf("Market rates at %s: 30y %.2f%%, 15y %.2f%%", VAL_DATE, MKT30, MKT15))

# Monthly series, used to decide when borrowers would have refinanced.
monthly <- function(d) d[, .(rate = mean(rate)), by = .(ym = format(date, "%Y-%m"))]
m30 <- monthly(f30); m15 <- monthly(f15)

# ---- HMDA loans ----------------------------------------------------------------
HMDA_COLS <- c("activity_year", "lei", "action_taken", "purchaser_type", "loan_type",
               "loan_purpose", "lien_status", "reverse_mortgage", "open-end_line_of_credit",
               "business_or_commercial_purpose", "loan_amount", "interest_rate",
               "loan_term", "intro_rate_period", "total_units")

read_hmda <- function(path) {
  d <- fread(path, select = HMDA_COLS, colClasses = "character", showProgress = FALSE)
  setnames(d, gsub("-", "_", names(d)))
  num <- function(x) suppressWarnings(as.numeric(x))  # "NA", "Exempt" -> NA
  d[, `:=`(year = as.integer(activity_year), amount = num(loan_amount) / 1000,  # $ thousands
           rate = num(interest_rate), term = num(loan_term), intro = num(intro_rate_period))]
  d
}

# Keep what a bank books as a "1-4 family closed-end first-lien mortgage".
mortgage_filter <- function(d) {
  d[action_taken == "1" & lien_status == "1" & open_end_line_of_credit != "1" &
      reverse_mortgage != "1" & business_or_commercial_purpose != "1" &
      total_units %in% c("1", "2", "3", "4") & !is.na(amount)]
}

clean <- function(d) {
  d <- mortgage_filter(d)
  d[, kept := purchaser_type == "0"]       # not sold in the year it was made
  d[!(rate > 0 & rate < 20), rate := NA_real_]
  d[is.na(term) | term < 12 | term > 480, term := 360]
  d[, fixed := is.na(intro) | intro >= term]
  d[fixed == TRUE, intro := NA_real_]
  d[]
}

vintage_table <- function(d, who) {
  d[, .(n_orig        = .N,
        usd_orig_k    = sum(amount),
        n_kept        = sum(kept),
        usd_kept_k    = sum(amount[kept]),
        kept_share    = sum(amount[kept]) / sum(amount),
        rate_kept     = weighted.mean(rate[kept], amount[kept], na.rm = TRUE),
        rate_sold     = weighted.mean(rate[!kept], amount[!kept], na.rm = TRUE),
        rate_coverage = sum(amount[kept & !is.na(rate)]) / sum(amount[kept]),
        fixed_share   = sum(amount[kept & fixed]) / sum(amount[kept]),
        term30_share  = sum(amount[kept & term > 180]) / sum(amount[kept])),
    by = year][order(year)][, bank := who][]
}

# ---- Cash-flow model -----------------------------------------------------------
# Each group = loans with the same (vintage, term, coupon, ARM reset month).
# We assume every loan was made on 1 July of its HMDA year, pays a level monthly
# payment, and is prepaid at CPR_BELOW a year when its coupon is under the going
# rate (+0.5 pt) and at CPR_ABOVE when it is worth refinancing. Past months use the
# actual FRED rate; future months assume today's rate stays put.
# An ARM is modelled as fixed until its first reset, then repaid at par (it reprices).
month_idx <- function(ym) {  # "2021-03" -> integer months since year 0
  as.integer(substr(ym, 1, 4)) * 12L + as.integer(substr(ym, 6, 7)) - 1L
}
m30[, idx := month_idx(ym)]; m15[, idx := month_idx(ym)]

run_book <- function(g, cpr_below = CPR_BELOW, cpr_above = CPR_ABOVE, shift = 0) {
  n       <- nrow(g)
  start   <- g$year * 12L + 6L                            # July of the vintage year
  age     <- month_idx(format(VAL_DATE, "%Y-%m")) - start # months since origination
  long    <- g$term > 180
  mkt_now <- ifelse(long, MKT30, MKT15) + shift
  c_m     <- g$coupon / 1200
  pay_r   <- c_m / (1 - (1 + c_m)^(-g$term))              # payment per $ of original balance
  bal     <- g$amount
  pv      <- numeric(n); bal_now <- rep(NA_real_, n)
  reset   <- ifelse(is.na(g$intro), Inf, g$intro)
  smm     <- function(cpr) 1 - (1 - cpr)^(1 / 12)
  for (m in seq_len(max(g$term))) {
    alive  <- m <= g$term & bal > 0
    # going market rate in month m (history from FRED, flat at today's after that)
    idx    <- start + m
    r_hist <- ifelse(long, m30$rate[match(idx, m30$idx)], m15$rate[match(idx, m15$idx)])
    r_mkt  <- ifelse(m <= age & !is.na(r_hist), r_hist, mkt_now)
    cpr   <- ifelse(g$coupon > r_mkt + 0.5, cpr_above, cpr_below)
    interest <- bal * c_m
    # level payment re-computed on what is left (prepayments shrink the payment,
    # they do not shorten the loan)
    left     <- pmax(g$term - m + 1, 1)
    pmt      <- bal * c_m / (1 - (1 + c_m)^(-left))
    sched    <- pmt - interest
    prepay   <- (bal - sched) * smm(cpr)
    cf       <- ifelse(alive, interest + sched + prepay, 0)
    newbal   <- ifelse(alive, bal - sched - prepay, 0)
    # ARM first reset: remaining balance reprices, treat as repaid at par
    hit <- alive & m == reset
    cf[hit] <- cf[hit] + newbal[hit]; newbal[hit] <- 0
    # record balance at valuation date, discount cash flows after it
    at_val <- m == age
    bal_now[at_val] <- newbal[at_val]
    fut <- m > age
    pv[fut] <- pv[fut] + cf[fut] / (1 + mkt_now[fut] / 1200)^(m - age[fut])
    bal <- newbal
  }
  bal_now[is.na(bal_now)] <- 0
  data.table(g, bal_now = bal_now, pv = pv, mkt_now = mkt_now)
}

summarise_book <- function(b) {
  b[, .(bal_now_k = sum(bal_now), pv_k = sum(pv),
        wac       = sum(coupon * bal_now) / sum(bal_now),
        mkt       = sum(mkt_now * bal_now) / sum(bal_now))]
}

# Value one bank's (or the benchmark's) retained loans.
value_book <- function(d) {
  g <- d[kept == TRUE & !is.na(rate),
         .(amount = sum(amount)),
         by = .(year, term = round(term / 12) * 12, coupon = round(rate * 8) / 8, intro)]
  base <- run_book(g)
  up   <- run_book(g, shift = +0.5)
  dn   <- run_book(g, shift = -0.5)
  s    <- summarise_book(base)
  # effective duration: % value change per 1 pt rate move (bumping the discount
  # rate and the refinance trigger together)
  s[, eff_duration := (sum(dn$pv) - sum(up$pv)) / (sum(base$pv) * 0.01)]  # years
  s[, `:=`(loss_pct_pv  = 1 - pv_k / bal_now_k,              # direct present value
           loss_pct_dur = eff_duration * (mkt - wac) / 100)]  # duration shortcut
  sens <- sapply(CPR_SENS, function(cpr) {
    r <- run_book(g, cpr_below = cpr); 1 - sum(r$pv) / sum(r$bal_now)
  })
  names(sens) <- sprintf("loss_pct_cpr%02d", round(CPR_SENS * 100))
  byv <- base[, .(bal_now_k = sum(bal_now),
                  wac_now = sum(coupon * bal_now) / sum(bal_now),
                  loss_pct_pv = 1 - sum(pv) / sum(bal_now)), by = year]
  list(summary = cbind(s, as.data.table(as.list(sens))), by_vintage = byv)
}

# ---- Call report cross-check -------------------------------------------------
call_report <- function(cert) {
  f <- as.data.table(fromJSON(file.path(RAW, sprintf("fdic_fin_%s.json", cert)))$data$data)
  f <- f[order(REPDTE)]
  f[, avg_loans := (LNLSGR + shift(LNLSGR)) / 2]
  f[, loan_yield := 100 * ILNLSQ * 4 / avg_loans]   # annualised, ALL loans
  f[REPDTE == format(VAL_DATE, "%Y%m%d")]
}

# ---- Run ------------------------------------------------------------------------
vint <- list(); books <- list()
for (i in seq_len(nrow(BANKS))) {
  b  <- BANKS[i, ]
  d  <- rbindlist(lapply(YEARS, function(y)
          read_hmda(file.path(RAW, sprintf("hmda_%s_%d.csv", b$short, y)))))
  d  <- clean(d)
  vt <- vintage_table(d, b$label)
  vb <- value_book(d)
  cr <- call_report(b$cert)
  if (nrow(cr) != 1) stop("no call report for CERT ", b$cert, " at ", VAL_DATE)
  s  <- vb$summary
  s[, `:=`(bank = b$label, cert = b$cert,
           hmda_kept_2018_2025_k = sum(vt$usd_kept_k),
           # closed-end 1-4 family = all 1-4 family minus home-equity lines.
           # (LNRERSF1, "first liens-adjust", is NOT this: for Capitol Federal it is
           # $0.9B of a $5.75B book, so we do not use it.)
           cr_closed_1to4_k      = cr$LNRERES - cr$LNRELOC,
           cr_heloc_k            = cr$LNRELOC,
           cr_total_loans_k      = cr$LNLSGR,
           cr_equity_k           = cr$EQTOT,
           cr_loan_yield         = cr$loan_yield)]
  vint[[i]]  <- merge(vt, vb$by_vintage, by = "year", all.x = TRUE)
  books[[i]] <- s
}

# Benchmark: loans made by any FDIC-insured bank on properties in one state.
panel_files <- list.files(RAW, pattern = "public_panel.*\\.csv$", recursive = TRUE, full.names = TRUE)
panel <- unique(rbindlist(lapply(panel_files, fread, select = c("lei", "respondent_rssd"),
                                 colClasses = "character")))
fdic_rssd <- as.character(fromJSON(file.path(RAW, "fdic_all_active_rssd.json"))$data$data$FED_RSSD)
bank_leis <- unique(panel[respondent_rssd %in% fdic_rssd, lei])
sd <- rbindlist(lapply(YEARS, function(y)
        read_hmda(file.path(RAW, sprintf("hmda_state%s_%d.csv", BENCH_STATE, y)))))
sd_all_n <- nrow(mortgage_filter(sd))
sd <- clean(sd[lei %in% bank_leis])
message(sprintf("%s benchmark: %d of %d first-lien originations were made by FDIC-insured banks",
                BENCH_STATE, nrow(sd), sd_all_n))
lab <- sprintf("All FDIC banks, %s properties", BENCH_STATE)
vt  <- vintage_table(sd, lab)
vb  <- value_book(sd)
vint[[length(vint) + 1]]   <- merge(vt, vb$by_vintage, by = "year", all.x = TRUE)
books[[length(books) + 1]] <- vb$summary[, bank := lab]

vint  <- rbindlist(vint, fill = TRUE)
books <- rbindlist(books, fill = TRUE)
books[, `:=`(gap_pts = mkt - wac,
             hmda_share_of_cr_book = bal_now_k / cr_closed_1to4_k,
             # apply the loss rate to the bank's whole first-lien book (call report)
             est_loss_k = loss_pct_pv * cr_closed_1to4_k)]
books[, est_loss_pct_equity := est_loss_k / cr_equity_k]
setcolorder(books, c("bank", "cert"))
setcolorder(vint, "bank")

rnd <- function(dt) dt[, lapply(.SD, function(x) if (is.numeric(x)) round(x, 4) else x)]
fwrite(rnd(vint),  file.path(OUT, "vintages.csv"))
fwrite(rnd(books), file.path(OUT, "book_summary.csv"))
fwrite(data.table(series = c("MORTGAGE30US", "MORTGAGE15US"), as_of = VAL_DATE,
                  rate = c(MKT30, MKT15)), file.path(OUT, "market_rates.csv"))

options(width = 200)
print(vint[, .(bank, year, n_kept, kept_m = round(usd_kept_k / 1e3), kept_sh = round(kept_share, 2),
               rate_kept = round(rate_kept, 2), rate_sold = round(rate_sold, 2),
               cov = round(rate_coverage, 2), fixed = round(fixed_share, 2), t30 = round(term30_share, 2),
               bal_now_m = round(bal_now_k / 1e3), loss = round(100 * loss_pct_pv, 1))])
print(books[, .(bank, wac = round(wac, 2), mkt = round(mkt, 2), dur = round(eff_duration, 1),
                loss_pv = round(100 * loss_pct_pv, 1), loss_dur = round(100 * loss_pct_dur, 1),
                s4 = round(100 * loss_pct_cpr04, 1), s10 = round(100 * loss_pct_cpr10, 1),
                bal_m = round(bal_now_k / 1e3), cr_closed_m = round(cr_closed_1to4_k / 1e3),
                cov = round(hmda_share_of_cr_book, 2), cr_yld = round(cr_loan_yield, 2),
                loss_m = round(est_loss_k / 1e3), pct_eq = round(100 * est_loss_pct_equity))])
