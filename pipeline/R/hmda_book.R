# HMDA mortgage book: pure functions, data frames in and out, shared with
# research/hmda-mortgage-rates. From that PR's 02_analyze.R
# (mortgage_filter(), clean(), the grouping in value_book()). This is the
# yearly part: filter the loans, link lenders to banks, collapse the loans
# into groups. The nightly valuation of the groups (run_book(),
# value_book()) is spec PR 10.
#
# Needs data.table (pipeline-only, not an app dependency): the callers
# (sources/hmda.R, tests/run.R) attach it.
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
