# Spec: Fold the research prototypes into the data pipeline

Status: PRs 1-6 implemented (see "PR order"); the rest is design. Inline
"PR 3:" to "PR 6:" notes record where the code differs from this design.

## Goal

Daniel asked: "is the data reproducible... can we live-pull it, can we make
a data pipeline that's easier to iterate upon rather than just be like oh
yeah here are the results... update this quarterly or monthly or however
often the cadence of these reports come out."

Today the four research PRs each have their own fetch script, their own
`cache/` folder and their own committed result CSVs. They answered the
research questions, but nothing refreshes them, two of them pull the same
FDIC quarters again, and a number in a README can't be traced back to a
dated input. This spec moves the **data pulls** and the **finished
estimators** into `pipeline/`, where they refresh on each source's own
schedule, are checked, and are published like the existing marts. The
**analysis** (backtests, charts, sensitivity runs) stays in `research/`.
It reads the pipeline's outputs and fetches nothing of its own.

Research inputs:

| PR | Branch | What it adds | Sources |
|---|---|---|---|
| #19 | `research/unrealized-losses` | Hidden-loss estimator: HTM loss + modeled loan loss per bank | FDIC, FRED `MORTGAGE30US`, `DGS10` (`DGS5` fetched, unused) |
| #20 | `research/hmda-mortgage-rates` | Mortgage book rate (WAC) and mark-to-market loss from loan-level HMDA | HMDA data browser + panel files, FDIC, FRED `MORTGAGE30US`, `MORTGAGE15US` |
| #21 | `research/backtest` | Scores the estimator against every failure 1997-2026 | FDIC 1996Q4 to now, FDIC `/failures`, FRED, Fed BTFP disclosure XLSX |
| #22 | `research/run-stress` | Deposit-run simulator and breaking point per bank (stacked on #19 + #21) | FDIC extra fields, plus the #21 cache |

## Principles

1. **One module per source, one file per mart.** A source module only
   fetches and stores raw data. A mart module only reads raw data (and
   other marts) and computes. Neither does the other's job.
2. **The estimators are pure functions.** They take data frames and a
   parameter list and return a data frame. They don't read cache paths,
   use the network or depend on today's date. The pipeline and the research
   scripts call the same function, so a number in a research README and a
   number in the app come from the same code.
3. **Every source has its own cadence and its own change check.** Nothing
   is re-downloaded unless it can have changed.
4. **FDIC stays the critical path.** A failure in any other source must
   never block the FDIC marts from publishing. (This needs a change to a
   current rule. See open question 1.)
5. **Missing is NA, never 0.** The research code fills NA with 0 in several
   places (see "Correctness traps"). The pipeline versions must count and
   flag every fill, or drop the row and count it.
6. **No new services or stores.** GitHub Releases stay the store and R
   scripts stay the code. The only possible new package is `data.table`,
   for the pipeline only, to stream the HMDA files (open question 4).

## Target layout

```
pipeline/
  build.R               orchestrator: runs the sources that are due, then the marts, then checks, then exits
  R/
    http.R              polite_get(): per-host throttle (>= 2 s), retries 10/30/90 s, request counter
    store.R             raw read/write, keyed diff -> revisions, per-source manifest
    sources.R           the source registry (table below)
    hidden_loss.R       pure estimator (from research/unrealized-losses/estimator.R)
    run_stress.R        pure simulator (from research/run-stress/simulate.R)
    hmda_book.R         HMDA filters, group builder, cash-flow valuation (from 02_analyze.R)
  sources/
    fdic.R              pull_quarter() and the change check, moved out of build.R unchanged
    fred.R
    failures.R
    hmda.R              yearly; run by its own workflow
    btfp.R              one-time; run by hand
  marts/
    industry.R          industry_quarterly + field_coverage (moved, unchanged)
    snapshot.R          latest_snapshot (moved, unchanged)
    fail_panel.R        replaces app/build/build_fail_panel.R
    rates.R             rates_monthly
    hidden_loss.R
    run_stress.R
    hmda_book.R
  checks/               one file per mart: check_<mart>(mart, raw) -> stop() on failure
  tests/                offline unit tests of the pure functions, with hand-built fixtures
  README.md
```

`build.R` keeps its current command line (`Rscript pipeline/build.R [N]`)
and shrinks to about 60 lines that call into these files.

The estimators go in `pipeline/R/`, not `app/R/`. The app only reads the
marts they produce, and shinylive would bundle anything under `app/`.

### Source contract

Each `sources/<name>.R` defines one list:

```r
SOURCE_FRED <- list(
  name     = "fred",
  critical = FALSE,             # TRUE only for fdic
  cadence  = "nightly",         # nightly | yearly | manual
  max_age_days = 10,            # stale limit for the marts that use it
  due      = function(state) TRUE,      # cheap check: is there anything new?
  pull     = function(raw_dir) ...,     # writes raw files; returns the paths it changed
  check    = function(raw_dir) ...      # stop() on a bad pull, before anything is stored
)
```

The registry in `pipeline/R/sources.R` lists the sources. `build.R` runs
each one inside `tryCatch`. A critical source that fails stops the run, as
today. A non-critical source that fails keeps the raw files from its last
good run, which were downloaded from the release at the start of the job,
and logs `source fred FAILED: <message>`. The job then finishes and exits
non-zero, so GitHub still emails the owner.

Each mart declares the sources it uses (`deps = c("fdic", "fred")`). If a
dependency's raw data is older than its `max_age_days`, or failed and has
no good copy, the mart is **not rebuilt**. The previously published copy
stays up and the run reports `mart hidden_loss skipped: fred stale`.

## Sources

| Source | Cadence | Change check (`due`) | Raw files (release `data-raw`) | Critical |
|---|---|---|---|---|
| FDIC financials | nightly, re-pulls the last 10 quarters (as today) | `latest_risdate()` plus the keyed diff of each quarter (as today) | `risdate.YYYYMMDD.parquet`, `manifest.csv`, `revisions.csv` (names unchanged) | yes |
| FDIC institutions | nightly (as today, inside the snapshot mart) | none: one request | not stored as raw today. Store it as `fdic.institutions.parquet` so the ID crosswalk can use `FED_RSSD` | yes |
| FRED | nightly. The series are daily (`DGS10`) or weekly (`MORTGAGE30US`, `MORTGAGE15US`) | always pull (1 request per series), then diff against the stored file | `fred.<SERIES>.csv` (full history), with revisions appended to `fred.revisions.csv` | no |
| FDIC failures | nightly (1 request; the list changes a few times a year) | diff by CERT + FAILDATE | `failures.parquet`, every RESTYPE since 1934 | no |
| HMDA | yearly. The snapshot for year Y comes out in the summer of Y+1. Own workflow `hmda.yml`, manual plus a monthly cron that exits at once unless a new snapshot year is listed | does the snapshot file for year `max(stored)+1` exist? (one HEAD request) | `hmda.lar.YYYY.parquet` (kept columns, FDIC-bank lenders only), `hmda.panel.parquet` (LEI to RSSD), `hmda.groups.parquet` (small, see below) | no |
| BTFP | static. The program ended in 2024 and the borrower file is final | none: `cadence = "manual"` | `btfp.borrowers.csv` plus `btfp.source.txt` (URL, download date, sha256 of the XLSX) | no |

Notes:

- **Release asset names are flat**, so new sources get a `<source>.`
  prefix. The FDIC asset names don't change, so the existing workflow
  downloads and the 171-quarter history keep working.
- **What the nightly job downloads.** Today it downloads every raw FDIC
  quarter. It also needs the FRED, failures and BTFP files (all small) and
  `hmda.groups.parquet`. It never downloads `hmda.lar.*`, at tens of MB
  per year. Only `hmda.yml` reads those.
- **The HMDA split.** The yearly job does the heavy work: it reads the
  multi-GB national snapshot as a stream, keeps the bank-originated,
  first-lien, closed-end loans, and collapses them into `hmda.groups`. One
  row per (CERT, vintage year, term, coupon rounded to 1/8 point, ARM
  reset, kept) with summed dollars, probably under 1 MB. The cash-flow
  valuation is cheap, so the nightly runs it on the groups with the
  current FRED rate and the latest call report balance. As a result the
  book rate only changes once a year, while the loss estimate follows
  rates every week.
- **BTFP** is run once by hand (`Rscript pipeline/sources/btfp.R`). It
  downloads the Fed XLSX, parses it with the minimal reader from #21,
  checks the row count and the total advances against the Fed's published
  totals, and writes the CSV. The CSV is a few hundred rows, so commit it
  to git under `pipeline/static/` next to its `.source.txt` (open question 6).

### The FDIC raw file gets wider

The estimator and the simulator need about 45 Call Report fields that
`APP_FIELDS` does not have (the maturity buckets `LNRS*`, `LNOT*`, `SCNM*`,
`SCPT*`, `SCO*`; the fair values `SCAA`, `SCAF`, `SCHA`, `SCHF`; `ILNLSQ`,
`ISCQ`, `RBCT1J`, `RBC1AAJ`, `DEPUNINS`, `DEPDOM`, `CHBAL`, `FREPO`,
`TRADE`, `INTAN`, `OTHBFHLB`, `SCPLEDGE`, `RSSDID`, ...). The #21 backtest
pulled 119 quarters again just to get them, which the pipeline should not
repeat. Instead:

- `RAW_FIELDS = APP_FIELDS + CITY + RESEARCH_FIELDS`, where
  `RESEARCH_FIELDS` is one constant in `pipeline/R/sources.R`, built from
  the field lists of the estimator modules.
- **The change check must handle a schema change.** As written,
  `diff_quarter()` would log every new column as about 4,000 NA-to-value
  changes per quarter, roughly 30 million rows over 171 quarters. A column
  that is new (absent from the stored file) must be logged as a single
  `<schema>` row per quarter (`field = "<added>", old = "", new = "LNRS3LES,..."`).
- Run it once as a backfill (`quarters = 171`, about 20 minutes), the same
  way as the industry-history backfill.
- First check that the API accepts the longer `fields=` list. The pipeline
  doesn't run in webR, so the 4,000-character browser limit doesn't apply,
  but the server may have its own limit. If it rejects the list, split the
  pull into two requests per quarter and join them on CERT. Don't split the
  raw file.
- Add every research field to the `field_coverage` mart (a separate
  `research_field_coverage` table), so a misspelled field name shows up as
  0% coverage instead of a silent all-NA column.

PR 4: `RESEARCH_FIELDS` lives in `sources/fdic.R` next to `RAW_FIELDS`
(the FDIC source owns its field list), built from `RESEARCH_NEEDS`, one
list per research module: 40 fields beyond `APP_FIELDS` + `CITY`. The API
took all 129 in one request, so there is no split. The `<schema>` row is
`field = "<schema>"`, `old` = columns dropped, `new` = columns added, so a
dropped column is caught too. The API silently drops an unknown field
name (it does not return an NA column), so the coverage mart has an
`in_raw` flag and its check fails when a field is missing from the
newest quarter. `research_field_coverage` and `bank_ids` are non-core
(`build_optional_mart`): their checks hold back only themselves.

## Marts

The marts the app could read are marked **app**. The rest feed other marts
or research.

| Mart | One row per | Built from | Rebuilt | Use |
|---|---|---|---|---|
| `rates_monthly` | month × series: average, last value, number of observations | FRED | nightly | input to hidden_loss and hmda_book; **app** context line ("30y mortgage rate 6.9%") |
| `failures` | failure event (CERT, FAILDATE, RESTYPE, RESTYPE1, QBFASSET, ...) | failures raw | nightly | `fail_panel`, backtest labels. PR 3: not a separate mart. The checked raw `failures.parquet` is this table (a typed copy would only duplicate it) |
| `fail_panel`, `failures_meta` | (CERT, quarter) for the 0-20 quarters before failure | FDIC raw + `failures` | nightly, published only if changed | **app** failures tab. Replaces `build_fail_panel.R` and `refresh.yml`, with **no per-bank requests**, because the raw files already hold every bank since 1984 |
| `bank_ids` | CERT: RSSD, LEI(s), (later) ticker, with the source of each link | FDIC institutions + HMDA panel | nightly | the one ID crosswalk every source joins through. PR 4 (FDIC part): RSSD comes from the call report's `RSSDID` in raw (every filer since 1984), not from `fdic.institutions.parquet`, so there is no new request or raw asset. Every CERT that ever filed, `active` from the snapshot directory |
| `hidden_loss` | (CERT, quarter), last 20 quarters | FDIC raw + `rates_monthly` | nightly | **app**: "hidden loss", "equity after hidden losses / assets" and its percentile. Columns: `loss_htm`, `loss_afs`, `loss_loans_res`, `loss_loans_oth`, `hidden_loss`, `adj_equity_to_assets`, `pct_worst`, `loan_yield`, `loan_yield_imputed`, `rate_gap`, `mtg_rate`, `bucket_cov`, `method_version` |
| `hidden_loss_history` | (CERT, quarter), 1997Q2 to now | same | nightly, published only if changed | research and backtest. Not shipped to the app (about 800k rows) |
| `run_stress` | CERT, latest quarter | `hidden_loss` + FDIC raw | nightly | **app**: breaking point for an uninsured run and an all-deposit run, FHLB off and on, `how` ("below 2%" / "can't pay"), `min_ratio`, rank |
| `hmda_book` | CERT (HMDA-reporting banks) | `hmda.groups` + `rates_monthly` + FDIC raw | nightly (book rate yearly, valuation nightly) | **app**: mortgage book rate (WAC), loss %, duration, HMDA share of the call-report book, `hmda_year_max` |

PR 5: `hidden_loss` also has `na_reason`, and is cut from
`hidden_loss_history` (one estimator run per quarter). Every filer is a
row: banks with zero or negative equity, which the research dropped, are
kept, and foreign-bank branches (no equity) have NA ratios. The history
starts at the first quarter with loan buckets in raw (1997 Q2). Both are
gzip with losses rounded to $1,000 and ratios to 5 decimals: `hidden_loss`
is about 2 MB, over the 1 MB app target, so the app PR should trim
quarters or columns. The `cal_factor` check is "NA or in (0, 5]": the
estimator returns NA in the 77 of 118 quarters where the factor is
negative (net securities gains) or above 5, so the nightly check does not
fail on history. The QBP figures live in `HL_QBP_SEC_LOSS`
(`checks/hidden_loss.R`). Research and the pipeline use the
floored base variant (open question 2); the history keeps `_sym` and `_cal`.

PR 6: `run_stress` is every filer in the newest quarter. Per run
(`unins`, `unins_fhlb`, `all`, `all_fhlb`) it has `bp_*`, `how_*` ("below 2%",
"can't pay", "never", or NA when inputs are missing), `min_ratio_*` and
`pct_worst_*` (a percentile, not a rank: trap 3), plus `unins_share`,
`loan_disc`, `na_reason` and `method_version`. Banks with no loans and no
securities are simulated but not ranked (trap 15). The loan discount comes
from tonight's `hidden_loss`, so the mart has deps fdic + fred and fails
when `hidden_loss` did. The check "`t1_after <= RBCT1J`" became "Tier 1
rises by no more than the securities gains sold", because selling a
security above cost realizes a gain. The research analysis
(`research/run-stress/analyze.R`) runs the same functions on older
quarters from raw + `hidden_loss_history`, and stops unless the newest
quarter equals the mart.

App-facing rules:

- The deploy downloads marts **by name** (`deploy.yml` uses
  `--pattern '<file>'`), so a research mart reaches the app only when its
  app PR adds it there. The history marts never do.
- Every app-facing research mart has `RISDATE` (or `as_of`) and
  `method_version` columns. The app shows the value only if `RISDATE`
  equals the snapshot's quarter. Otherwise it shows "as of <quarter>", so
  a stale research mart is never shown as current.
- If a mart file is missing, the app hides that panel. It must not error.
  The smoke test covers both cases (mart present, mart missing).
- Keep each app mart under about 1 MB, because it ships inside the browser
  bundle.

## What becomes shared code, what stays research

| Research file | Goes to | Changes on the way |
|---|---|---|
| `unrealized-losses/estimator.R` `estimate()` | `pipeline/R/hidden_loss.R` `hidden_loss(cur, prev, rates, params)` | Takes data frames instead of cache paths. Parameters (`DUR`, `MAX_DROP`, ...) are a list argument with the current values as defaults. NA fills are counted and flagged. Ranks keep NA. The symmetric and calibrated variants stay available through parameters, but the mart ships one (open question 2) |
| `unrealized-losses/estimator.R` `fred_month_avg()` | `marts/rates.R` | Reads the `rates_monthly` mart instead of a CSV in a cache folder |
| `run-stress/simulate.R` `run_sim()`, `breaking_point()`, `bp_rank()` | `pipeline/R/run_stress.R` | Already pure. `load_quarter()` becomes the mart builder. Assumptions become a parameter list |
| `hmda-mortgage-rates/02_analyze.R` `mortgage_filter()`, `clean()`, `run_book()`, `value_book()` | `pipeline/R/hmda_book.R` | Split into a yearly part (filter and group) and a nightly part (value the groups). `VAL_DATE` becomes an argument (the latest quarter) |
| `hmda-mortgage-rates/config.R` | removed | `BANKS` becomes "every bank in `bank_ids` with an LEI". The CPR assumptions move to the parameter list |
| `backtest/02_backtest.R` `read_xlsx_min()` | `pipeline/sources/btfp.R` | Used once |
| all four `01_fetch.R`, `probe_coverage.R`, `probe_fields.R` | **deleted** | Replaced by the source modules. The probe results are already written up in the READMEs |
| `backtest/02_backtest.R` labeling, AUC, bootstrap, eras | **stays in research** | Reads `hidden_loss_history`, `failures` and `btfp.borrowers.csv`. `TODAY` becomes the `pulled_at` date in the raw manifest |
| `run-stress/02_run.R` grid, curves, validation, worked example | **stays in research** | Reads the marts. The hard-coded `QUARTERS` list goes away |
| HMDA sensitivity runs, the SD benchmark | **stays in research** | Calls `hmda_book.R` with other parameters |
| All `03_chart.R`, READMEs, `summary.txt`, PNGs | **stay in research** | The findings stay where they are |
| Committed result CSVs (`results_latest.csv` 4,264 rows, `curves.csv`, `grid.csv`, `top25_latest.csv`, ...) | **deleted** | They are mart outputs now. Each README gets the `gh release download` line that reproduces them |

After this, each research folder holds `README.md`, an analysis script, a
chart script and small summary outputs, all reproducible from a published
release.

## Checks and tests

All checks run in `build.R` before anything is written. A failed check
stops that mart (or, for FDIC, the whole run).

| Where | Check |
|---|---|
| FDIC (existing) | All the current checks, unchanged. New: `research_field_coverage` reported per quarter. Bucket fields ≥ 95% of assets from 2012 on (before 2012 the OTS thrift filers are a known gap, reported but not failed) |
| FRED | Each series non-empty. Newest observation no older than `max_age_days` (daily series 7, weekly 10). Values within [0, 25]%. No duplicate dates. History never shrinks by more than 5 rows |
| failures | Row count ≥ the stored count (the list only grows). No NA after parsing `FAILDATE` (`%m/%d/%Y`). SVB 24735, Signature 57053 and First Republic 59017 present with 2023 dates |
| HMDA | Rows per year within 10% of the CFPB's published national count for the filtered population. LEI to RSSD to CERT match rate reported, and failed below 90% of bank-originated dollars. Rate coverage reported. `kept_share` within [0, 1] |
| BTFP | sha256 of the XLSX matches `btfp.source.txt`. Borrower count and total advances match the Fed's published totals |
| `rates_monthly` | Every month from the first FDIC quarter used to the latest quarter-end month is present for `MORTGAGE30US` and `DGS10` |
| `hidden_loss` | Industry `loss_htm + loss_afs` equals the sum of the raw fair-value gaps (to the dollar), and its total is within 2% of the FDIC Quarterly Banking Profile figure we record per quarter (the research matched $486B in 2026Q3 and $616B in 2022Q4). `loan_yield_imputed` share ≤ 5%. `cal_factor` finite. Rows = filers with inputs, with the dropped count reported |
| `run_stress` | Per bank: `sum(from_*) + shortfall == need`, `t1_after <= RBCT1J`, breaking point on the grid or NA |
| `hmda_book` | PV loss and the duration shortcut within 1 point of each other (as in #20) |
| `bank_ids` | CERT unique. No RSSD mapped to two active CERTs |

**Golden tests** (`pipeline/tests/`, offline, run in CI on PRs touching
`pipeline/**`; this needs a new small workflow, since `deploy.yml` only
watches `app/**`):

- `hidden_loss()` on a 3-bank hand-made fixture with hand-computed answers,
  plus SVB 2022Q4 as a fixture row: HTM loss 15.1 ($B), adjusted equity
  +0.1% of assets.
- `run_sim()` on the SVB 2022Q4 row reproduces `example.txt`: 40%
  uninsured run gives ratio 6.56%, breaking point 65%. Republic First
  2022Q4 breaks at 38%.
- `value_book()` on a single 3% 30-year loan from 2021, valued at 7%,
  against a closed-form price.

These fixtures are small RDS files cut from the raw parquet, like
`app/tests/fixtures/sd_banks.rds`.

The **backtest is not a nightly gate.** AUCs move as failures arrive, and
gating on them would make the pipeline flaky. It stays a research script
anyone can re-run from the published releases.

## Caching

- **The release is the cache.** Local runs start with
  `gh release download data-raw --dir pipeline/out/raw` and then pull only
  what is due. The per-folder `research/*/cache/` directories go away.
- **HMDA downloads** (GBs) go to `pipeline/out/cache/hmda/` (gitignored)
  and are never uploaded. Only the filtered parquet files are.
- **The FRED "cached forever" bug** in the research scripts
  (`if (!file.exists(f)) download`) goes away: FRED is pulled each night
  and diffed.
- The app's 30-day per-bank cache is unchanged.

## Failure handling

| What fails | What happens |
|---|---|
| FDIC request or FDIC check | Run stops, nothing is published (as today) |
| FRED, failures or HMDA request | That source keeps its last good raw files. Dependent marts are rebuilt from them while within `max_age_days`, and skipped after that (the old copy stays live). FDIC marts publish. Job exits red |
| A research mart's check | That mart is not published (its old copy stays). The others publish. Job exits red |
| A core mart's check (industry, snapshot, coverage) | Run stops, nothing is published (as today) |
| The `fail_panel` check (PR 3: it is built on the non-critical failures source, so it is not core) | `fail_panel` and `failures_meta` are not published (old copies stay). The others publish. Job exits red |
| The app finds a research mart missing or out of date | Panel hidden, or labeled "as of" |

Publishing stays all-or-nothing for each mart. A mart is either fully
rebuilt and checked or left as it was.

## Adding a new source later

1. Write `pipeline/sources/<name>.R` with the contract above. Start with
   `critical = FALSE`.
2. Add it to the registry. Raw assets get the `<name>.` prefix.
3. Join through `bank_ids`. If the source has a new ID, add the link to
   the crosswalk with its provenance. Don't match on names.
4. Write the mart and its check. Add a golden test if it computes
   anything.
5. Add it to the "Sources" table in `pipeline/README.md`.

What the candidate sources need:

| Source | Cadence | Key | Extension point it needs |
|---|---|---|---|
| Stock prices, public banks | daily | ticker, joined to RSSD through the holding company | `bank_ids` gets a `ticker` column from a published crosswalk (for example the NY Fed CRSP-FRB link file), never from name matching. Prices are per holding company, not per bank |
| Fed H.8 weekly | weekly | none: aggregate by bank group (large, small, foreign) | A plain dated series like FRED, so it reuses `fred.R`'s shape and `rates_monthly`-style marts. No bank join |
| FFIEC CDR bulk call reports | quarterly | IDRSSD | `bank_ids` (RSSD to CERT). Would supply line items the FDIC API lacks (RIAD4435/4436, real-estate interest income). The public bulk download may need a registered account token: check before planning |

## Correctness traps found in the research code

These need fixing (or explicit flags) as the code moves:

1. **NA silently becomes 0.** `bucket_loss()` sets missing bucket balances
   to 0. `load_quarter()` sets a missing `loan_disc` and missing
   `OTHBFHLB` to 0. `bucket_cov` treats missing as 0. HMDA sets a missing
   `term` to 360. Each of these turns "not reported" into "zero". In the
   pipeline, count them, flag them, or drop the row and count it.
2. **The calibration factor can blow up.** `cal_factor` = reported ÷
   modeled securities loss for the whole industry. In low-rate quarters
   (2020-21) the floored gap is about 0, so the modeled loss is about 0
   and the factor is huge or `Inf`. Fail the check when it isn't finite or
   is above 5.
3. **Cross-sectional values move as late filers arrive.** The median
   imputed yield, `cal_factor`, the ranks and the percentiles all depend on
   which banks have filed. The newest quarter goes from 95% to 100% of
   filers over a few weeks, so every bank's number shifts slightly. Expect
   nightly mart changes (and deploys) in those weeks, and show
   percentiles, not exact ranks.
4. **Two definitions of uninsured share.** The estimator uses
   `DEPUNINS / DEPDOM`. The run-stress table uses `DEPUNINS / DEP`. Pick
   one (`DEPDOM`, because `DEPUNINS` counts domestic deposits) and use it
   everywhere.
5. **Two definitions of failure.** `build_fail_panel.R` keeps
   `RESTYPE == "FAILURE"` from 2000. The backtest keeps FAILURE plus
   ASSISTANCE from 1997. The `failures` mart keeps every row, and each
   user filters explicitly.
6. **Hard-coded dates and lists.** `TODAY <- as.Date("2026-11-25")`,
   `VAL_DATE <- 2026-09-30`, the `FAILED` CERTs, the dated BTFP URL, and
   the run-stress `QUARTERS` list. That list **skips 2025-06-30**, so a
   failure whose last public report was 2025Q2 is silently scored on
   2025Q1 (`fl$q` takes the latest quarter it has).
7. **FRED never refreshes** in the research scripts (cached when the file
   exists). Also: Freddie Mac changed the `MORTGAGE30US` method in
   November 2022 (it now uses application data), a small level break in
   the series used for every rate gap.
8. **Ranks put NA banks at the safe end.** `rank()` defaults to
   `na.last = TRUE`, so in `rank_hidden_to_equity` a bank with no equity
   data ranks as the safest. Keep NA.
9. **The loan yield is distorted by mergers.** The average loan balance
   is (this quarter + last quarter) / 2, matched by CERT. In a merger
   quarter the acquirer's average understates the loans that earned the
   income, so the yield runs high and the rate gap low.
10. **Look-ahead from restatements.** The API serves amended figures, so
    the backtest scores data the market never saw. We can't fix history,
    but `revisions.csv` measures it from now on. The README should say so.
11. **The minimal XLSX reader is fragile.** It ignores `inlineStr` cells,
    takes "the sheet with the most rows", and reads numbers as text. Fine
    for one file checked once, but not as a general tool.
12. **HMDA at scale.** "Kept" (`purchaser_type == 0`) overstates
    retention. The LEI-to-RSSD panel only covers 2018-2023, so banks with
    a newer LEI don't match. `stop()` when an RSSD has 2 LEIs is right for
    4 banks, but across all banks it has to become a reported list. Loans
    are discounted at the borrower survey rate, not a buyer's yield (loss
    understated). The data browser serves the current dataset: pin the
    yearly **snapshot** files for reproducibility.
13. **The coverage probe sampled.** `probe_coverage.R` used `limit = 2000`
    with no sort, so "first quarter with buckets = 1997Q2" was measured on
    a partial, arbitrary sample. The `research_field_coverage` mart will
    settle it on the full cross-section.
14. **`FAILDATE` parsing isn't checked.** `as.Date(FAILDATE, "%m/%d/%Y")`
    has no NA check in the backtest. If the format changes, the labels
    silently disappear.
15. **The run simulator's "can't pay" artifact.** Trust companies with
    few sellable assets "fail" any large run. Keep `how` in the mart and
    exclude banks with no loans and no securities from the app's ranking.
16. **`DEPUNINS` coverage for small banks is unverified.** Check it in
    `research_field_coverage` before the app shows an uninsured-run
    breaking point. If small banks don't report it, the result is NA
    ("not reported"), not "never breaks".

## PR order

Each PR is small, leaves main working, and can ship alone.

| # | PR | Size | Depends on | Ships |
|---|---|---|---|---|
| 0 | This spec plus the CLAUDE.md/verify Linux fixes | S | none | docs |
| 1 | **Split `build.R` into modules, no behavior change.** `R/http.R`, `R/store.R`, `sources/fdic.R`, `marts/industry.R`, `marts/snapshot.R`, `checks/`. Proof: on the same raw files, the marts are byte-identical to the published ones. Also replace `Rscript.exe` with `Rscript` in the script header comments | M | 0 | nothing visible |
| 2 | **Source registry and non-critical failure handling**, plus **FRED** (`fred.R`, `rates_monthly`, checks), plus `pipeline-test.yml` for the golden tests. Pipeline README "Sources" table and "Adding a source" section | M | 1 | `rates_monthly` mart |
| 3 | **Failures source and `fail_panel` built from raw.** Compare with the current `fail_panel.rds` and explain every difference. Then delete `build_fail_panel.R` and `refresh.yml` | M | 2, and the 1984 backfill done | panel refreshes nightly with no per-bank requests |
| 4 | **Wider FDIC raw** (`RESEARCH_FIELDS`), schema-change rows in the diff, `research_field_coverage`, one-time 171-quarter backfill. Includes the `bank_ids` mart (FDIC part) | M | 1 | coverage report |
| 5 | **`hidden_loss` and `hidden_loss_history` marts**: `R/hidden_loss.R`, checks, golden tests. Trim `research/unrealized-losses` to README plus analysis reading the mart. Close #19 | M | 2, 4 | marts (no UI yet) |
| 6 | **`run_stress` mart**: `R/run_stress.R`, checks, SVB/Republic First golden tests. Trim `research/run-stress`. Close #22 | S | 5 | mart |
| 7 | **BTFP static file**, then re-point `research/backtest` at the marts. Delete its fetch and probe. Close #21 | S | 3, 5 | research reproducible from releases |
| 8 | **App: hidden loss and breaking point** on the bank view (deploy pattern, missing-mart handling, smoke test) | M | 5, 6 | first user-visible change |
| 9 | **HMDA source** (`hmda.yml`, snapshot stream and filter, `hmda.panel`, `bank_ids` LEI links, `hmda.groups`) | L | 2, 4 | raw HMDA in the release |
| 10 | **`hmda_book` mart** plus golden test. Trim `research/hmda-mortgage-rates`. Close #20 | M | 9 | mart |
| 11 | **App: mortgage book rate** | S | 10 | UI |

PRs 3 and 4 can run in parallel after 2. HMDA (9 to 11) is independent of
6 to 8 and can come last, because it has the biggest download and the most
open questions.

## Open questions for Daniel

1. **Fail-closed rule.** CLAUDE.md says that when a check fails, nothing
   is published. This plan narrows that: core marts stay all-or-nothing
   together, but a research mart or non-FDIC source that fails only holds
   back itself. OK?
2. **Which hidden-loss number goes in the app?** The floored base version
   (the #21 default and recommended), the calibrated one, or both?
3. **Should these show in the app at all, or only be published as data
   first?** They are estimates with known biases (no deposit franchise, no
   credit loss). The app would need a plain caveat line.
4. **HMDA scope.** All HMDA-reporting banks from the national snapshot
   (yearly, multi-GB stream, and `data.table` as a pipeline-only
   dependency), or a short list of banks through the data browser as in
   #20?
5. **The four research PRs.** Close each one when its module PR lands and
   carry its README findings into main there (recommended), or merge them
   as they are first, as an archive?
6. **BTFP file.** Commit the small derived CSV to git (recommended), or
   keep it in the release only?
7. **History length.** The app gets the last 20 quarters of hidden loss,
   and the full 1997+ panel goes to research only. Enough?
8. **FRED access.** Keep the keyless `fredgraph.csv` download, or register
   an API key (a repo secret) for the official API?
