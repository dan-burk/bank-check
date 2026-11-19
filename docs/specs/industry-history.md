# Spec: Industry statements over time (1984 to now)

Status: draft for review. No code has changed yet.

## Goal

Give the Industry tab (every FDIC-insured bank combined) the same
balance-sheet and income-statement lines it has today, but for **every
quarter since FDIC data begins (1984 Q1)** rather than only the latest
quarter and its two comparison quarters. A single bank's history works the
same way today (the Dacotah fixture goes back to 1984).

## Decisions (Daniel, 2026-11)

1. **History starts at 1984 Q1.** The earlier advice to cut off at 1992
   was too cautious and is dropped.
2. **Quarterly granularity**, one row per quarter end, with no gaps.
3. **No new statement fields.** The lines are the ones in
   `STATEMENT_FIELDS`, `app/R/statements.R:157`.
4. **Missing data is in scope.** The pipeline must detect and report
   coverage for each field in each quarter. It must never silently turn a
   missing value into 0 or into "Other".
5. Architecture is unchanged: `build.R` builds the marts from raw parquet
   files in the `data-raw` release. No new database or service.

## Verified facts (FDIC API, index `risview_20261116221646`)

| Check | Result |
|---|---|
| Earliest quarter | 1984-03-31, with 17,930 filers. 1984 has all 4 quarters (17,930 / 17,935 / 17,946 / 17,949) |
| `RISDATE:19841231` (the filter `build.R` uses) | 17,949 rows, the same as Daniel's `REPDTE` query |
| 1984Q4 server-side sums | ASSET 3,659,538,669 · LIAB 3,470,330,758 · EQTOT 188,812,545 · NETINCQ 3,459,189 ($ thousands) |
| 1984Q4 identity | ASSET − (LIAB + EQTOT) is 0.011% of ASSET, which passes the 0.1% check |
| Sample 1984 rows | All 18 statement fields are present, including SUBND, FREPP and IGLSECQ |
| `agg_by=RISDATE` | Works across a date range in one request. Gotcha: in aggregate output, `RISDATE` comes back as **epoch milliseconds** (e.g. `473299200000` = 1984-12-31), not `YYYYMMDD` |

Full coverage for 1984 to 1990 is **not** verified yet. That is the job
of the coverage check below. `data.R` notes that some banks filed
semiannually in 1985, so expect gaps in the Q fields for 1985 Q1 and Q3.

## What already works and what breaks

The current design already supports most of this. `industry_quarterly`
is built from **every** raw file on disk (`build.R:182`), and the nightly
job downloads all of `data-raw` before it builds. So a single backfill
run that puts 1984 to now into `data-raw` gives us full history from then
on: each night re-pulls only the last 10 quarters, and the mart keeps the
rest.

What breaks or is silently wrong with 170+ quarters:

| Where | Problem | Fix |
|---|---|---|
| `build.R:228` `all(ind$ASSET > 1e10)` | 1984 assets are $3.66T, so the $10T floor **fails the backfill** | Floor of $1T (`1e9`), plus the existing bank-count check |
| `statements.R:166` `sum(..., na.rm = TRUE)` | A field no bank reported sums to 0, and a field half the banks reported sums to roughly half its real value. Both are silent | Coverage check, then NA when coverage is too low (below) |
| `statements.R:8` `z()` | A missing component becomes 0, so its value ends up in "Other" | "Other" becomes NA when any of its components is NA (below) |
| `pipeline.yml` upload step | Re-uploads **every** raw file with `--clobber` each night (170+ files) | Upload only the quarters pulled this run, plus `manifest.csv` and `revisions.csv` |
| `build.R:168` `manifest.csv` | Overwritten with only this run's quarters, so the backfill rows are lost the next night | Merge into the existing manifest by `risdate` |
| `build.R:236` 10% bank-count drop | Untested over 1984 to now (the S&L crisis had heavy attrition, but probably no more than 10% in one quarter) | Keep it. If it trips during the backfill, look at the quarter before loosening it |
| No check for gaps | A missing raw file gives a hole in the history and no error | Check that the quarter sequence is unbroken from 19840331 to the newest quarter |

## Field-coverage check

**Where:** `build.R`, computed from each raw quarter right next to
`industry_totals()`.

**Output:** a new small mart, `field_coverage.parquet`, with one row per
(quarter, field) for the 18 statement fields. That is about 3,100 rows.

| Column | Meaning |
|---|---|
| `RISDATE` | quarter |
| `field` | e.g. `NIMQ` |
| `n_banks` | banks filing that quarter |
| `n_reported` | banks with a non-NA value (a reported 0 counts as reported) |
| `asset_share` | Σ ASSET of reporting banks ÷ Σ ASSET of all banks |

`asset_share` is the number that matters: it is the share of the
industry total that is actually in the sum. A field missing for 2% of
banks that hold 0.01% of assets does no harm. A field missing for one
money-center bank does.

**Rule** (one constant, `COVERAGE_MIN`, proposed at 0.995 by asset
share):
- **Coverage at or above the minimum:** the mart holds the sum over the
  reporting banks, as today.
- **Coverage below the minimum:** the mart holds **NA** for that field and
  quarter. The table shows "–" and the footnote says the line was not
  reported for that quarter.
- **"Other" lines** are remainders (`statement_lines`). If any component
  is NA, Other is NA, and it is never absorbed into Other. Totals (ASSET,
  LIAB, NETINCQ) still display.

**Report and fail:**
- Every run prints a coverage summary: each field and quarter below 100%,
  grouped into runs of quarters (e.g. `NIMQ  19850331,19850930  asset_share
  0.93`).
- **Fail the run** if any field is below `COVERAGE_MIN` in any of the
  **last 10 quarters**. Modern filings are complete, so a gap there means
  a broken pull or an FDIC change.
- Gaps in history are **reported, not failed**, because they are real and
  permanent. `field_coverage` is published with the marts so the app and
  tests can read it.

**Cross-checks** (cheap, and they catch arithmetic or pull errors):
1. **Aggregation API.** One extra request per run (`agg_by=RISDATE`, over
   the run's quarter range, `agg_sum_fields=ASSET,LIAB,EQTOT,DEP,NETINCQ`,
   with `agg_limit` ≥ number of quarters) must match our raw sums within
   1e-9 relative, and its `count` must match `n_banks`. For the backfill,
   run it over the full 1984 to now range. Convert epoch ms to YYYYMMDD
   before joining. We keep it as a cross-check rather than the source:
   the raw files are still needed for revisions, the snapshot, future
   historical peer bands, and coverage, which the sums cannot give.
2. **Q1 identity.** In every Q1, quarterly net income equals the year to
   date, so Σ NETINCQ = Σ NETINC (NETINC is already in the raw files).
   Report any Q1 mismatch above 0.1%. Fail on one in the last 10 quarters.
3. The existing balance-sheet identity check runs on every quarter,
   skipping quarters where LIAB or EQTOT is NA by coverage. Those skips
   are reported.

## Backfill plan and runtime

1. Add a `quarters` input to `pipeline.yml`'s `workflow_dispatch`
   (default 10, passed to `Rscript pipeline/build.R`). The one-time
   backfill then runs through the same publish path, with the same tests
   and the same fail-closed behavior. No separate script.
2. Run it once from main with `quarters = 171`, which is 1984 Q1 through
   2026 Q3 if Q3 has cleared the 95% gate (otherwise 170).
3. The nightly runs after that are unchanged (10 quarters). The mart keeps
   history because every raw file is downloaded.

**Requests:** each quarter with more than 10k filers needs 2 pages, which
is roughly 1984 to the late 1990s. That makes about 171 + ~60 paging
requests + about 5 overhead, so **~240 requests**. Today's nightly run
averages about 8.5 s per request (14 requests in about 2 min, 2 s gap
plus transfer). Pages with 10k early-era rows are heavier, so estimate
**30 to 60 min**, far below the 6 h Actions limit. If it fails partway,
the run stops without publishing and can be rerun safely. A resume
option is not needed.

## Data-raw size growth

Measure this, don't guess: `manifest.csv` already records `bytes` per
quarter. Estimate it by scaling today's per-quarter size (about 4.3k
banks) by each quarter's bank count. The average across 1984 to now is
about 2× today's count, and 1984 is about 4.2×. The expected total is a
few hundred MB, and every file stays well under the 2 GB per-file release
limit. The consequences:
- The nightly job downloads the whole `data-raw` release, which adds about
  a minute. That is acceptable.
- The nightly upload has to become incremental (see the table above), or
  it re-uploads all of that every night.
- The `industry_quarterly` mart grows from about 10 rows to about 171 rows
  × 21 columns, and `field_coverage` is about 3k rows. Both are a few KB,
  so the shinylive bundle barely changes.

## Open questions (presentation)

1. **Table, charts, or both.** The options, smallest first:
   - **(a) Quarter picker.** A `selectInput` of all quarters feeds the
     existing `industry()` reactive. `statement_table()` is unchanged,
     and the QoQ/YoY column keeps working, because the reactive already
     selects the chosen quarter, the prior quarter and the same quarter a
     year earlier. 1984 Q1 has no prior quarter, so its change column
     shows "–". `statement_table()` already handles that.
   - **(b) Multi-quarter table.** Columns are quarters, e.g. the last 8 or
     a range. This reuses the **multi-bank path** of `statement_table()`
     as is: pass a named list of quarter rows, one column each. That path
     **drops the change column**, and the QoQ/YoY toggle greys out the
     way the bank comparison does (`fs_cmp_enabled`). Change becomes
     visible from column to column. In % mode each column uses its own
     base (assets or revenue), which is correct.
   - **(c) Charts.** One plotly line per statement line, 1984 to now,
     $ or % of base. This needs a new plot builder. Coverage gaps must
     appear as breaks in the line, never as a drop to zero.
   - Recommendation: (a) first, then (c) for one selected line if wanted.
     (b) is nearly free but is wide on mobile.
2. **QoQ/YoY in a multi-quarter table**, if (b) is chosen: (i) no change
   column, as in the multi-bank mode (recommended, zero code); (ii) a
   change row under each line (doubles the height); or (iii) one change
   column relative to the leftmost quarter (ambiguous). Needs a decision.
3. **`COVERAGE_MIN`**: is 0.995 of assets the right threshold, or should
   the app show partial sums with a coverage note instead of "–"?
4. **Single-bank statements**: should the change to "Other" (NA when a
   component is missing) apply to single banks as well? It is the same
   function, and the honest answer is yes, but old single-bank quarters
   would then show "–" where they show a number today.
5. **Nominal dollars**: 1984 and 2026 dollars side by side. Inflation
   adjustment is out of scope. Should there be a caption note?

## Tests and acceptance criteria

**Pipeline (`build.R` checks; the run fails closed)**
- `industry_quarterly` has one row per quarter, unbroken, from 19840331 to
  `newest`, with no duplicates.
- 1984Q4 row: `n_banks` = 17,949, ASSET = 3,659,538,669, and NETINCQ =
  3,459,189 if it meets `COVERAGE_MIN` (or NA with the coverage reported).
  The aggregation cross-check matches for every quarter.
- `field_coverage` has 18 rows per quarter. Every field is ≥
  `COVERAGE_MIN` in the last 10 quarters.
- No mart value is a sum taken over coverage below `COVERAGE_MIN`.
  Checked by joining the mart to `field_coverage`: where coverage is
  below the minimum, the mart value is NA.
- The Q1 NETINCQ = NETINC identity holds, or is reported.
- After the next nightly run, `data-raw` still has every quarter, and
  `manifest.csv` still lists them all.

**App (`smoke.R`, offline)**
- `nrow(ind) >= 170`, the oldest row is 19840331, and the newest equals
  the snapshot quarter (the existing check).
- `statement_table()` renders for the oldest quarter (no prior quarter,
  so the change column is "–") and for a quarter with a field forced to
  NA. That line shows "–", Other shows "–", and the totals still show.
- `industry_totals()` unit test: a two-bank fixture with one NA in a field
  gives NA for that field when coverage is below the minimum, never a
  silent partial sum.

**Manual**
- The Industry tab shows 1984 Q1 and the latest quarter. % mode adds to
  100 for each block. Dacotah's 1984 single-bank statement still renders
  unchanged (or as decided in question 4).

## Out of scope

New statement lines, historical peer bands (`peer_bands_quarterly`),
inflation adjustment, moving `fail_panel` into the pipeline.
