# Stress test card on the Overview: what higher interest rates have done to
# the value of a bank's bonds and loans ("hidden loss"), and how big a
# deposit run it could pay out. Both numbers come from the nightly
# pipeline's research marts (pipeline/marts/hidden_loss.R and
# run_stress.R; method in docs/specs/research-pipeline.md). They are
# estimates, so the card says so (STRESS_CAVEAT). Copy is kept minimal on
# purpose: no explanatory paragraphs.
#
# Each mart is optional (read_mart_optional): a missing file hides its half
# of the card, and both missing hide the card. A number the mart could not
# compute shows "Not reported" (the mart's na_reason in a tooltip), never 0.

STRESS_CAVEAT <- "Estimates."
STRESS_NA <- "Not reported"

# list(hl = hidden_loss mart, rs = run_stress mart), each NULL if missing
load_stress <- function() {
  list(hl = read_mart_optional("hidden_loss"), rs = read_mart_optional("run_stress"))
}

# One bank's hidden_loss rows, oldest first, plus equity / assets as
# reported and the hidden loss as a share of equity, from EQTOT and ASSET
# in the bank's own history (matched on quarter; NA where the history
# lacks the quarter or equity is not positive). NULL without the mart;
# zero rows when the mart has no estimate for the bank.
hl_bank <- function(hl, cert, hist) {
  if (is.null(hl)) return(NULL)
  d <- hl[hl$CERT == as.integer(cert), ]
  d <- d[order(d$RISDATE), ]
  m <- match(d$RISDATE, as.integer(as.character(hist$RISDATE)))
  eq <- as.numeric(hist$EQTOT[m])
  a  <- as.numeric(hist$ASSET[m])
  d$eq_to_assets   <- ifelse(a > 0, eq / a, NA_real_)
  d$loss_to_equity <- ifelse(eq > 0, d$hidden_loss / eq, NA_real_)
  d
}

# Anything to chart: at least one quarter with an estimate (a foreign
# bank's branch has rows, all NA, and would draw empty axes)
hl_has_series <- function(d) {
  !is.null(d) && any(is.finite(d$adj_equity_to_assets))
}

# The bank's run_stress row: NULL without the mart, zero rows if absent
rs_bank <- function(rs, cert) {
  if (is.null(rs)) NULL else rs[rs$CERT == as.integer(cert), ]
}

# ---- formatting ------------------------------------------------------------

pct_txt <- function(x, digits = 1) paste0(round(100 * x, digits), "%")

ordinal <- function(n) {
  suf <- if (n %% 100 %in% 11:13) "th" else
    c("th", "st", "nd", "rd", "th", "th", "th", "th", "th", "th")[n %% 10 + 1]
  paste0(n, suf)
}

# "Q3 2026", flagged when the estimate is older than the app's latest
# quarter, so a stale mart is never shown as current
stress_asof <- function(rd, xs_rd) {
  if (rd == xs_rd) quarter_name(rd) else paste0(quarter_name(rd), " (not latest)")
}

# "Not reported", with the reason as a hover tooltip
na_span <- function(why) {
  htmltools::span(class = "text-muted", title = if (!is.na(why)) why, STRESS_NA)
}

stress_box <- function(title, value, sub = NULL) {
  bslib::value_box(
    class = "kpi-compact", title = title, value = value,
    if (!is.null(sub)) htmltools::span(class = "kpi-delta", sub),
    theme = bslib::value_box_theme(bg = COL_PANEL, fg = COL_FG))
}

# ---- hidden loss -----------------------------------------------------------

# Three boxes for the bank's newest estimate. d from hl_bank().
stress_hidden_ui <- function(d, xs_rd) {
  if (is.null(d)) return(NULL)
  if (nrow(d) == 0) {
    return(htmltools::div(class = "text-muted",
                          "No estimate."))
  }
  r <- d[nrow(d), ]
  na_box <- function(title) stress_box(title, na_span(r$na_reason))
  # The share of equity is NA when equity is not positive: no sub line then
  loss <- if (is.na(r$hidden_loss)) na_box("Hidden loss") else
    stress_box("Hidden loss", fmt_value(r$hidden_loss, "usd_k"),
               if (!is.na(r$loss_to_equity)) paste0(pct_txt(r$loss_to_equity, 0), " of equity"))
  adj <- if (is.na(r$adj_equity_to_assets)) na_box("Equity after losses") else
    stress_box("Equity after losses", paste0(pct_txt(r$adj_equity_to_assets), " of assets"),
               paste0("Reported: ",
                      if (is.na(r$eq_to_assets)) STRESS_NA else pct_txt(r$eq_to_assets)))
  rank <- if (is.na(r$pct_worst)) na_box("Percentile") else
    stress_box("Percentile", ordinal(max(1, round(100 * r$pct_worst))), "vs. all banks")
  # One div, not a tagList: each child of a card is a flex item with a gap
  htmltools::div(
    htmltools::tags$h6(paste0("Hidden losses, ", stress_asof(r$RISDATE, xs_rd))),
    bslib::layout_columns(col_widths = bslib::breakpoints(xs = 12, md = 4),
                          gap = "0.6rem", loss, adj, rank)
  )
}

# ---- deposit run -----------------------------------------------------------

RS_RUN_ROWS <- c(unins = "Uninsured leave*", all = "All leave")

# Why one run was not computed: the mart's na_reason lists every missing
# input, some tagged with the runs they block ("(FHLB-on runs)",
# "(uninsured runs)"); keep the ones that apply to run k, tags dropped
run_na_why <- function(na_reason, k) {
  if (is.na(na_reason)) return("inputs not reported")
  w <- strsplit(na_reason, "; ", fixed = TRUE)[[1]]
  if (!grepl("fhlb", k)) w <- w[!grepl("(FHLB-on runs)", w, fixed = TRUE)]
  if (!startsWith(k, "unins")) w <- w[!grepl("(uninsured runs)", w, fixed = TRUE)]
  w <- trimws(sub("\\(.*\\)$", "", w))
  if (length(w) == 0) "inputs not reported" else paste(w, collapse = "; ")
}

# One table cell: run k's outcome. Both failure modes ("below 2%" capital,
# "can't pay") read the same; the reason for a missing run is a tooltip.
run_cell <- function(r, k) {
  how <- r[[paste0("how_", k)]]
  bp  <- r[[paste0("bp_", k)]]
  if (is.na(how)) return(na_span(run_na_why(r$na_reason, k)))
  switch(how,
    "never"     = "Survives",
    "below 2%"  = ,
    "can't pay" = htmltools::strong(paste0("Fails at ", pct_txt(bp))),
    how)
}

# The breaking-point table. r from rs_bank().
stress_run_ui <- function(r, xs_rd) {
  if (is.null(r)) return(NULL)
  if (nrow(r) == 0) {
    return(htmltools::div(class = "text-muted",
                          "No estimate."))
  }
  rows <- lapply(names(RS_RUN_ROWS), function(k) {
    htmltools::tags$tr(htmltools::tags$th(RS_RUN_ROWS[[k]]),
                       htmltools::tags$td(run_cell(r, k)),
                       htmltools::tags$td(run_cell(r, paste0(k, "_fhlb"))))
  })
  htmltools::div(
    # The quarter shows only when stale
    htmltools::tags$h6(if (r$RISDATE == xs_rd) "Deposit run" else
      paste0("Deposit run, ", stress_asof(r$RISDATE, xs_rd))),
    htmltools::tags$table(
      class = "table table-sm stress-run",
      htmltools::tags$thead(htmltools::tags$tr(
        htmltools::tags$th(""), htmltools::tags$th("No borrowing"),
        htmltools::tags$th("With FHLB*"))),
      htmltools::tags$tbody(rows))
  )
}
