# Mart: latest_snapshot.
# The newest quarter's filings joined to the FDIC directory of active banks.
# Replaces both the cross-section (peer bands) and the institution list
# (picker). Rows: every bank that filed, plus any active bank that has not
# filed yet (a new charter), so the picker never loses one. Banks that filed
# but are not active (clearing houses, trust-only charters, banks closed
# after quarter end) stay for the peer bands with active = FALSE.
# One request (the directory). Returns list(snap, n_unfiled).
build_snapshot <- function(newest) {
  dir_df <- fetch_institutions()
  if (is.null(dir_df) || nrow(dir_df) < 3000) {
    stop("Directory came back with ", if (is.null(dir_df)) 0 else nrow(dir_df), " banks")
  }
  snap <- as.data.frame(read_parquet(raw_path(newest)))
  snap$active <- snap$CERT %in% dir_df$CERT
  d <- dir_df[match(snap$CERT, dir_df$CERT), ]
  snap$NAME <- ifelse(is.na(d$NAME), snap$NAMEFULL, d$NAME)
  snap$CITY <- ifelse(is.na(snap$CITY), d$CITY, snap$CITY)
  unfiled <- dir_df[!dir_df$CERT %in% snap$CERT, ]
  if (nrow(unfiled)) {
    extra <- snap[0, ][seq_len(nrow(unfiled)), ]
    extra$CERT <- unfiled$CERT; extra$NAME <- unfiled$NAME
    extra$CITY <- unfiled$CITY; extra$STALP <- unfiled$STALP
    extra$ASSET <- unfiled$ASSET; extra$active <- TRUE
    snap <- rbind(snap, extra)
  }
  snap <- snap[order(-ifelse(is.na(snap$ASSET), -Inf, snap$ASSET)), ]
  rownames(snap) <- NULL
  list(snap = snap, n_unfiled = nrow(unfiled))
}
