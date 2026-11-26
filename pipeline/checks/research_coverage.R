# Checks on research_field_coverage. Not a core mart: a failure holds back
# only this mart (build.R builds it with build_optional_mart()).

# The maturity / repricing buckets the hidden-loss estimator values
BUCKET_FIELDS <- grep("^(LNRS|LNOT|SCNM|SCPT|SCO)", RESEARCH_FIELDS, value = TRUE)
# From here on every filer reports them (before 2012, OTS thrift filers are
# a known gap: reported by report_research_coverage(), not failed)
BUCKET_FULL_FROM <- 20120331L
BUCKET_MIN       <- 0.95

check_research_coverage <- function(cov, newest, fields = RESEARCH_FIELDS) {
  check(!anyDuplicated(cov[c("RISDATE", "field")]), "duplicate quarter-fields in research_field_coverage")
  check(nrow(cov) == length(fields) * length(unique(cov$RISDATE)),
        "research_field_coverage is not one row per research field per quarter")
  # The API drops a field name it does not know without an error
  nw <- cov[cov$RISDATE == newest, ]
  miss <- nw$field[!nw$in_raw | !(nw$asset_share > 0)]
  check(nrow(nw) == length(fields) && length(miss) == 0,
        paste("research fields missing or never reported in", newest, ":",
              paste(miss, collapse = ",")))
  b <- cov[cov$in_raw & cov$field %in% BUCKET_FIELDS & cov$RISDATE >= BUCKET_FULL_FROM, ]
  low <- b[b$asset_share < BUCKET_MIN, ]
  check(nrow(low) == 0, paste0("bucket fields below ", 100 * BUCKET_MIN,
                               "% of assets since 2012: ",
                               paste(utils::head(paste(low$field, low$RISDATE), 5), collapse = ", ")))
}
