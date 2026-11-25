# Run-stress step 3: one chart. Banks (top row) and their assets (bottom row)
# that break (Tier 1 below 2% of assets, or can't pay) as the run grows,
# 2022Q4 vs the latest quarter, FHLB backstop off (solid) and on (dashed).
# Reads curves.csv from 02_run.R.
# Run from the repo root:  Rscript research/run-stress/03_chart.R

library(ggplot2)
DIR <- "research/run-stress"
cv <- read.csv(file.path(DIR, "curves.csv"))
latest <- max(cv$quarter)
qlab <- function(q) sprintf("%sQ%d", substr(q, 1, 4), as.integer(substr(q, 5, 6)) / 3)
cv$Quarter <- factor(qlab(cv$quarter), levels = qlab(c(20221231, latest)))
cv$Backstop <- factor(ifelse(cv$fhlb, "FHLB borrowing ON (up to 25% of assets)",
                             "FHLB borrowing OFF"),
                      levels = c("FHLB borrowing OFF", "FHLB borrowing ON (up to 25% of assets)"))
RUNS <- c("Run on uninsured deposits", "Run on all deposits")
WHAT <- c("banks that break", "their assets, $ billions")
cv$panel_col <- factor(ifelse(cv$run_on == "unins", RUNS[1], RUNS[2]), levels = RUNS)
long <- rbind(
  data.frame(cv[c("s", "Quarter", "Backstop", "panel_col")], what = WHAT[1], y = cv$breaks),
  data.frame(cv[c("s", "Quarter", "Backstop", "panel_col")], what = WHAT[2], y = cv$assets_break_bn))
long$what <- factor(long$what, levels = WHAT)

# Mark where SVB / First Republic break in 2022Q4 (uninsured run, FHLB off)
v <- read.csv(file.path(DIR, "validation.csv"))
v <- v[v$check == "last public quarter" & v$quarter == 20221231 & !is.na(v$bp_unins), ]
v$lab <- c("24735" = "SVB", "59017" = "First Republic")[as.character(v$CERT)]
ann <- data.frame(s = v$bp_unins, lab = paste(v$lab, "breaks"),
                  panel_col = factor(levels(long$panel_col)[1], levels = levels(long$panel_col)),
                  what = factor(levels(long$what)[2], levels = levels(long$what)),
                  left = v$lab == "SVB")

p <- ggplot(long, aes(100 * s, y, colour = Quarter, linetype = Backstop)) +
  geom_step(linewidth = 0.8) +
  geom_vline(data = ann, aes(xintercept = 100 * s), colour = "#8a8984", linewidth = 0.4,
             linetype = "dotted", inherit.aes = FALSE) +
  geom_text(data = ann, aes(x = 100 * s - 1.5, y = Inf, label = lab,
                            vjust = ifelse(left, 1.5, 3.2)),
            inherit.aes = FALSE, hjust = 1, size = 3.3, colour = "#52514e") +
  facet_wrap(~ panel_col + what, scales = "free_y", ncol = 2, dir = "v",
             labeller = function(l) list(paste0(l$panel_col, ": ", l$what))) +
  scale_y_continuous(breaks = function(l) unique(round(pretty(l)))) +
  scale_colour_manual(values = c("#eb6834", "#2a78d6")) +
  scale_linetype_manual(values = c("solid", "22")) +
  scale_x_continuous("Run size: % of those deposits withdrawn", breaks = seq(0, 100, 20),
                     expand = c(0.01, 0)) +
  labs(y = NULL, colour = NULL, linetype = NULL,
       caption = "Uninsured run is the realistic case: insured depositors rarely run.",
       title = "How big a deposit run does it take to push banks below 2% capital (or out of cash)?",
       subtitle = paste("Each bank pays the run from cash, then fed funds, (FHLB), trading assets, AFS, HTM",
                        "securities, then loans,\nrealizing the market-value losses. Below 2% tangible",
                        "equity, the law requires the regulator to close the bank within ~90 days.")) +
  theme_minimal(base_size = 12) +
  theme(legend.position = "top", legend.justification = "left",
        strip.text = element_text(face = "bold", size = 10.5, hjust = 0),
        panel.spacing.x = unit(2, "lines"), panel.spacing.y = unit(1, "lines"),
        panel.grid.minor = element_blank(), panel.grid.major = element_line(colour = "#e6e5e0"),
        plot.title = element_text(face = "bold", size = 14),
        plot.subtitle = element_text(colour = "#52514e", size = 10.5),
        plot.background = element_rect(fill = "#fcfcfb", colour = NA))
ggsave(file.path(DIR, "run_curves.png"), p, width = 11, height = 7.5, dpi = 150)
message("wrote run_curves.png")
