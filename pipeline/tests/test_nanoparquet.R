# nanoparquet 0.5.1 returned garbage instead of NA when read_parquet() used
# col_select on a subset or reordering of the columns (fixed in 0.5.2, #170).
# CI got 0.5.1 from an old package snapshot and corrupted every mart whose
# builder reads raw with col_select. Pins the version and the behavior.
suppressPackageStartupMessages(library(nanoparquet))   # as in build.R

expect(packageVersion("nanoparquet") >= "0.5.2", "nanoparquet >= 0.5.2 (build.R refuses older)")

n <- 500L
d <- data.frame(
  CERT  = seq_len(n),
  ASSET = ifelse(seq_len(n) %% 3L == 0L, NA, seq_len(n) * 1.5),
  DEP   = ifelse(seq_len(n) %% 7L == 1L, NA_integer_, seq_len(n)),
  NAME  = ifelse(seq_len(n) %% 5L == 2L, NA, paste0("bank", seq_len(n))),
  FLAG  = ifelse(seq_len(n) %% 4L == 3L, NA, seq_len(n) %% 2L == 0L),
  SCAF  = NA_real_,
  stringsAsFactors = FALSE
)
f <- tempfile(fileext = ".parquet")
write_parquet(d, f)

full <- as.data.frame(read_parquet(f))
cols <- c("SCAF", "NAME", "ASSET", "FLAG")   # reordered subset, CERT and DEP skipped
sub  <- as.data.frame(read_parquet(f, col_select = cols))
expect(identical(sub, full[cols]), "col_select of a reordered subset equals the full read's subset")
expect(identical(sapply(sub, function(x) sum(is.na(x))), sapply(d[cols], function(x) sum(is.na(x)))),
       "col_select keeps every NA where it was written")
unlink(f)
