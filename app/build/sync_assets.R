# Refresh the shipped offline fallback in app/data/.
#
# The app fetches the cross-section and the institution directory live, so
# these files are NOT what users normally see -- they are the fallback for
# FDIC downtime, and what the CI smoke test runs against so the deploy gate
# needs no network. They only need refreshing occasionally, to keep the
# fallback from drifting far behind live.
#
# Run from the repo root, then commit whatever it changes:
#   Rscript.exe app/build/sync_assets.R

setwd("app")
source("R/api.R")
source("R/data.R")

# latest_risdate() applies the completeness guard, so a quarter that has
# only just opened (a few hundred early filers) is rejected in favor of the
# last full one -- a half-filled cross-section would poison every peer band.
rd <- latest_risdate()
if (is.na(rd)) stop("FDIC API returned no quarters")
cat("Latest usable quarter:", rd, "\n")

xs <- fetch_all_banks_quarter(rd)
if (is.null(xs) || nrow(xs) < 3000) {
  stop("Cross-section came back with ", if (is.null(xs)) 0 else nrow(xs),
       " banks; refusing to overwrite a good fallback.")
}
need <- c("CERT", "ASSET", "DEP", "EQ", "LNLSNET", "LNATRES", "RISDATE")
gap  <- setdiff(need, names(xs))
if (length(gap)) stop("Cross-section missing columns: ",
                      paste(gap, collapse = ", "))

# Prove the shipped file survives the app's own derive() before writing it
chk <- derive(xs)
stopifnot(nrow(chk) == nrow(xs))
cat("Cross-section:", nrow(xs), "banks x", ncol(xs), "fields,",
    "label", xs_quarter_label(chk), "\n")

out <- file.path("data", paste0("xs_", rd, ".rds"))
saveRDS(xs, out)

# Drop superseded snapshots: newest_xs() takes the newest, but leaving old
# ones behind just grows the shinylive bundle with dead weight.
old <- setdiff(list.files("data", pattern = "^xs_[0-9]{8}\\.rds$",
                          full.names = TRUE), out)
if (length(old)) {
  file.remove(old)
  cat("Removed superseded:", paste(basename(old), collapse = ", "), "\n")
}

inst <- fetch_institutions()
if (is.null(inst) || nrow(inst) < 3000) {
  stop("Institution directory came back with ",
       if (is.null(inst)) 0 else nrow(inst),
       " banks; refusing to overwrite a good fallback.")
}
saveRDS(inst, file.path("data", "institutions.rds"))
cat("Institutions:", nrow(inst), "banks\n")
cat("Done. Commit app/data/ to ship the refreshed fallback.\n")
