# Step 1: download the raw inputs and cache them under cache/.
#   - FDIC Call Report fields for every bank, for the latest complete quarter,
#     the quarter before it, 2022Q4 and 2022Q3 (the last two are the backtest).
#   - FRED weekly 30-year mortgage rate and 5-year / 10-year Treasury yields.
# Run from the repo root:  Rscript research/unrealized-losses/01_fetch.R
# Re-running reuses the cache; delete cache/*.rds to force a fresh pull.

source("app/R/api.R")   # fdic_query(), latest_risdate(), prev_quarter_end()

OUT <- "research/unrealized-losses/cache"
dir.create(OUT, showWarnings = FALSE, recursive = TRUE)

FIELDS <- paste0(
  "CERT,NAMEFULL,STALP,RISDATE,ASSET,EQTOT,RBCT1J,EQCCOMPI,",
  "DEP,DEPDOM,DEPUNINS,",
  # securities: amortized cost and fair value, AFS and HTM
  "SCAA,SCAF,SCHA,SCHF,SC,ISCQ,",
  # loans and loan interest income (quarterly)
  "LNLSGR,LNRE,LNRERES,LNRENRES,LNREMULT,LNRECONS,LNREAG,LNAG,LNCI,LNCON,",
  "ILNLSQ,ILNDOMQ,ILNFORQ,",
  # RC-C memo 2.a: closed-end first-lien 1-4 family, remaining maturity / repricing
  "LNRS3LES,LNRS3T12,LNRS1T3,LNRS3T5,LNRS5T15,LNRSOV15,",
  # RC-C memo 2.b: all other loans and leases
  "LNOT3LES,LNOT3T12,LNOT1T3,LNOT3T5,LNOT5T15,LNOTOV15,",
  # RC-B memo 2: securities by remaining maturity / repricing (model check)
  "SCNM3LES,SCNM3T12,SCNM1T3,SCNM3T5,SCNM5T15,SCNMOV15,",
  "SCPT3LES,SCPT3T12,SCPT1T3,SCPT3T5,SCPT5T15,SCPTOV15,",
  "SCO3YLES,SCOOV3Y"
)

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
