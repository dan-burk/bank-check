# config.R -- the few choices the prototype depends on, in one place.

# Banks studied (all still open). Picked from FDIC data on 2026-11-25:
#   Third Federal  ~90% of assets in 1-4 family mortgages (heavy mortgage holder)
#   Capitol Federal ~60% (second heavy mortgage holder, different region)
#   Associated     $51B regional bank, mixed lending
#   Dacotah        $5B South Dakota community/ag bank (the repo's test-fixture bank)
BANKS <- data.frame(
  cert  = c(30012, 27981, 5296, 17437),
  short = c("thirdfed", "capfed", "associated", "dacotah"),
  label = c("Third Federal S&L (OH)", "Capitol Federal (KS)",
            "Associated Bank (WI)", "Dacotah Bank (SD)"),
  stringsAsFactors = FALSE
)

YEARS       <- 2018:2025  # HMDA has interest_rate from 2018; 2025 published mid-2026
BENCH_STATE <- "SD"       # small state used as an "all banks" benchmark (whole US is GBs)

# Valuation date = latest call report quarter end.
VAL_DATE <- as.Date("2026-09-30")

# Prepayment assumptions (CPR = share of the remaining balance paid off early per year).
CPR_BELOW <- 0.06  # loan rate below today's rate: only home sales pay it off
CPR_ABOVE <- 0.20  # loan rate > today's rate + 0.5 pt: borrowers refinance away
CPR_SENS  <- c(0.04, 0.06, 0.10)  # sensitivity runs for the below-market CPR
