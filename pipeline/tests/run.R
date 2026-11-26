# Offline golden tests of the pipeline's pure functions, on hand-built
# fixtures with hand-computed answers. No network. Run from the repo root:
#   Rscript pipeline/tests/run.R
# CI: .github/workflows/pipeline-test.yml, on PRs touching pipeline/**.

source(file.path("app", "R", "api.R"))
for (f in c("R/http.R", "sources/fdic.R", "sources/fred.R", "R/sources.R",
            "marts/rates.R", "checks/check.R", "checks/rates.R")) {
  source(file.path("pipeline", f))
}

.n_fail <- 0L
expect <- function(ok, label) {
  if (isTRUE(ok)) cat("  ok  ", label, "\n")
  else { cat("  FAIL", label, "\n"); .n_fail <<- .n_fail + 1L }
}
expect_error <- function(expr, pattern, label) {
  msg <- tryCatch({ expr; "" }, error = conditionMessage)
  expect(grepl(pattern, msg), label)
}

for (f in sort(list.files(file.path("pipeline", "tests"), "^test_.*\\.R$",
                          full.names = TRUE))) {
  cat(basename(f), "\n")
  source(f, local = new.env())
}
if (.n_fail) stop(.n_fail, " pipeline test(s) failed")
cat("All pipeline tests passed.\n")
