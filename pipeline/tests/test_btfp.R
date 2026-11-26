# sources/btfp.R: parsing, the borrower table, its check, and the committed file
m <- cbind("Date Of Advance" = c("44998", "45000", "45100"),   # 2023-03-13, -15, 2023-06-23
           "Repayment Date"  = c("45010", "45200", "45110"),
           "Borrower Name"   = c("OLD BK ", "NEW BK", "OTHER CU"),
           "Borrower City"   = c("A", "A", "B"), "Borrower State" = c("TX", "TX", "MN"),
           "Borrower RSSD"   = c("100", "100", "900"),
           "Advance Amount"  = c("5000000", "2500500", "500"))
tx <- btfp_advances(m)
b <- btfp_borrowers(tx)
expect(identical(b$RSSD, c(100L, 900L)) && identical(b$n_advances, c(2L, 1L)),
       "one row per borrower RSSD, advances counted")
expect(identical(b$advances, c(7500.5, 0.5)), "advances summed in $ thousands, not rounded")
expect(b$name[1] == "NEW BK" && b$first_advance[1] == as.Date("2023-03-13") &&
         b$last_repayment[1] == as.Date("2023-10-01"),
       "name of the latest advance; Excel serial dates; latest repayment")
bad <- m; bad[2, "Borrower RSSD"] <- ""
expect_error(btfp_advances(bad), "unparsed values in RSSD", "an advance with no RSSD fails, never 0")

src <- list(n_borrowers = "2", n_advances = "3", advances_total = "7501.000")
ids <- data.frame(CERT = c(1L, 2L), RSSD = c(100L, NA))
expect_error(check_btfp(b, src, ids), "only 50.0% of borrowers join",
             "under BTFP_MIN_BANK_SHARE of borrowers joining to bank_ids fails")
ids$RSSD[2] <- 900L
j <- check_btfp(b, src, ids)
expect(identical(j$CERT, c(1L, 2L)), "join report: CERT per borrower through bank_ids")
expect_error(check_btfp(b, modifyList(src, list(n_advances = "4")), ids), "3 advances",
             "an advance count off the source record fails")
expect_error(check_btfp(b, modifyList(src, list(advances_total = "7600")), ids), "advances total",
             "a total off the source record fails")
expect_error(check_btfp(rbind(b, b[1, ]), modifyList(src, list(n_borrowers = "3")), ids),
             "duplicated", "a duplicated RSSD fails")

# The committed file is the one its source record describes
s <- btfp_source()
cb <- btfp_read()
expect(identical(unname(tools::sha256sum(BTFP_CSV)), s$csv_sha256) &&
         s$xlsx_sha256 == BTFP_EXPECT$sha256,
       "committed btfp.borrowers.csv matches the sha256 in btfp.source.txt")
expect(nrow(cb) == as.integer(s$n_borrowers) && sum(cb$n_advances) == as.integer(s$n_advances) &&
         abs(sum(cb$advances) - as.numeric(s$advances_total)) <= 1 &&
         nrow(cb) == BTFP_EXPECT$n_borrowers,
       "committed file: borrowers, advances and total match the source record")
