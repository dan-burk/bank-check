# Run stress: the tables behind README.md, from the published releases. The
# simulator is pipeline/R/run_stress.R (the run_stress mart calls the same
# functions); this script fetches nothing. It runs the simulator on the
# older quarters from raw + hidden_loss_history, and checks that the newest
# quarter matches the published run_stress mart. Run from the repo root
# after downloading:
#   gh release download data-marts --dir pipeline/out/marts --pattern 'hidden_loss_history.parquet'
#   gh release download data-marts --dir pipeline/out/marts --pattern 'run_stress.parquet'
#   gh release download data-marts --dir pipeline/out/marts --pattern 'bank_ids.parquet'
#   gh release download data-raw   --dir pipeline/out/raw   --pattern 'risdate.20*.parquet'
#   gh release download data-raw   --dir pipeline/out/raw   --pattern 'failures.parquet'
#   Rscript research/run-stress/analyze.R
# Writes summary.txt and example.txt here, and curves.csv and
# validation.csv (for chart.R) to research/run-stress/out/ (gitignored).
# Dollars are $ thousands.

suppressPackageStartupMessages(library(nanoparquet))
options(width = 200)
source("app/R/api.R")                    # prev_quarter_end()
for (f in c("R/hidden_loss.R", "R/run_stress.R")) source(file.path("pipeline", f))
DIR <- "research/run-stress"
dir.create(file.path(DIR, "out"), showWarnings = FALSE)
rd <- function(f, ...) as.data.frame(read_parquet(file.path("pipeline", "out", f), ...))

PUB_LAG <- 45                            # days from quarter end until the call report is public
VALID_Q <- c(20211231L, 20221231L, 20231231L)   # before, at and after the 2023 runs
STRESS  <- 20221231L
S_GRID  <- c(0.05, 0.10, 0.20, 0.30, 0.50)
# The analyst's reading of why each bank failed: these four failed from
# rate losses plus a run; the other failures since 2022 were credit or fraud
RATE_RUN <- c(24735L, 57053L, 59017L, 27332L)   # SVB, Signature, First Republic, Republic First

hl  <- rd("marts/hidden_loss_history.parquet",
          col_select = c("CERT", "RISDATE", "loss_loans_res", "loss_loans_oth"))
mart <- rd("marts/run_stress.parquet")
ids <- rd("marts/bank_ids.parquet")
LATEST <- mart$RISDATE[1]

# Failures since 2022 (FAILURE only, as the app) and, for each, the last
# quarter that was public before it failed, from every raw quarter on hand
qdate <- function(q) as.Date(as.character(q), "%Y%m%d")
avail_q <- sort(as.integer(sub("risdate\\.(\\d+)\\.parquet", "\\1",
                               list.files("pipeline/out/raw", "^risdate\\.\\d+\\.parquet$"))))
fl <- rd("raw/failures.parquet")
fl$fail_date <- as.Date(fl$FAILDATE, "%m/%d/%Y")
stopifnot(!anyNA(fl$fail_date))
fl <- fl[fl$RESTYPE == "FAILURE" & fl$fail_date >= as.Date("2022-01-01"), c("CERT", "NAME", "fail_date")]
fl$CERT <- as.integer(fl$CERT)
fl$q <- vapply(fl$fail_date, function(fd) max(avail_q[qdate(avail_q) + PUB_LAG < fd]), 0L)
fl$group <- ifelse(fl$CERT %in% RATE_RUN, "rate+run", "credit/fraud")

# One quarter: simulator inputs, every run's result, and the Tier 1 leverage ratio
quarters <- sort(unique(c(LATEST, VALID_Q, fl$q)))
stopifnot(all(quarters %in% avail_q))
res <- list()
for (q in quarters) {
  cur <- rd(sprintf("raw/risdate.%d.parquet", q), col_select = c(RS_FIELDS, "RBC1AAJ"))
  h <- hl[hl$RISDATE == q, ]
  rs <- run_stress(cur, h)
  rs$tier1_lev <- as.numeric(cur$RBC1AAJ) / 100
  res[[as.character(q)]] <- list(d = rs_inputs(cur, h), rs = rs)
  message(q, ": ", nrow(rs), " filers, ", sum(!is.na(rs$pct_worst_unins)), " ranked")
}
# Same code, same numbers: the newest quarter equals the published mart
lt <- res[[as.character(LATEST)]]$rs
for (k in names(RS_CONFIGS)) {
  stopifnot(identical(round(lt[[paste0("bp_", k)]], 3), mart[[paste0("bp_", k)]]),
            identical(lt[[paste0("how_", k)]], mart[[paste0("how_", k)]]))
}

# Banks and assets that break at run size s, over the banks with that run
breaks_at <- function(q, k, s) {
  x <- res[[as.character(q)]]; cf <- RS_CONFIGS[[k]]
  ok <- !is.na(x$rs[[paste0("how_", k)]])
  d <- x$d[ok, ]
  r <- run_sim(d, s, cf$base, cf$fhlb)
  data.frame(quarter = q, run = k, s = s, banks = nrow(d), breaks = sum(r$fails),
             below_2pct = sum(r$crit), cant_pay = sum(r$cant_pay), below_4pct = sum(r$under),
             assets_break_bn = round(sum(d$ASSET[r$fails]) / 1e6, 1))
}
grid <- do.call(rbind, lapply(c(STRESS, LATEST), function(q) do.call(rbind, lapply(names(RS_CONFIGS),
  function(k) do.call(rbind, lapply(S_GRID, function(s) breaks_at(q, k, s)))))))
curves <- do.call(rbind, lapply(c(STRESS, LATEST), function(q) do.call(rbind, lapply(names(RS_CONFIGS),
  function(k) do.call(rbind, lapply(RS_PARAMS$s_fine, function(s) breaks_at(q, k, s)))))))
write.csv(curves[c("quarter", "run", "s", "breaks", "assets_break_bn")],
          file.path(DIR, "out", "curves.csv"), row.names = FALSE)

# Per-bank table for a quarter: ranks among the banks ranked in that run
# (1 = most fragile; NA = not ranked, never "safest")
bank_table <- function(q) {
  rs <- res[[as.character(q)]]$rs
  t <- data.frame(CERT = rs$CERT, name = substr(ids$NAMEFULL[match(rs$CERT, ids$CERT)], 1, 34),
                  assets_bn = round(rs$ASSET / 1e6, 2), unins_share = round(rs$unins_share, 3),
                  tier1_lev = round(rs$tier1_lev, 4), loan_disc = round(rs$loan_disc, 3))
  for (k in names(RS_CONFIGS)) {
    t[[paste0("bp_", k)]] <- rs[[paste0("bp_", k)]]
    t[[paste0("rank_", k)]] <- rs_rank(rs[[paste0("bp_", k)]], rs[[paste0("min_ratio_", k)]],
                                       !is.na(rs[[paste0("pct_worst_", k)]]))
  }
  t$how_unins <- rs$how_unins
  ranked <- !is.na(t$rank_unins)
  t$rank_tier1 <- rank(replace(t$tier1_lev, !ranked, NA), ties.method = "min", na.last = "keep")
  t$n <- sum(ranked)
  t
}

lt <- bank_table(LATEST)
rk <- lt[!is.na(lt$rank_all), ]   # most fragile first: uninsured run, then all-deposit run
top <- utils::head(rk[order(ifelse(is.na(rk$bp_unins), 2, rk$bp_unins), rk$rank_all), ], 20)

# Validation: (a) every 2022+ failure alive in each validation quarter;
# (b) each failure in the last quarter public before it failed
val <- list()
for (q in VALID_Q) {
  v <- bank_table(q); v <- v[v$CERT %in% fl$CERT[fl$fail_date > qdate(q)], ]
  if (nrow(v)) val[[length(val) + 1]] <- cbind(check = paste("quarter", q), quarter = q, v)
}
for (i in seq_len(nrow(fl))) {
  v <- bank_table(fl$q[i]); v <- v[v$CERT == fl$CERT[i], ]
  if (nrow(v)) val[[length(val) + 1]] <- cbind(check = "last public quarter", quarter = fl$q[i], v)
}
val <- do.call(rbind, val)
val$fail_date <- fl$fail_date[match(val$CERT, fl$CERT)]
val$group <- fl$group[match(val$CERT, fl$CERT)]
val_cols <- c("check", "quarter", "CERT", "name", "fail_date", "group", "assets_bn", "unins_share",
              "tier1_lev", "bp_unins", "rank_unins", "bp_unins_fhlb", "rank_unins_fhlb", "bp_all",
              "rank_all", "rank_tier1", "n")
write.csv(val[val_cols], file.path(DIR, "out", "validation.csv"), row.names = FALSE)

# Worked example: SVB, 2022Q4, 40% of uninsured deposits leave
x <- res[[as.character(STRESS)]]
ex <- x$d[x$d$CERT == 24735, ]
ex_s <- 0.40
er <- run_sim(ex, ex_s, "unins")
bn <- function(v) sprintf("%8.1f", v / 1e6)
example <- c(
  sprintf("Silicon Valley Bank, 2022Q4 call report, run = %.0f%% of uninsured deposits", 100 * ex_s),
  "($ billions)",
  paste("Total assets              ", bn(ex$ASSET)),
  paste("Deposits / uninsured      ", bn(ex$DEP), "/", bn(ex$DEPUNINS),
        sprintf(" (%.1f%% of domestic deposits)", 100 * ex$unins_share)),
  paste("Tier 1 capital            ", bn(ex$RBCT1J), sprintf("  (%.2f%% of assets)", 100 * ex$t1_ratio)),
  paste("Cash needed               ", bn(er$need)),
  "Where the cash comes from:",
  paste("  cash above 2% floor     ", bn(er$from_cash), "  of", bn(ex$CHBAL), "cash on hand"),
  paste("  fed funds + repos       ", bn(er$from_ffrp)),
  paste("  trading assets          ", bn(er$from_trade)),
  paste("  AFS securities          ", bn(er$from_afs), "  of", bn(ex$SCAF),
        sprintf(" (cost %s, so %.1f%% loss realized)", trimws(bn(ex$SCAA)), 100 * (ex$SCAA - ex$SCAF) / ex$SCAA)),
  paste("  HTM securities          ", bn(er$from_htm), "  of", bn(ex$SCHF),
        sprintf(" fair value (book %s, %.1f%% loss)", trimws(bn(ex$SCHA)), 100 * (ex$SCHA - ex$SCHF) / ex$SCHA)),
  paste("  loans                   ", bn(er$from_loans)),
  paste("Realized loss (hits Tier 1)", bn(er$loss)),
  paste("Tier 1 after              ", bn(er$t1_after)),
  paste("Assets after              ", bn(er$asset_after)),
  sprintf("Ratio after                %8.2f%%  (2%% = critically undercapitalized)", 100 * er$ratio_after),
  sprintf("Breaking point (uninsured run, FHLB off): %.1f%%",
          100 * x$rs$bp_unins[x$rs$CERT == 24735]))
writeLines(example, file.path(DIR, "example.txt"))

# Summary
show <- function(d) capture.output(print(d, row.names = FALSE))
dist <- vapply(names(RS_CONFIGS), function(k) {
  b <- lt[[paste0("bp_", k)]]
  sprintf("%-11s broke at <=100%%: %4d banks; at <=50%%: %4d; <=20%%: %4d", k,
          sum(!is.na(b)), sum(b <= .5, na.rm = TRUE), sum(b <= .2, na.rm = TRUE))
}, "")
t22 <- bank_table(STRESS)
na_tab <- table(mart$na_reason)
out <- c(
  sprintf("Run-stress simulator (%s). Latest quarter: %d (%d filers; %d ranked in the uninsured run)",
          RS_PARAMS$method_version, LATEST, nrow(lt), lt$n[1]),
  "Not run or not ranked, latest quarter:", paste0("  ", names(na_tab), " x", na_tab),
  sprintf("Failures since 2022 and the quarter used: %s",
          paste(sprintf("%s %d", fl$CERT, fl$q), collapse = ", ")),
  "", "== Banks that break (below 2% or can't pay) by run size ==", show(grid),
  "", "== Breaking point distribution, latest quarter ==", dist,
  "", "== Top 20 most fragile, latest quarter (uninsured run first, then all-deposit run) ==",
  show(top[c("name", "assets_bn", "unins_share", "tier1_lev", "bp_unins", "how_unins",
             "bp_unins_fhlb", "bp_all", "bp_all_fhlb", "rank_tier1")]),
  "", sprintf("== Top 10 by breaking point, %d (uninsured run, FHLB off; %d ranked) ==", STRESS, t22$n[1]),
  show(utils::head(t22[order(t22$rank_unins), c("rank_unins", "name", "assets_bn", "unins_share",
                                                 "tier1_lev", "bp_unins", "how_unins", "bp_all",
                                                 "rank_tier1")], 10)),
  "", "== Validation ==",
  show(transform(val[c("check", "quarter", "name", "group", "bp_unins", "rank_unins", "rank_unins_fhlb",
                       "bp_all", "rank_all", "rank_tier1", "n")], name = substr(name, 1, 26))),
  "", example)
writeLines(out, file.path(DIR, "summary.txt"))
cat(out, sep = "\n")
