# FDIC API client for the app. No httr2/curl on purpose: the curl package
# has no WebAssembly build, so httr2 cannot load under shinylive/webR. Base
# url() works in both worlds (webR shims it onto the browser's fetch, and
# the FDIC API is CORS-open), so the same code runs on desktop R and on
# GitHub Pages. The repo-root R/ fetch functions keep httr2 for analysis
# scripts; this file is the app's only transport.
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

# GET endpoint?params and parse the JSON body. simplifyVector = FALSE keeps
# the structure identical to httr2::resp_body_json, so the flattening code
# is shared verbatim with the repo fetch functions.
# Fetch goes to a temp file with download.file, never url() + readLines: the
# FDIC returns the whole body as ONE line, and streaming a 500 KB line
# through webR's connection buffer crashes the wasm runtime ("memory
# access out of bounds"). download.file is webR's well-trodden path (one
# fetch into the virtual filesystem) and behaves identically on desktop R.
fdic_query <- function(endpoint, params) {
  qs <- paste(names(params),
              vapply(params, function(v) utils::URLencode(as.character(v),
                                                          reserved = TRUE),
                     character(1)),
              sep = "=", collapse = "&")
  tmp <- tempfile(fileext = ".json")
  on.exit(unlink(tmp))
  status <- utils::download.file(paste0(endpoint, "?", qs), tmp,
                                 quiet = TRUE, mode = "wb")
  if (status != 0) stop("FDIC request failed with status ", status)
  jsonlite::fromJSON(tmp, simplifyVector = FALSE)
}

# One FDIC record to a 1-row data frame; NULL fields (not reported that
# quarter) become NA
flatten_record <- function(record) {
  record <- lapply(record, function(v) if (is.null(v)) NA else v)
  as.data.frame(record, stringsAsFactors = FALSE)
}

# Full quarterly history for one bank
fetch_bank_financials <- function(cert, years = 1984:2026,
                                  fields = APP_FIELDS) {
  q_ends <- c("0331", "0630", "0930", "1231")
  dates <- paste0(rep(years, each = 4), q_ends)
  body <- fdic_query(FDIC_FINANCIALS_ENDPOINT, list(
    filters = paste0("RISDATE:(", paste(dates, collapse = " OR "),
                     ") AND CERT:", cert),
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
