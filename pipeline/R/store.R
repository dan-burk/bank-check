# Raw store under pipeline/out/: one parquet per quarter, manifest.csv,
# and the revisions log. Needs RAW and OUT (set in build.R).

raw_path <- function(rd) file.path(RAW, paste0("risdate.", rd, ".parquet"))

# Every raw quarter on disk, newest first
raw_files <- function() {
  sort(list.files(RAW, pattern = "^risdate\\.\\d{8}\\.parquet$",
                  full.names = TRUE), decreasing = TRUE)
}

# The quarter (integer YYYYMMDD) of each raw file path
raw_rds <- function(files) {
  as.integer(sub("^risdate\\.(\\d{8})\\.parquet$", "\\1", basename(files)))
}

# ---- Change check ----------------------------------------------------------
# Every value that differs between the stored copy and the new pull, keyed by
# CERT. Numbers compare with a small tolerance (JSON round-trips can wobble
# in the last digit); NA vs a value counts as a change.
#
# A column only one side has is a schema change, not a revision: it is
# logged as one row per quarter (CERT NA, field "<schema>", old = columns
# dropped, new = columns added, comma-separated), and its values are not
# compared. Without this, widening RAW_FIELDS would log every new value as
# NA -> value (about 4,000 rows per column per quarter).
diff_quarter <- function(old, new, rd, seen) {
  out <- list()
  cols_dropped <- setdiff(names(old), names(new))
  cols_added   <- setdiff(names(new), names(old))
  if (length(cols_dropped) || length(cols_added)) {
    out$schema <- data.frame(risdate = rd, CERT = NA_integer_, field = "<schema>",
                             old = paste(cols_dropped, collapse = ","),
                             new = paste(cols_added, collapse = ","))
  }
  gone  <- setdiff(old$CERT, new$CERT)
  added <- setdiff(new$CERT, old$CERT)
  if (length(gone))  out$gone  <- data.frame(risdate = rd, CERT = gone,  field = "<bank>", old = "present", new = "absent")
  if (length(added)) out$added <- data.frame(risdate = rd, CERT = added, field = "<bank>", old = "absent",  new = "present")
  both <- intersect(old$CERT, new$CERT)
  o <- old[match(both, old$CERT), , drop = FALSE]
  n <- new[match(both, new$CERT), , drop = FALSE]
  for (f in setdiff(intersect(names(o), names(n)), "CERT")) {
    a <- o[[f]]; b <- n[[f]]
    if (is.numeric(a) && is.numeric(b)) {
      same <- (is.na(a) & is.na(b)) |
              (!is.na(a) & !is.na(b) & abs(a - b) <= 1e-9 * pmax(1, abs(a)))
    } else {
      a <- as.character(a); b <- as.character(b)
      same <- (is.na(a) & is.na(b)) | (!is.na(a) & !is.na(b) & a == b)
    }
    if (any(!same)) {
      out[[f]] <- data.frame(risdate = rd, CERT = both[!same], field = f,
                             old = as.character(a[!same]),
                             new = as.character(b[!same]))
    }
  }
  if (length(out) == 0) return(NULL)
  d <- do.call(rbind, out); d$seen <- seen; rownames(d) <- NULL
  d
}

# Write one quarter over its stored copy. Returns the quarter's manifest row
# and its revisions (NULL when it is a first pull or nothing changed).
store_quarter <- function(df, rd, seen, t1) {
  path <- raw_path(rd)
  n_changes <- NA_integer_
  d <- NULL
  if (file.exists(path)) {
    d <- diff_quarter(as.data.frame(read_parquet(path)), df, rd, seen)
    n_changes <- if (is.null(d)) 0L else nrow(d)
  }
  write_parquet(df, path, compression = "zstd")
  man <- data.frame(
    risdate = rd, n_banks = nrow(df), n_fields = ncol(df),
    bytes = file.size(path),
    md5 = unname(tools::md5sum(path)),
    pulled_at = seen,
    changes_vs_stored = n_changes,
    seconds = round(as.numeric(difftime(Sys.time(), t1, units = "secs")), 1)
  )
  cat(sprintf("  %d  %5d banks  %6.0f KB  changes: %s\n", rd, nrow(df),
              file.size(path) / 1024,
              if (is.na(n_changes)) "first pull" else n_changes))
  list(manifest = man, revisions = d)
}

# Merge into the stored manifest, so quarters pulled by an earlier run
# (the backfill) keep their rows. Returns the merged manifest.
save_manifest <- function(manifest) {
  man_path <- file.path(RAW, "manifest.csv")
  if (file.exists(man_path)) {
    old <- utils::read.csv(man_path)
    manifest <- rbind(old[!old$risdate %in% manifest$risdate, names(manifest)],
                      manifest)
  }
  manifest <- manifest[order(-manifest$risdate), ]
  utils::write.csv(manifest, man_path, row.names = FALSE)
  manifest
}

append_revisions <- function(revisions) {
  rev_path <- file.path(OUT, "revisions.csv")
  if (length(revisions)) {
    rev <- do.call(rbind, revisions)
    utils::write.table(rev, rev_path, sep = ",", row.names = FALSE,
                       col.names = !file.exists(rev_path),
                       append = file.exists(rev_path))
    cat("Revisions logged:", nrow(rev), "->", rev_path, "\n")
  }
}
