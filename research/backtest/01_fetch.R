# Backtest step 1: download everything into research/backtest/cache/
# (gitignored). Re-running reuses the cache; delete a file to re-pull it.
# Run from the repo root:  Rscript research/backtest/01_fetch.R
#
#   - FDIC Call Report fields for every bank, every quarter 1997Q1..latest
#     (~119 quarters, ~25 min on a cold cache). Same fields as the
#     estimator, plus RBC1AAJ (Tier 1 leverage ratio) and RSSDID (Fed ID,
#     for the BTFP match).
#   - FDIC failures list (api.fdic.gov/banks/failures), 1997 onward.
#   - FRED 30-year mortgage rate and 10-year Treasury (as the estimator).
#   - Fed BTFP borrower-level disclosure (XLSX, published 2025-03).

source("app/R/api.R")                              # fdic_query(), latest_risdate()
source("research/unrealized-losses/estimator.R")   # UL_FIELDS

OUT <- "research/backtest/cache"
dir.create(OUT, showWarnings = FALSE, recursive = TRUE)
FIELDS <- paste0(UL_FIELDS, ",RBC1AAJ,RSSDID")
# The maturity/repricing buckets (LNRS*, LNOT*) first appear in 1997Q2
# (probe_coverage.R); 1997Q1 is only there as 1997Q2's "previous quarter".
FIRST_Q <- 19970331L

# One quarter, every bank, paged past the API's 10k-row cap (the late 1990s
# have up to ~11,500 filers). Columns a page lacks are filled with NA.
pull <- function(risdate) {
  f <- file.path(OUT, paste0("fdic_", risdate, ".rds"))
  if (file.exists(f)) return(invisible(NULL))
  cols <- strsplit(FIELDS, ",")[[1]]
  pages <- list(); offset <- 0L
  repeat {
    Sys.sleep(2)  # API etiquette: one request at a time, 2 s apart
    b <- fdic_query(FDIC_FINANCIALS_ENDPOINT, list(
      filters = paste0("RISDATE:", risdate), fields = FIELDS,
      sort_by = "CERT", sort_order = "ASC", limit = 10000, offset = offset))
    p <- flatten_body(b)
    if (is.null(p) || nrow(p) == 0) break
    for (v in setdiff(cols, names(p))) p[[v]] <- NA
    pages[[length(pages) + 1]] <- p[cols]
    offset <- offset + nrow(p)
    if (offset >= b$meta$total) break
  }
  d <- do.call(rbind, pages)
  stopifnot(nrow(d) == b$meta$total, !anyDuplicated(d$CERT))
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
f <- file.path(OUT, "failures_1997.rds")
if (!file.exists(f)) {
  Sys.sleep(2)
  b <- fdic_query("https://api.fdic.gov/banks/failures", list(
    filters = "FAILYR:[1997 TO 2030]",
    fields = "CERT,NAME,CITYST,FAILDATE,RESTYPE,RESTYPE1,QBFASSET",
    limit = 2000, sort_by = "FAILDATE", sort_order = "ASC"))
  stopifnot(b$meta$total < 2000)
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
