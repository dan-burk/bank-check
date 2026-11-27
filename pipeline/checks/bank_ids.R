# Checks on bank_ids. Not a core mart: a failure holds back only this mart.
#   ids       build_bank_ids() result
#   newest    the newest quarter
#   n_filed   banks that filed for the newest quarter

BANK_IDS_RSSD_MIN <- 0.99   # share of the newest quarter's active filers with an RSSD

check_bank_ids <- function(ids, newest, n_filed) {
  check(!anyDuplicated(ids$CERT), "duplicate CERT in bank_ids")
  check(sum(ids$last_risdate == newest) == n_filed,
        "bank_ids newest-quarter filers disagree with latest_snapshot")
  act <- ids[ids$active & !is.na(ids$RSSD), ]
  dup <- unique(act$RSSD[duplicated(act$RSSD)])
  check(length(dup) == 0, paste("RSSD mapped to two active CERTs:",
                                paste(utils::head(dup, 5), collapse = ",")))
  cur <- ids[ids$active & ids$last_risdate == newest, ]
  share <- mean(!is.na(cur$RSSD))
  check(nrow(cur) > 0 && share >= BANK_IDS_RSSD_MIN,
        sprintf("only %.1f%% of active filers have an RSSD", 100 * share))
  # Reported, not failed: RSSD shared across inactive CERTs, CERTs that
  # changed RSSD, banks with no RSSD in any filing
  all_rssd <- ids$RSSD[!is.na(ids$RSSD)]
  cat(sprintf("bank_ids: %d CERTs, %d active; RSSD for %.2f%% of active filers, %d CERTs with none; %d CERTs with >1 RSSD; %d RSSDs on >1 CERT (any status)\n",
              nrow(ids), sum(ids$active), 100 * share, sum(is.na(ids$RSSD)),
              sum(ids$n_rssd > 1), length(unique(all_rssd[duplicated(all_rssd)]))))
  # HMDA LEI links (reported: the HMDA job checks the links themselves)
  check(all(is.na(ids$LEI) == is.na(ids$lei_source)), "LEI without a lei_source")
  lei <- ids$LEI[!is.na(ids$LEI)]
  cat(sprintf("bank_ids: LEI for %d CERTs (%d active); %d CERTs with >1 LEI over the years; %d LEIs on >1 CERT\n",
              length(lei), sum(ids$active & !is.na(ids$LEI)), sum(ids$n_lei > 1),
              length(unique(lei[duplicated(lei)]))))
}
