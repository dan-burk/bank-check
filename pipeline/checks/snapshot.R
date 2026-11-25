# Checks on latest_snapshot. stop()s on the first failure.
check_snapshot <- function(snap) {
  filed <- snap[!is.na(snap$RISDATE), ]
  check(length(unique(filed$RISDATE)) == 1, "snapshot mixes quarters")
  check(nrow(filed) >= 3000, paste("snapshot has only", nrow(filed), "filers"))
  check(sum(snap$active) >= 3000, paste("only", sum(snap$active), "active banks"))
  check(!anyDuplicated(snap$CERT), "duplicate CERTs in snapshot")
  check(!any(is.na(snap$NAME[snap$active])), "active bank without a name")
  need <- c("CERT", "RISDATE", "ASSET", "DEP", "EQ", "LNLSNET", "LNATRES")
  check(all(need %in% names(snap)), "snapshot missing core columns")
}
