# Data pipeline: pull the last N quarters for every bank, store one parquet
# file per quarter, log any FDIC revisions against the copy already on disk,
# pull the other sources (FRED, failures), build the marts and check them. An FDIC or
# core-mart failure stops the run with an error and writes no marts. A
# non-critical source or mart failure holds back only its own marts and
# ends the run with status 2. Design: see pipeline/README.md.
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
#   raw/risdate.YYYYMMDD.parquet   every bank, one quarter, RAW_FIELDS
#                                  (APP_FIELDS + CITY + RESEARCH_FIELDS)
#   raw/manifest.csv               one row per quarter on hand (merged with
#                                  the stored manifest by risdate)
#   revisions.csv                  appended: every value FDIC changed since
#                                  the last pull (quarter, CERT, field, old, new),
#                                  one "<schema>" row per quarter whose columns changed
#   marts/industry_quarterly.parquet  statement lines summed, one row per quarter
#   marts/latest_snapshot.parquet     newest quarter, one row per bank, plus
#                                     the active directory (NAME, active flag)
#   marts/field_coverage.parquet      per quarter and statement field: banks
#                                     reporting it and their share of assets
#   raw/fred.*.csv, marts/rates_monthly.parquet   FRED rates (sources/fred.R)
#   raw/failures.*, marts/fail_panel.parquet, marts/failures_meta.parquet
#                                     failures list and the app's failures
#                                     tab (sources/failures.R, marts/fail_panel.R)
#   marts/research_field_coverage.parquet, marts/bank_ids.parquet
#                                     research inputs, not read by the app
#   marts/hidden_loss.parquet, marts/hidden_loss_history.parquet
#                                     hidden-loss estimate per bank and quarter
#                                     (R/hidden_loss.R), not read by the app yet
#   marts/run_stress.parquet          deposit-run breaking point per bank, newest
#                                     quarter (R/run_stress.R), not read by the app yet
#
# The work is in pipeline/R/ (transport, raw store, source registry), pipeline/sources/
# (pulls), pipeline/marts/ (builders) and pipeline/checks/.

suppressPackageStartupMessages(library(nanoparquet))
if (packageVersion("nanoparquet") < "0.5.2")
  stop("nanoparquet >= 0.5.2 required: 0.5.1 reads NAs as garbage under col_select (#170)")

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
for (f in c("R/http.R", "R/store.R", "sources/fdic.R", "sources/fred.R",
            "sources/failures.R", "R/sources.R", "R/hidden_loss.R", "R/run_stress.R",
            "marts/industry.R", "marts/snapshot.R", "marts/rates.R",
            "marts/fail_panel.R", "marts/research_coverage.R", "marts/bank_ids.R",
            "marts/hidden_loss.R", "marts/run_stress.R",
            "checks/check.R", "checks/snapshot.R", "checks/industry.R",
            "checks/rates.R", "checks/fail_panel.R", "checks/research_coverage.R",
            "checks/bank_ids.R", "checks/hidden_loss.R", "checks/run_stress.R")) {
  source(file.path("pipeline", f))
}

# ---- Extract, change check, raw (every source in R/sources.R) --------------
t0 <- Sys.time()
newest <- latest_risdate()
if (is.na(newest)) stop("FDIC API returned no quarters")
quarters <- fdic_quarters(newest, N_QUARTERS,
  sample = if (SAMPLE) as.integer(strsplit(ARG, ",")[[1]]))
cat("Pulling", length(quarters), "quarters:", min(quarters), "to", newest, "\n")

seen <- format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
src <- run_sources(SOURCES, list(quarters = quarters, seen = seen,
                                 today = Sys.Date()))
manifest <- src$fdic$value

# ---- Marts, then checks: nothing is written unless all pass -----------------
files <- raw_files()
industry <- build_industry(files)

# Auto-heal: FDIC sometimes restates quarters older than the window.
# Re-pull those once (logging the revisions) and rebuild; the checks below
# still fail the run if any quarter disagrees after that.
stale <- stale_quarters(industry$raw_sums, quarters, newest)
if (length(stale)) {
  cat("Re-pulling", length(stale), "restated quarters:", stale, "\n")
  healed <- pull_fdic(stale, seen)
  manifest <- save_manifest(healed$manifest)
  append_revisions(healed$revisions)
  industry <- build_industry(files)
}

snapshot <- build_snapshot(newest)
snap <- snapshot$snap
check_snapshot(snap)
check_industry(industry, files, newest, manifest,
               n_filed = sum(!is.na(snap$RISDATE)), sample = SAMPLE)

write_parquet(industry$ind, file.path(MARTS, "industry_quarterly.parquet"))
write_parquet(snap,         file.path(MARTS, "latest_snapshot.parquet"), compression = "zstd")
write_parquet(industry$cov, file.path(MARTS, "field_coverage.parquet"))

# ---- Non-core marts: each fails or skips alone (R/sources.R) ---------------
marts_ok <- c(
  rates_monthly = build_optional_mart("rates_monthly", "fred", src, function(path) {
    rates <- build_rates_monthly(lapply(stats::setNames(nm = FRED_SERIES$series), fred_read))
    check_rates_monthly(rates, min(industry$ind$RISDATE), newest)
    write_parquet(rates, path)
    cat(sprintf("Mart rates_monthly: %d rows, %d series.\n", nrow(rates),
                length(unique(rates$series))))
  }),
  fail_panel = build_optional_mart("fail_panel", c("fdic", "failures"), src, also = "failures_meta",
    function(path) {
      fails <- panel_failures(failures_read())
      fp <- build_fail_panel(fails, read_fail_history(files, fails$CERT))
      check_fail_panel(fp, fails, raw_rds(files), newest)
      # gzip: 3.0 MB, the size of the old rds (zstd is 4.4 MB on this table)
      write_parquet(fp$panel, path[["fail_panel"]], compression = "gzip")
      write_parquet(fp$meta,  path[["failures_meta"]])
      cat(sprintf("Mart fail_panel: %d rows; failures_meta: %d failures, %d with filings.\n",
                  nrow(fp$panel), nrow(fp$meta), sum(fp$meta$n_filings > 0)))
    }),
  # Not read by the app (NO_DEPLOY in pipeline.yml)
  research_field_coverage = build_optional_mart("research_field_coverage", "fdic", src,
    function(path) {
      rcov <- build_research_coverage(files)
      report_research_coverage(rcov)
      check_research_coverage(rcov, newest)
      write_parquet(rcov, path)
    }),
  bank_ids = build_optional_mart("bank_ids", "fdic", src, function(path) {
    ids <- build_bank_ids(read_id_history(files), snap$CERT[snap$active])
    check_bank_ids(ids, newest, n_filed = sum(!is.na(snap$RISDATE)))
    write_parquet(ids, path)
  }),
  # Reads tonight's rates_monthly (built above, as c() runs in order): skipped
  # when FRED is unusable, failed when rates_monthly failed
  hidden_loss = build_optional_mart("hidden_loss", c("fdic", "fred"), src,
    also = "hidden_loss_history", function(path) {
      rates_path <- file.path(MARTS, "rates_monthly.parquet")
      if (!file.exists(rates_path)) stop("rates_monthly was not built this run")
      hl <- build_hidden_loss_history(files, as.data.frame(read_parquet(rates_path)))
      report_hidden_loss(hl$history)
      check_hidden_loss(hl$history, hl$audit, newest)
      # gzip: 2.1 MB and 46 MB (zstd: 5.2 and 129, as for fail_panel)
      write_parquet(hidden_loss_app(hl$history), path[["hidden_loss"]], compression = "gzip")
      write_parquet(hl$history, path[["hidden_loss_history"]], compression = "gzip")
    }),
  # Reads tonight's hidden_loss (so FRED too): skipped with it, failed when it failed
  run_stress = build_optional_mart("run_stress", c("fdic", "fred"), src, function(path) {
    hl_path <- file.path(MARTS, "hidden_loss.parquet")
    if (!file.exists(hl_path)) stop("hidden_loss was not built this run")
    rs <- build_run_stress(files[raw_rds(files) == newest], as.data.frame(read_parquet(hl_path)))
    report_run_stress(rs$mart)
    check_run_stress(rs$mart, rs$inputs, newest)
    write_parquet(rs$mart, path)
  })
)

cat(sprintf("Done: %d requests, %.0f s. Raw %.1f MB across %d quarters.\n",
            .n_requests, as.numeric(difftime(Sys.time(), t0, units = "secs")),
            sum(file.size(files)) / 1048576, length(files)))
cat(sprintf("Marts: industry_quarterly %d rows (%.0f KB); latest_snapshot %d banks, %d active, %d not yet filed (%.0f KB).\n",
            nrow(industry$ind), file.size(file.path(MARTS, "industry_quarterly.parquet")) / 1024,
            nrow(snap), sum(snap$active), snapshot$n_unfiled,
            file.size(file.path(MARTS, "latest_snapshot.parquet")) / 1024))

# FDIC marts are written; a failed non-critical source or mart turns the
# job red (status 2) without holding them back. pipeline.yml publishes on 2.
failed <- c(names(Filter(function(r) !r$ok, src)), names(marts_ok)[!marts_ok])
if (length(failed)) {
  cat("FAILED:", failed, "(FDIC marts written; see the source/mart lines above)\n")
  quit(status = 2)
}
