# Offline golden tests of the pipeline's pure functions, on hand-built
# fixtures with hand-computed answers. No network. Run from the repo root:
#   Rscript pipeline/tests/run.R
# CI: .github/workflows/pipeline-test.yml, on PRs touching pipeline/**.

source(file.path("app", "R", "api.R"))
for (f in c("R/http.R", "R/store.R", "sources/fdic.R", "sources/fred.R",
            "sources/failures.R", "R/sources.R", "R/hidden_loss.R", "R/run_stress.R",
            "marts/rates.R", "marts/fail_panel.R",
            "marts/research_coverage.R", "marts/bank_ids.R", "marts/hidden_loss.R",
            "marts/run_stress.R",
            "checks/check.R", "checks/rates.R", "checks/fail_panel.R",
            "checks/research_coverage.R", "checks/bank_ids.R", "checks/hidden_loss.R",
            "checks/run_stress.R")) {
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
