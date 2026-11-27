# The source registry and non-critical failure handling. Source after
# pipeline/sources/*.R (it lists their SOURCE_* objects).
#
# Each source is a list:
#   name          prefix of its raw assets ("fred." -> fred.*.csv)
#   critical      TRUE only for fdic: its failure stops the run
#   cadence       nightly | yearly | manual
#   max_age_days  how old its last good pull may be for marts to use it
#   run(ctx)      pull, check, then store; stop() before storing on a bad
#                 pull. ctx = list(quarters, seen, today)
#   last_pull()   time of the last good stored pull, NA if none
#
# A non-critical source that fails keeps its last good raw files (the copy
# downloaded from the release) and the run carries on. build.R then exits
# with status 2, so the FDIC marts still publish but the job goes red.

# hmda pulls nothing at night: it checks the groups hmda.yml stored
SOURCES <- list(fdic = SOURCE_FDIC, fred = SOURCE_FRED, failures = SOURCE_FAILURES,
                hmda = SOURCE_HMDA)

# Run every source in order. Returns, per name, list(ok, value or error).
run_sources <- function(sources, ctx) {
  out <- list()
  for (s in sources) {
    if (s$critical) {                       # errors propagate: run stops
      out[[s$name]] <- list(ok = TRUE, value = s$run(ctx))
      next
    }
    out[[s$name]] <- tryCatch(
      list(ok = TRUE, value = s$run(ctx)),
      error = function(e) {
        cat("source", s$name, "FAILED:", conditionMessage(e), "\n")
        list(ok = FALSE, error = conditionMessage(e))
      })
  }
  out
}

# Why a mart can't use source `name` this run, or NULL if it can: the
# source failed and has no good copy, or its last good pull is older than
# its max_age_days.
dep_problem <- function(name, results, sources = SOURCES, now = Sys.time()) {
  if (isTRUE(results[[name]]$ok)) return(NULL)
  last <- sources[[name]]$last_pull()
  if (is.na(last)) return(paste(name, "failed, no good copy"))
  age <- as.numeric(difftime(now, last, units = "days"))
  if (age > sources[[name]]$max_age_days) {
    return(sprintf("%s stale (last good pull %.1f days ago)", name, age))
  }
  cat("  ", name, "failed this run; using its last good pull from",
      format(last), "\n")
  NULL
}

# Build and check one non-core mart into MARTS/<name>.parquet (plus
# MARTS/<also>.parquet for marts published as a set). build(path) must
# check before it writes; path is named by mart. Skipped (dependency
# unusable) or failed, every file of the set is absent, so the published
# copies stay live together. Returns FALSE only if the mart itself failed:
# a skip follows a source failure already counted.
build_optional_mart <- function(name, deps, results, build, also = character()) {
  path <- stats::setNames(file.path(MARTS, paste0(c(name, also), ".parquet")),
                          c(name, also))
  unlink(path)
  why <- unlist(lapply(deps, dep_problem, results = results))
  if (length(why)) {
    cat("mart", name, "skipped:", paste(why, collapse = "; "), "\n")
    return(TRUE)
  }
  tryCatch({ build(path); TRUE }, error = function(e) {
    cat("mart", name, "FAILED:", conditionMessage(e), "\n")
    unlink(path)
    FALSE
  })
}
