# Build the all-failures panel for the Compare to Failures tab: pre-failure
# quarterly histories for every FDIC failure since 2000, plus a metadata
# table (region, size bucket, display label) for the app's filters.
#
# Self-contained on app/R/api.R (public FDIC API, no auth). Run from the
# repo root, only to refresh:
#   Rscript.exe app/build/build_fail_panel.R
#
# Output:
#   app/data/fail_panel.csv     one row per (CERT, quarter), 0-20 quarters
#                               before failure, APP_FIELDS columns
#   app/data/failures_meta.csv  one row per failed bank, picker metadata
#
# Survivorship gap: failed banks often stop filing 1-2 quarters before
# FAILDATE. qtrs_before is computed from actual filed RISDATEs, so missing
# quarters are simply absent. Never forward-fill them.

# Load libraries ----
library(dplyr)
library(readr)

source(paste0(getwd(), "/app/R/api.R"))

OUT_DIR <- paste0(getwd(), "/app/data")
MAX_QTRS_BEFORE <- 20
CHUNK_SIZE <- 50
FDIC_FAILURES_ENDPOINT <- "https://api.fdic.gov/banks/failures"

# 1. Failure list ----
# FAILDATE arrives as "M/D/YYYY" text; RESTYPE filter drops open-bank
# assistance deals.
body <- fdic_query(FDIC_FAILURES_ENDPOINT, list(
  filters = 'FAILYR:[2000 TO *] AND RESTYPE:"FAILURE"',
  limit = 10000, offset = 0
))
stopifnot(body$meta$total > 0, body$meta$total < 10000)
fails <- bind_rows(lapply(body$data, function(x) flatten_record(x$data)))
fails$fail_date <- as.Date(fails$FAILDATE, format = "%m/%d/%Y")
fails <- arrange(fails, fail_date)
cat("failures fetched:", nrow(fails), "\n")
stopifnot(!any(duplicated(fails$CERT)))
fails$FAILYR <- as.integer(fails$FAILYR)

# 2. Region lookup ----
# datasets::state.region covers the 50 states and labels the Census Midwest
# region "North Central" (pre-1984 name). Relabel, then add DC and the
# territories explicitly so no PSTALP maps to NA.
regions <- setNames(as.character(datasets::state.region), datasets::state.abb)
regions[regions == "North Central"] <- "Midwest"
regions <- c(regions, DC = "South", PR = "South", VI = "South",
             GU = "West", AS = "West", MP = "West")
fails$region <- unname(regions[fails$PSTALP])
stopifnot(!any(is.na(fails$region)))

# 3. Size buckets from assets at failure (QBFASSET is $thousands) ----
fails$size_bucket <- cut(
  fails$QBFASSET, breaks = c(0, 1e5, 1e6, 1e7, Inf),
  labels = c("Under $100M", "$100M to $1B", "$1B to $10B", "Over $10B"),
  right = FALSE
)
stopifnot(!any(is.na(fails$size_bucket)))

# 4. Display labels: name, state, fail year; city breaks ties ----
fails$label <- paste0(tools::toTitleCase(tolower(fails$NAME)),
                      " (", fails$PSTALP, " ", fails$FAILYR, ")")
dup <- fails$label %in% fails$label[duplicated(fails$label)]
fails$label[dup] <- paste0(tools::toTitleCase(tolower(fails$NAME[dup])),
                           ", ", tools::toTitleCase(tolower(fails$CITY[dup])),
                           " (", fails$PSTALP[dup], " ", fails$FAILYR[dup], ")")
stopifnot(!any(duplicated(fails$label)))

# 5. Histories, batched: per fail year, chunks of CERTs, one request each ----
# 6 years back covers 20 quarters before any failure quarter with margin.
# Worst case per request: 50 banks x 28 quarters = 1,400 rows, far under the
# 10k cap, but assert anyway.
fetch_chunk <- function(certs, failyr) {
  body <- fdic_query(FDIC_FINANCIALS_ENDPOINT, list(
    filters = paste0("CERT:(", paste(certs, collapse = " OR "), ")",
                     " AND RISDATE:[", failyr - 6, "0101 TO ",
                     failyr, "1231]"),
    fields = APP_FIELDS, limit = 10000, offset = 0
  ))
  stopifnot(body$meta$total < 10000)
  if (body$meta$total == 0) return(NULL)
  bind_rows(lapply(body$data, function(x) flatten_record(x$data)))
}

hist_parts <- list()
for (yr in sort(unique(fails$FAILYR))) {
  certs <- fails$CERT[fails$FAILYR == yr]
  chunks <- split(certs, ceiling(seq_along(certs) / CHUNK_SIZE))
  for (ch in chunks) {
    hist_parts[[length(hist_parts) + 1]] <- fetch_chunk(ch, yr)
    cat("fetched", yr, "chunk of", length(ch), "certs:",
        nrow(hist_parts[[length(hist_parts)]]), "rows\n")
    Sys.sleep(0.3)
  }
}
hist <- bind_rows(hist_parts)
cat("total history rows fetched:", nrow(hist), "\n")

# 6. Quarter-index distance to failure (same formula as app/R/data.R) ----
panel <- hist |>
  inner_join(fails |> select(CERT, label, fail_date), by = "CERT") |>
  mutate(
    date      = as.Date(as.character(RISDATE), format = "%Y%m%d"),
    qidx      = as.integer(format(date, "%Y")) * 4 +
                (as.integer(format(date, "%m")) - 1) %/% 3,
    fail_qidx = as.integer(format(fail_date, "%Y")) * 4 +
                (as.integer(format(fail_date, "%m")) - 1) %/% 3,
    qtrs_before = fail_qidx - qidx
  ) |>
  filter(qtrs_before >= 0, qtrs_before <= MAX_QTRS_BEFORE) |>
  select(-date, -qidx, -fail_qidx) |>
  arrange(fail_date, CERT, RISDATE)

# 7. Write outputs ----
meta <- fails |>
  left_join(panel |> count(CERT, name = "n_filings"), by = "CERT") |>
  mutate(n_filings = ifelse(is.na(n_filings), 0L, n_filings)) |>
  select(CERT, label, NAME, CITY, PSTALP, fail_date, QBFASSET,
         region, size_bucket, n_filings) |>
  arrange(fail_date)

write_csv(panel, file.path(OUT_DIR, "fail_panel.csv"))
write_csv(meta, file.path(OUT_DIR, "failures_meta.csv"))

# 8. Survivorship summary: how close to failure does the last filing get ----
last_filing <- panel |>
  group_by(CERT) |>
  summarise(last_gap = min(qtrs_before), .groups = "drop")
cat("\nbanks with histories:", nrow(last_filing), "of", nrow(fails), "\n")
cat("panel rows:", nrow(panel), "\n")
cat("last filing, quarters before failure (0 = filed in failure quarter):\n")
print(table(last_filing$last_gap))
cat("\nbanks with zero filings (excluded from the app picker):",
    sum(meta$n_filings == 0), "\n")
cat("region counts:\n")
print(table(meta$region))
cat("size buckets:\n")
print(table(meta$size_bucket))
