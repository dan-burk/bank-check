# R/hmda_book.R (filter, links, groups), sources/hmda.R (stream, checks)
# and the bank_ids LEI links, on hand-built LAR rows with hand-computed answers.

lar_row <- function(...) {
  base <- list(activity_year = "2021", lei = "LEIA", state_code = "SD", action_taken = "1",
               purchaser_type = "0", loan_type = "1", loan_purpose = "1", lien_status = "1",
               reverse_mortgage = "2", open_end_line_of_credit = "2",
               business_or_commercial_purpose = "2", loan_amount = "205000",
               interest_rate = "3.0", loan_term = "360", intro_rate_period = "NA",
               total_units = "1")
  as.data.frame(utils::modifyList(base, list(...)), stringsAsFactors = FALSE)
}

# ---- hmda_filter ---------------------------------------------------------------
d <- rbind(lar_row(),                                   # 1 kept by the filter
           lar_row(action_taken = "3"),                 # 2 denied
           lar_row(lien_status = "2"),                  # 3 junior lien
           lar_row(open_end_line_of_credit = "1"),      # 4 HELOC
           lar_row(reverse_mortgage = "1"),             # 5 reverse
           lar_row(business_or_commercial_purpose = "1"),  # 6 business
           lar_row(total_units = "5-24"),               # 7 multifamily
           lar_row(loan_amount = "NA"),                 # 8 no amount
           lar_row(open_end_line_of_credit = "1111", reverse_mortgage = "1111"))  # 9 exempt flags
expect(identical(hmda_filter(d), c(TRUE, rep(FALSE, 7), TRUE)),
       "filter: originated closed-end 1-4 unit first liens with an amount; exempt flags stay in")
expect(identical(hmda_first_lien(d), c(TRUE, FALSE, FALSE, rep(TRUE, 6))),
       "first-lien count (the published population) ignores the closed-end filters")

# ---- hmda_links: dated LEI -> RSSD -> CERT -------------------------------------
reporters <- data.frame(activity_year = 2021L, lei = c("LEIA", "LEIB", "LEIC"),
                        respondent_rssd = c(100L, NA, 300L), rssd_panel_year = c(2021L, NA, 2021L))
ids <- data.frame(CERT    = c(1L, 2L, 2L, 3L),
                  RISDATE = c(20210630L, 20211231L, 20221231L, 20201231L),
                  RSSDID  = c(100L, 100L, 100L, 300L))
l <- hmda_links(reporters, ids)
expect(identical(l$CERT, c(2L, NA, NA)) &&
         identical(l$link, c("matched", "no_rssd", "rssd_not_in_fdic")),
       "links: RSSD -> CERT of the newest call report in the HMDA year; RSSD filing only in 2020 does not match 2021")
expect_error(hmda_links(rbind(reporters, transform(reporters[1, ], activity_year = 2022L)), ids),
             "one HMDA year", "links: one year at a time")

# ---- hmda_groups ---------------------------------------------------------------
lar <- rbind(
  lar_row(loan_amount = "200000", interest_rate = "3.06"),          # 3.06 -> 3.000
  lar_row(loan_amount = "100000", interest_rate = "2.94"),          # 2.94 -> 3.000, same group
  lar_row(loan_amount = "300000", interest_rate = "3.07", purchaser_type = "1"),  # sold, 3.125
  lar_row(loan_amount = "50000", interest_rate = "Exempt", loan_term = "Exempt",
          intro_rate_period = "Exempt"),                            # all unknown: NA, never 360
  lar_row(loan_amount = "400000", interest_rate = "5.5", intro_rate_period = "60"),   # 5/1 ARM
  lar_row(loan_amount = "80000", interest_rate = "6", loan_term = "180",
          intro_rate_period = "180"),                               # intro = term: fixed
  lar_row(loan_amount = "70000", interest_rate = "25", loan_term = "600"))  # out of range: NA
lar$CERT <- 7L
g <- hmda_groups(lar)
key <- paste(g$term_m, g$coupon, g$fixed, g$reset_m, g$kept)
want <- c("360 3 TRUE NA TRUE" = 300, "360 5.5 FALSE 60 TRUE" = 400, "180 6 TRUE NA TRUE" = 80,
          "NA NA NA NA TRUE" = 50, "NA NA TRUE NA TRUE" = 70, "360 3.125 TRUE NA FALSE" = 300)
expect(setequal(key, names(want)) && all(abs(g$usd_k[match(names(want), key)] - want) < 1e-9),
       "groups: coupon to 1/8, term in years, ARM reset, kept; unknowns grouped as NA with their dollars")
expect(sum(g$n) == nrow(lar) && sum(g$usd_k) == 1200 && all(g$CERT == 7L & g$year == 2021L),
       "groups: every loan and dollar ($ thousands) counted once")
expect(is.integer(g$term_m) && is.integer(g$reset_m), "groups: term and reset in whole months")
bad <- lar; bad$CERT[1] <- NA
expect_error(hmda_groups(bad), "without CERT", "groups: a loan with no CERT fails")

s <- hmda_group_summary(g)
expect(abs(s$kept_share - 900 / 1200) < 1e-12 &&
         abs(s$rate_coverage - 780 / 900) < 1e-12 &&
         abs(s$wac_kept - (3 * 300 + 5.5 * 400 + 6 * 80) / 780) < 1e-12,
       "summary: kept_share, rate coverage and WAC of kept dollars")
sold <- g[!g$kept, ]
s2 <- hmda_group_summary(sold)
expect(s2$kept_share == 0 && is.na(s2$rate_coverage) && is.na(s2$wac_kept),
       "summary: a bank that kept nothing has NA coverage and WAC, not 0 or NaN")
expect(nrow(check_hmda_groups(g, 2021L)) == 1, "groups check passes")
expect_error(check_hmda_groups(rbind(g, g[1, ]), 2021L), "duplicate group key",
             "groups check: a duplicated key fails")
expect_error(check_hmda_groups(g, c(2021L, 2022L)), "years differ",
             "groups check: a stored year with no groups fails")

# ---- hmda_stream: chunk boundaries, header with "-", totals ----------------------
dir <- tempfile("hmda_"); dir.create(dir)
csv <- file.path(dir, "2021_public_lar_csv.csv")
rows <- rbind(lar_row(lei = "LEIA"), lar_row(lei = "LEIB", loan_amount = "100000"),
              lar_row(lei = "LEIA", action_taken = "3"), lar_row(lei = "LEIA", loan_amount = "50000"),
              lar_row(lei = "LEIB", lien_status = "2"))
names(rows)[names(rows) == "open_end_line_of_credit"] <- "open-end_line_of_credit"
rows$extra <- "x"                                   # a column the stream drops
utils::write.csv(rows, csv, row.names = FALSE, quote = FALSE)
zip <- file.path(dir, "2021_public_lar_csv.zip")
utils::zip(zip, csv, flags = "-jq")
st <- hmda_stream(zip, basename(csv), keep = "LEIA", chunk = 2L)
expect(st$n_lines == 5 && st$n_first_lien == 3,
       "stream: every line read across chunks of 2; first liens counted for all lenders")
expect(identical(sort(names(st$lar)), sort(HMDA_LAR_COLS)) && nrow(st$lar) == 2 &&
         all(st$lar$lei == "LEIA"), "stream: kept columns only, filtered loans of kept lenders")
lt <- st$lenders[order(st$lenders$lei), ]
expect(identical(lt$n_loans, c(2L, 1L)) && all(abs(lt$usd_k - c(255, 100)) < 1e-9),
       "stream: filtered originations per lender, every lender")
unlink(dir, recursive = TRUE)

# ---- check_hmda_year -------------------------------------------------------------
rep_ok <- data.frame(lei = c("LEIA", "LEIB", "LEIC"), lar_count = c(3L, 2L, 0L),
                     agency_code = c("3", "9", "7"), respondent_rssd = c(100L, 900L, NA),
                     link = c("matched", "rssd_not_in_fdic", "no_rssd"))
st$lar$CERT <- 1L
expect(abs(check_hmda_year(2021L, st, rep_ok, published = 3.1, fdic_rssd = 100L) - 1) < 1e-12,
       "year check passes: a CFPB lender whose RSSD files no call report is not a bank")
expect_error(check_hmda_year(2021L, st, transform(rep_ok, lar_count = c(3L, 3L, 0L)), 3, 100L),
             "transmittal sheets count 6", "year check: rows read != the TS count fails")
expect_error(check_hmda_year(2021L, st, rep_ok, published = 4, fdic_rssd = 100L),
             "data browser publishes 4", "year check: more than 10% off the published count fails")
expect_error(check_hmda_year(2021L, st, rep_ok, published = 3, fdic_rssd = c(100L, 900L)),
             "only 71.8% of bank-originated dollars", "year check: under 90% of bank dollars linked fails")
expect_error(check_hmda_year(2021L, st, transform(rep_ok[-2, ], lar_count = c(5L, 0L)),
                             published = 3, fdic_rssd = 100L),
             "missing from the transmittal", "year check: a LAR lender with no TS row fails")

expect(identical(hmda_parse_years("2018:2020,2025"), c(2018L, 2019L, 2020L, 2025L)),
       "years argument: ranges and lists")

# ---- bank_ids LEI links ----------------------------------------------------------
ids0 <- data.frame(CERT = 1:3, NAMEFULL = c("A", "B", "C"), RSSD = c(100L, 200L, NA))
panel <- data.frame(activity_year = c(2020L, 2021L, 2021L, 2021L, 2021L),
                    lei = c("OLD1", "NEW1", "TWIN1", "LEI2", "CU"),
                    CERT = c(1L, 1L, 1L, 2L, NA), link = c(rep("matched", 4), "no_rssd"),
                    usd_k = c(10, 50, 5, 7, 99))
x <- add_lei_links(ids0, panel)
expect(identical(x[names(ids0)], ids0), "LEI links: every bank_ids column unchanged")
expect(identical(x$LEI, c("NEW1", "LEI2", NA)) && identical(x$lei_year, c(2021L, 2021L, NA)) &&
         identical(x$n_lei, c(3L, 1L, 0L)) && identical(x$lei_source, c("hmda_panel", "hmda_panel", NA)),
       "LEI links: newest year, more dollars on a tie; n_lei over all years; NA without a link")
y <- add_lei_links(ids0, NULL)
expect(all(is.na(y$LEI)) && identical(y[names(ids0)], ids0), "LEI links: no panel stored -> NA columns")
expect_error(add_lei_links(ids0[1:2, ], transform(panel, CERT = c(1L, 1L, 1L, 9L, NA))),
             "not in bank_ids", "LEI links: a panel CERT unknown to bank_ids fails")
