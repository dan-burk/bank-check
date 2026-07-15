# Data loading, derived metrics, and the live FDIC fetch with cache.
# Working directory at runtime is app/ (shiny::runApp("app") from repo
# root, or the shinylive virtual filesystem root in the browser). The app
# reads ONLY from app/: shinylive exports the app directory alone.
# Transport lives in R/api.R (auto-sourced first).
#
# Shipped data is .rds, not .csv, and the app avoids readr on purpose:
# rds is ~4x smaller in the bundle and loads pre-parsed (parsing a 7 MB
# CSV inside WebAssembly is slow), and dropping readr removes seven
# packages from the browser's cold-start download.

CACHE_DIR <- "data-cache"
if (!dir.exists(CACHE_DIR)) dir.create(CACHE_DIR)

# na.strings: read.csv turns blank cells into "" by default, but the
# footnote and threshold code tests is.na()
FIELDS_META <- utils::read.csv("data/fields_meta.csv",
                               na.strings = c("", "NA"))

# Derived columns shared by every bank data frame ----
derive <- function(df) {
  df |>
    dplyr::arrange(RISDATE) |>
    dplyr::mutate(
      date        = as.Date(as.character(RISDATE), format = "%Y%m%d"),
      qlab        = paste0("Q", (as.integer(format(date, "%m")) - 1) %/% 3 + 1,
                           "'", format(date, "%y")),
      gross_lns   = LNLSNET + LNATRES,
      p3_pct      = 100 * P3LNLS / gross_lns,
      alw_cover   = ifelse(NCLNLS > 0, LNATRES / NCLNLS, NA),
      bro_pct_dep = 100 * BRO / DEP,
      # Core as % of DEPOSITS, computed here: FDIC's COREDEPR is % of total
      # ASSETS, which silently mixed denominators on the Funding Mix chart
      # (caught 2026-07 via Capital Bank and Trust: $500k deposits on $226M
      # assets put "core" at 0.2 where share-of-deposits says 100)
      core_pct_dep = ifelse(DEP > 0, 100 * COREDEP / DEP, NA),
      unrl_pct_eq = 100 * ((SCAF - SCAA) + (SCHF - SCHA)) / EQ
    )
}

# Base store: the 7-bank comparison panel, with Dacotah swapped for its
# longer 1984+ pull from analysis 001.
load_base_banks <- function() {
  panel <- readRDS("data/panel_histories.rds")
  dacotah <- readRDS("data/dacotah_expanded.rds") |>
    dplyr::mutate(label = "Dacotah (SD)", fail_date = as.Date(NA))

  panel <- panel |> dplyr::filter(label != "Dacotah (SD)")
  dplyr::bind_rows(panel, dacotah) |>
    derive() |>
    dplyr::mutate(
      # Quarters before failure as an exact quarter-index difference
      fail_dt   = as.Date(fail_date),
      qidx      = as.integer(format(date, "%Y")) * 4 +
                  (as.integer(format(date, "%m")) - 1) %/% 3,
      fail_qidx = as.integer(format(fail_dt, "%Y")) * 4 +
                  (as.integer(format(fail_dt, "%m")) - 1) %/% 3,
      qtrs_before = ifelse(!is.na(fail_dt), fail_qidx - qidx, NA)
    )
}

# All ~570 post-2000 failures: pre-failure quarterly histories (0-20
# quarters before failure) built once by app/build/build_fail_panel.R.
# qtrs_before is stored in the rds; derive() adds the shared derived columns.
load_fail_panel <- function() {
  readRDS("data/fail_panel.rds") |> derive()
}

# Picker metadata for the failures tab: label, region, size bucket. Banks
# with zero pre-failure filings are excluded (nothing to draw).
load_fail_meta <- function() {
  readRDS("data/failures_meta.rds") |>
    dplyr::filter(n_filings > 0)
}

# Per-quarter median of one metric across a failure panel. min_n trims the
# ragged tail where few banks report (early-2000s quarters lack modern
# fields), so the baseline never rests on a handful of banks.
fail_median <- function(panel, code, min_n = 5) {
  if (!code %in% names(panel)) return(NULL)
  panel |>
    dplyr::filter(qtrs_before >= 0, qtrs_before <= 20) |>
    dplyr::group_by(qtrs_before) |>
    dplyr::summarise(
      n   = sum(is.finite(.data[[code]])),
      med = stats::median(.data[[code]][is.finite(.data[[code]])]),
      .groups = "drop"
    ) |>
    dplyr::filter(n >= min_n)
}

# Live fetch of any CERT, cached as CSV so the FDIC API is hit once per
# bank. In the browser the cache is webR's in-memory filesystem, so it
# lasts one session; on desktop it persists in app/data-cache/.
fetch_bank_cached <- function(cert) {
  cache <- file.path(CACHE_DIR, paste0("cert_", cert, ".rds"))
  if (file.exists(cache)) {
    return(derive(readRDS(cache)))
  }
  df <- fetch_bank_financials(cert = cert)
  if (is.null(df)) return(NULL)
  saveRDS(df, cache)
  derive(df)
}

# Latest full cross-section (~4,350 banks), feeding the peer percentile
# bands. A shipped copy in data/ (refreshed by sync_assets.R at each
# deploy) makes first paint instant; the live fetch is the fallback.
XS_RISDATE <- 20260331

fetch_cross_section_cached <- function(max_age_days = 30) {
  shipped <- file.path("data", paste0("xs_", XS_RISDATE, ".rds"))
  if (file.exists(shipped)) {
    return(derive(readRDS(shipped)))
  }
  cache <- file.path(CACHE_DIR, paste0("xs_", XS_RISDATE, ".rds"))
  if (file.exists(cache) &&
      difftime(Sys.time(), file.mtime(cache), units = "days") < max_age_days) {
    return(derive(readRDS(cache)))
  }
  xs <- fetch_all_banks_quarter(XS_RISDATE)
  saveRDS(xs, cache)
  derive(xs)
}

# Per-metric peer quantiles for every rate metric in fields_meta. Quantiles,
# not mean/sd: bank ratios have heavy tails (see analysis/003).
peer_stats <- function(xs, meta) {
  codes <- meta$code[meta$units %in% c("pct", "x")]
  rows <- lapply(codes, function(cd) {
    v <- xs[[cd]]
    if (is.null(v)) return(NULL)
    v <- v[is.finite(v)]   # zero-denominator banks produce Inf, not NA
    if (length(v) < 100) return(NULL)
    q <- stats::quantile(v, c(0.25, 0.50, 0.75))
    data.frame(code = cd, p25 = q[[1]], p50 = q[[2]], p75 = q[[3]])
  })
  do.call(rbind, rows)
}

# Display label for a fetched bank: name plus place, never a CERT number.
# "First National Bank" alone is ambiguous; "First National Bank (Fort
# Pierre, SD)" is not.
bank_label <- function(cert, inst, fallback_name = NULL) {
  r <- inst[inst$CERT == as.integer(cert), ]
  nm <- if (nrow(r) > 0) r$NAME[1] else fallback_name
  nm <- tools::toTitleCase(tolower(nm))
  if (nrow(r) > 0 && !is.na(r$CITY[1])) {
    paste0(nm, " (", tools::toTitleCase(tolower(r$CITY[1])), ", ",
           r$STALP[1], ")")
  } else nm
}

# Directory of ALL active FDIC banks (~4,300) for the pickers. Shipped
# copy first (refreshed at deploy), then the 30-day desktop cache, then a
# live fetch (one request; all rows fit under the 10k cap).
fetch_institutions_cached <- function(max_age_days = 30) {
  shipped <- file.path("data", "institutions.rds")
  if (file.exists(shipped)) {
    return(readRDS(shipped))
  }
  cache <- file.path(CACHE_DIR, "institutions.rds")
  if (file.exists(cache) &&
      difftime(Sys.time(), file.mtime(cache), units = "days") < max_age_days) {
    return(readRDS(cache))
  }
  df <- fetch_institutions()
  saveRDS(df, cache)
  df
}

# Named choice vector for the directory picker: label -> CERT
institution_choices <- function(inst) {
  asset_lab <- ifelse(inst$ASSET >= 1e6,
                      paste0("$", round(inst$ASSET / 1e6, 1), "B"),
                      paste0("$", round(inst$ASSET / 1e3), "M"))
  stats::setNames(
    inst$CERT,
    paste0(inst$NAME, ", ", inst$CITY, " ", inst$STALP, " (", asset_lab, ")")
  )
}
