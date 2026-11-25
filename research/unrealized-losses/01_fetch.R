# Step 1: download the raw inputs and cache them under cache/.
#   - FDIC Call Report fields for every bank, for the latest complete quarter,
#     the quarter before it, 2022Q4 and 2022Q3 (the last two are the backtest).
#   - FRED weekly 30-year mortgage rate and 5-year / 10-year Treasury yields.
# Run from the repo root:  Rscript research/unrealized-losses/01_fetch.R
# Re-running reuses the cache; delete cache/*.rds to force a fresh pull.

source("app/R/api.R")   # fdic_query(), latest_risdate(), prev_quarter_end()
source("research/unrealized-losses/estimator.R")   # UL_FIELDS

OUT <- "research/unrealized-losses/cache"
dir.create(OUT, showWarnings = FALSE, recursive = TRUE)

FIELDS <- UL_FIELDS

pull <- function(risdate) {
  f <- file.path(OUT, paste0("fdic_", risdate, ".rds"))
  if (file.exists(f)) return(invisible(readRDS(f)))
  Sys.sleep(2)  # API etiquette: one request at a time, 2 s apart
  d <- fetch_all_banks_quarter(risdate, fields = FIELDS)
  d$ID <- NULL
  saveRDS(d, f)
  message(risdate, ": ", nrow(d), " banks")
  invisible(d)
}

latest <- latest_risdate()
message("Latest complete quarter: ", latest)
for (q in c(latest, prev_quarter_end(latest), 20221231L, 20220930L)) pull(q)
writeLines(as.character(latest), file.path(OUT, "latest_risdate.txt"))

for (s in c("MORTGAGE30US", "DGS5", "DGS10")) {
  f <- file.path(OUT, paste0("fred_", s, ".csv"))
  if (!file.exists(f)) {
    utils::download.file(
      paste0("https://fred.stlouisfed.org/graph/fredgraph.csv?id=", s),
      f, quiet = TRUE)
  }
}
message("done")
