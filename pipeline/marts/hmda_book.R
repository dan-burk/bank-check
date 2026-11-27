# Mart: hmda_book, the HMDA mortgage book of each bank valued at the newest
# quarter end: hb_value() (R/hmda_book.R) on the stored hmda.groups (written
# yearly by sources/hmda.R) with tonight's rates_monthly, joined to the
# newest raw call report. One row per CERT that has HMDA groups and filed
# in the newest quarter (a CERT that has since merged or failed is dropped
# and counted). Not read by the app (NO_DEPLOY in pipeline.yml).
#
# Columns ($ thousands; rates, losses and shares as decimals):
#   CERT, RISDATE         RISDATE = the valuation date (newest quarter)
#   kept_k, valued_share, bal_k, pv_k, wac, mkt_rate, duration, loss_pv,
#   loss_dur, hmda_year_max   from hb_value()
#   book_k                1-4 family closed-end first liens in the call report
#                         (the LNRS* maturity buckets, RC-C memo 2.a, as in
#                         hidden_loss): the same loans HMDA's filter keeps
#   hmda_share            bal_k / book_k: how much of that book HMDA explains
#                         (the rest is pre-2018 loans, purchased loans, or
#                         loans HMDA does not capture; above 1 when the bank
#                         sold kept loans later)
#   na_reason             why a value is NA (reasons joined by "; ")
#   method_version        HB_PARAMS$method_version

# The stored groups (SOURCE_HMDA's nightly run() has checked the file)
read_hmda_groups <- function(path = file.path(RAW, "hmda.groups.parquet")) {
  as.data.frame(read_parquet(path, col_select = HB_GROUP_COLS))
}

# Pure: groups + the newest raw quarter (CERT, RISDATE, HL_LN_RES) + rates
# -> list(mart, dropped = CERTs with groups but no filing that quarter)
build_hmda_book <- function(groups, cur, rates, params = HB_PARAMS) {
  rd <- as.integer(cur$RISDATE[1])
  v <- hb_value(groups, rates, rd, params)
  m <- match(v$CERT, cur$CERT)
  dropped <- v$CERT[is.na(m)]
  v <- v[!is.na(m), ]
  book <- rowSums(as.matrix(cur[m[!is.na(m)], HL_LN_RES]))   # NA if a bucket is NA
  v$book_k <- book
  v$hmda_share <- ifelse(!is.na(book) & book > 0, v$bal_k / book, NA_real_)
  why_book <- ifelse(is.na(book), "no 1-4 family first-lien buckets in the call report",
                ifelse(book <= 0, "no 1-4 family first liens in the call report", NA_character_))
  v$na_reason <- ifelse(is.na(v$na_reason), why_book,
                   ifelse(is.na(why_book), v$na_reason, paste(v$na_reason, why_book, sep = "; ")))
  v$RISDATE <- rd
  v$method_version <- params$method_version
  # Rounded to what the inputs carry, so the file compresses
  for (c in c("kept_k", "bal_k", "pv_k", "book_k")) v[[c]] <- round(v[[c]])
  for (c in c("valued_share", "wac", "mkt_rate", "loss_pv", "loss_dur", "hmda_share")) {
    v[[c]] <- round(v[[c]], 5)
  }
  v$duration <- round(v$duration, 3)
  cols <- c("CERT", "RISDATE", "kept_k", "valued_share", "bal_k", "pv_k", "wac", "mkt_rate",
            "duration", "loss_pv", "loss_dur", "book_k", "hmda_share", "hmda_year_max",
            "na_reason", "method_version")
  out <- v[cols]
  rownames(out) <- NULL
  list(mart = out, dropped = dropped)
}

# Every bank's groups valued as one book (CERT 0), for the check
hmda_book_pooled <- function(groups, rates, rd, params = HB_PARAMS) {
  groups$CERT <- 0L
  hb_value(groups, rates, rd, params)
}

# Two lines per run: the headline, what was not computed, and the
# duration cross-check per bank (reported, not failed: checks/hmda_book.R)
report_hmda_book <- function(hb, dropped, pooled) {
  d <- abs(hb$loss_pv - hb$loss_dur)
  off <- which(d > HB_DUR_TOL)
  cat(sprintf(paste0("hmda_book %d: %d banks (%d valued), HMDA through %d; balance $%.0fB; ",
                     "%d CERTs with groups not filing (dropped); reasons: %s\n"),
              hb$RISDATE[1], nrow(hb), sum(!is.na(d)), max(hb$hmda_year_max), sum(hb$bal_k) / 1e6,
              length(dropped),
              paste(names(table(hb$na_reason)), table(hb$na_reason), sep = " x", collapse = " | ")))
  cat(sprintf(paste0("hmda_book pooled: WAC %.2f%%, loss %.2f%% (PV) vs %.2f%% (duration %.2f x gap); ",
                     "%d of %d banks more than 1 point apart (%.0f%% of balance); %d with hmda_share > 1\n"),
              100 * pooled$wac, 100 * pooled$loss_pv, 100 * pooled$loss_dur, pooled$duration,
              length(off), sum(!is.na(d)), 100 * sum(hb$bal_k[off]) / sum(hb$bal_k),
              sum(hb$hmda_share > 1, na.rm = TRUE)))
}
