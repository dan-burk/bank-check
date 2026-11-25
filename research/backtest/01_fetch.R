# Backtest step 1: download everything into research/backtest/cache/
# (gitignored). Re-running reuses the cache; delete a file to re-pull it.
# Run from the repo root:  Rscript research/backtest/01_fetch.R
#
#   - FDIC Call Report fields for every bank, every quarter 2021Q3..latest
#     (2021Q3 is only there as the "previous quarter" for 2021Q4's averages).
#     Same fields as the estimator, plus RBC1AAJ (Tier 1 leverage ratio) and
#     RSSDID (Fed ID, for the BTFP match).
#   - FDIC failures list (api.fdic.gov/banks/failures), 2021 onward.
#   - FRED 30-year mortgage rate and 10-year Treasury (as the estimator).
#   - Fed BTFP borrower-level disclosure (XLSX, published 2025-03).

source("app/R/api.R")                              # fdic_query(), latest_risdate()
source("research/unrealized-losses/estimator.R")   # UL_FIELDS

OUT <- "research/backtest/cache"
dir.create(OUT, showWarnings = FALSE, recursive = TRUE)
FIELDS <- paste0(UL_FIELDS, ",RBC1AAJ,RSSDID")
FIRST_Q <- 20211231L

pull <- function(risdate) {
  f <- file.path(OUT, paste0("fdic_", risdate, ".rds"))
  if (file.exists(f)) return(invisible(NULL))
  Sys.sleep(2)  # API etiquette: one request at a time, 2 s apart
  d <- fetch_all_banks_quarter(risdate, fields = FIELDS)
  d$ID <- NULL
  saveRDS(d, f)
  message(risdate, ": ", nrow(d), " banks")
}

latest <- latest_risdate()
stopifnot(!is.na(latest))
qs <- latest
while (qs[1] > prev_quarter_end(FIRST_Q)) qs <- c(prev_quarter_end(qs[1]), qs)
for (q in qs) pull(q)
writeLines(as.character(qs), file.path(OUT, "quarters.txt"))
message("Quarters: ", qs[1], " .. ", latest, " (", length(qs), ")")

# Failures (RESTYPE = FAILURE or ASSISTANCE; both kept)
f <- file.path(OUT, "failures.rds")
if (!file.exists(f)) {
  Sys.sleep(2)
  b <- fdic_query("https://api.fdic.gov/banks/failures", list(
    filters = "FAILYR:[2021 TO 2030]",
    fields = "CERT,NAME,CITYST,FAILDATE,RESTYPE,RESTYPE1,QBFASSET",
    limit = 1000, sort_by = "FAILDATE", sort_order = "ASC"))
  saveRDS(flatten_body(b), f)
}

for (s in c("MORTGAGE30US", "DGS10")) {
  f <- file.path(OUT, paste0("fred_", s, ".csv"))
  if (!file.exists(f)) utils::download.file(
    paste0("https://fred.stlouisfed.org/graph/fredgraph.csv?id=", s), f, quiet = TRUE)
}

f <- file.path(OUT, "btfp.xlsx")
if (!file.exists(f)) utils::download.file(
  paste0("https://www.federalreserve.gov/publications/files/",
         "section-11s-btfp-transaction-specific-disclosures-03-12-25.xlsx"),
  f, quiet = TRUE, mode = "wb")
message("done")
