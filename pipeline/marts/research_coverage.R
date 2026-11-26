# Mart: research_field_coverage. One row per raw quarter and RESEARCH_FIELDS
# field (sources/fdic.R): banks reporting it (a reported 0 counts) and their
# share of assets, weighted as the app's field_coverage()
# (app/R/statements.R): insured US branches of foreign banks file no call
# report, so they are left out of the weights.
#
#   in_raw  the column is in the stored raw file. FALSE for a quarter still
#           on the old, narrower schema (pulled before RESEARCH_FIELDS, so
#           asset_share is NA: not pulled is not "not reported"), and for a
#           field the API dropped. The API silently drops a field name it
#           does not know, so a misspelled or retired field shows up here.

research_coverage <- function(xs, fields = RESEARCH_FIELDS) {
  branch <- is.na(xs$EQTOT) & !is.na(xs$LIAB) & xs$LIAB == xs$ASSET
  a <- ifelse(branch, 0, as.numeric(xs$ASSET))
  in_raw <- fields %in% names(xs)
  has <- lapply(fields, function(k) if (k %in% names(xs)) !is.na(xs[[k]]) else rep(FALSE, nrow(xs)))
  share <- vapply(has, function(h) sum(a[h], na.rm = TRUE) / sum(a, na.rm = TRUE), 1)
  data.frame(RISDATE = as.integer(xs$RISDATE[1]), field = fields, in_raw = in_raw,
             n_banks = nrow(xs), n_branches = sum(branch),
             n_reported = ifelse(in_raw, vapply(has, sum, 1L), NA_integer_),
             asset_share = ifelse(in_raw, share, NA_real_), row.names = NULL)
}

# Every raw quarter on disk, reading only the columns it needs
build_research_coverage <- function(files, fields = RESEARCH_FIELDS) {
  cov <- do.call(rbind, lapply(files, function(f) {
    cols <- intersect(c("RISDATE", "ASSET", "LIAB", "EQTOT", fields),
                      read_parquet_schema(f)$name)
    research_coverage(as.data.frame(read_parquet(f, col_select = cols)), fields)
  }))
  rownames(cov) <- NULL
  cov
}

# The report: per field, its share of assets in the newest quarter, the
# first quarter at 95% or more, and how many quarters are under 50%.
report_research_coverage <- function(cov) {
  wide <- cov[cov$in_raw, ]
  n_old <- length(unique(cov$RISDATE)) - length(unique(wide$RISDATE))
  if (n_old) cat("research_field_coverage:", n_old, "quarters still on the old raw schema (backfill not run)\n")
  newest <- max(cov$RISDATE)
  cat("Research field coverage (share of assets): newest, first quarter >= 95%, quarters < 50%\n")
  for (k in unique(cov$field)) {
    w <- wide[wide$field == k, ]
    w <- w[order(w$RISDATE), ]
    first95 <- w$RISDATE[w$asset_share >= 0.95][1]
    cat(sprintf("  %-8s %6.1f%%  %-8s  %3d of %d\n", k,
                100 * w$asset_share[w$RISDATE == newest][1],
                if (is.na(first95)) "never" else first95,
                sum(w$asset_share < 0.5), nrow(w)))
  }
}
