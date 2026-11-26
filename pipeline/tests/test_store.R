# R/store.R diff_quarter(): a schema change is one <schema> row per
# quarter, not one revision per value of the new columns
old <- data.frame(CERT = c(1L, 2L, 3L), ASSET = c(10, 20, 30), NAMEFULL = c("A", "B", "C"))
new <- data.frame(CERT = c(1L, 2L, 4L), ASSET = c(10, 21, 40), NAMEFULL = c("A", "B", "D"),
                  LNRS3LES = c(5, NA, 7), RSSDID = c(11L, 12L, 14L))
d <- diff_quarter(old, new, 20260930L, "t")
sch <- d[d$field == "<schema>", ]
expect(nrow(sch) == 1 && is.na(sch$CERT) && sch$old == "" && sch$new == "LNRS3LES,RSSDID",
       "added columns: exactly one <schema> row, CERT NA, new = the added columns")
expect(!any(d$field %in% c("LNRS3LES", "RSSDID")), "values of added columns are not logged as revisions")
expect(identical(paste(d$CERT, d$field, d$old, d$new)[d$field != "<schema>"],
                 c("3 <bank> present absent", "4 <bank> absent present", "2 ASSET 20 21")),
       "bank and value revisions are logged as before")
d <- diff_quarter(new, old, 20260930L, "t")
expect(identical(d$old[d$field == "<schema>"], "LNRS3LES,RSSDID") &&
         identical(d$new[d$field == "<schema>"], ""),
       "dropped columns: one <schema> row, old = the dropped columns")
expect(is.null(diff_quarter(old, old, 20260930L, "t")), "same schema, same values: no rows")
expect(!any(diff_quarter(old, transform(old, ASSET = c(10, 20, 31)), 1L, "t")$field == "<schema>"),
       "same schema: no <schema> row")
