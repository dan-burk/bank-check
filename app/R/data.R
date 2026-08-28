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
fetch_bank_cached <- function(cert, max_age_days = 30) {
  cache <- file.path(CACHE_DIR, paste0("cert_", cert, ".rds"))
  if (file.exists(cache) &&
      difftime(Sys.time(), file.mtime(cache), units = "days") < max_age_days) {
    return(derive(readRDS(cache)))
  }
  df <- tryCatch(fetch_bank_financials(cert = cert),
                 error = function(e) {
                   message("FDIC fetch failed for CERT ", cert, ": ",
                           conditionMessage(e))
                   NULL
                 })
  if (is.null(df)) {
    # Unreachable API or a withdrawn bank: a stale history beats no chart
    if (file.exists(cache)) return(derive(readRDS(cache)))
    return(NULL)
  }
  saveRDS(df, cache)
  derive(df)
}

# Newest xs_<RISDATE>.rds in a directory, or NULL if there is none. The
# filename carries the quarter, so the data and the label the UI prints for
# it cannot drift apart -- there is no separate constant to forget to bump.
newest_xs <- function(dir) {
  f <- list.files(dir, pattern = "^xs_[0-9]{8}\\.rds$", full.names = TRUE)
  if (length(f) == 0) return(NULL)
  sort(f, decreasing = TRUE)[1]
}

# Latest full cross-section (~4,300 banks), feeding the peer percentile
# bands. Live first, so a new FDIC quarter shows up on its own with no
# redeploy: a session cache newer than max_age_days short-circuits the
# fetch, and the shipped copy in data/ is the offline fallback for FDIC
# downtime and for the CI smoke test, which must run without network.
# Refresh the shipped copy with app/build/sync_assets.R.
fetch_cross_section_cached <- function(max_age_days = 30) {
  cache <- newest_xs(CACHE_DIR)
  if (!is.null(cache) &&
      difftime(Sys.time(), file.mtime(cache), units = "days") < max_age_days) {
    return(derive(readRDS(cache)))
  }
  live <- tryCatch({
    rd <- latest_risdate()
    if (is.na(rd)) stop("no RISDATE returned")
    xs <- fetch_all_banks_quarter(rd)
    saveRDS(xs, file.path(CACHE_DIR, paste0("xs_", rd, ".rds")))
    xs
  }, error = function(e) {
    message("Live cross-section unavailable (", conditionMessage(e),
            "); falling back to the shipped copy.")
    NULL
  })
  if (!is.null(live)) return(derive(live))
  if (!is.null(cache)) return(derive(readRDS(cache)))  # stale beats nothing
  shipped <- newest_xs("data")
  if (is.null(shipped)) {
    stop("No cross-section: no network and no shipped data/xs_*.rds")
  }
  derive(readRDS(shipped))
}

# Quarter label ("2026 Q2") for whichever cross-section actually loaded, so
# a legend can never name a quarter the data behind it is not from.
xs_quarter_label <- function(xs) {
  d <- xs$date[!is.na(xs$date)]
  if (length(d) == 0) return("latest quarter")
  d <- max(d)
  paste0(format(d, "%Y"), " Q", (as.integer(format(d, "%m")) - 1L) %/% 3L + 1L)
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
  # 85 banks in the financials cross-section are absent from the ACTIVE:1
  # directory (clearing houses like DTC CERT 90544, trust-only charters).
  # With no name from either source this fell through as character(0),
  # which becomes a silently unnamed plotly trace rather than an error.
  if (length(nm) == 0 || is.na(nm)) return(paste0("CERT ", cert))
  nm <- tools::toTitleCase(tolower(nm))
  if (nrow(r) > 0 && !is.na(r$CITY[1])) {
    paste0(nm, " (", tools::toTitleCase(tolower(r$CITY[1])), ", ",
           r$STALP[1], ")")
  } else nm
}

# Directory of ALL active FDIC banks (~4,300) for the pickers. Same
# ordering as the cross-section: fresh cache, then live (one request; all
# rows fit under the 10k cap), then the shipped copy. Live-first is what
# lets new charters, mergers and failures reach the pickers on their own.
fetch_institutions_cached <- function(max_age_days = 30) {
  cache <- file.path(CACHE_DIR, "institutions.rds")
  if (file.exists(cache) &&
      difftime(Sys.time(), file.mtime(cache), units = "days") < max_age_days) {
    return(readRDS(cache))
  }
  df <- tryCatch(fetch_institutions(), error = function(e) {
    message("Live institution directory unavailable (", conditionMessage(e),
            "); falling back to the shipped copy.")
    NULL
  })
  if (!is.null(df)) {
    saveRDS(df, cache)
    return(df)
  }
  if (file.exists(cache)) return(readRDS(cache))
  shipped <- file.path("data", "institutions.rds")
  if (!file.exists(shipped)) stop("No institution directory available")
  readRDS(shipped)
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
