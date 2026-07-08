# Bank risk explorer. Run from the repo root:
#   Rscript.exe -e "shiny::runApp('app', port = 7788)"
#
# Layout follows the data dictionary's CAMELS categories, one top-level tab
# each. Hard rule: at most two full charts visible per screen. Every card
# header wears a color-coded category chip; every chart carries a footnote
# with the formula in plain words. Rate charts draw yellow/red regulatory
# lines (fields_meta) and the peer band: the middle half of all FDIC banks.

library(shiny)
library(bslib)
library(plotly)
library(dplyr)

# helpers in app/R/ are auto-sourced by shiny (data.R, plots.R, theme.R)

BASE <- load_base_banks()
INSTITUTIONS <- fetch_institutions_cached()
INST_CHOICES <- institution_choices(INSTITUTIONS)
PEER <- peer_stats(fetch_cross_section_cached(), FIELDS_META)

# All post-2000 failures (built by app/build/build_fail_panel.R)
FAIL_PANEL <- load_fail_panel()
FAIL_META  <- load_fail_meta()
TRAJ_REGIONS <- c("Midwest", "Northeast", "South", "West")
TRAJ_SIZES   <- c("Under $100M", "$100M to $1B", "$1B to $10B", "Over $10B")

EMPTY_MSG <- "Search for a bank in the sidebar to load its history."

peer_for <- function(code) {
  r <- PEER[PEER$code == code, ]
  if (nrow(r) > 0) r else NULL
}

# Footnote under every metric chart: formula and caveat, a color-swatch key
# for whatever reference lines the chart actually drew (threshold_layers in
# plots.R), then one starred definition per unfamiliar term (the `stars`
# column, pipe-separated). No line drawn, no swatch: nothing to key.
metric_footnote <- function(code) {
  row <- FIELDS_META[FIELDS_META$code == code, ]
  if (nrow(row) == 0) return(NULL)
  parts <- c(row$formula[1], row$caveat[1])
  parts <- parts[!is.na(parts) & nzchar(parts)]
  parts <- sub("[.]+$", "", parts)  # avoid doubled periods when joined below
  text <- if (length(parts) > 0) paste0(paste(parts, collapse = ". "), ".") else NULL

  swatches <- list()
  if (row$units[1] %in% c("pct", "x")) {
    if (!is.na(row$ref_warn[1])) {
      lbl <- if (!is.na(row$warn_label[1])) row$warn_label[1] else "Watch level"
      swatches[[length(swatches) + 1]] <- line_swatch(COL_WARN, lbl)
    }
    if (!is.na(row$ref_crit[1])) {
      lbl <- if (!is.na(row$crit_label[1])) row$crit_label[1] else "Regulatory floor"
      swatches[[length(swatches) + 1]] <- line_swatch(COL_CRIT, lbl)
    }
    if (!is.null(peer_for(code))) {
      swatches[[length(swatches) + 1]] <-
        line_swatch(COL_GRAY, "Median, all FDIC banks, 2026 Q1 (band: middle 50%)")
    }
  }

  tagList(
    if (!is.null(text)) div(text),
    if (length(swatches) > 0)
      div(class = "d-flex flex-wrap align-items-center mt-1", swatches),
    star_lines(row$stars[1])
  )
}

# Starred term definitions, one line each, below everything else
star_line <- function(s) {
  div(style = "font-size:0.88em; opacity:0.85;", paste0("*", trimws(s), "."))
}
star_lines <- function(stars) {
  if (is.na(stars) || !nzchar(stars)) return(NULL)
  lapply(strsplit(stars, "|", fixed = TRUE)[[1]], star_line)
}

# Flex classes go on card_header itself, never on a wrapper div inside it:
# card_header is a flex container in current bslib, so an inner div shrinks
# to content width and its justify-content-between does nothing (title and
# controls end up jammed together).
chip_header <- function(title, group) {
  card_header(class = "d-flex justify-content-between align-items-center gap-2",
              span(title), cat_chip(group))
}

# Dotted-line swatch matching threshold_layers() in plots.R, for legends
line_swatch <- function(color, label) {
  span(class = "me-3 text-nowrap d-inline-flex align-items-center",
       span(style = paste0("display:inline-block; width:20px; height:0; ",
                           "border-top:2px dotted ", color, "; margin-right:5px;")),
       label)
}

# Preloaded live banks, keyed by CERT
SEED_BANKS <- list(
  "17437" = BASE |> filter(label == "Dacotah (SD)"),
  "3973"  = BASE |> filter(label == "First B&T (SD)")
)

KPI_DEFS <- list(
  list(code = "ASSET",     title = "Total Assets"),
  list(code = "ROAQ",      title = "Return on Assets"),
  list(code = "RBC1AAJ",   title = "Tier 1 Leverage"),
  list(code = "NCLNLSR",   title = "Noncurrent Loans"),
  list(code = "alw_cover", title = "Allowance Coverage"),
  list(code = "COREDEPR",  title = "Core Deposits")
)
KPI_GOOD_UP <- c(ASSET = TRUE, ROAQ = TRUE, RBC1AAJ = TRUE, NCLNLSR = FALSE,
                 alw_cover = TRUE, COREDEPR = TRUE)

CAMELS_TILES <- list(
  list(code = "RBC1AAJ",     title = "Tier 1 Leverage"),
  list(code = "NCLNLSR",     title = "Noncurrent Loans"),
  list(code = "p3_pct",      title = "30-89 Days Late"),
  list(code = "ROAQ",        title = "Return on Assets"),
  list(code = "COREDEPR",    title = "Core Deposits"),
  list(code = "unrl_pct_eq", title = "Unrealized Securities Loss / Equity")
)

# One scoped metric explorer per category page: id -> metric scope + default
EXPLORERS <- list(
  cap  = list(groups = c("Capital", "Size"),                  default = "RBC1AAJ"),
  aq   = list(groups = c("Asset Quality", "Concentration"),   default = "NCLNLSR"),
  earn = list(groups = "Earnings",                            default = "ROA"),
  liq  = list(groups = "Liquidity & Funding",                 default = "LNLSDEPR")
)

scoped_choices <- function(groups) {
  m <- FIELDS_META[FIELDS_META$group %in% groups, ]
  split(setNames(m$code, m$label), m$group)
}

DISPLAY_CHOICES <- c("$" = "level", "% assets" = "pct_assets",
                     "% loans" = "pct_loans")

# Explorer card: metric picker, unit toggle, and category chip in the
# header; chart fills the card; footnote explains the metric.
ui_explorer <- function(id, groups, default, height = "440px") {
  card(
    card_header(
      class = "d-flex justify-content-between align-items-center flex-wrap gap-2",
      selectInput(paste0(id, "_metric"), NULL,
                  choices = scoped_choices(groups), selected = default,
                  width = "340px"),
      div(class = "d-flex align-items-center gap-3",
          uiOutput(paste0(id, "_toggle")),
          uiOutput(paste0(id, "_chip")))
    ),
    plotlyOutput(paste0(id, "_plot"), height = height),
    card_footer(class = "text-muted small", uiOutput(paste0(id, "_caveat")))
  )
}

ui <- page_navbar(
  title = "Bank Check",
  theme = app_theme(),
  # The dashboard panels have fixed-height charts and stay fillable.
  # Dictionary and Legal are documents: excluded from fillable so their
  # cards grow with content and the page scrolls, instead of flex-fitting
  # everything into one viewport (which crushed the metric table to a sliver).
  fillable = c("Overview", "Capital", "Asset Quality", "Earnings",
               "Liquidity & Funding", "Sensitivity", "Compare to Failures"),
  header = tagList(
    # Dictionary styling: commonmark emits bare <table> tags that Bootstrap
    # 5 leaves unstyled; the gsub in output$dict_full adds .table classes
    # and this block handles sizing and heading rhythm.
    tags$style(HTML("
      .dict-md { max-width: 72rem; }
      .dict-md h1 { font-size: 1.4rem; }
      .dict-md h2 { font-size: 1.15rem; margin-top: 1.5rem;
                    border-bottom: 1px solid #DEE2E6; padding-bottom: 0.3rem; }
      .dict-md table { font-size: 0.92rem; }
      #dict_table { font-size: 0.95rem; }
    ")),
    # Dependency primer for shinylive: a hidden static widget makes the
    # browser fetch plotly's JS at page load. Without it, the first server-
    # rendered charts race the 3.5 MB script through the service worker and
    # lose ("Plotly is not defined", blank cards) on uncached first visits.
    div(style = "display:none;", plotly::plot_ly())
  ),
  sidebar = sidebar(
    width = 320,
    selectizeInput("bank_pick", "Find a bank", choices = NULL,
                   options = list(placeholder = "Search by bank name...",
                                  maxOptions = 8)),
    selectizeInput("compare", "Compare with", choices = NULL, multiple = TRUE,
                   options = list(placeholder = "Search any bank...",
                                  maxOptions = 8)),
    helpText("Supports all active FDIC banks. Quarterly history from 1984 ",
             "(or Origination) to present."),
    # Legal one-liner lives here, not in a page footer: a footer inside the
    # fillable pages fights the flex layout and overlaps the last outputs
    div(class = "text-muted small mt-auto pt-3",
        paste0("Informational only, not financial advice. Public FDIC ",
               "data; not affiliated with the FDIC. Deposits at ",
               "FDIC-insured banks are insured up to $250,000. ",
               "See the Legal tab."))
  ),

  nav_panel(
    "Overview",
    uiOutput("kpis"),
    card(
      chip_header("Every FDIC Bank by Size", "Size"),
      plotlyOutput("scale_plot", height = "250px")#,
      # card_footer(class = "text-muted small",paste0(""))
    ),
    uiOutput("camels_grid"),
    uiOutput("overview_legend")
  ),

  nav_panel("Capital", ui_explorer("cap", EXPLORERS$cap$groups, EXPLORERS$cap$default)),

  nav_panel(
    "Asset Quality",
    navset_card_tab(
      nav_panel(
        "Delinquency",
        card(
          chip_header("The Pipeline: 30-89 Days Late, Noncurrent, Allowance",
                      "Asset Quality"),
          plotlyOutput("pipeline_plot", height = "440px"),
          card_footer(class = "text-muted small",
                      div(paste0("Each line is a share of gross loans*. ",
                                 "Noncurrent = 90+ days past due or on ",
                                 "nonaccrual*. The allowance* should cover ",
                                 "the red line.")),
                      star_line("Gross loans: all loans before subtracting the allowance"),
                      star_line("Nonaccrual: loans the bank stopped booking interest on because full collection is doubtful"),
                      star_line("Allowance: money set aside for expected loan losses"))
        )
      ),
      nav_panel(
        "Reserves",
        layout_columns(
          col_widths = c(6, 6),
          card(card_header(
                 class = "d-flex justify-content-between align-items-center",
                 "Risk vs Cushion",
                 radioButtons("rc_mode", NULL, inline = TRUE,
                              choices = c("%" = "pct", "$" = "usd"))),
               plotlyOutput("rc_plot", height = "400px"),
               card_footer(class = "text-muted small",
                           div(paste0("The allowance* should cover the ",
                                      "noncurrent* line. Below 1x coverage is ",
                                      "a flag, not a verdict: troubled loans ",
                                      "backed by collateral recover some ",
                                      "value.")),
                           star_line("Allowance: money set aside for expected loan losses"),
                           star_line("Noncurrent: loans 90+ days past due or no longer collecting interest"),
                           star_line(paste0("CECL: an accounting change; since 2023 (2020 for ",
                                            "the largest banks) the allowance covers expected ",
                                            "lifetime losses, so the line can jump without ",
                                            "new trouble")))),
          card(card_header(
                 class = "d-flex justify-content-between align-items-center",
                 "Provision vs Charge-offs",
                 radioButtons("prov_mode", NULL, inline = TRUE,
                              choices = c("%" = "pct", "$" = "usd"))),
               plotlyOutput("prov_plot", height = "400px"),
               card_footer(class = "text-muted small",
                           div(paste0("Provision* adds to the allowance; ",
                                      "charge-offs* take from it. Provision ",
                                      "trailing charge-offs thins the ",
                                      "cushion.")),
                           star_line("Provision: money the bank sets aside this quarter for expected loan losses"),
                           star_line("Charge-off: a loan written off as uncollectible")))
        )
      ),
      nav_panel(
        "Loan Mix",
        card(
          card_header(
            class = "d-flex justify-content-between align-items-center",
            "What the Bank Lends Against",
            radioButtons("mix_mode", NULL, inline = TRUE,
                         choices = c("%" = "pct", "$" = "usd"))),
          plotlyOutput("mix_plot", height = "440px"),
          card_footer(class = "text-muted small",
                      div(paste0("Each band is a share of the loan book. ",
                                 "One dominant loan type is one ",
                                 "concentrated bet.")))
        )
      ),
      nav_panel(
        "Explore",
        ui_explorer("aq", EXPLORERS$aq$groups, EXPLORERS$aq$default)
      )
    )
  ),

  nav_panel("Earnings", ui_explorer("earn", EXPLORERS$earn$groups, EXPLORERS$earn$default)),

  nav_panel(
    "Liquidity & Funding",
    navset_card_tab(
      nav_panel(
        "Funding Mix",
        card(
          chip_header("Where the Money Comes From", "Liquidity & Funding"),
          plotlyOutput("funding_share_plot", height = "440px"),
          card_footer(class = "text-muted small",
                      div(paste0("Each line is a share of total deposits. ",
                                 "Core deposits tend to stay; brokered* and ",
                                 "uninsured money leave first.")),
                      star_line(paste0("Brokered: deposits bought through a broker rather ",
                                       "than gathered from the bank's own customers")))
        )
      ),
      nav_panel(
        "Explore",
        ui_explorer("liq", EXPLORERS$liq$groups, EXPLORERS$liq$default)
      )
    )
  ),

  nav_panel(
    "Sensitivity",
    card(
      chip_header("Unrealized Securities Loss / Equity", "Sensitivity"),
      plotlyOutput("sens_plot", height = "440px"),
      card_footer(class = "text-muted small", uiOutput("sens_caveat"))
    )
  ),

  nav_panel(
    "Compare to Failures",
    layout_columns(
      col_widths = c(3, 9),
      card(
        selectInput("traj_metric", "Metric",
                    choices = split(setNames(FIELDS_META$code, FIELDS_META$label),
                                    FIELDS_META$group),
                    selected = "NCLNLSR"),
        checkboxGroupInput("traj_region", "Region",
                           choices = TRAJ_REGIONS, selected = TRAJ_REGIONS),
        checkboxGroupInput("traj_size", "Size at failure",
                           choices = TRAJ_SIZES, selected = TRAJ_SIZES),
        selectizeInput("traj_banks", "Highlight banks (max 10)",
                       choices = NULL, multiple = TRUE,
                       options = list(maxItems = 10,
                                      placeholder = "Search failed banks...")),
        helpText("All FDIC failures since 2000, aligned on quarters before ",
                 "failure. Gray line: median of the filtered set. Dashed ",
                 "line: the selected bank today. Failed banks often stop ",
                 "filing one or two quarters before the failure date, so ",
                 "lines can end early.")
      ),
      card(card_header(textOutput("traj_title")),
           plotlyOutput("traj_plot", height = "500px"))
    )
  ),

  nav_panel(
    "Dictionary",
    # fill = FALSE: a fill-mode DT inside a card with no fixed height
    # collapses to a zero-height flex item
    card(card_header("Every Metric in the App"),
         DT::DTOutput("dict_table", fill = FALSE)),
    card(card_header("Full Dictionary"),
         div(class = "dict-md p-3", uiOutput("dict_full")))
  ),

  nav_panel(
    "Legal",
    card(div(class = "dict-md p-3", uiOutput("legal_docs")))
  )
)

server <- function(input, output, session) {

  loaded <- reactiveVal(SEED_BANKS)

  # Both pickers search all active banks; either fetches on pick. No bank
  # preselected: every tab shows the sidebar prompt until one is picked.
  # selected = character(0) is load-bearing: without it selectize falls back
  # to the first choice, which is the largest bank (JPMorgan) ----
  updateSelectizeInput(session, "bank_pick", choices = INST_CHOICES,
                       selected = character(0), server = TRUE)
  updateSelectizeInput(session, "compare", choices = INST_CHOICES,
                       server = TRUE)

  ensure_loaded <- function(cert) {
    if (!nzchar(cert) || cert %in% names(loaded())) return(invisible(TRUE))
    id <- showNotification("Fetching from FDIC...", duration = NULL)
    on.exit(removeNotification(id))
    df <- tryCatch(fetch_bank_cached(as.integer(cert)), error = function(e) NULL)
    if (is.null(df) || nrow(df) == 0) {
      showNotification(paste("No FDIC data for CERT", cert), type = "error")
      return(invisible(FALSE))
    }
    df$label <- bank_label(cert, INSTITUTIONS,
                           fallback_name = df$NAMEFULL[nrow(df)])
    df$fail_date <- as.Date(NA)
    b <- loaded(); b[[cert]] <- df; loaded(b)
    invisible(TRUE)
  }

  observeEvent(input$bank_pick, ensure_loaded(input$bank_pick))
  observeEvent(input$compare, {
    for (ct in setdiff(input$compare, names(loaded()))) ensure_loaded(ct)
  })

  # One EMPTY_MSG per screen: the shared reactives halt silently (req), and
  # only the designated first output of each screen calls bank_gate() to
  # show the prompt. Otherwise every gated output on a page repeats it.
  bank_picked <- reactive({
    isTruthy(input$bank_pick) && input$bank_pick %in% names(loaded())
  })
  bank_gate <- function() validate(need(bank_picked(), EMPTY_MSG))

  cur <- reactive({
    req(bank_picked())
    loaded()[[input$bank_pick]]
  })

  # Selected + comparison banks, keyed by display label
  sel_certs <- reactive({
    req(bank_picked())
    unique(c(input$bank_pick, intersect(input$compare, names(loaded()))))
  })
  sel_banks <- reactive({
    b <- loaded()[sel_certs()]
    setNames(b, sapply(b, function(d) d$label[1]))
  })
  # Color by selection slot: primary always steel blue, first comparison
  # always amber, etc. (SEL_COLS in theme.R)
  sel_cols <- reactive({
    certs <- sel_certs()
    b <- loaded()[certs]
    setNames(rep_len(SEL_COLS, length(certs)),
             sapply(b, function(d) d$label[1]))
  })

  # First comparison bank that is loaded and not the primary; the dotted
  # overlay on the fixed asset-quality and funding charts (max 2 banks).
  cmp <- reactive({
    cands <- setdiff(intersect(input$compare, names(loaded())),
                     input$bank_pick)
    if (length(cands) == 0) NULL else loaded()[[cands[1]]]
  })

  # KPI row: carries the Overview page's single empty-state prompt ----
  output$kpis <- renderUI({
    bank_gate()
    df <- cur()
    n <- nrow(df)
    boxes <- lapply(KPI_DEFS, function(k) {
      val  <- df[[k$code]][n]
      prev <- if (n > 4) df[[k$code]][n - 4] else NA
      meta_row <- FIELDS_META[FIELDS_META$code == k$code, ]
      delta <- if (!is.na(prev) && !is.na(val)) val - prev else NA
      good  <- KPI_GOOD_UP[[k$code]]
      trend <- if (is.na(delta)) "" else {
        arrow <- if (delta >= 0) "▲" else "▼"
        paste0(arrow, " ", fmt_value(abs(delta), meta_row$units[1]), " vs 1y ago")
      }
      trend_color <- if (is.na(delta)) "#666" else
        if ((delta >= 0) == good) "#1B7837" else "#C0392B"
      value_box(
        title = k$title,
        value = fmt_value(val, meta_row$units[1]),
        p(style = paste0("color:", trend_color, "; font-size: 0.85rem;"), trend),
        theme = value_box_theme(bg = "#F4F7FA", fg = "#1F2933")
      )
    })
    do.call(layout_columns, c(list(col_widths = rep(2, 6)), boxes))
  })

  # Scale strip: selected banks against all ~4,300 by total assets ----
  output$scale_plot <- renderPlotly({
    b <- sel_banks(); cols <- sel_cols()
    sel <- data.frame(
      label = names(b),
      asset = sapply(b, function(d) utils::tail(d$ASSET[!is.na(d$ASSET)], 1)),
      col   = unname(cols[names(b)]),
      stringsAsFactors = FALSE
    )
    scale_strip(INSTITUTIONS, sel)
  })

  # CAMELS small-multiples grid, comparison banks included ----
  output$camels_grid <- renderUI({
    df <- cur()
    n <- nrow(df)
    tiles <- lapply(seq_along(CAMELS_TILES), function(i) {
      t <- CAMELS_TILES[[i]]
      meta_row <- FIELDS_META[FIELDS_META$code == t$code, ]
      val <- fmt_value(df[[t$code]][n], meta_row$units[1])
      card(
        card_header(
          class = "py-1 small d-flex justify-content-between align-items-center gap-2",
          span(paste0(t$title, ": ", val)), cat_chip(meta_row$group[1])
        ),
        plotlyOutput(paste0("tile_", i), height = "200px")
      )
    })
    do.call(layout_columns, c(list(col_widths = rep(4, 6)), tiles))
  })
  for (i in seq_along(CAMELS_TILES)) local({
    ii <- i
    output[[paste0("tile_", ii)]] <- renderPlotly({
      code <- CAMELS_TILES[[ii]]$code
      camels_mini(sel_banks(), code, FIELDS_META, sel_cols(), peer_for(code))
    })
  })

  # One legend for the whole overview page, at the bottom ----
  output$overview_legend <- renderUI({
    cols <- sel_cols()
    dots <- lapply(names(cols), function(lb) {
      span(class = "me-3 text-nowrap",
           span(style = paste0("display:inline-block; width:10px; height:10px;",
                               "border-radius:5px; background:", cols[[lb]],
                               "; margin-right:5px;")),
           lb)
    })
    div(class = "text-muted small mt-1 mb-3 px-2",
        div(dots),
        div(class = "d-flex flex-wrap align-items-center mt-1",
            line_swatch(COL_WARN, "Watch level"),
            line_swatch(COL_CRIT, "Regulatory floor"),
            line_swatch(COL_GRAY, "Median of all FDIC banks, 2026 Q1")))
  })

  # Scoped explorers, one per category page ----
  for (id in names(EXPLORERS)) local({
    eid <- id
    metric_input <- paste0(eid, "_metric")
    output[[paste0(eid, "_toggle")]] <- renderUI({
      units <- FIELDS_META$units[FIELDS_META$code == input[[metric_input]]]
      if (length(units) && units == "usd_k") {
        radioButtons(paste0(eid, "_display"), NULL, inline = TRUE,
                     choices = DISPLAY_CHOICES)
      }
    })
    output[[paste0(eid, "_chip")]] <- renderUI({
      g <- FIELDS_META$group[FIELDS_META$code == input[[metric_input]]]
      if (length(g)) cat_chip(g[1])
    })
    output[[paste0(eid, "_caveat")]] <- renderUI({
      metric_footnote(input[[metric_input]])
    })
    output[[paste0(eid, "_plot")]] <- renderPlotly({
      bank_gate()
      disp <- input[[paste0(eid, "_display")]]
      if (is.null(disp)) disp <- "level"
      metric_ts(sel_banks(), input[[metric_input]], FIELDS_META, sel_cols(),
                display = disp, peer = peer_for(input[[metric_input]]))
    })
  })

  # Fixed-purpose charts. bank_gate() on the first chart of each screen;
  # prov_plot shares the Reserves screen with rc_plot, so it stays silent ----
  output$pipeline_plot <- renderPlotly({
    bank_gate()
    pipeline_lines(cur(), df2 = cmp())
  })
  output$rc_plot <- renderPlotly({
    bank_gate()
    risk_cushion(cur(), mode = input$rc_mode, df2 = cmp())
  })
  output$prov_plot <- renderPlotly({
    prov_nco_bars(cur(), mode = input$prov_mode)
  })
  output$mix_plot <- renderPlotly({
    bank_gate()
    loan_mix(cur(), mode = input$mix_mode)
  })
  output$funding_share_plot <- renderPlotly({
    bank_gate()
    funding_share(cur(), df2 = cmp())
  })
  output$sens_plot <- renderPlotly({
    bank_gate()
    metric_ts(sel_banks(), "unrl_pct_eq", FIELDS_META, sel_cols(),
              peer = peer_for("unrl_pct_eq"))
  })
  output$sens_caveat <- renderUI({ metric_footnote("unrl_pct_eq") })

  # Failure comparison ----
  # Region + size filters narrow the picker AND the baseline set; explicit
  # picks (max 10) get their own traces on top of the filtered-set median.
  traj_meta_r <- reactive({
    FAIL_META |>
      filter(region %in% input$traj_region, size_bucket %in% input$traj_size)
  })
  observe({
    m <- traj_meta_r()
    updateSelectizeInput(
      session, "traj_banks",
      choices = setNames(m$CERT, m$label),
      selected = intersect(isolate(input$traj_banks), as.character(m$CERT)),
      server = TRUE
    )
  })
  traj_panel_r <- reactive({
    FAIL_PANEL |> filter(CERT %in% traj_meta_r()$CERT)
  })
  traj_sel_r <- reactive({
    traj_panel_r() |> filter(as.character(CERT) %in% input$traj_banks)
  })
  traj_cols_r <- reactive({
    m <- traj_meta_r()
    labs <- m$label[match(input$traj_banks, as.character(m$CERT))]
    labs <- labs[!is.na(labs)]
    setNames(TRAJ_PALETTE[seq_along(labs)], labs)
  })

  output$traj_title <- renderText({
    paste0(FIELDS_META$label[FIELDS_META$code == input$traj_metric],
           ", aligned on failure date")
  })
  output$traj_plot <- renderPlotly({
    bank_gate()
    trajectory_plot(traj_sel_r(), input$traj_metric, FIELDS_META,
                    baseline = fail_median(traj_panel_r(), input$traj_metric),
                    cols = traj_cols_r(),
                    ref_df = cur(), ref_label = cur()$label[1])
  })

  # Dictionary ----
  output$dict_table <- DT::renderDT({
    unit_suffix <- ifelse(FIELDS_META$units == "pct", "%",
                          ifelse(FIELDS_META$units == "x", "x", ""))
    tbl <- FIELDS_META |>
      mutate(
        thr = trimws(paste0(
          ifelse(is.na(ref_warn), "",
                 paste0("watch ", ref_warn, unit_suffix)),
          ifelse(is.na(ref_warn) | is.na(ref_crit), "", ", "),
          ifelse(is.na(ref_crit), "",
                 paste0("floor ", ref_crit, unit_suffix))
        ))
      ) |>
      select(Metric = label, Group = group, Formula = formula,
             Thresholds = thr, `Watch Out` = caveat, Code = code)
    DT::datatable(
      tbl, rownames = FALSE,
      options = list(pageLength = nrow(tbl), dom = "ft", autoWidth = TRUE,
                     columnDefs = list(list(width = "38%", targets = 4)))
    )
  })
  output$dict_full <- renderUI({
    md <- readLines("data/data-dictionary.md", warn = FALSE)
    html <- commonmark::markdown_html(paste(md, collapse = "\n"),
                                      extensions = TRUE)
    # commonmark emits bare <table>; Bootstrap 5 only styles .table
    html <- gsub("<table>", '<table class="table table-striped table-sm">',
                 html, fixed = TRUE)
    HTML(html)
  })

  # Legal: disclaimer + terms, rendered from app/legal/ ----
  output$legal_docs <- renderUI({
    md <- c(readLines("legal/DISCLAIMER.md", warn = FALSE), "", "---", "",
            readLines("legal/TERMS.md", warn = FALSE))
    HTML(commonmark::markdown_html(paste(md, collapse = "\n"),
                                   extensions = TRUE))
  })
}

shinyApp(ui, server)
