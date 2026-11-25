# Mart checks stop the run, so nothing is written unless all pass.
check <- function(ok, msg) if (!isTRUE(ok)) stop("Mart check failed: ", msg)
