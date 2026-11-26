# FDIC financials: every bank, one request (or a few pages) per quarter.
# Loops over quarters, never over banks.

HISTORY_START <- 19840331L   # first quarter in the FDIC API
PAGE_SIZE     <- 10000L

# Call Report fields each research module reads, copied from its code
# (docs/specs/research-pipeline.md, "The FDIC raw file gets wider"). Kept
# whole per module, overlap with APP_FIELDS included, so each list can be
# checked against its source file.
RESEARCH_NEEDS <- list(
  # research/unrealized-losses/estimator.R UL_FIELDS
  hidden_loss = c(
    "CERT", "NAMEFULL", "STALP", "RISDATE", "ASSET", "EQTOT", "RBCT1J", "EQCCOMPI",
    "DEP", "DEPDOM", "DEPUNINS",
    "SCAA", "SCAF", "SCHA", "SCHF", "SC", "ISCQ",
    "LNLSGR", "LNRE", "LNRERES", "LNRENRES", "LNREMULT", "LNRECONS", "LNREAG",
    "LNAG", "LNCI", "LNCON", "ILNLSQ", "ILNDOMQ", "ILNFORQ",
    # loans by remaining maturity / repricing: 1-4 family first lien, other
    "LNRS3LES", "LNRS3T12", "LNRS1T3", "LNRS3T5", "LNRS5T15", "LNRSOV15",
    "LNOT3LES", "LNOT3T12", "LNOT1T3", "LNOT3T5", "LNOT5T15", "LNOTOV15",
    # securities by remaining maturity / repricing, other MBS
    "SCNM3LES", "SCNM3T12", "SCNM1T3", "SCNM3T5", "SCNM5T15", "SCNMOV15",
    "SCPT3LES", "SCPT3T12", "SCPT1T3", "SCPT3T5", "SCPT5T15", "SCPTOV15",
    "SCO3YLES", "SCOOV3Y"),
  # research/backtest/01_fetch.R: UL_FIELDS plus these
  backtest = c("RBC1AAJ", "RSSDID"),
  # research/run-stress/01_fetch.R FIELDS and simulate.R SIM_FIELDS
  run_stress = c("CHBAL", "FREPO", "TRADE", "INTAN", "LNLSNET", "OTHBFHLB",
                 "DEPINS", "SCPLEDGE", "DEP", "DEPUNINS", "RBCT1J", "ASSET",
                 "SCAA", "SCAF", "SCHA", "SCHF")
)

# What the research modules add to the app's fields. Stored in raw, but
# no existing mart reads them (latest_snapshot drops them).
RESEARCH_FIELDS <- setdiff(unique(unlist(RESEARCH_NEEDS)),
                           c(strsplit(APP_FIELDS, ",")[[1]], "CITY"))
RAW_FIELDS <- paste(c(APP_FIELDS, "CITY", RESEARCH_FIELDS), collapse = ",")

# The quarters to pull, newest first: the last n, or the newest plus an
# explicit sample (sample = integer vector, or NULL)
fdic_quarters <- function(newest, n, sample = NULL) {
  if (!is.null(sample)) {
    return(sort(unique(c(newest, sample)), decreasing = TRUE))
  }
  quarters <- newest
  while (length(quarters) < n &&
         quarters[length(quarters)] > HISTORY_START) {
    quarters <- c(quarters, prev_quarter_end(quarters[length(quarters)]))
  }
  quarters
}

# Every bank for one quarter, paging past the 10k cap, sorted by CERT so
# the file is deterministic and diffs line up.
pull_quarter <- function(rd) {
  pages <- list(); offset <- 0L; total <- NA_integer_
  repeat {
    body <- fdic_query(FDIC_FINANCIALS_ENDPOINT, list(
      filters = paste0("RISDATE:", rd), fields = RAW_FIELDS,
      sort_by = "CERT", sort_order = "ASC",
      limit = PAGE_SIZE, offset = offset
    ))
    total <- as.integer(body$meta$total)
    page  <- flatten_body(body)
    if (is.null(page) || nrow(page) == 0) break
    pages[[length(pages) + 1]] <- page
    offset <- offset + nrow(page)
    if (offset >= total) break
  }
  if (length(pages) == 0) return(NULL)
  df <- do.call(rbind, pages)
  df$ID <- NULL                                  # "CERT_RISDATE", redundant
  if (nrow(df) != total) stop("Quarter ", rd, ": got ", nrow(df), " of ", total)
  if (anyDuplicated(df$CERT)) stop("Quarter ", rd, ": duplicate CERTs")
  df <- df[order(df$CERT), c("CERT", setdiff(sort(names(df)), "CERT"))]
  rownames(df) <- NULL
  df
}

# Pull each quarter, diff it against the stored copy and overwrite it.
# Returns this run's manifest rows and the list of revision tables.
pull_fdic <- function(quarters, seen) {
  manifest <- list(); revisions <- list()
  for (rd in quarters) {
    t1 <- Sys.time()
    df <- pull_quarter(rd)
    if (is.null(df)) stop("Quarter ", rd, " came back empty")
    s <- store_quarter(df, rd, seen, t1)
    manifest[[length(manifest) + 1]] <- s$manifest
    if (!is.null(s$revisions)) revisions[[length(revisions) + 1]] <- s$revisions
  }
  list(manifest = do.call(rbind, manifest), revisions = revisions)
}

# Critical: any error stops the run before anything is published. Returns
# the merged raw manifest.
SOURCE_FDIC <- list(
  name = "fdic", critical = TRUE, cadence = "nightly", max_age_days = NA,
  run = function(ctx) {
    pulled <- pull_fdic(ctx$quarters, ctx$seen)
    manifest <- save_manifest(pulled$manifest)
    append_revisions(pulled$revisions)
    manifest
  },
  last_pull = function() as.POSIXct(NA)
)
