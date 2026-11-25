# One-off: check which extra Call Report fields the FDIC API returns.
# Run from repo root:  Rscript research/run-stress/probe_fields.R
source("app/R/api.R")
f <- "CERT,REPDTE,ASSET,CHBAL,FREPO,INTAN,TRADE,SCPLEDGE,LNATRES,LNLSNET,OTHBFHLB,DEPINS,EQTOT,RBCT1J,RBC1AAJ,SC,SCAF,SCHA,SCHF,LIAB,DEP"
b <- fdic_query(FDIC_FINANCIALS_ENDPOINT, list(
  filters = "CERT:24735 AND RISDATE:20221231", fields = f, limit = 5))
str(flatten_body(b))
