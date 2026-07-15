# Smoke test for the app: every plot builder returns a plotly object and
# every server output renders. Run from the repo root:
#   Rscript.exe app/tests/smoke.R
# First run fetches the cross-section from the FDIC API (one request);
# after that everything reads from app/data-cache/.

library(shiny)
library(bslib)
library(plotly)
library(dplyr)

setwd("app")
source("R/api.R")
source("R/theme.R")
source("R/data.R")
source("R/plots.R")

BASE <- load_base_banks()
inst <- fetch_institutions_cached()
PEER <- peer_stats(fetch_cross_section_cached(), FIELDS_META)
stopifnot(nrow(PEER) >= 15, all(c("p25", "p50", "p75") %in% names(PEER)))
cat("peer stats:", nrow(PEER), "metrics\n")

FAIL_PANEL <- load_fail_panel()
FAIL_META  <- load_fail_meta()
stopifnot(nrow(FAIL_META) > 500, !any(is.na(FAIL_META$region)),
          all(FAIL_META$n_filings > 0))
cat("fail panel:", nrow(FAIL_PANEL), "rows,", nrow(FAIL_META), "banks\n")

pf <- function(code) {
  r <- PEER[PEER$code == code, ]
  if (nrow(r) > 0) r else NULL
}
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
     metric_ts(banks, code, FIELDS_META, cols, peer = pf(code)))
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

for (code in c("ASSET", "RBC1AAJ", "NCLNLSR", "p3_pct", "ROAQ", "COREDEPR",
               "unrl_pct_eq")) {
  ok(paste("camels_mini", code),
     camels_mini(banks, code, FIELDS_META, cols, pf(code)))
}

sel <- data.frame(
  label = names(banks),
  asset = sapply(banks, function(d) utils::tail(d$ASSET[!is.na(d$ASSET)], 1)),
  col   = unname(cols)
)
ok("scale_strip", scale_strip(inst, sel))
ok("pipeline_lines", pipeline_lines(dac))
ok("pipeline_lines df2", pipeline_lines(dac, df2 = fbt))
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
  outs <- c("kpis", "scale_plot", "camels_grid", "overview_legend",
            paste0("tile_", 1:6),
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
  stopifnot(!is.null(cmp()), cmp()$label[1] == "First B&T (SD)")
  cat("comparison bank active: yes\n")

  session$setInputs(prov_mode = "usd")
  stopifnot(!is.null(output$prov_plot))
  cat("ok output: prov_plot usd\n")

  # Directory modal: table renders with one row per active bank, and a
  # row pick runs without error (inst here is the same INSTITUTIONS the
  # app loads: both come from fetch_institutions_cached)
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
