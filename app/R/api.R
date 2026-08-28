# FDIC API client for the app, base R networking only: the app must run
# unchanged on desktop R, shinyapps.io, and shinylive/webR, and the usual
# HTTP client packages have no working WebAssembly build. download.file
# covers all three runtimes (webR shims it onto the browser's fetch, and
# the FDIC API is CORS-open). The repo-root R/ fetch functions keep their
# richer client for analysis scripts; this file is the app's only transport.
#
# Keep request URLs short. webR's internet module writes the URL into a
# fixed buffer; past ~4,000 chars every in-browser fetch dies with
# "problem writing module_download template in internet module". That, not
# response size, is what broke the GitHub Pages build in 2026-07.
#
# API conventions (verified 2026-07-07, see analysis/data-dictionary.md):
# dollar fields are $thousands, RISDATE = REPDTE (integer YYYYMMDD), 10k
# record cap per request, join key is CERT, no auth or headers needed.

FDIC_FINANCIALS_ENDPOINT   <- "https://api.fdic.gov/banks/financials"
FDIC_INSTITUTIONS_ENDPOINT <- "https://api.fdic.gov/banks/institutions"

# Same field set as R/fetch_bank_financials.R EXPANDED_FIELDS; kept in sync
# manually (the app must be self-contained for shinylive export).
APP_FIELDS <- paste0(
  "CERT,NAMEFULL,REPDTE,RISDATE,STALP,BKCLASS,REGAGNT,NUMEMP,",
  "ASSET,LIAB,EQ,EQTOT,DEP,DEPDOM,DEPINS,DEPUNINS,LNLSNET,SC,CHBAL,",
  "NCLNLS,P3ASSET,P9ASSET,NTLNLS,",
  "NETINC,INTINC,EINTEXP,NONII,NONIX,ELNATR,",
  "ROA,ROE,NIMY,LNATRESR,ELNATRY,NTLNLSR,RBC1AAJ,RBCRWAJ,",
  "BRO,BROR,COREDEP,COREDEPR,VOLIAB,VOLIABR,NTRTMLGJ,",
  "OTHBOR,OTHBFHLB,FREPP,LNLSDEPR,DEPDASTR,",
  "SCAA,SCAF,SCHA,SCHF,IGLSEC,",
  "LNRE,LNCI,LNAG,LNAGR,LNRECONS,LNRECONSR,LNRENRES,LNRENRESR,",
  "LNREMULT,LNREMULTR,",
  "NCLNLSR,LNATRES,RSLNLS,RSLNLSR,P3LNLS,P9LNLS,NALNLS,",
  "EQV,ERNASTR,",
  "ROAQ,ROEQ,NIMYQ,ELNATRYQ,NTLNLSQR"
)

# Download to a temp file and read the whole body back. Verified in all
# three runtimes (desktop smoke test; headless Chromium against the
# deployed shinylive build, 2026-07-09, including the 260 KB Citibank
# history).
fetch_body <- function(u) {
  tmp <- tempfile(fileext = ".json")
  on.exit(unlink(tmp))
  status <- suppressWarnings(utils::download.file(u, tmp, quiet = TRUE,
                                                  mode = "wb"))
  if (status != 0) stop("download.file returned status ", status)
  readChar(tmp, file.size(tmp), useBytes = TRUE)
}

# GET endpoint?params and parse the JSON body. jsonlite's own vectorized
# simplification builds the entire data frame in one pass, so body$data$data
# comes back ready to use. It replaces a per-record as.data.frame +
# bind_rows loop that cost 9.44s on a 4,313-bank cross-section against
# 0.31s here; the two were verified to agree exactly (same 74 columns, same
# classes, same NA pattern, all 67 numeric columns equal). (Do not name the
# repo's HTTP client package here: shinylive's dependency scan reads
# comments too, and a bare mention ships seven extra wasm packages to the
# browser.)
fdic_query <- function(endpoint, params) {
  qs <- paste(names(params),
              vapply(params, function(v) utils::URLencode(as.character(v),
                                                          reserved = TRUE),
                     character(1)),
              sep = "=", collapse = "&")
  u <- paste0(endpoint, "?", qs)
  jsonlite::fromJSON(fetch_body(u))
}

# Records from a parsed body as a data frame, NULL when nothing matched.
# Fields a bank did not report that quarter arrive as NA already.
flatten_body <- function(body) {
  if (is.null(body$data) || length(body$data) == 0) return(NULL)
  body$data$data
}

# Full quarterly history for one bank. The date filter is a range, not an
# OR-list of the 172 quarter-ends: webR's internet module writes the URL
# into a fixed buffer, and the enumerated form (~4,600 chars) overflows it
# ("problem writing module_download template"), killing every in-browser
# fetch. The index only holds quarter-end records, so the range is exact.
# years defaults to 1984 through next calendar year, evaluated at call
# time: a literal upper bound silently truncates every history the moment
# the year rolls over, with no error to notice.
fetch_bank_financials <- function(cert,
                                  years = 1984:(as.integer(
                                    format(Sys.Date(), "%Y")) + 1L),
                                  fields = APP_FIELDS) {
  body <- fdic_query(FDIC_FINANCIALS_ENDPOINT, list(
    filters = paste0("CERT:", cert, " AND RISDATE:[", min(years), "0101 TO ",
                     max(years), "1231]"),
    fields = fields, limit = 10000, offset = 0
  ))
  if (body$meta$total == 0) return(NULL)
  flatten_body(body)
}

# One quarter for all ~4,300 banks (the peer-percentile cross-section)
fetch_all_banks_quarter <- function(risdate, fields = APP_FIELDS) {
  body <- fdic_query(FDIC_FINANCIALS_ENDPOINT, list(
    filters = paste0("RISDATE:", risdate),
    fields = fields, limit = 10000, offset = 0
  ))
  if (body$meta$total >= 10000) {
    stop("Cross-section hit the 10k cap; paginate before trusting it.")
  }
  flatten_body(body)
}

# Quarter-end RISDATE immediately before the given one (dates are the
# integer YYYYMMDD form the index uses; only the four quarter-ends exist).
prev_quarter_end <- function(risdate) {
  y  <- risdate %/% 10000L
  md <- risdate %% 10000L
  if (md == 331L)  return((y - 1L) * 10000L + 1231L)
  if (md == 630L)  return(y * 10000L + 331L)
  if (md == 930L)  return(y * 10000L + 630L)
  if (md == 1231L) return(y * 10000L + 930L)
  NA_integer_
}

# Number of banks filing for one quarter (meta$total only; no records).
count_quarter <- function(risdate) {
  body <- fdic_query(FDIC_FINANCIALS_ENDPOINT, list(
    filters = paste0("RISDATE:", risdate), fields = "CERT", limit = 1
  ))
  as.integer(body$meta$total)
}

# A quarter is usable as the peer cross-section only once most banks have
# filed. Quarters open on the API as a trickle of early filers and fill over
# the following weeks, so the newest RISDATE can represent a few hundred
# banks -- peer medians built on that are silently, badly wrong rather than
# missing. Real quarter-over-quarter attrition is ~1% (consolidation:
# 4494 -> 4452 -> 4411 -> 4353 -> 4313 across 2025Q2..2026Q2), so a 95%
# floor admits every genuine quarter and rejects a half-filled one.
XS_MIN_COMPLETE <- 0.95

# Newest sufficiently-complete quarter on the API, or NA if the endpoint
# gave us nothing. sort_by/sort_order ARE honored even though the API
# omits them from the echoed meta$parameters (verified: DESC -> 20260630,
# ASC -> 20250331, unsorted -> insertion order).
latest_risdate <- function() {
  yr <- as.integer(format(Sys.Date(), "%Y"))
  body <- fdic_query(FDIC_FINANCIALS_ENDPOINT, list(
    filters = paste0("RISDATE:[", yr - 2L, "0101 TO ", yr + 1L, "1231]"),
    fields = "CERT,RISDATE", limit = 1,
    sort_by = "RISDATE", sort_order = "DESC"
  ))
  if (as.integer(body$meta$total) == 0) return(NA_integer_)
  rows <- flatten_body(body)
  if (is.null(rows) || is.null(rows$RISDATE)) return(NA_integer_)
  newest <- as.integer(rows$RISDATE[1])

  prior <- prev_quarter_end(newest)
  if (is.na(prior)) return(newest)
  n_new <- count_quarter(newest)
  n_old <- count_quarter(prior)
  if (n_old > 0 && n_new < XS_MIN_COMPLETE * n_old) {
    message("FDIC quarter ", newest, " only ", n_new, " of ", n_old,
            " banks (<", round(100 * XS_MIN_COMPLETE), "%); using ", prior)
    return(prior)
  }
  newest
}

# Directory of all active banks for the pickers
fetch_institutions <- function() {
  body <- fdic_query(FDIC_INSTITUTIONS_ENDPOINT, list(
    filters = "ACTIVE:1",
    fields = "CERT,NAME,CITY,STALP,ASSET",
    limit = 10000
  ))
  raw <- flatten_body(body)
  if (is.null(raw)) return(NULL)
  col <- function(nm) if (is.null(raw[[nm]])) NA else raw[[nm]]
  data.frame(
    CERT  = col("CERT"),
    NAME  = col("NAME"),
    CITY  = col("CITY"),
    STALP = col("STALP"),
    ASSET = col("ASSET"),
    stringsAsFactors = FALSE
  ) |>
    dplyr::filter(!is.na(CERT)) |>
    dplyr::arrange(dplyr::desc(ASSET))
}
