# Shared plotly builders. Chart rules: one y axis, explicit titles, unified
# hover, color follows the bank, legend whenever >= 2 series. Dollar axes
# resolve their $M/$B unit ONCE per axis from every series drawn on it
# (usd_axis_unit), never per series.
#
# Two-bank convention on the fixed multi-series charts (funding_share,
# pipeline_lines, risk_cushion): color follows the SERIES there, so the
# bank is encoded by line dash instead: solid = primary, dotted = the
# comparison bank (df2). Dotted threshold/CECL lines are shapes, not
# traces, and are unaffected.

PLT_FONT <- list(family = 'system-ui, "Segoe UI", Roboto, sans-serif')

base_layout <- function(p, y_title, x_title = "Quarter-end", yrange = NULL) {
  yaxis <- list(title = y_title, zeroline = FALSE)
  if (!is.null(yrange)) yaxis$range <- yrange
  plotly::layout(
    p,
    font = PLT_FONT,
    hovermode = "x unified",
    xaxis = list(title = x_title, showgrid = FALSE),
    yaxis = yaxis,
    legend = list(orientation = "h", y = -0.22),
    margin = list(t = 30)
  ) |>
    plotly::config(displaylogo = FALSE,
                   modeBarButtonsToRemove = list("lasso2d", "select2d"))
}

# Plotly autorange ignores shape extent when the shape is x-paper/y-data
# (our dotted threshold lines and the peer band both are), so a chart whose
# values sit well clear of its ref_warn/ref_crit can render those lines
# entirely off-screen. Pad the range to guarantee any threshold is visible.
yrange_with_refs <- function(all_y, row, peer) {
  if (!row$units[1] %in% c("pct", "x")) return(NULL)
  ref_vals <- c(row$ref_warn[1], row$ref_crit[1])
  if (!is.null(peer) && nrow(peer) > 0) {
    ref_vals <- c(ref_vals, peer$p25[1], peer$p50[1], peer$p75[1])
  }
  ref_vals <- ref_vals[!is.na(ref_vals)]
  all_y <- all_y[is.finite(all_y)]
  if (length(ref_vals) == 0 || length(all_y) == 0) return(NULL)
  lo <- min(c(all_y, ref_vals)); hi <- max(c(all_y, ref_vals))
  pad <- max((hi - lo) * 0.08, 0.5)
  c(lo - pad, hi + pad)
}

range_buttons <- function(p) {
  plotly::layout(p, xaxis = list(
    rangeselector = list(buttons = list(
      list(count = 5,  label = "5y",  step = "year", stepmode = "backward"),
      list(count = 10, label = "10y", step = "year", stepmode = "backward"),
      list(step = "all", label = "max")
    )),
    rangeslider = list(visible = FALSE)
  ))
}

# One axis, one unit. Raw values arrive in $ thousands; the display unit is
# resolved from the POOLED values of every series that will share the axis.
# Deciding per series put a $357M bank and a $4.9B bank on the same axis in
# different units (357.84 "$M" next to 4.87 "$B"), inflating the smaller
# bank 1000x. Callers divide by $div and label with $unit/$letter/$word.
usd_axis_unit <- function(vals) {
  vals <- vals[is.finite(vals)]
  if (length(vals) > 0 && max(abs(vals)) >= 1e6) {
    list(div = 1e6, unit = "$B", letter = "B", word = "$ billions")
  } else {
    list(div = 1e3, unit = "$M", letter = "M", word = "$ millions")
  }
}

# Reference layers drawn under every rate chart: yellow/red dotted lines
# where a regulatory or breakeven level exists (fields_meta ref_warn /
# ref_crit), plus the peer band (25th-75th percentile of all FDIC banks)
# with a dotted median. Returned as a plotly shapes list.
threshold_layers <- function(row, peer = NULL) {
  shp <- list()
  hline <- function(y, color) {
    list(type = "line", xref = "paper", x0 = 0, x1 = 1, y0 = y, y1 = y,
         line = list(color = color, dash = "dot", width = 1.4))
  }
  if (!is.null(peer) && nrow(peer) > 0) {
    shp[[length(shp) + 1]] <- list(
      type = "rect", xref = "paper", x0 = 0, x1 = 1,
      y0 = peer$p25[1], y1 = peer$p75[1],
      fillcolor = COL_BAND, line = list(width = 0), layer = "below"
    )
    shp[[length(shp) + 1]] <- hline(peer$p50[1], COL_GRAY)
  }
  if (!is.na(row$ref_warn[1])) shp[[length(shp) + 1]] <- hline(row$ref_warn[1], COL_WARN)
  if (!is.na(row$ref_crit[1])) shp[[length(shp) + 1]] <- hline(row$ref_crit[1], COL_CRIT)
  shp
}

# One metric, one or more banks. `display` rescales dollar metrics on the
# fly: "level" ($), "pct_assets", or "pct_loans" — flat rates on a growing
# book look like rising dollars, so both views matter.
metric_ts <- function(banks, code, meta, cols, display = "level", peer = NULL) {
  row <- meta[meta$code == code, ]
  if (nrow(row) == 0) {
    row <- data.frame(code = code, label = code, units = "usd_k",
                      ref_warn = NA, ref_crit = NA)
  }
  units <- row$units[1]
  y_title <- row$label[1]
  hover_pre <- ""; hover_suf <- ""

  # Pass 1: transform every bank's series first, so a dollar axis can
  # resolve its unit from the pooled values rather than per bank
  series <- list()
  for (lb in names(banks)) {
    df <- banks[[lb]]
    if (!code %in% names(df)) next
    y <- df[[code]]
    if (units == "usd_k" && display == "pct_assets") {
      y <- 100 * y / df$ASSET
    } else if (units == "usd_k" && display == "pct_loans") {
      y <- 100 * y / df$gross_lns
    }
    series[[lb]] <- list(x = df$date, y = y)
  }
  if (units == "usd_k" && display == "pct_assets") {
    y_title <- paste0(row$label[1], " (% of assets)"); hover_suf <- "%"
  } else if (units == "usd_k" && display == "pct_loans") {
    y_title <- paste0(row$label[1], " (% of gross loans)"); hover_suf <- "%"
  } else if (units == "usd_k") {
    sc <- usd_axis_unit(unlist(lapply(series, `[[`, "y")))
    series <- lapply(series, function(s) { s$y <- s$y / sc$div; s })
    y_title <- paste0(row$label[1], " (", sc$unit, ")")
    hover_pre <- "$"; hover_suf <- sc$letter
  } else if (units == "pct") {
    hover_suf <- "%"
  } else if (units == "x") {
    hover_suf <- "x"
  }

  # Pass 2: draw
  p <- plotly::plot_ly()
  all_y <- numeric(0)
  for (lb in names(series)) {
    s <- series[[lb]]
    all_y <- c(all_y, s$y[is.finite(s$y)])
    p <- plotly::add_trace(
      p, x = s$x, y = round(s$y, 2), name = lb,
      type = "scatter", mode = "lines",
      line = list(color = cols[[lb]], width = 2),
      hovertemplate = paste0(hover_pre, "%{y}", hover_suf)
    )
    # Title test: the current value sits on the chart, not just in hover
    if (any(!is.na(s$y))) {
      last_i <- max(which(!is.na(s$y)))
      p <- plotly::add_annotations(
        p, x = s$x[last_i], y = round(s$y[last_i], 2),
        text = paste0("<b>", hover_pre, round(s$y[last_i], 2), hover_suf,
                      "</b>"),
        xanchor = "left", showarrow = FALSE, xshift = 8,
        font = list(color = cols[[lb]], size = 12)
      )
    }
  }
  # Reference layers only make sense on the metric's native rate scale
  yrange <- NULL
  if (row$units[1] %in% c("pct", "x") && display == "level") {
    shp <- threshold_layers(row, peer)
    if (length(shp) > 0) p <- plotly::layout(p, shapes = shp)
    yrange <- yrange_with_refs(all_y, row, peer)
  }
  base_layout(p, y_title, yrange = yrange) |> range_buttons()
}

# Compact CAMELS tile: one headline metric, last 10 years, all selected
# banks, no legend (the overview page carries one shared legend row)
camels_mini <- function(banks, code, meta, cols, peer = NULL) {
  row <- meta[meta$code == code, ]
  pre <- ""
  suf <- if (row$units[1] == "pct") "%" else if (row$units[1] == "x") "x" else ""
  series <- list()
  for (lb in names(banks)) {
    df <- banks[[lb]]
    if (!code %in% names(df)) next
    dd <- df[df$date >= max(df$date) - 3653, ]
    series[[lb]] <- list(x = dd$date, y = dd[[code]])
  }
  # Dollar unit resolved once across all banks (one axis, one unit)
  if (row$units[1] == "usd_k") {
    sc <- usd_axis_unit(unlist(lapply(series, `[[`, "y")))
    series <- lapply(series, function(s) { s$y <- s$y / sc$div; s })
    pre <- "$"; suf <- sc$letter
  }
  p <- plotly::plot_ly()
  all_y <- numeric(0)
  for (lb in names(series)) {
    s <- series[[lb]]
    all_y <- c(all_y, s$y[is.finite(s$y)])
    p <- plotly::add_trace(p, x = s$x, y = round(s$y, 2), name = lb,
                           type = "scatter", mode = "lines",
                           line = list(color = cols[[lb]], width = 2),
                           hovertemplate = paste0(pre, "%{y}", suf))
  }
  yaxis <- list(title = NA, zeroline = FALSE)
  if (row$units[1] %in% c("pct", "x")) {
    shp <- threshold_layers(row, peer)
    if (length(shp) > 0) p <- plotly::layout(p, shapes = shp)
    yr <- yrange_with_refs(all_y, row, peer)
    if (!is.null(yr)) yaxis$range <- yr
  }
  plotly::layout(
    p, font = PLT_FONT, showlegend = FALSE, hovermode = "x unified",
    xaxis = list(title = NA, showgrid = FALSE),
    yaxis = yaxis,
    margin = list(t = 6, b = 24, l = 36, r = 8)
  ) |>
    plotly::config(displayModeBar = FALSE)
}

# Where the bank sits among all ~4,300 FDIC banks: log-binned histogram of
# total assets with one labeled marker per selected bank. The app version
# of the deep dive's scale chart; dollars cannot be the yardstick, so the
# rest of the app is rates and percentiles.
scale_strip <- function(inst, sel) {
  sel <- sel[!is.na(sel$asset) & sel$asset > 0, ]
  lx <- log10(inst$ASSET[!is.na(inst$ASSET) & inst$ASSET > 0])
  br <- seq(floor(min(lx) * 10) / 10, ceiling(max(lx) * 10) / 10, by = 0.1)
  ct <- as.integer(table(cut(lx, br, include.lowest = TRUE)))
  mid <- utils::head(br, -1) + 0.05
  p <- plotly::plot_ly(
    x = mid, y = ct, type = "bar", width = 0.09,
    marker = list(color = "#CBD5DD"),
    hovertemplate = "%{y} banks<extra></extra>"
  )
  shp <- list(); ann <- list()
  ymax <- max(ct)
  for (i in seq_len(nrow(sel))) {
    xv <- log10(sel$asset[i])
    shp[[i]] <- list(type = "line", x0 = xv, x1 = xv, y0 = 0, y1 = ymax * 0.88,
                     line = list(color = sel$col[i], width = 2.5))
    ann[[i]] <- list(
      x = xv, y = ymax * (0.98 - 0.11 * ((i - 1) %% 4)),
      text = paste0("<b>", sel$label[i], "</b> ",
                    fmt_value(sel$asset[i], "usd_k")),
      font = list(color = sel$col[i], size = 12),
      xanchor = if (xv > mean(range(mid))) "right" else "left",
      showarrow = FALSE
    )
  }
  tickv <- log10(c(1e4, 1e5, 1e6, 1e7, 1e8, 1e9))
  tickl <- c("$10M", "$100M", "$1B", "$10B", "$100B", "$1T")
  plotly::layout(
    p, font = PLT_FONT, showlegend = FALSE, shapes = shp, annotations = ann,
    xaxis = list(title = "Total assets (log scale)", tickvals = tickv,
                 ticktext = tickl, showgrid = FALSE),
    yaxis = list(title = "Banks", zeroline = FALSE),
    margin = list(t = 10), bargap = 0
  ) |>
    plotly::config(displayModeBar = FALSE)
}

# Funding share lines: the mix view behind the stacked dollars. df2 = the
# comparison bank, drawn dotted in the same series colors.
funding_share <- function(df, df2 = NULL, from_date = as.Date("2015-01-01")) {
  banks <- if (is.null(df2)) list(df) else list(df, df2)
  series <- list(
    list(y = function(d) d$COREDEPR,           name = "Core",      color = COL_MAIN),
    list(y = function(d) d$bro_pct_dep,        name = "Brokered",  color = COL_ALERT),
    list(y = function(d) 100 * d$DEPUNINS / d$DEP, name = "Uninsured", color = COL_EARLY)
  )
  p <- plotly::plot_ly()
  for (i in seq_along(banks)) {
    dd <- banks[[i]][banks[[i]]$date >= from_date, ]
    dash <- if (i == 1) NULL else "dot"
    for (s in series) {
      nm <- if (length(banks) > 1)
        paste0(s$name, " - ", banks[[i]]$label[1]) else s$name
      p <- plotly::add_trace(
        p, x = dd$date, y = round(s$y(dd), 1), name = nm,
        type = "scatter", mode = "lines",
        line = list(color = s$color, width = 2, dash = dash),
        hovertemplate = "%{y}%"
      )
    }
  }
  base_layout(p, "% of total deposits")
}

# Loan-book mix, stacked $ or share of gross loans
loan_mix <- function(df, mode = "pct", from_date = as.Date("2010-01-01")) {
  dd <- df[df$date >= from_date, ] |>
    dplyr::mutate(
      other_re = pmax(LNRE - LNRECONS - LNRENRES - LNREMULT, 0),
      other_ln = pmax(gross_lns - LNAG - LNCI - LNRE, 0)
    )
  comps <- list(
    list(col = "LNAG",     name = "Agriculture",             color = "#009E73"),
    list(col = "LNRECONS", name = "Construction",            color = "#D55E00"),
    list(col = "LNRENRES", name = "Commercial real estate",  color = "#E69F00"),
    list(col = "LNREMULT", name = "Apartments",              color = "#CC79A7"),
    list(col = "other_re", name = "Other real estate",       color = "#56B4E9"),
    list(col = "LNCI",     name = "Business loans",          color = "#2C5F8A"),
    list(col = "other_ln", name = "Everything else",         color = "#BBBBBB")
  )
  # Unit from gross loans: the bands stack to the whole book
  sc <- if (mode == "usd") usd_axis_unit(dd$gross_lns) else NULL
  p <- plotly::plot_ly(dd, x = ~date)
  for (cm in comps) {
    y <- dd[[cm$col]]
    if (mode == "pct") {
      y <- 100 * y / dd$gross_lns; hv <- "%{y}%"
    } else {
      y <- y / sc$div; hv <- paste0("$%{y}", sc$letter)
    }
    p <- plotly::add_trace(p, y = round(y, 2), name = cm$name,
                           type = "scatter", mode = "none",
                           stackgroup = "one", fillcolor = cm$color,
                           hovertemplate = hv)
  }
  base_layout(p, if (mode == "pct") "% of gross loans" else sc$word)
}

# Quarterly net charge-offs from the YTD field (in-year difference)
add_nco_q <- function(df) {
  df |>
    dplyr::group_by(yr = format(date, "%Y")) |>
    dplyr::mutate(nco_q = NTLNLS - dplyr::lag(NTLNLS, default = 0)) |>
    dplyr::ungroup()
}

# Risk vs cushion: allowance, noncurrent, and quarterly charge-offs on ONE
# axis, in $ or as % of gross loans. The divergence between red and blue is
# the story; the $ view shows how a growing book turns flat rates into
# rising dollars.
# df2 = comparison bank: allowance and noncurrent dotted, charge-off bars
# grouped in a second muted hue. The usd view with a much larger comparison
# bank compresses the primary; pct is the comparable view and the default.
risk_cushion <- function(df, mode = "pct", df2 = NULL,
                         from_date = as.Date("2019-01-01")) {
  banks <- if (is.null(df2)) list(df) else list(df, df2)
  bar_cols <- c("#D9B8B3", "#C3CBD4")
  dds <- lapply(banks, function(b) {
    add_nco_q(b) |> dplyr::filter(date >= from_date)
  })
  # Dollar unit pooled across BOTH banks: one axis, one unit
  sc <- if (mode == "usd") {
    usd_axis_unit(unlist(lapply(dds, function(d) {
      c(d$LNATRES, d$NCLNLS, d$nco_q)
    })))
  } else NULL
  y_title <- if (mode == "usd") sc$word else "% of gross loans"
  p <- plotly::plot_ly()
  for (i in seq_along(banks)) {
    dd <- dds[[i]]
    if (mode == "usd") {
      alw <- dd$LNATRES / sc$div; nc <- dd$NCLNLS / sc$div
      nco <- dd$nco_q / sc$div
      hv <- function(pre) paste0(pre, ": $%{y}", sc$letter)
    } else {
      alw <- dd$LNATRESR; nc <- dd$NCLNLSR
      nco <- 100 * dd$nco_q / dd$gross_lns
      hv <- function(pre) paste0(pre, ": %{y}%")
    }
    tag <- if (length(banks) > 1) paste0(" - ", banks[[i]]$label[1]) else ""
    dash <- if (i == 1) NULL else "dot"
    mk <- function(color) if (i == 1) list(size = 5, color = color) else NULL
    line_mode <- if (i == 1) "lines+markers" else "lines"
    p <- p |>
      plotly::add_bars(x = dd$date, y = round(nco, 2),
                       name = paste0("Charge-offs", tag),
                       marker = list(color = bar_cols[i]),
                       hovertemplate = hv(paste0("Charge-offs", tag))) |>
      plotly::add_trace(x = dd$date, y = round(alw, 2),
                        name = paste0("Allowance", tag),
                        type = "scatter", mode = line_mode,
                        line = list(color = COL_MAIN, width = 2, dash = dash),
                        marker = mk(COL_MAIN),
                        hovertemplate = hv(paste0("Allowance", tag))) |>
      plotly::add_trace(x = dd$date, y = round(nc, 2),
                        name = paste0("Noncurrent", tag),
                        type = "scatter", mode = line_mode,
                        line = list(color = COL_ALERT, width = 2, dash = dash),
                        marker = mk(COL_ALERT),
                        hovertemplate = hv(paste0("Noncurrent", tag)))
  }
  p <- plotly::layout(p, barmode = "group")
  p <- base_layout(p, y_title)
  # CECL adoption marker: the allowance definition changed here (2023 for
  # most banks; the footnote star carries the 2020 large-bank nuance)
  cecl <- as.Date("2023-01-01")
  if (from_date < cecl) {
    p <- plotly::layout(
      p,
      shapes = list(list(type = "line", x0 = cecl, x1 = cecl,
                         yref = "paper", y0 = 0, y1 = 0.94,
                         line = list(color = COL_GRAY, dash = "dot",
                                     width = 1.2))),
      annotations = list(list(x = cecl, y = 1, yref = "paper", text = "CECL",
                              showarrow = FALSE, yanchor = "top",
                              xanchor = "left", xshift = 4,
                              font = list(color = COL_GRAY, size = 11)))
    )
  }
  p
}

# Roll-rate proxies were cut in iteration 5: net flows from quarterly bucket
# totals are not account-level transitions and did not meet the "only solid
# charts" bar. The builder lives in git history (pre-2026-07-07) if real
# transition data ever shows up.

# Delinquency pipeline lines. df2 = comparison bank, dotted, no markers.
pipeline_lines <- function(df, df2 = NULL, from_date = as.Date("2019-01-01")) {
  banks <- if (is.null(df2)) list(df) else list(df, df2)
  series <- list(
    list(col = "p3_pct",   name = "30-89 days late", color = COL_EARLY),
    list(col = "NCLNLSR",  name = "Noncurrent",      color = COL_ALERT),
    list(col = "LNATRESR", name = "Allowance",       color = COL_MAIN)
  )
  p <- plotly::plot_ly()
  for (i in seq_along(banks)) {
    dd <- banks[[i]][banks[[i]]$date >= from_date, ]
    for (s in series) {
      nm <- if (length(banks) > 1)
        paste0(s$name, " - ", banks[[i]]$label[1]) else s$name
      if (i == 1) {
        p <- plotly::add_trace(
          p, x = dd$date, y = round(dd[[s$col]], 2), name = nm,
          type = "scatter", mode = "lines+markers",
          line = list(color = s$color, width = 2),
          marker = list(size = 5, color = s$color),
          hovertemplate = "%{y}%"
        )
      } else {
        p <- plotly::add_trace(
          p, x = dd$date, y = round(dd[[s$col]], 2), name = nm,
          type = "scatter", mode = "lines",
          line = list(color = s$color, width = 2, dash = "dot"),
          hovertemplate = "%{y}%"
        )
      }
    }
  }
  base_layout(p, "% of gross loans")
}

# Quarterly provision vs charge-offs (YTD fields differenced in-year), as
# dollars or as % of gross loans. Same denominator for both series so the
# bars stay comparable; matches the pct convention of the sibling charts.
prov_nco_bars <- function(df, mode = "usd", from = 20220101) {
  dd <- df |>
    dplyr::filter(RISDATE >= from) |>
    dplyr::group_by(yr = format(date, "%Y")) |>
    dplyr::mutate(prov_q = ELNATR - dplyr::lag(ELNATR, default = 0),
                  nco_q  = NTLNLS - dplyr::lag(NTLNLS, default = 0)) |>
    dplyr::ungroup()
  if (mode == "pct") {
    prov <- round(100 * dd$prov_q / dd$gross_lns, 3)
    nco  <- round(100 * dd$nco_q / dd$gross_lns, 3)
    y_title <- "Quarterly flow (% of gross loans)"; hv <- "%{y}%"
  } else {
    sc <- usd_axis_unit(c(dd$prov_q, dd$nco_q))
    prov <- round(dd$prov_q / sc$div, 2)
    nco  <- round(dd$nco_q / sc$div, 2)
    y_title <- paste0("Quarterly flow (", sc$unit, ")")
    hv <- paste0("$%{y}", sc$letter)
  }
  p <- plotly::plot_ly(dd, x = ~qlab) |>
    plotly::add_bars(y = prov, name = "Provision",
                     marker = list(color = COL_MAIN),
                     hovertemplate = hv) |>
    plotly::add_bars(y = nco, name = "Charge-offs",
                     marker = list(color = COL_ALERT),
                     hovertemplate = hv) |>
    plotly::layout(barmode = "group",
                   xaxis = list(categoryorder = "array",
                                categoryarray = dd$qlab))
  base_layout(p, y_title, "Quarter")
}

# Failure trajectories aligned on quarters before failure. sel_panel holds
# the explicitly picked banks (max 10 by the UI); baseline is the per-quarter
# median of the WHOLE filtered set (fail_median in data.R), drawn first so
# the picked banks sit on top. cols is a label-keyed color vector assigned
# positionally in the server (TRAJ_PALETTE). ref_df is the selected live
# bank: its last 21 quarters draw as a dashed line with TODAY at 0, so the
# same x position means "failure" for the gray lines and "now" for the
# dashed one -- the legend and hover carry that distinction.
trajectory_plot <- function(sel_panel, code, meta, baseline = NULL,
                            cols = NULL, ref_df = NULL, ref_label = NULL) {
  row <- meta[meta$code == code, ]
  units <- row$units[1]
  prefix <- ""
  suffix <- if (units == "pct") "%" else if (units == "x") "x" else ""
  y_title <- row$label[1]

  dd <- sel_panel |>
    dplyr::filter(!is.na(fail_date), qtrs_before >= 0, qtrs_before <= 20)
  # Last 21 rows by date, not last 21 finite values: NA quarters must stay
  # as gaps or the line compresses time and misaligns against the x axis
  ref_tail <- if (!is.null(ref_df) && code %in% names(ref_df)) {
    utils::tail(ref_df, 21)
  } else NULL
  ref_vals <- if (!is.null(ref_tail)) {
    ref_tail[[code]][is.finite(ref_tail[[code]])]
  } else numeric(0)

  # Dollar metrics arrive in $ thousands; one unit resolved across the
  # baseline, the picked banks, and the reference line together
  div <- 1
  if (units == "usd_k") {
    pool <- c(if (!is.null(baseline)) baseline$med,
              if (code %in% names(dd)) dd[[code]],
              ref_vals)
    sc <- usd_axis_unit(pool)
    div <- sc$div
    prefix <- "$"; suffix <- sc$letter
    y_title <- paste0(y_title, " (", sc$unit, ")")
  }

  p <- plotly::plot_ly()
  if (!is.null(baseline) && nrow(baseline) > 0) {
    bl <- baseline[order(-baseline$qtrs_before), ]
    p <- plotly::add_trace(
      p, x = -bl$qtrs_before, y = round(bl$med / div, 2),
      name = "Median, filtered failures",
      type = "scatter", mode = "lines",
      line = list(color = COL_GRAY, width = 3),
      text = paste0(bl$n, " banks"),
      hovertemplate = paste0(prefix, "%{y}", suffix, " (median of %{text})")
    )
  }

  if (nrow(dd) > 0 && code %in% names(dd)) {
    labs <- unique(dd$label)
    if (!is.null(cols)) labs <- intersect(names(cols), labs)
    for (lb in labs) {
      di <- dd[dd$label == lb, ]
      di <- di[order(-di$qtrs_before), ]
      col <- if (!is.null(cols)) cols[[lb]] else COL_GRAY
      p <- plotly::add_trace(
        p, x = -di$qtrs_before, y = round(di[[code]] / div, 2), name = lb,
        type = "scatter", mode = "lines+markers",
        line = list(color = col, width = 1.6),
        marker = list(size = 4, color = col),
        hovertemplate = paste0(prefix, "%{y}", suffix)
      )
    }
  }

  if (length(ref_vals) > 0) {
    p <- plotly::add_trace(
      p, x = seq_len(nrow(ref_tail)) - nrow(ref_tail),
      y = round(ref_tail[[code]] / div, 2),
      name = paste0(ref_label, " (0 = today)"),
      type = "scatter", mode = "lines",
      line = list(color = COL_MAIN, width = 2.5, dash = "dash"),
      text = ref_tail$qlab,
      hovertemplate = paste0(prefix, "%{y}", suffix, " (%{text})")
    )
  }
  base_layout(p, y_title, "Quarters before failure (0 = failure)") |>
    plotly::layout(hovermode = "closest")
}
