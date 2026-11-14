# Balance sheet and income statement for the Overview, built from FDIC's
# own call report lines ($ thousands). "Other" rows are the remainder, so
# each block adds up exactly to FDIC's reported total. `tab` names the page
# that explains the line and links to it.

# One quarter's lines. kind: "head" (section title), "line", "total".
statement_lines <- function(r) {
  z <- function(x) ifelse(is.na(x), 0, x)   # unreported line = nothing
  loans_net <- z(r$LNLSGR) - z(r$LNATRES)
  borrow    <- z(r$OTHBOR) + z(r$FREPP) + z(r$SUBND)
  revenue   <- z(r$NIMQ) + z(r$NONIIQ)
  pre_other <- revenue - z(r$NONIXQ) - z(r$ELNATQ) + z(r$IGLSECQ) - z(r$ITAXQ)
  ln <- function(section, label, value, kind = "line", tab = "") {
    data.frame(section = section, label = label, value = value, kind = kind,
               tab = tab)
  }
  bs <- rbind(
    ln("bs", "Assets", NA, "head"),
    ln("bs", "Loans", r$LNLSGR, tab = "Asset Quality"),
    ln("bs", "− Allowance*", -r$LNATRES, tab = "Asset Quality"),
    ln("bs", "Bonds", r$SC, tab = "Sensitivity"),
    ln("bs", "Cash", r$CHBAL, tab = "Liquidity & Funding"),
    ln("bs", "Other", r$ASSET - loans_net - z(r$SC) - z(r$CHBAL)),
    ln("bs", "Total assets", r$ASSET, "total"),
    ln("bs", "Liabilities", NA, "head"),
    ln("bs", "Deposits", r$DEP, tab = "Liquidity & Funding"),
    ln("bs", "Borrowings", borrow, tab = "Liquidity & Funding"),
    ln("bs", "Other", r$LIAB - z(r$DEP) - borrow),
    ln("bs", "Total liabilities", r$LIAB, "total"),
    ln("bs", "Capital", NA, "head"),
    ln("bs", "Equity (owners)", r$EQTOT, "total", "Capital")
  )
  is <- rbind(
    ln("is", "Interest earned − paid", r$NIMQ, tab = "Earnings"),
    ln("is", "Fees", r$NONIIQ, tab = "Earnings"),
    ln("is", "Revenue", revenue, "total"),
    ln("is", "Expenses", -r$NONIXQ, tab = "Earnings"),
    ln("is", "Loan loss provision", -r$ELNATQ, tab = "Asset Quality"),
    ln("is", "Bond gains/losses", r$IGLSECQ, tab = "Sensitivity"),
    ln("is", "Taxes", -r$ITAXQ),
    ln("is", "Other", r$NETINCQ - pre_other),
    ln("is", "Net income", r$NETINCQ, "total", "Earnings")
  )
  # Percent of the block's base: total assets, or revenue
  bs$pct <- 100 * bs$value / r$ASSET
  is$pct <- if (is.finite(revenue) && revenue > 0) 100 * is$value / revenue else NA
  rbind(bs, is)
}

# Quarter label like "Q2 2026" from a RISDATE
quarter_name <- function(risdate) {
  rd <- as.integer(risdate)
  paste0("Q", (rd %% 10000L %/% 100L - 1L) %/% 3L + 1L, " ", rd %/% 10000L)
}

# Table for one statement. banks: one derive()d history, or a named list
# of them (names = labels, cols = colors keyed by label). unit "usd" or
# "pct"; cmp "qoq" (vs prior quarter) or "yoy" (vs same quarter last year).
# One bank gets a change column; two or more get a column each instead.
statement_table <- function(banks, section, unit = "usd", cmp = "qoq",
                            cols = NULL) {
  if (is.data.frame(banks)) banks <- list(banks)
  single <- length(banks) == 1
  latest <- function(df) df[order(df$RISDATE), ][nrow(df), ]
  pick <- function(r) {
    l <- statement_lines(r)
    l[l$section == section, ]
  }
  nows <- lapply(banks, latest)
  cur  <- lapply(nows, pick)   # same rows, same order, for every bank
  lines <- cur[[1]]
  col <- if (unit == "pct") "pct" else "value"
  vals <- do.call(cbind, lapply(cur, `[[`, col))
  usd  <- do.call(cbind, lapply(cur, `[[`, "value"))

  chg <- NULL
  if (single) {
    df <- banks[[1]]
    rd <- as.integer(nows[[1]]$RISDATE)
    prior_rd <- if (cmp == "qoq") prev_quarter_end(rd) else rd - 10000L
    prior <- df[as.integer(df$RISDATE) == prior_rd, ]
    chg <- if (nrow(prior)) vals[, 1] - pick(prior[1, ])[[col]] else NA * vals[, 1]
  }

  # $ unit shared by every column, from the largest line: $M reads best up
  # to $100B (a $4.8B bank's income would be all 0.0 in $B); whole numbers
  # once the lines are big enough that decimals are noise
  big <- suppressWarnings(max(abs(usd), na.rm = TRUE))
  if (unit == "pct") {
    div <- 1; digits <- 1; unit_lab <- "%"
  } else if (is.finite(big) && big >= 1e8) {
    div <- 1e6; digits <- 1; unit_lab <- "$B"
  } else {
    div <- 1e3; unit_lab <- "$M"
    digits <- if (is.finite(big) && big >= 1e5) 0 else 1
  }
  num <- function(x, sign = FALSE) {
    if (!is.finite(x)) return("–")
    x <- round(x / div, digits)
    s <- formatC(abs(x), format = "f", digits = digits, big.mark = ",")
    if (x > 0 && sign) paste0("+", s) else if (x < 0) paste0("−", s) else s
  }

  # Income "Other" is rarely nonzero (e.g. discontinued operations): hide
  # it when it is zero for every bank shown
  zero_other <- lines$label == "Other" & lines$section == "is" &
    apply(usd, 1, function(v) all(is.na(v) | abs(v) < 0.5))
  n_cols <- 2 + ncol(vals) + !is.null(chg)
  rows <- lapply(which(!zero_other), function(i) {
    if (lines$kind[i] == "head") {
      return(tags$tr(class = "fs-head", tags$td(colspan = n_cols, lines$label[i])))
    }
    tags$tr(class = if (lines$kind[i] == "total") "fs-total",
            tags$td(lines$label[i]),
            lapply(seq_len(ncol(vals)), function(k) {
              tags$td(class = "text-end", num(vals[i, k]))
            }),
            if (!is.null(chg)) {
              tags$td(class = "text-end text-muted", num(chg[i], sign = TRUE))
            },
            # Jumps to the tab that explains the line (handler in app.js)
            tags$td(class = "fs-tab",
                    if (nzchar(lines$tab[i])) {
                      tags$a(href = "#", class = "fs-tab-link",
                             `data-tab` = lines$tab[i], lines$tab[i])
                    }))
  })

  bank_heads <- if (single) {
    list(
      tags$th(class = "text-end",
              paste(quarter_name(nows[[1]]$RISDATE), "·", unit_lab)),
      tags$th(class = "text-end", paste("vs", quarter_name(prior_rd))))
  } else {
    lapply(seq_along(banks), function(k) {
      lb <- names(banks)[k]
      color <- if (!is.null(cols) && lb %in% names(cols)) cols[[lb]] else COL_FG
      tags$th(class = "text-end",
              div(class = "fs-bank", style = paste0("color:", color),
                  title = lb, sub(" [(].*$", "", lb)),
              div(class = "fs-sub",
                  paste(quarter_name(nows[[k]]$RISDATE), "·", unit_lab)))
    })
  }
  tags$table(
    class = "table table-sm fs-table mb-0",
    tags$thead(tags$tr(tags$th(""), bank_heads, tags$th(""))),
    tags$tbody(rows)
  )
}
