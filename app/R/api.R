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

# GET endpoint?params and parse the JSON body. simplifyVector = FALSE keeps
# the structure identical to what the repo fetch functions get from their
# HTTP client, so the flattening code is shared verbatim. (Do not name that
# client package here: shinylive's dependency scan reads comments too, and
# a bare mention ships seven extra wasm packages to the browser.)
fdic_query <- function(endpoint, params) {
  qs <- paste(names(params),
              vapply(params, function(v) utils::URLencode(as.character(v),
                                                          reserved = TRUE),
                     character(1)),
              sep = "=", collapse = "&")
  u <- paste0(endpoint, "?", qs)
  jsonlite::fromJSON(fetch_body(u), simplifyVector = FALSE)
}

# One FDIC record to a 1-row data frame; NULL fields (not reported that
# quarter) become NA
flatten_record <- function(record) {
  record <- lapply(record, function(v) if (is.null(v)) NA else v)
  as.data.frame(record, stringsAsFactors = FALSE)
}

# Full quarterly history for one bank. The date filter is a range, not an
# OR-list of the 172 quarter-ends: webR's internet module writes the URL
# into a fixed buffer, and the enumerated form (~4,600 chars) overflows it
# ("problem writing module_download template"), killing every in-browser
# fetch. The index only holds quarter-end records, so the range is exact.
fetch_bank_financials <- function(cert, years = 1984:2026,
                                  fields = APP_FIELDS) {
  body <- fdic_query(FDIC_FINANCIALS_ENDPOINT, list(
    filters = paste0("CERT:", cert, " AND RISDATE:[", min(years), "0101 TO ",
                     max(years), "1231]"),
    fields = fields, limit = 10000, offset = 0
  ))
  if (body$meta$total == 0) return(NULL)
  dplyr::bind_rows(lapply(body$data, function(x) flatten_record(x$data)))
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
  dplyr::bind_rows(lapply(body$data, function(x) flatten_record(x$data)))
}

# Directory of all active banks for the pickers
fetch_institutions <- function() {
  body <- fdic_query(FDIC_INSTITUTIONS_ENDPOINT, list(
    filters = "ACTIVE:1",
    fields = "CERT,NAME,CITY,STALP,ASSET",
    limit = 10000
  ))
  df <- dplyr::bind_rows(lapply(body$data, function(x) {
    r <- lapply(x$data, function(v) if (is.null(v)) NA else v)
    data.frame(
      CERT  = if (is.null(r$CERT)) NA else r$CERT,
      NAME  = if (is.null(r$NAME)) NA else r$NAME,
      CITY  = if (is.null(r$CITY)) NA else r$CITY,
      STALP = if (is.null(r$STALP)) NA else r$STALP,
      ASSET = if (is.null(r$ASSET)) NA else r$ASSET,
      stringsAsFactors = FALSE
    )
  })) |>
    dplyr::filter(!is.na(CERT)) |>
    dplyr::arrange(dplyr::desc(ASSET))
  df
}
