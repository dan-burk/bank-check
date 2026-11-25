# Run-stress step 1: download the few extra Call Report fields the run
# simulator needs (cash, fed funds, intangibles, FHLB, ...), for the quarters
# we simulate. Everything else comes from research/backtest/cache/ (the
# estimator fields, already pulled by research/backtest/01_fetch.R).
# Output: research/run-stress/cache/extra_<risdate>.rds (gitignored).
# Run from the repo root:  Rscript research/run-stress/01_fetch.R

source("app/R/api.R")    # fdic_query(), flatten_body()

OUT <- "research/run-stress/cache"
dir.create(OUT, showWarnings = FALSE, recursive = TRUE)
FIELDS <- "CERT,CHBAL,FREPO,TRADE,INTAN,LNLSNET,OTHBFHLB,DEPINS,SCPLEDGE"

# Validation quarters + latest + the last quarter that was public (quarter
# end + 45 days) before each 2022+ failure, plus neighbours
QUARTERS <- c(20211231, 20221231, 20230331, 20230630, 20230930, 20231231,
              20240331, 20240630, 20240930, 20241231, 20250331, 20250930,
              20251231, 20260331, 20260630, 20260930)

pull <- function(risdate) {
  f <- file.path(OUT, paste0("extra_", risdate, ".rds"))
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

for (q in QUARTERS) pull(q)
message("done")
