# Balance sheet and income statement for the Overview, built from FDIC's
# own call report lines ($ thousands). "Other" rows are the remainder, so
# each block adds up exactly to FDIC's reported total. `tab` names the page
# that explains the line.

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
    ln("bs", "− Loss cushion", -r$LNATRES, tab = "Asset Quality"),
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
  # Rarely nonzero (e.g. discontinued operations); hide when it is
  is <- is[!(is$label == "Other" & abs(z(is$value)) < 0.5), ]
  rbind(bs, is)
}

# Quarter label like "Q2 2026" from a RISDATE
quarter_name <- function(risdate) {
  rd <- as.integer(risdate)
  paste0("Q", (rd %% 10000L %/% 100L - 1L) %/% 3L + 1L, " ", rd %/% 10000L)
}

# Table for one statement. df: a bank's derive()d history; unit "usd" or
# "pct"; cmp "qoq" (vs prior quarter) or "yoy" (vs same quarter last year).
statement_table <- function(df, section, unit = "usd", cmp = "qoq") {
  df <- df[order(df$RISDATE), ]
  now <- df[nrow(df), ]
  rd  <- as.integer(now$RISDATE)
  prior_rd <- if (cmp == "qoq") prev_quarter_end(rd) else rd - 10000L
  prior <- df[as.integer(df$RISDATE) == prior_rd, ]
  a <- statement_lines(now)
  a <- a[a$section == section, ]
  b <- if (nrow(prior)) statement_lines(prior[1, ]) else NULL
  b <- if (!is.null(b)) b[b$section == section, ] else NULL

  col <- if (unit == "pct") "pct" else "value"
  # $ unit per table, from its own largest line: $M reads best up to
  # $100B (a $4.8B bank's income would be all 0.0 in $B); whole numbers
  # once the lines are big enough that decimals are noise
  big <- max(abs(a$value), na.rm = TRUE)
  if (unit == "pct") {
    div <- 1; digits <- 1; now_head <- "%"
  } else if (is.finite(big) && big >= 1e8) {
    div <- 1e6; digits <- 1; now_head <- "$B"
  } else {
    div <- 1e3; now_head <- "$M"
    digits <- if (is.finite(big) && big >= 1e5) 0 else 1
  }
  num <- function(x, sign = FALSE) {
    if (!is.finite(x)) return("–")
    x <- round(x / div, digits)
    s <- formatC(abs(x), format = "f", digits = digits, big.mark = ",")
    if (x > 0 && sign) paste0("+", s) else if (x < 0) paste0("−", s) else s
  }
  # Rows matched by position within the section; "Other" may be dropped
  # from one quarter's income statement, so match by label when it differs
  prior_val <- function(i) {
    if (is.null(b)) return(NA)
    j <- which(b$label == a$label[i] & b$kind == a$kind[i])
    if (length(j)) b[[col]][j[1]] else NA
  }
  rows <- lapply(seq_len(nrow(a)), function(i) {
    if (a$kind[i] == "head") {
      return(tags$tr(class = "fs-head", tags$td(colspan = 4, a$label[i])))
    }
    now_v <- a[[col]][i]
    chg <- now_v - prior_val(i)
    tags$tr(class = if (a$kind[i] == "total") "fs-total",
            tags$td(a$label[i]),
            tags$td(class = "text-end", num(now_v)),
            tags$td(class = "text-end text-muted", num(chg, sign = TRUE)),
            tags$td(class = "fs-tab", a$tab[i]))
  })
  tags$table(
    class = "table table-sm fs-table mb-0",
    tags$thead(tags$tr(
      tags$th(""),
      tags$th(class = "text-end", paste(quarter_name(rd), "·", now_head)),
      tags$th(class = "text-end",
              paste("vs", quarter_name(prior_rd))),
      tags$th("More in")
    )),
    tags$tbody(rows)
  )
}
