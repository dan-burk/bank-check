# Mart: run_stress, the simulator in R/run_stress.R run on the newest raw
# quarter, with each bank's loan discount from tonight's hidden_loss mart.
# One row per filer (CERT, RISDATE). research/run-stress runs the same
# functions on older quarters (raw + hidden_loss_history).
#
# Columns ($ thousands; ratios and run sizes as decimals):
#   ASSET, RBCT1J, t1_ratio      the bank before the run
#   unins_share                  DEPUNINS / DEPDOM (uninsured_share())
#   loan_disc                    loan sale discount from hidden_loss
#   for each run k in unins, unins_fhlb, all, all_fhlb (RS_CONFIGS):
#     bp_k          breaking point: smallest run (share of uninsured / all
#                   deposits, steps of 0.005) that breaks the bank; NA if
#                   it never breaks or the inputs are missing (see how_k)
#     how_k         "below 2%", "can't pay", "never", or NA (inputs missing)
#     min_ratio_k   lowest Tier 1 / assets reached on the way
#     pct_worst_k   share of ranked banks at least as fragile (small = worse)
#   na_reason       inputs missing, or why the bank is not ranked
#   method_version  RS_PARAMS$method_version

RS_RATIOS <- c("t1_ratio", "unins_share", "loan_disc",
               paste0(rep(c("min_ratio_", "pct_worst_"), each = length(RS_CONFIGS)),
                      names(RS_CONFIGS)))

# f: the newest raw quarter file; hl: the hidden_loss mart (any quarters).
# Ratios rounded to 5 decimals, breaking points to the 0.005 grid.
build_run_stress <- function(f, hl, params = RS_PARAMS) {
  cur <- as.data.frame(read_parquet(f, col_select = RS_FIELDS))
  rd <- as.integer(cur$RISDATE[1])
  hlq <- hl[hl$RISDATE == rd, ]
  if (!nrow(hlq)) stop("hidden_loss has no rows for ", rd)
  rs <- run_stress(cur, hlq, params)
  for (v in RS_RATIOS) rs[[v]] <- round(rs[[v]], 5)
  for (k in names(RS_CONFIGS)) rs[[paste0("bp_", k)]] <- round(rs[[paste0("bp_", k)]], 3)
  list(mart = rs, inputs = rs_inputs(cur, hlq, params))
}

# One line per run: banks that break in each run, and the NA count
report_run_stress <- function(rs) {
  brk <- vapply(names(RS_CONFIGS), function(k) {
    h <- rs[[paste0("how_", k)]]
    sprintf("%s %d", k, sum(h %in% c("below 2%", "can't pay")))
  }, "")
  n_na <- sum(rowSums(is.na(rs[paste0("how_", names(RS_CONFIGS))])) > 0)
  cat(sprintf("run_stress %d: %d filers; break at <= 100%%: %s; %d with an NA run; reasons: %s\n",
              rs$RISDATE[1], nrow(rs), paste(brk, collapse = ", "), n_na,
              paste(names(table(rs$na_reason)), table(rs$na_reason), sep = " x", collapse = " | ")))
}
