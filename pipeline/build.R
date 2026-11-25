# Data pipeline: pull the last N quarters for every bank, store one parquet
# file per quarter, log any FDIC revisions against the copy already on disk,
# build the marts the app reads, and check them. Stops with an error (and
# writes no marts) if any check fails. Design: see pipeline/README.md.
#
# Run from the repo root:
#   Rscript pipeline/build.R          # last 10 quarters
#   Rscript pipeline/build.R 40       # last 40 quarters
#   Rscript pipeline/build.R 171      # backfill: 1984 Q1 to now
#   Rscript pipeline/build.R 19841231,19880630   # a sample, plus the
#                                     # newest quarter (local testing:
#                                     # gaps are reported, not failed)
#
# Output (gitignored), under pipeline/out/:
#   raw/risdate.YYYYMMDD.parquet   every bank, one quarter, APP_FIELDS + CITY
#   raw/manifest.csv               one row per quarter on hand (merged with
#                                  the stored manifest by risdate)
#   revisions.csv                  appended: every value FDIC changed since
#                                  the last pull (quarter, CERT, field, old, new)
#   marts/industry_quarterly.parquet  statement lines summed, one row per quarter
#   marts/latest_snapshot.parquet     newest quarter, one row per bank, plus
#                                     the active directory (NAME, active flag)
#   marts/field_coverage.parquet      per quarter and statement field: banks
#                                     reporting it and their share of assets
#
# The work is in pipeline/R/ (transport, raw store), pipeline/sources/
# (pulls), pipeline/marts/ (builders) and pipeline/checks/.

suppressPackageStartupMessages(library(nanoparquet))

ARG <- commandArgs(trailingOnly = TRUE)[1]
SAMPLE <- !is.na(ARG) && grepl(",", ARG)   # explicit quarter list
N_QUARTERS  <- if (SAMPLE) NA_integer_ else as.integer(ARG)
if (!SAMPLE && is.na(N_QUARTERS)) N_QUARTERS <- 10L

OUT   <- normalizePath(file.path("pipeline", "out"), mustWork = FALSE)
RAW   <- file.path(OUT, "raw")
MARTS <- file.path(OUT, "marts")
for (d in c(RAW, MARTS)) dir.create(d, recursive = TRUE, showWarnings = FALSE)

# The app's API client and statement definitions, unchanged, then the
# pipeline's own pieces (http.R must come after api.R: it wraps fdic_query)
source(file.path("app", "R", "api.R"))
source(file.path("app", "R", "statements.R"))
for (f in c("R/http.R", "R/store.R", "sources/fdic.R",
            "marts/industry.R", "marts/snapshot.R",
            "checks/check.R", "checks/snapshot.R", "checks/industry.R")) {
  source(file.path("pipeline", f))
}

# ---- Extract, change check, raw --------------------------------------------
t0 <- Sys.time()
newest <- latest_risdate()
if (is.na(newest)) stop("FDIC API returned no quarters")
quarters <- fdic_quarters(newest, N_QUARTERS,
  sample = if (SAMPLE) as.integer(strsplit(ARG, ",")[[1]]))
cat("Pulling", length(quarters), "quarters:", min(quarters), "to", newest, "\n")

seen <- format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
pulled <- pull_fdic(quarters, seen)
manifest <- save_manifest(pulled$manifest)
append_revisions(pulled$revisions)

# ---- Marts, then checks: nothing is written unless all pass -----------------
files <- raw_files()
industry <- build_industry(files)
snapshot <- build_snapshot(newest)
snap <- snapshot$snap
check_snapshot(snap)
check_industry(industry, files, newest, manifest,
               n_filed = sum(!is.na(snap$RISDATE)), sample = SAMPLE)

write_parquet(industry$ind, file.path(MARTS, "industry_quarterly.parquet"))
write_parquet(snap,         file.path(MARTS, "latest_snapshot.parquet"), compression = "zstd")
write_parquet(industry$cov, file.path(MARTS, "field_coverage.parquet"))

cat(sprintf("Done: %d requests, %.0f s. Raw %.1f MB across %d quarters.\n",
            .n_requests, as.numeric(difftime(Sys.time(), t0, units = "secs")),
            sum(file.size(files)) / 1048576, length(files)))
cat(sprintf("Marts: industry_quarterly %d rows (%.0f KB); latest_snapshot %d banks, %d active, %d not yet filed (%.0f KB).\n",
            nrow(industry$ind), file.size(file.path(MARTS, "industry_quarterly.parquet")) / 1024,
            nrow(snap), sum(snap$active), snapshot$n_unfiled,
            file.size(file.path(MARTS, "latest_snapshot.parquet")) / 1024))
