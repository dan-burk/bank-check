# Backtest step 3: one chart. For each failed bank, where it ranked among
# all banks in each of the 4 quarters before it failed, under the baseline
# (reported equity / assets, Tier 1 leverage) and our score (adjusted
# equity / assets, base). Reads failed_bank_ranks.csv from 02_backtest.R.
# Run from the repo root:  Rscript research/backtest/03_chart.R

library(ggplot2)
DIR <- "research/backtest"
fr <- read.csv(file.path(DIR, "failed_bank_ranks.csv"))
fl <- read.csv(file.path(DIR, "failures.csv"))

SHORT <- c("24735" = "Silicon Valley Bank", "57053" = "Signature Bank",
           "59017" = "First Republic", "25851" = "Heartland Tri-State",
           "8758" = "Citizens Bank (Sac City)", "27332" = "Republic First",
           "4134" = "First NB of Lindsay", "28611" = "Pulaski Savings",
           "5520" = "Santa Anna NB", "57488" = "Metropolitan Capital",
           "25796" = "CB&T West Georgia", "28722" = "Kentland FS&LA",
           "25744" = "Small Business Bank")
GROUP <- c("rate+run" = "rate losses + run", fraud = "fraud", credit = "credit / losses")
fl$panel <- sprintf("%s\n%s · %s", SHORT[as.character(fl$CERT)],
                    format(as.Date(fl$fail_date), "%b %Y"), GROUP[fl$group])
fr$panel <- factor(fl$panel[match(fr$CERT, fl$CERT)], levels = fl$panel)

SERIES <- c(p_adj_eq = "Ours: equity after hidden losses",
            p_eq_ta = "Baseline: reported equity / assets",
            p_tier1_leverage = "Baseline: Tier 1 leverage ratio")
long <- do.call(rbind, lapply(names(SERIES), function(s)
  data.frame(panel = fr$panel, q = fr$qtrs_before,
             pct = pmax(fr[[s]], 0.0002), series = SERIES[[s]])))
long$series <- factor(long$series, levels = SERIES)

g <- ggplot(long, aes(q, pct, colour = series, shape = series)) +
  annotate("rect", xmin = -Inf, xmax = Inf, ymin = 0.0002, ymax = 0.05,
           fill = "#eef3fb") +
  geom_hline(yintercept = c(0.01, 0.05), colour = "#9a9994", linewidth = 0.3,
             linetype = "22") +
  geom_line(aes(linewidth = series)) +
  scale_linewidth_manual(values = c(1.2, 0.6, 0.6), name = NULL) +
  geom_point(size = 2.2, stroke = 0.9, fill = "#fcfcfb") +
  facet_wrap(~panel, ncol = 5) +
  scale_x_reverse(breaks = 4:1, labels = c("4", "3", "2", "1"),
                  expand = expansion(add = 0.3)) +
  scale_y_continuous(breaks = c(0.001, 0.01, 0.05, 0.2, 1),
                     labels = c("0.1%", "1%", "5%", "20%", "100%"),
                     transform = scales::transform_compose(scales::transform_log10(),
                                                           scales::transform_reverse())) +
  scale_colour_manual(values = c("#2a78d6", "#eb6834", "#1baf7a"), name = NULL) +
  scale_shape_manual(values = c(16, 21, 24), name = NULL) +
  labs(title = "Where each failed bank ranked before it failed",
       subtitle = paste0("Share of all US banks that looked at least as weak that quarter ",
                         "(top = worst). Shaded = the worst-5% watch list; dashed = 1% and 5%.\n",
                         "x axis: call reports before failure (1 = the last one public before ",
                         "the bank failed). 2022-2026, 13 failures."),
       x = "Quarters before failure", y = "Rank from the worst end (log scale)") +
  theme_minimal(base_size = 11) +
  theme(plot.background = element_rect(fill = "#fcfcfb", colour = NA),
        panel.grid.minor = element_blank(), panel.grid.major.x = element_blank(),
        panel.grid.major.y = element_line(colour = "#e6e5e1", linewidth = 0.3),
        strip.text = element_text(face = "bold", hjust = 0, size = 9.5, colour = "#0b0b0b"),
        plot.title = element_text(face = "bold", size = 15, colour = "#0b0b0b"),
        plot.subtitle = element_text(colour = "#52514e", size = 10),
        axis.text = element_text(colour = "#52514e"),
        legend.position = "top", legend.justification = "left",
        legend.text = element_text(size = 10.5))
ggsave(file.path(DIR, "failed_bank_ranks.png"), g, width = 13, height = 8.5, dpi = 150)
