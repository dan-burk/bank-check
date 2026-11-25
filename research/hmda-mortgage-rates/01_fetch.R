# 01_fetch.R -- download and cache every input for the HMDA mortgage-rate prototype.
#
# Run from the repo root:  Rscript research/hmda-mortgage-rates/01_fetch.R
# Everything lands in research/hmda-mortgage-rates/raw/ (gitignored). Files that
# already exist are not downloaded again, so re-running is cheap and polite.
#
# Sources (all free, no key):
#   FDIC BankFind API   institutions (CERT -> FED_RSSD) and financials (call report)
#   HMDA public panel   one CSV per year mapping LEI -> RSSD (files.ffiec.cfpb.gov)
#   HMDA Data Browser   loan-level CSV by lender LEI (or by state) and year
#   FRED                MORTGAGE30US, MORTGAGE15US weekly survey rates

suppressMessages({
  library(data.table)
  library(jsonlite)
})

DIR   <- "research/hmda-mortgage-rates"
RAW   <- file.path(DIR, "raw")
dir.create(RAW, showWarnings = FALSE, recursive = TRUE)
source(file.path(DIR, "config.R"))

# One polite downloader: skip if cached, wait 2 s between live requests,
# retry after 10/30/90 s, then stop.
fetch <- function(url, dest) {
  if (file.exists(dest) && file.size(dest) > 0) return(invisible(dest))
  for (wait in c(0, 10, 30, 90)) {
    if (wait > 0) { message("  retry in ", wait, " s"); Sys.sleep(wait) }
    Sys.sleep(2)
    ok <- tryCatch({
      utils::download.file(url, dest, quiet = TRUE, mode = "wb")
      file.size(dest) > 0
    }, error = function(e) FALSE, warning = function(w) FALSE)
    if (isTRUE(ok)) { message("  got ", basename(dest)); return(invisible(dest)) }
    if (file.exists(dest)) file.remove(dest)
  }
  stop("download failed: ", url)
}

# ---- 1. FDIC: CERT -> RSSD, name, size --------------------------------------
certs <- paste(BANKS$cert, collapse = "%20OR%20")
fetch(paste0("https://api.fdic.gov/banks/institutions?filters=CERT:(", certs, ")",
             "&fields=CERT,NAME,FED_RSSD,ASSET,STALP,ACTIVE&limit=50"),
      file.path(RAW, "fdic_institutions.json"))

# All active FDIC-insured institutions' RSSDs, to tell banks from non-bank
# lenders in the state benchmark.
fetch(paste0("https://api.fdic.gov/banks/institutions?filters=ACTIVE:1",
             "&fields=CERT,FED_RSSD&limit=10000"),
      file.path(RAW, "fdic_all_active_rssd.json"))

# Call report history for the cross-check (quarterly, 2017 onward).
CR_FIELDS <- "CERT,REPDTE,ASSET,LNLSGR,LNRERES,LNRERSF1,LNRELOC,ILNLSQ,EQTOT"
for (cert in BANKS$cert) {
  fetch(paste0("https://api.fdic.gov/banks/financials?filters=CERT:", cert,
               "%20AND%20REPDTE:[20170101%20TO%2099991231]",
               "&fields=", CR_FIELDS, "&limit=200&sort_by=REPDTE&sort_order=ASC"),
        file.path(RAW, sprintf("fdic_fin_%s.json", cert)))
}

# ---- 2. HMDA public panel: LEI <-> RSSD, one file per year ------------------
# (Snapshot panels for 2024+ were not at this path when written; an LEI does not
# change over time, so 2018-2023 are enough to map our banks.)
PANEL_YEARS <- 2018:2023
for (y in PANEL_YEARS) {
  z <- file.path(RAW, sprintf("panel%d.zip", y))
  fetch(sprintf("https://files.ffiec.cfpb.gov/static-data/snapshot/%d/%d_public_panel_csv.zip", y, y), z)
  utils::unzip(z, exdir = file.path(RAW, sprintf("panel%d", y)), overwrite = FALSE)
}

# ---- 3. HMDA loan-level CSVs ------------------------------------------------
# Only originated loans (actions_taken=1) to keep files small.
panel <- rbindlist(lapply(PANEL_YEARS, function(y) {
  f <- list.files(file.path(RAW, sprintf("panel%d", y)), pattern = "\\.csv$", full.names = TRUE)[1]
  fread(f, select = c("activity_year", "lei", "respondent_rssd"), colClasses = "character")
}))
inst <- fromJSON(file.path(RAW, "fdic_institutions.json"))$data$data
for (i in seq_len(nrow(BANKS))) {
  rssd <- inst$FED_RSSD[inst$CERT == BANKS$cert[i]]
  leis <- unique(panel$lei[panel$respondent_rssd == rssd])
  if (length(leis) != 1) stop("CERT ", BANKS$cert[i], ": expected 1 LEI for RSSD ", rssd,
                              ", found ", length(leis))
  message(BANKS$short[i], ": CERT ", BANKS$cert[i], " -> RSSD ", rssd, " -> LEI ", leis)
  for (y in YEARS) {
    fetch(sprintf("https://ffiec.cfpb.gov/v2/data-browser-api/view/csv?years=%d&leis=%s&actions_taken=1", y, leis),
          file.path(RAW, sprintf("hmda_%s_%d.csv", BANKS$short[i], y)))
  }
}

# State benchmark: every lender's first-lien originations in BENCH_STATE.
for (y in YEARS) {
  fetch(sprintf("https://ffiec.cfpb.gov/v2/data-browser-api/view/csv?years=%d&states=%s&actions_taken=1&lien_statuses=1",
                y, BENCH_STATE),
        file.path(RAW, sprintf("hmda_state%s_%d.csv", BENCH_STATE, y)))
}

# ---- 4. FRED mortgage rates --------------------------------------------------
for (id in c("MORTGAGE30US", "MORTGAGE15US")) {
  fetch(paste0("https://fred.stlouisfed.org/graph/fredgraph.csv?id=", id),
        file.path(RAW, paste0("fred_", id, ".csv")))
}
message("fetch done")
