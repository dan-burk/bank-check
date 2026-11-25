# Bank Check: guide for Claude Code sessions

Plain R Shiny app comparing any FDIC-insured bank with its peers and with
every post-2000 failure. All data comes from the public FDIC API
(`api.fdic.gov`, no key). It runs as two deployments of the same code:
shinyapps.io (server-side) and GitHub Pages (shinylive/webR, in the browser).
User docs are in `README.md`, and the pipeline design is in `pipeline/README.md`.

## Layout

| Path | What |
|---|---|
| `app/app.R` | UI and server. Tabs: Overview, Industry, the CAMELS-style tabs, failures |
| `app/R/api.R` | The only FDIC transport (base `download.file`, so it works in webR). Holds `APP_FIELDS`, `latest_risdate()`, `prev_quarter_end()` |
| `app/R/data.R` | `derive()`, the live per-bank fetch and its cache, mart loaders (`load_snapshot`, `load_industry`), peer stats |
| `app/R/statements.R` | `statement_lines()`, `statement_table()`, `STATEMENT_FIELDS`, `industry_totals()`. The pipeline uses these too |
| `app/R/plots.R`, `theme.R` | Plotly builders, colors |
| `app/data/` | Shipped data: `fail_panel.rds`, `failures_meta.rds`, `fields_meta.csv`, `data-dictionary.md`. Mart `*.parquet` files are gitignored and downloaded |
| `app/build/build_fail_panel.R` | Rebuilds the failures panel (run monthly by `refresh.yml`) |
| `app/tests/smoke.R` | Deploy gate. Runs offline from the marts and `tests/fixtures/sd_banks.rds` (Dacotah, history from 1984, plus First B&T) |
| `app/tests/integrity.R` | Recomputes chart values from the raw FDIC columns. Phase 2 hits the live API. `INTEGRITY_SKIP_LIVE=1` runs it offline |
| `pipeline/build.R` | Nightly ETL entry point: pulls the last N quarters, writes the revisions log, builds the marts, runs the mart checks. The pieces: `R/` (throttled transport, raw store), `sources/fdic.R`, `marts/`, `checks/` |
| `.github/workflows/pipeline.yml` | Nightly at 08:00 UTC, main only. Publishes the `data-raw` and `data-marts` releases and starts the deploy if the marts changed |
| `.github/workflows/deploy.yml` | Smoke test, then deploys to both shinyapps.io and Pages. Runs on pushes to main that touch `app/**`, `pages/**`, `DESCRIPTION`. PRs run the test only |
| `.github/workflows/refresh.yml` | Monthly failures-panel rebuild, committed to git |
| `DESCRIPTION` | Not a package, just the dependency list that CI installs from a dated Posit snapshot |
| `docs/specs/` | Implementation specs |

## Data flow

The FDIC API is pulled nightly by `pipeline/build.R`, one request per
quarter (paged past the 10k-row cap). It writes:
- **raw**: `risdate.YYYYMMDD.parquet`, one file per quarter, every bank.
  Stored in the `data-raw` GitHub Release along with `manifest.csv` and
  `revisions.csv`.
- **marts**: `industry_quarterly` (one row per quarter, built from every
  raw file on hand) and `latest_snapshot` (newest quarter plus the active
  directory). Stored in the `data-marts` release.

Each deploy downloads the marts into `app/data/` and ships them inside the
site. The app does no multi-bank fetching. A single bank's history is
fetched live (`fetch_bank_financials`, 1984 onward) and cached for 30 days
in `app/data-cache/`.

## Run and test

R runs natively on Linux here: use `Rscript`. CI uses R 4.5.1.

```sh
gh release download data-marts --dir app/data --clobber   # marts first
Rscript -e "shiny::runApp('app', port = 7788)"
Rscript app/tests/smoke.R                                 # deploy gate, offline
INTEGRITY_SKIP_LIVE=1 Rscript app/tests/integrity.R
Rscript pipeline/build.R [N_QUARTERS]                     # default 10; output in pipeline/out/
```

## Data conventions (do not break)

- Dollar fields are **$ thousands**. `RISDATE` = `REPDTE`, an integer
  `YYYYMMDD` at a quarter end. CERT is the join key.
- Quarterly flows use FDIC's **Q fields** (`NIMQ`, `NONIIQ`, `NONIXQ`,
  `ELNATQ`, `IGLSECQ`, `ITAXQ`, `NETINCQ`, `NTLNLSQ`), never YTD
  differencing. `derive()` differences only as a fallback for old cached
  data. Differencing breaks when YTD figures are restated and for the
  semiannual filers of 1985.
- Industry rows are sums of the raw fields. Ratios and percentages are
  computed **on the summed totals** (`statement_lines` on the summed row),
  never by averaging bank ratios. Peer bands are quantiles, not mean/sd.
- The newest quarter counts only once ≥ 95% as many banks have filed as in
  the prior quarter (`XS_MIN_COMPLETE`, `latest_risdate()`).
- Restatement window: each night re-pulls the **last 10 quarters** and logs
  every changed value to `revisions.csv`.
- History starts at **1984 Q1** (17,930 filers; 17,949 at 1984-12-31).
  Early quarters have more than 10k filers, so `pull_quarter()` pages
  through them.
- Missing data is detected and reported, never coerced to 0:
  `statement_lines()` propagates NA, and `industry_totals()` returns NA for
  any field below `COVERAGE_MIN` (`field_coverage()`, which excludes
  foreign-bank branches). See `docs/specs/industry-history.md`.
- webR limits: keep request URLs under about 4,000 chars (use date ranges,
  not OR-lists). The app reads only from `app/`. Don't add readr or an HTTP
  client package. Shinylive's dependency scan reads comments too, so don't
  name packages you don't use.
- API etiquette (pipeline): loop over quarters, never over banks. One
  request at a time, at least 2 s apart, retry after 10/30/90 s, then stop
  without publishing.

## Working rules

- Work on a branch and merge to main by PR. Main deploys, and only main
  publishes data.
- Keep it simple: reuse the existing helpers (`statement_table`,
  `industry_totals`, `fdic_query`). No new database or services, because
  static files in GitHub Releases are the store. Don't add dependencies
  for a few lines.
- Any change to marts or checks must keep `pipeline/build.R` failing
  closed: when a check fails, nothing is published.
- Run the smoke test before committing app changes.
