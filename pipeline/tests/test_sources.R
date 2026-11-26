# R/sources.R: a failing non-critical source is contained, a critical one
# stops the run, and stale or missing raw holds back dependent marts
fake <- function(name, critical, run, last = as.POSIXct(NA), max_age = 10) {
  list(name = name, critical = critical, cadence = "nightly",
       max_age_days = max_age, run = run, last_pull = function() last)
}
good <- fake("good", TRUE, function(ctx) "value")
bad  <- fake("bad", FALSE, function(ctx) stop("HTTP 404"))

out <- NULL
log <- capture.output(out <- run_sources(list(good, bad), list()))
expect(isTRUE(out$good$ok) && identical(out$good$value, "value"), "critical source returns its value")
expect(identical(out$bad$ok, FALSE) && identical(out$bad$error, "HTTP 404"),
       "non-critical failure is caught and recorded")
expect(any(grepl("source bad FAILED: HTTP 404", log)), "the failure is logged by name")
expect_error(run_sources(list(fake("fdic", TRUE, function(ctx) stop("FDIC down"))), list()),
             "FDIC down", "a critical failure stops the run")

now <- as.POSIXct("2024-01-20 12:00:00", tz = "UTC")
srcs <- list(
  fresh   = fake("fresh", FALSE, NULL, last = now - 86400),
  stale   = fake("stale", FALSE, NULL, last = now - 20 * 86400),
  never   = fake("never", FALSE, NULL),
  ok      = fake("ok", FALSE, NULL))
res <- list(fresh = list(ok = FALSE), stale = list(ok = FALSE),
            never = list(ok = FALSE), ok = list(ok = TRUE))
expect(is.null(dep_problem("ok", res, srcs, now)), "a source that ran is usable")
invisible(capture.output(p <- dep_problem("fresh", res, srcs, now)))
expect(is.null(p), "a failed source with a recent good copy is usable")
expect(grepl("stale", dep_problem("stale", res, srcs, now)), "past max_age_days -> stale")
expect(grepl("no good copy", dep_problem("never", res, srcs, now)), "no copy -> skipped")

# A mart set (fail_panel + failures_meta) is written or held back together
MARTS <<- tempfile(); dir.create(MARTS)
write_both <- function(path) for (p in path) writeLines("x", p)
both <- file.path(MARTS, c("a.parquet", "b.parquet"))
expect(build_optional_mart("a", "ok", res, write_both, also = "b") && all(file.exists(both)),
       "a good mart set writes every file")
invisible(capture.output(r <- build_optional_mart("a", "ok", res, also = "b",
  function(path) { write_both(path); stop("check failed") })))
expect(!r && !any(file.exists(both)), "a failed check removes every file of the set")
registry <- SOURCES; SOURCES <<- srcs        # dep_problem reads the registry
invisible(capture.output(r <- build_optional_mart("a", "stale", res, write_both, also = "b")))
SOURCES <<- registry
expect(r && !any(file.exists(both)), "a skipped set leaves no file, so the published copies stay")
