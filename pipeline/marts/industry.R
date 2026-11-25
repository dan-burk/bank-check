# Marts: industry_quarterly, field_coverage.
# Built from every raw quarter on disk (not just this run), with the app's
# own industry_totals() so the numbers match the Industry tab exactly.
# raw_sums are plain sums for the aggregation cross-check in
# checks/industry.R: every summed field, so each mart column is checked
# against FDIC's own sums.

AGG_FIELDS <- setdiff(strsplit(STATEMENT_FIELDS, ",")[[1]], c("CERT", "RISDATE"))

# Returns list(ind, cov, raw_sums), one row per file (per field for cov)
build_industry <- function(files) {
  ind <- list(); cov <- list(); raw_sums <- list()
  for (f in files) {
    x <- as.data.frame(read_parquet(f))
    miss <- setdiff(AGG_FIELDS, names(x))
    if (length(miss)) stop(basename(f), " lacks summed fields: ", paste(miss, collapse = ","))
    ind[[f]] <- industry_totals(x)
    cov[[f]] <- field_coverage(x)
    raw_sums[[f]] <- data.frame(
      RISDATE = as.integer(x$RISDATE[1]), n = nrow(x),
      as.list(colSums(x[AGG_FIELDS], na.rm = TRUE)))
  }
  ind <- do.call(rbind, ind); cov <- do.call(rbind, cov)
  raw_sums <- do.call(rbind, raw_sums)
  rownames(ind) <- rownames(cov) <- rownames(raw_sums) <- NULL
  ind$RISDATE <- as.integer(ind$RISDATE)
  report_coverage(cov)
  list(ind = ind, cov = cov, raw_sums = raw_sums)
}

# Coverage report: every field and quarter below 100% of assets
report_coverage <- function(cov) {
  low <- cov[cov$asset_share < 1, ]
  if (nrow(low)) {
    cat("Field coverage below 100% of assets (* = below COVERAGE_MIN, mart NA):\n")
    for (k in unique(low$field)) {
      l <- low[low$field == k, ]
      cat(sprintf("  %-8s %s\n", k, paste0(l$RISDATE, ifelse(
        l$asset_share < COVERAGE_MIN, "*", ""), " ",
        formatC(l$asset_share, format = "f", digits = 4), collapse = ", ")))
    }
  } else {
    cat("Field coverage: 100% of assets for every field and quarter.\n")
  }
}
