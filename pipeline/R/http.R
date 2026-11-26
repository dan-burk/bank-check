# Throttled transport. Every request in a run goes through polite(), which
# keeps at least MIN_GAP_S between requests to the same host and retries
# with growing waits. fdic_query() is replaced here for everything sourced
# from app/R/ (latest_risdate, count_quarter, fetch_institutions), so no
# FDIC request skips the throttle. Source after app/R/api.R.
#
# API etiquette: one request at a time, at least 2 s apart per host,
# 3 retries with growing waits, then stop.

MIN_GAP_S   <- 2
RETRY_WAITS <- c(10, 30, 90)

.last_request <- numeric(0)   # host -> time of its last request
.n_requests   <- 0L

# Run f() (one request) politely; label names the source in the error
polite <- function(host, label, f) {
  for (attempt in 0:length(RETRY_WAITS)) {
    last <- if (host %in% names(.last_request)) .last_request[[host]] else 0
    wait <- MIN_GAP_S - (as.numeric(Sys.time()) - last)
    if (wait > 0) Sys.sleep(wait)
    .last_request[[host]] <<- as.numeric(Sys.time())
    .n_requests <<- .n_requests + 1L
    res <- tryCatch(f(), error = function(e) e)
    if (!inherits(res, "error")) return(res)
    if (attempt == length(RETRY_WAITS)) {
      stop(label, " request failed after ", attempt + 1, " tries: ",
           conditionMessage(res))
    }
    message("  request failed (", conditionMessage(res), "); retrying in ",
            RETRY_WAITS[attempt + 1], " s")
    Sys.sleep(RETRY_WAITS[attempt + 1])
  }
}

fdic_query_raw <- fdic_query
fdic_query <- function(endpoint, params) {
  polite("api.fdic.gov", "FDIC", function() fdic_query_raw(endpoint, params))
}

# A plain GET, returned as text. Base download.file, like app/R/api.R.
polite_get <- function(url, label) {
  host <- sub("^[a-z]+://([^/]+).*$", "\\1", url)
  polite(host, label, function() {
    tmp <- tempfile(); on.exit(unlink(tmp))
    status <- suppressWarnings(utils::download.file(url, tmp, quiet = TRUE,
                                                    mode = "wb"))
    if (status != 0) stop("download.file returned status ", status)
    readChar(tmp, file.size(tmp), useBytes = TRUE)
  })
}
