# Theme and palette for the app. Same house colors as the report charts.

COL_MAIN  <- "#2C5F8A"   # steel blue: the selected bank
COL_ALERT <- "#C0392B"   # brick red: stress series
COL_EARLY <- "#E69F00"   # amber: early-warning series
COL_GRAY  <- "#7F8C8D"

# Threshold lines and the peer band (middle half of all FDIC banks)
COL_WARN  <- "#C9A227"                    # yellow dotted: watch level
COL_CRIT  <- "#C0392B"                    # red dotted: regulatory floor
COL_BAND  <- "rgba(127,140,141,0.13)"     # peer 25th-75th percentile fill

# One color per metric category; the chip on every card header uses these
# so a reader can place a chart without decoding a letter code.
# All pass 4.5:1 contrast for the white chip text; don't lighten casually.
CAT_COLS <- c(
  "Capital"             = "#0072B2",
  "Asset Quality"       = "#AD4A00",
  "Earnings"            = "#1B7837",
  "Liquidity & Funding" = "#5E548E",
  "Sensitivity"         = "#A94452",
  "Concentration"       = "#7A5C03",
  "Size"                = "#6C757D"
)

cat_chip <- function(group) {
  col <- CAT_COLS[[group]]
  if (is.null(col) || is.na(col)) col <- "#6C757D"
  htmltools::span(
    group,
    style = paste0("background:", col, "; color:#FFF; border-radius:10px;",
                   "padding:1px 9px; font-size:0.72rem; font-weight:600;",
                   "white-space:nowrap;")
  )
}

# Positional palette for the sidebar selection: the primary bank is always
# steel blue, the first comparison always amber, and so on (Okabe-Ito,
# CVD-safe). Color follows the selection slot, not the bank; with ~4,300
# possible banks a per-bank assignment would be arbitrary anyway.
SEL_COLS <- c("#2C5F8A", "#E69F00", "#009E73", "#CC79A7",
              "#D55E00", "#56B4E9", "#F0E442", "#999999")

# Failure-trajectory palette, assigned positionally to whichever failed
# banks are selected (up to 10). Excludes COL_GRAY (the filtered-set median
# baseline) and COL_MAIN (the selected live bank's dashed reference line).
TRAJ_PALETTE <- c("#E69F00", "#D55E00", "#009E73", "#CC79A7", "#56B4E9",
                  "#0072B2", "#F0E442", "#8C510A", "#5AB4AC", "#999999")

app_theme <- function() {
  bslib::bs_theme(
    version = 5,
    bg = "#FFFFFF", fg = "#1F2933",
    primary = COL_MAIN, danger = COL_ALERT,
    base_font = 'system-ui, "Segoe UI", Roboto, Helvetica, Arial, sans-serif',
    heading_font = 'system-ui, "Segoe UI", Roboto, Helvetica, Arial, sans-serif',
    "navbar-bg" = COL_MAIN
  )
}

# Value formatting by units type (units come from fields_meta.csv)
fmt_value <- function(x, units) {
  if (is.na(x)) return("n/a")
  switch(units,
    usd_k = if (abs(x) >= 1e6) paste0("$", round(x / 1e6, 2), "B")
            else paste0("$", round(x / 1e3, 1), "M"),
    pct   = paste0(round(x, 2), "%"),
    x     = paste0(round(x, 2), "x"),
    count = format(round(x), big.mark = ","),
    as.character(round(x, 2))
  )
}
