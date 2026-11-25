# Run-stress step 2: run the simulator on the latest quarter and the
# validation quarters, and write the tables.
# Run from the repo root:  Rscript research/run-stress/02_run.R
#   grid.csv         s x (uninsured / all deposits) x (FHLB off / on): banks and assets that break
#   top20_latest.csv the 20 most fragile banks in the latest quarter
#   validation.csv   breaking-point rank vs Tier 1 rank for every 2022+ failure
#   example.txt      one bank's run, numbers end to end (README walk-through)
#   summary.txt      everything above in plain text

source("research/run-stress/simulate.R")
DIR <- "research/run-stress"
PUB_LAG <- 45   # days from quarter end until the call report is public

avail_q <- sort(as.integer(sub("extra_(\\d+)\\.rds", "\\1",
                               list.files(RS_CACHE, "^extra_\\d+\\.rds$"))))
LATEST <- max(avail_q)
VALID_Q <- c(20211231L, 20221231L, 20231231L)
CONFIGS <- list(unins = list(base = "unins", fhlb = FALSE),
                unins_fhlb = list(base = "unins", fhlb = TRUE),
                all = list(base = "all", fhlb = FALSE),
                all_fhlb = list(base = "all", fhlb = TRUE))

# Failures since 2022 and the last quarter public before each failure
fl <- read.csv("research/backtest/failures.csv")
fl$fail_date <- as.Date(fl$fail_date)
qdate <- function(q) as.Date(as.character(q), "%Y%m%d")
fl$q <- sapply(fl$fail_date, function(fd) max(avail_q[qdate(avail_q) + PUB_LAG < fd]))

quarters <- sort(unique(c(LATEST, VALID_Q, fl$q)))
res <- list()
for (q in quarters) {
  d <- load_quarter(q)
  message(q, ": ", nrow(d), " banks (", attr(d, "dropped"), " dropped for missing inputs)")
  bps <- lapply(CONFIGS, function(cf) breaking_point(d, base = cf$base, fhlb = cf$fhlb))
  grid <- do.call(rbind, lapply(names(CONFIGS), function(k) {
    cf <- CONFIGS[[k]]
    do.call(rbind, lapply(S_GRID, function(s) {
      r <- run_sim(d, s, base = cf$base, fhlb = cf$fhlb)
      data.frame(quarter = q, run_on = cf$base, fhlb = cf$fhlb, s = s,
                 banks = nrow(d), breaks = sum(r$fails), below_2pct = sum(r$crit),
                 cant_pay = sum(r$cant_pay), below_4pct = sum(r$under),
                 assets_break_bn = sum(d$ASSET[r$fails]) / 1e6)
    }))
  }))
  res[[as.character(q)]] <- list(d = d, bps = bps, grid = grid)
}

# Curves for the chart: banks / assets that break at every s on S_FINE
curves <- do.call(rbind, lapply(c(20221231L, LATEST), function(q) {
  d <- res[[as.character(q)]]$d
  do.call(rbind, lapply(names(CONFIGS), function(k) {
    cf <- CONFIGS[[k]]
    do.call(rbind, lapply(S_FINE, function(s) {
      r <- run_sim(d, s, base = cf$base, fhlb = cf$fhlb)
      data.frame(quarter = q, run_on = cf$base, fhlb = cf$fhlb, s = s,
                 breaks = sum(r$fails), assets_break_bn = sum(d$ASSET[r$fails]) / 1e6)
    }))
  }))
}))
write.csv(curves, file.path(DIR, "curves.csv"), row.names = FALSE)

r1 <- function(x) round(x, 1)
grid <- do.call(rbind, lapply(res, `[[`, "grid"))
grid$assets_break_bn <- r1(grid$assets_break_bn)
write.csv(grid, file.path(DIR, "grid.csv"), row.names = FALSE)

# ---- Per-bank table for a quarter -------------------------------------------
bank_table <- function(q) {
  x <- res[[as.character(q)]]; d <- x$d
  t <- data.frame(CERT = d$CERT, name = d$NAMEFULL, state = d$STALP,
                  assets_bn = d$ASSET / 1e6,
                  unins_share = d$DEPUNINS / d$DEP,
                  tier1_lev = d$RBC1AAJ / 100,
                  sec_loss_to_t1 = (d$SCAA - d$SCAF + d$SCHA - d$SCHF) / d$RBCT1J,
                  loan_disc = d$loan_disc)
  for (k in names(CONFIGS)) {
    t[[paste0("bp_", k)]] <- x$bps[[k]]$bp
    t[[paste0("rank_", k)]] <- bp_rank(x$bps[[k]])
  }
  t$how_unins <- x$bps$unins$how
  t$rank_tier1 <- rank(t$tier1_lev, ties.method = "min", na.last = "keep")
  t$n <- nrow(t)
  t
}

lt <- bank_table(LATEST)
# Most fragile first: breaks under an uninsured run (smallest first), then
# under an all-deposit run (smallest first), then all-deposit rank.
top <- head(lt[order(ifelse(is.na(lt$bp_unins), 2, lt$bp_unins),
                     lt$rank_all), ], 20)
top$fragile_rank <- seq_len(nrow(top))
top_out <- transform(top, assets_bn = round(assets_bn, 2), unins_share = round(unins_share, 3),
                     tier1_lev = round(tier1_lev, 4), sec_loss_to_t1 = round(sec_loss_to_t1, 3),
                     loan_disc = round(loan_disc, 3))
write.csv(top_out[c("fragile_rank", "CERT", "name", "state", "assets_bn", "unins_share",
                    "tier1_lev", "sec_loss_to_t1", "loan_disc", "bp_unins", "how_unins",
                    "bp_unins_fhlb", "bp_all", "bp_all_fhlb", "rank_tier1")],
          file.path(DIR, "top20_latest.csv"), row.names = FALSE)

# ---- Validation ---------------------------------------------------------------
# (a) the validation quarters: every 2022+ failure still alive in that quarter
# (b) "any era": each failure in the last quarter public before it failed
val <- list()
for (q in VALID_Q) {
  t <- bank_table(q)
  ids <- fl$CERT[fl$fail_date > qdate(q)]
  v <- t[t$CERT %in% ids, ]
  if (nrow(v)) val[[length(val) + 1]] <- cbind(check = paste0("quarter ", q), quarter = q, v)
}
for (i in seq_len(nrow(fl))) {
  t <- bank_table(fl$q[i]); v <- t[t$CERT == fl$CERT[i], ]
  if (nrow(v)) val[[length(val) + 1]] <- cbind(check = "last public quarter", quarter = fl$q[i], v)
}
val <- do.call(rbind, val)
val$fail_date <- fl$fail_date[match(val$CERT, fl$CERT)]
val$group <- fl$group[match(val$CERT, fl$CERT)]
val_out <- val[c("check", "quarter", "CERT", "name", "fail_date", "group", "assets_bn",
                 "unins_share", "tier1_lev", "bp_unins", "rank_unins", "bp_unins_fhlb",
                 "rank_unins_fhlb", "bp_all", "rank_all", "rank_tier1", "n")]
val_out$assets_bn <- round(val_out$assets_bn, 2)
val_out$unins_share <- round(val_out$unins_share, 3)
val_out$tier1_lev <- round(val_out$tier1_lev, 4)
write.csv(val_out, file.path(DIR, "validation.csv"), row.names = FALSE)

# ---- Worked example: SVB, 2022Q4, 40% of uninsured deposits leave ---------------
ex_d <- res[["20221231"]]$d; ex <- ex_d[ex_d$CERT == 24735, ]
ex_s <- 0.40
er <- run_sim(ex, ex_s, base = "unins")
bn <- function(x) sprintf("%8.1f", x / 1e6)
example <- c(
  sprintf("Silicon Valley Bank, 2022Q4 call report, run = %.0f%% of uninsured deposits", 100 * ex_s),
  "($ billions)",
  paste("Total assets              ", bn(ex$ASSET)),
  paste("Deposits / uninsured      ", bn(ex$DEP), "/", bn(ex$DEPUNINS)),
  paste("Tier 1 capital            ", bn(ex$RBCT1J), sprintf("  (%.2f%% of assets)", 100 * ex$RBCT1J / ex$ASSET)),
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
          100 * res[["20221231"]]$bps$unins$bp[ex_d$CERT == 24735]))
writeLines(example, file.path(DIR, "example.txt"))

# ---- Summary ----------------------------------------------------------------------
pct <- function(x) ifelse(is.na(x), "never", sprintf("%.1f%%", 100 * x))
sink(file.path(DIR, "summary.txt"))
cat("Run-stress simulator. Latest quarter:", LATEST, "\n\n")
cat("== Banks that break (below 2% or can't pay) by run size ==\n")
print(grid[grid$quarter %in% c(LATEST, 20221231), c("quarter", "run_on", "fhlb", "s", "banks",
       "breaks", "below_2pct", "cant_pay", "below_4pct", "assets_break_bn")], row.names = FALSE)
cat("\n== Breaking point distribution, latest quarter ==\n")
for (k in names(CONFIGS)) cat(sprintf("%-11s broke at <=100%%: %4d banks; at <=50%%: %4d; <=20%%: %4d\n", k,
    sum(!is.na(lt[[paste0("bp_", k)]])), sum(lt[[paste0("bp_", k)]] <= .5, na.rm = TRUE),
    sum(lt[[paste0("bp_", k)]] <= .2, na.rm = TRUE)))
cat("\n== Top 20 most fragile, latest quarter (uninsured run first, then all-deposit run) ==\n")
print(transform(top_out[c("fragile_rank", "name", "state", "assets_bn", "unins_share", "tier1_lev",
                          "bp_unins", "how_unins", "bp_unins_fhlb", "bp_all", "bp_all_fhlb", "rank_tier1")],
                name = substr(name, 1, 34)), row.names = FALSE)
cat("\n== Top 10 by breaking point, 2022Q4 (uninsured run, FHLB off) ==\n")
t22 <- bank_table(20221231L)
print(transform(head(t22[order(t22$rank_unins), c("rank_unins", "name", "state", "assets_bn",
      "unins_share", "tier1_lev", "bp_unins", "how_unins", "bp_all", "rank_tier1")], 10),
      name = substr(name, 1, 34), assets_bn = round(assets_bn, 2)), row.names = FALSE)
cat("\n== Validation ==\n")
print(transform(val_out[c("check", "quarter", "name", "group", "bp_unins", "rank_unins",
                          "rank_unins_fhlb", "bp_all", "rank_all", "rank_tier1", "n")],
                name = substr(name, 1, 26)), row.names = FALSE)
cat("\n"); writeLines(example)
sink()
message("done")
