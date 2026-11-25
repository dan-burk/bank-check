# One-off probe (not part of the pipeline): the first quarter in which the
# estimator's inputs are filled in. Run: Rscript research/backtest/probe_coverage.R
# Result 2026-11-25: fair values (SCHA/SCHF/SCAA/SCAF) from 1994-ish; the
# maturity/repricing buckets (LNRS*, LNOT*) first appear 1997Q2.
source("app/R/api.R")
F <- c("LNRS5T15", "LNOT5T15", "SCHF", "ILNLSQ", "DEPUNINS", "RBC1AAJ")
for (rd in c(19961231L, 19970331L, 19970630L, 19970930L)) {
  Sys.sleep(2)
  b <- fdic_query(FDIC_FINANCIALS_ENDPOINT, list(
    filters = paste0("RISDATE:", rd),
    fields = paste(c("CERT", F), collapse = ","), limit = 2000, offset = 0))
  d <- flatten_body(b)
  print(c(rd = rd, total = b$meta$total, sapply(F, function(f) round(mean(!is.na(d[[f]])), 2))))
}
