# Smoke test for the app: every plot builder returns a plotly object and
# every server output renders. Run from the repo root:
#   Rscript.exe app/tests/smoke.R
# Needs the pipeline marts in app/data/ (see pipeline/README.md); runs
# without network to FDIC.

library(shiny)
library(bslib)
library(plotly)
library(dplyr)

setwd("app")
source("R/api.R")
source("R/theme.R")
source("R/data.R")
source("R/plots.R")
source("R/statements.R")

# Two-bank fixture (Dacotah 1984+, First B&T) in raw API columns, so the
# test exercises derive() just as a live fetch would
BASE <- readRDS("tests/fixtures/sd_banks.rds") |> derive()
snap <- load_snapshot()
inst <- snapshot_institutions(snap)
PEER <- peer_stats(snapshot_cross_section(snap), FIELDS_META)
stopifnot(nrow(inst) > 3000, !anyNA(inst$NAME))
ind <- load_industry()
stopifnot(nrow(ind) >= 5, !is.unsorted(rev(ind$RISDATE)),
          ind$RISDATE[1] == max(snap$RISDATE, na.rm = TRUE))
cat("marts: snapshot", nrow(snap), "banks,", nrow(inst), "active; industry",
    nrow(ind), "quarters\n")
stopifnot(nrow(PEER) >= 15, all(c("p25", "p50", "p75") %in% names(PEER)))
cat("peer stats:", nrow(PEER), "metrics\n")

FAIL_PANEL <- load_fail_panel()
FAIL_META  <- load_fail_meta()
stopifnot(nrow(FAIL_META) > 500, !any(is.na(FAIL_META$region)),
          all(FAIL_META$n_filings > 0))
cat("fail panel:", nrow(FAIL_PANEL), "rows,", nrow(FAIL_META), "banks\n")

ok <- function(nm, p) {
  stopifnot(inherits(p, "plotly"))
  cat("ok:", nm, "\n")
}

dac <- BASE |> filter(label == "Dacotah (SD)")
fbt <- BASE |> filter(label == "First B&T (SD)")
banks <- list("Dacotah (SD)" = dac, "First B&T (SD)" = fbt)
cols  <- c("Dacotah (SD)" = "#2C5F8A", "First B&T (SD)" = "#0072B2")

# Every metric through the shared time-series builder, band included
for (code in FIELDS_META$code) {
  ok(paste("metric_ts", code),
     metric_ts(banks, code, FIELDS_META, cols, peer = peer_for(code, PEER)))
}
ok("metric_ts pct_assets",
   metric_ts(banks, "DEPUNINS", FIELDS_META, cols, display = "pct_assets"))
ok("metric_ts pct_loans",
   metric_ts(banks, "OTHBFHLB", FIELDS_META, cols, display = "pct_loans"))

# One axis, one unit: two banks straddling the $1B line must share one
# divisor (the regression behind the BankStar-vs-Dacotah 1000x inflation)
big   <- data.frame(date = dac$date, ASSET = dac$ASSET)        # ~$4.9B
small <- data.frame(date = dac$date, ASSET = dac$ASSET / 10)   # ~$490M
pb <- plotly::plotly_build(
  metric_ts(list(Big = big, Small = small), "ASSET", FIELDS_META,
            c(Big = "#2C5F8A", Small = "#E69F00"))
)
line_traces <- Filter(function(t) identical(t$mode, "lines"), pb$x$data)
stopifnot(length(line_traces) == 2)
maxes <- sapply(line_traces, function(t) max(unlist(t$y), na.rm = TRUE))
ratio <- max(maxes) / min(maxes)
stopifnot(abs(ratio - 10) < 0.5)   # true 10x asset gap survives on the axis
ttl <- pb$x$layout$yaxis$title
if (is.list(ttl)) ttl <- ttl$text
stopifnot(grepl("($B)", ttl, fixed = TRUE))
cat("ok: shared $ axis unit across mixed-size banks\n")

# Statements: every block adds up to FDIC's own total, and both tables
# render in every unit / comparison mode
for (d in list(dac, fbt)) {
  L <- statement_lines(d[nrow(d), ])
  r <- d[nrow(d), ]
  blk <- function(sec, from, to) {
    x <- L[L$section == sec, ]
    sum(x$value[(which(x$label == from) + 1):(which(x$label == to) - 1)],
        na.rm = TRUE)
  }
  stopifnot(abs(blk("bs", "Assets", "Total assets") - r$ASSET) < 1,
            abs(blk("bs", "Liabilities", "Total liabilities") - r$LIAB) < 1,
            abs(r$ASSET - r$LIAB - r$EQTOT) < 1)
  I <- L[L$section == "is", ]
  below_rev <- I$value[I$kind == "line" & seq_len(nrow(I)) > which(I$label == "Revenue")]
  stopifnot(abs(I$value[I$label == "Revenue"] + sum(below_rev) - r$NETINCQ) < 1,
            abs(I$pct[I$label == "Revenue"] - 100) < 1e-9)
  for (sec in c("bs", "is")) for (u in c("usd", "pct")) for (cm in c("qoq", "yoy")) {
    stopifnot(inherits(statement_table(d, sec, u, cm), "shiny.tag"))
  }
}
two <- statement_table(banks, "bs", "pct", cols = cols)
two_html <- as.character(two)
stopifnot(grepl("Dacotah (SD)", two_html, fixed = TRUE),
          grepl("First B&amp;T (SD)", two_html, fixed = TRUE),
          !grepl("vs Q", two_html, fixed = TRUE))   # no change column
cat("ok: statements add up and render in all modes, 1 or 2 banks\n")

# Industry totals: a summed cross-section is just another "bank" row
mini_xs <- dplyr::bind_rows(lapply(banks, function(d) d[which.max(d$RISDATE), ]))
tot <- industry_totals(mini_xs)
stopifnot(tot$n_banks == 2, abs(tot$ASSET - sum(mini_xs$ASSET)) < 1e-6,
          abs(tot$NETINCQ - sum(mini_xs$NETINCQ)) < 1e-6,
          inherits(statement_table(tot, "is", "pct", links = FALSE), "shiny.tag"))
cat("ok: industry totals sum the banks and render\n")

# No silent zeros: a field reported by banks holding < COVERAGE_MIN of
# assets is NA, never a partial sum; its line and "Other" show "–" while
# the totals still show
gap_xs <- mini_xs
gap_xs$SC[which.max(gap_xs$ASSET)] <- NA
gtot <- industry_totals(gap_xs)
stopifnot(is.na(gtot$SC), !is.na(gtot$ASSET),
          field_coverage(gap_xs)$asset_share[field_coverage(gap_xs)$field == "SC"] < COVERAGE_MIN)
gl <- statement_lines(gtot)
stopifnot(is.na(gl$value[gl$label == "Bonds"]),
          is.na(gl$value[gl$section == "bs" & gl$label == "Other"][1]),
          !is.na(gl$value[gl$label == "Total assets"]))
gh <- as.character(statement_table(gtot, "bs", links = FALSE))
stopifnot(grepl("–", gh, fixed = TRUE))
# Oldest industry quarter has no prior quarter: change column is "–"
old <- ind[ind$RISDATE == min(ind$RISDATE), ]
stopifnot(inherits(statement_table(old, "bs", links = FALSE), "shiny.tag"))
# History charts: a quarter with a forced NA field is a gap, not 0
ind_gap <- ind; ind_gap$SC[nrow(ind_gap)] <- NA
ind_long <- industry_long(ind)
for (sec in c("bs", "is")) for (u in c("usd", "pct")) {
  ok(paste("industry_history", sec, u), industry_history(ind_long, sec, u))
}
bt <- Filter(function(t) identical(t$name, "Bonds"),
             plotly::plotly_build(industry_history(industry_long(ind_gap), "bs"))$x$data)[[1]]
by <- unlist(bt$y)
stopifnot(sum(!is.na(by)) == sum(!is.na(ind$SC)) - 1, !any(by == 0, na.rm = TRUE))
cat("ok: missing coverage is NA (\"–\" in tables, gaps in charts), never 0\n")

# industry_long() (one vectorized statement_lines() call) equals the old
# per-quarter loop, NA gaps and quarters missing from the mart included
loop_long <- function(ind) {
  q <- max(ind$RISDATE)
  while (q[length(q)] > min(ind$RISDATE)) q <- c(q, prev_quarter_end(q[length(q)]))
  l <- do.call(rbind, lapply(q, function(rd) {
    l <- statement_lines(ind[ind$RISDATE == rd, ][1, ])
    l$label[l$section == "bs" & l$label == "Other"] <- c("Other assets", "Other liabilities")
    l$date <- as.Date(as.character(rd), "%Y%m%d")
    l[l$kind != "head", ]
  }))
  l <- l[order(l$date), ]
  rownames(l) <- NULL
  l
}
ind_odd <- ind_gap[-c(5, 80), ]                       # two quarters missing
ind_odd$NIMQ[3] <- -ind_odd$NONIIQ[3] - 1              # revenue < 0: is pct NA
for (x in list(ind, ind_odd)) stopifnot(identical(industry_long(x), loop_long(x)))
cat("ok: industry_long matches the per-quarter loop\n")

sel <- data.frame(
  label = names(banks),
  asset = sapply(banks, function(d) utils::tail(d$ASSET[!is.na(d$ASSET)], 1)),
  col   = unname(cols)
)
ok("scale_strip", scale_strip(inst, sel))
ok("pipeline_lines", pipeline_lines(dac))
ok("pipeline_lines df2", pipeline_lines(dac, df2 = fbt))
# Industry lines: summed dollars / summed gross loans, one per series, and
# none with a comparison bank. A mart without P3LNLS/NCLNLS (built before
# they were summed) drops just those two. ind_dq makes sure both exist.
ind_dq <- ind
if (is.null(ind_dq$P3LNLS)) ind_dq$P3LNLS <- 0.005 * ind_dq$LNLSGR
if (is.null(ind_dq$NCLNLS)) ind_dq$NCLNLS <- 0.010 * ind_dq$LNLSGR
pl_names <- function(p) vapply(plotly::plotly_build(p)$x$data, function(t) t$name, "")
ind_lines <- paste(c("30-89 days late", "Noncurrent", "Allowance"), "- All banks")
pl <- plotly::plotly_build(pipeline_lines(dac, ind = ind_dq))$x$data
stopifnot(identical(vapply(pl, `[[`, "", "name")[4:6], ind_lines))
w <- ind_dq[ind_dq$RISDATE >= 20190101, ]; w <- w[order(w$RISDATE), ]
for (k in 1:3) {
  stopifnot(isTRUE(all.equal(as.numeric(unlist(pl[[3 + k]]$y)),
    round(100 * w[[c("P3LNLS", "NCLNLS", "LNATRES")[k]]] / w$LNLSGR, 2))))
}
stopifnot(!any(grepl("All banks", pl_names(pipeline_lines(dac, df2 = fbt, ind = ind_dq)))),
          identical(grep("All banks", pl_names(pipeline_lines(
            dac, ind = ind[setdiff(names(ind), c("P3LNLS", "NCLNLS"))])), value = TRUE),
            "Allowance - All banks"))
cat("ok: pipeline_lines industry lines (columns present, absent, hidden with df2)\n")
ok("risk_cushion pct", risk_cushion(dac))
ok("risk_cushion usd", risk_cushion(dac, mode = "usd"))
ok("risk_cushion pct df2", risk_cushion(dac, df2 = fbt))
ok("risk_cushion usd df2", risk_cushion(dac, mode = "usd", df2 = fbt))
ok("prov_nco_bars usd", prov_nco_bars(dac))
ok("prov_nco_bars pct", prov_nco_bars(dac, mode = "pct"))
ok("loan_mix pct", loan_mix(dac))
ok("loan_mix usd", loan_mix(dac, mode = "usd"))
ok("funding_share", funding_share(dac))
ok("funding_share df2", funding_share(dac, df2 = fbt))
# Funding Mix Core line = COREDEP/DEP, sharing the deposits denominator
# with Brokered and Uninsured (FDIC's COREDEPR is % of ASSETS, not deposits)
pf_core <- plotly::plotly_build(funding_share(dac))
core_tr <- Filter(function(t) identical(t$name, "Core"), pf_core$x$data)
stopifnot(length(core_tr) == 1)
dd15 <- dac[dac$date >= as.Date("2015-01-01"), ]
expect_core <- round(100 * dd15$COREDEP / dd15$DEP, 1)
got_core <- unlist(core_tr[[1]]$y)
stopifnot(length(got_core) == length(expect_core),
          all(abs(got_core - expect_core) < 1e-6, na.rm = TRUE),
          # and it is NOT the %-of-assets series it used to plot
          any(abs(got_core - round(dd15$COREDEPR, 1)) > 0.5, na.rm = TRUE))
cat("ok: funding core = COREDEP/DEP, not COREDEPR\n")

# Failure trajectories: baseline sanity, picked banks, baseline-only
bl <- fail_median(FAIL_PANEL, "NCLNLSR")
stopifnot(all(bl$qtrs_before >= 0), all(bl$qtrs_before <= 20),
          all(bl$n >= 5), all(is.finite(bl$med)))
cat("fail_median: ", nrow(bl), "quarters, n range",
    min(bl$n), "-", max(bl$n), "\n")

sub <- FAIL_PANEL |> filter(CERT %in% head(unique(FAIL_PANEL$CERT), 3))
tcols <- setNames(TRAJ_PALETTE[seq_along(unique(sub$label))],
                  unique(sub$label))
ok("trajectory_plot banks+baseline",
   trajectory_plot(sub, "NCLNLSR", FIELDS_META, baseline = bl, cols = tcols,
                   ref_df = dac, ref_label = "Dacotah (SD)"))
ok("trajectory_plot baseline only",
   trajectory_plot(sub[0, ], "NCLNLSR", FIELDS_META, baseline = bl))
# The reference bank draws its own last 21 quarters (t-20..0), not a flat
# line at its current value
pr <- plotly::plotly_build(
  trajectory_plot(sub, "NCLNLSR", FIELDS_META, baseline = bl, cols = tcols,
                  ref_df = dac, ref_label = "Dacotah (SD)")
)
ref_tr <- Filter(function(t) identical(t$line$dash, "dash"), pr$x$data)
stopifnot(length(ref_tr) == 1)
rx <- unlist(ref_tr[[1]]$x); ry <- unlist(ref_tr[[1]]$y)
stopifnot(length(rx) == 21, min(rx) == -20, max(rx) == 0,
          length(unique(ry[is.finite(ry)])) > 1)   # a history, not a constant
cat("ok: trajectory ref line = last 21 quarters\n")
# Dollar metric: scaled from $ thousands and unit-labeled, jointly with
# the baseline and reference line
pt <- plotly::plotly_build(
  trajectory_plot(sub, "ASSET", FIELDS_META,
                  baseline = fail_median(FAIL_PANEL, "ASSET"), cols = tcols,
                  ref_df = dac, ref_label = "Dacotah (SD)")
)
ttl <- pt$x$layout$yaxis$title
if (is.list(ttl)) ttl <- ttl$text
stopifnot(grepl("($", ttl, fixed = TRUE))
cat("ok: trajectory_plot usd scaled + labeled\n")
cat("all builders ok\n")

# Server outputs via testServer, with a comparison bank active
setwd("..")
shiny::testServer(app = "app", {
  # Empty state: no bank picked yet, outputs carry the sidebar prompt
  err <- tryCatch({ output$kpis; NULL }, error = function(e) e)
  stopifnot(!is.null(err),
            grepl("Search for a bank", conditionMessage(err)))
  cat("ok: empty state before any pick\n")

  traj_picks <- as.character(head(FAIL_META$CERT, 3))
  session$setInputs(
    bank_pick = "17437", compare = "3973",
    rc_mode = "pct", mix_mode = "pct", prov_mode = "pct",
    traj_metric = "NCLNLSR",
    traj_region = c("Midwest", "Northeast", "South", "West"),
    traj_size = c("Under $100M", "$100M to $1B", "$1B to $10B", "Over $10B"),
    traj_banks = traj_picks,
    cap_metric = "RBC1AAJ", aq_metric = "NCLNLSR",
    earn_metric = "ROA", liq_metric = "LNLSDEPR"
  )
  outs <- c("kpis", "scale_plot", "overview_grid", "bs_table", "is_table",
            "ind_caption", "ind_bs_table", "ind_is_table",
            "ind_bs_plot", "ind_is_plot",
            "cap_plot", "cap_caveat", "cap_chip",
            "aq_plot", "earn_plot", "liq_plot",
            "pipeline_plot", "rc_plot", "prov_plot", "mix_plot",
            "funding_share_plot", "sens_plot", "sens_caveat",
            "traj_title", "traj_plot", "dict_table", "dict_full",
            "legal_docs")
  for (o in outs) {
    stopifnot(!is.null(output[[o]]))
    cat("ok output:", o, "\n")
  }
  stopifnot(length(sel_banks()) == 2)
  # Label comes from the live directory now, not a hand-written short name
  # in a shipped file, so assert against what bank_label() actually yields
  stopifnot(!is.null(cmp()), cmp()$label[1] == bank_label(3973, inst))
  cat("comparison bank active: yes\n")

  session$setInputs(fs_unit = "pct", fs_cmp = "yoy")
  stopifnot(grepl("% of total assets", output$bs_table$html, fixed = TRUE),
            grepl("% of revenue", output$is_table$html, fixed = TRUE))
  cat("ok output: statements in % vs 1 year ago\n")

  session$setInputs(prov_mode = "usd")
  stopifnot(!is.null(output$prov_plot))
  cat("ok output: prov_plot usd\n")

  # Industry lines (and their footer note) only without a comparison bank
  stopifnot(!grepl("Dashed", output$pipeline_note$html))
  session$setInputs(compare = character(0))
  stopifnot(is.null(cmp()), !is.null(output$pipeline_plot),
            grepl("Dashed = all FDIC-insured banks", output$pipeline_note$html))
  cat("ok output: pipeline_note shown only without a comparison bank\n")

  # Directory modal: table renders with one row per active bank, and a
  # row pick runs without error (inst here is the same INSTITUTIONS the
  # app loads: both come from snapshot_institutions)
  dir_payload <- jsonlite::fromJSON(output$dir_table)
  stopifnot(nrow(dir_payload$x$data) == nrow(inst))
  session$setInputs(browse_all = 1, dir_table_rows_selected = 2L)
  cat("ok output: dir_table + row pick\n")

  # Region filter shrinks the baseline set
  session$setInputs(traj_region = "Midwest")
  stopifnot(nrow(traj_meta_r()) < nrow(FAIL_META),
            all(traj_meta_r()$region == "Midwest"))
  stopifnot(!is.null(output$traj_plot))
  cat("ok output: traj_plot filtered to Midwest\n")
})
cat("smoke test passed\n")
