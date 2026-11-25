# Throttled transport. Replaces fdic_query() for everything sourced from
# app/R/ (latest_risdate, count_quarter, fetch_institutions), so no request
# anywhere in a run skips the throttle. Source after app/R/api.R.
#
# API etiquette: one request at a time, at least 2 s apart, 3 retries with
# growing waits, then stop.

MIN_GAP_S   <- 2
RETRY_WAITS <- c(10, 30, 90)

.last_request <- 0
.n_requests   <- 0L
fdic_query_raw <- fdic_query
fdic_query <- function(endpoint, params) {
  for (attempt in 0:length(RETRY_WAITS)) {
    wait <- MIN_GAP_S - (as.numeric(Sys.time()) - .last_request)
    if (wait > 0) Sys.sleep(wait)
    .last_request <<- as.numeric(Sys.time())
    .n_requests   <<- .n_requests + 1L
    res <- tryCatch(fdic_query_raw(endpoint, params), error = function(e) e)
    if (!inherits(res, "error")) return(res)
    if (attempt == length(RETRY_WAITS)) {
      stop("FDIC request failed after ", attempt + 1, " tries: ",
           conditionMessage(res))
    }
    message("  request failed (", conditionMessage(res), "); retrying in ",
            RETRY_WAITS[attempt + 1], " s")
    Sys.sleep(RETRY_WAITS[attempt + 1])
  }
}
