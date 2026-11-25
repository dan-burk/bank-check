# Backtest: does "equity after hidden losses" find failing banks earlier?

**Short answer.** Only in the rate era. Over 1997-2026 (541 failed banks
scored), our score does about as well as plain reported equity in every
era, and the regulators' Tier 1 leverage ratio does slightly better.
2022-2026 is the one era where ours comes out ahead: 9 of 13 failures on the
worst-5% list vs 6. With only 13 failures, though, that lead can't be told
apart from luck. In the 2008-2012 crisis the score adds essentially nothing.
That was expected, because those failures came from credit and real-estate
losses, not from rates.

![AUC by era](auc_by_era.png)

## How the model works (the 3-4% vs 7% idea)

A bank that made a 30-year mortgage at 3% in 2021 still collects 3%. By late
2022 new mortgages paid about 7%, so the old loan is worth less than its face
value, while the books still show face value. That gap is a *hidden loss*.
The estimator (`research/unrealized-losses/estimator.R`) adds two of them,
for every bank and every quarter:

1. **Bonds held to maturity**: the loss read straight off the Call Report
   (fair value vs book).
2. **Loans**: an estimate. The rate gap is the mortgage rate minus the
   bank's own loan yield. Each slice of loans, grouped by years until it
   matures or reprices, loses gap × duration.

**Our score** is (equity − hidden losses) / assets. Low is bad.

## How far back, and how it is tested

- **The data starts in 1997Q2.** That is the first quarter in which the FDIC
  API has the loan maturity buckets (`probe_coverage.R`). Fair values start
  earlier, around 1994-95. We score 118 quarters, 1997Q2 to 2026Q3: 807,268
  bank-quarters.
- **A gap before 2012.** Savings institutions that filed the OTS Thrift
  Financial Report (about 10% of banks and 17% of loans, including WaMu,
  IndyMac and World Savings) have neither the loan buckets nor HTM fair
  values in the API. They are left out of *every* score, so the comparison
  stays like-for-like, but 56 failed banks (252 pre-failure reports) could
  not be scored. Since 2012 all banks file the Call Report and the gap is
  gone.
- **Same rules as before.** A report counts as public 45 days after quarter
  end. A "hit" is a failure within 1 year after that. Reports that only
  became public after the bank had failed are thrown out. FDIC "assistance"
  deals count as failures, and a bank that kept filing after one is labeled
  report by report.
- **Eras** are set by the year a report became public. A bank whose last
  4 reports straddle an era boundary counts in both eras.
- **Metrics.** AUC is the chance that a pre-failure report ranks worse than
  a surviving bank's report (0.5 = coin flip). *Caught* means the bank was
  on the worst-5% list in at least one of its 4 pre-failure quarters. The
  90% range resamples the failed banks, and comparisons are paired (same
  resample for every score). No fitted models.
- **Run time:** `02_backtest.R` takes about 45 s. The first fetch takes
  about 45 min (one request every 2 s, ~120 quarters); later runs reuse the
  cache.

## Results by era

AUC (90% range) and failed banks caught on the worst-5% list:

| Era | Failed banks | Reported equity / assets | Tier 1 leverage | **Ours, floored (default)** | Ours, symmetric |
|---|---|---|---|---|---|
| 1997-2007 | 54 | 0.76 (0.69-0.82) · 23 | 0.77 (0.70-0.82) · 27 | 0.76 (0.69-0.82) · 27 | 0.67 (0.60-0.75) · 22 |
| 2008-2012 | 442 | 0.92 (0.91-0.93) · 404 | 0.93 (0.92-0.94) · 412 | 0.92 (0.91-0.93) · 406 | 0.93 (0.91-0.94) · 406 |
| 2013-2021 | 68 | 0.96 (0.94-0.99) · 64 | 0.97 (0.94-0.99) · 65 | 0.96 (0.94-0.98) · 64 | 0.95 (0.91-0.98) · 64 |
| 2022-2026 | 13 | 0.80 (0.70-0.89) · 6 | 0.84 (0.76-0.91) · 6 | **0.85 (0.76-0.92) · 9** | 0.82 (0.73-0.91) · 9 |

Which differences are real (paired, `era_compare.csv`):

- **2008-2012**, the only era with enough failures to settle anything. Ours
  beats reported equity by 0.003 AUC. That is real (in 100% of resamples)
  but far too small to matter. Tier 1 beats ours by 0.008, also real. Here
  the score is reported equity plus a little noise, as expected.
- **2013-2021.** The three capital measures are effectively tied. Tier 1 is
  ahead by under 0.01.
- **2022-2026.** Ours leads reported equity by 0.05 (in 82% of resamples)
  and Tier 1 by 0.01 (58%). Neither difference is proven.

## The falling-rate question: should hidden *gains* count?

Daniel's point: when rates fall, old loans at 5% become worth *more* than
new 3% loans, so banks can sit on hidden gains. The default score floors
the rate gap at zero, so it can never show a gain. The *symmetric* variant
drops the floor.

What happens without the floor (`rate_gap_by_quarter.csv`):

| Period | Mortgage rate | Bank-quarters with a negative gap | Industry loan "gain", avg (worst) |
|---|---|---|---|
| 2008-2012 | 6.0% → 3.3% | 96% | 6% of equity (15%, $250 bn) |
| 2019-2021 | 4.3% → 3.1% | 99% | 13% of equity (17%, $378 bn) |
| 1997-2007 | 7.7% → 6.1% | 92% | 8% of equity |
| 2013-2018 (rates rising) | 3.6% → 4.6% | 94% | 4% of equity |
| 2022-2026 (rate era) | 4.2% → 6.9% | 35% | loss: +7% of equity |

**Decision: keep the floor as the default.** Three reasons:

1. **Most of the "gain" is not from falling rates.** The gap is negative for
   over 90% of banks in *every* era before 2022, rising-rate years included.
   A bank's loan yield sits above the mortgage rate mostly because of credit
   spread and loan mix (business, consumer and card loans pay more). That
   extra yield pays for expected losses. It is not a hidden asset. Without
   the floor, the riskiest lenders get the biggest equity boost.
2. **The backtest says so.** The symmetric variant is clearly worse in
   1997-2007 (−0.09 AUC, worse in 100% of resamples) and in 2013-2021
   (−0.02, 99.6%), and a bit worse in 2022-2026 (−0.02, 93%). It is better
   only in 2008-2012, by 0.006 (96%), a hair.
3. **Gains are hard to cash in.** Borrowers refinance when rates drop, so a
   premium mortgage gets prepaid at par, and a bank under stress rarely
   gets to sell at a gain.

So yes, Daniel is right that in falling-rate years banks were sitting on
paper gains, not losses, and a symmetric model would show it. It just
doesn't help spot failures. When the gap is floored, the score collapses to
reported equity in those years, which is the honest answer: no hidden rate
problem.

## 2022-2026 in detail (unchanged from the first backtest)

The numbers are identical to the first run. See `summary.txt`, `metrics.csv`
and `failed_bank_ranks.csv` (chart: `failed_bank_ranks.png`). The main
points:

- **First Republic** was in our worst 1% in all 4 quarters before it failed.
  Reported equity had it at 37-45%.
- **SVB** was in our worst 5% in all 4 quarters. Reported equity had it at
  9-28%.
- **Signature** was missed by every capital measure. Its problem was its
  depositors.
- **The fraud failures** are invisible to every score.
- **The 2026 small-bank failures** are caught by everything.
- **BTFP borrowing** is weakly predicted by every score (AUC 0.58-0.65).

## What this does and doesn't prove

- **It does show** that the score does no harm across 30 years and ~540
  failures, and that it moves the two big rate-driven failures (SVB, First
  Republic) to the top of the list a year ahead.
- **It does not show** that we beat Tier 1. In every era with enough
  failures to tell, Tier 1 is at least as good.
- **Only one rate-driven episode exists in the data**, with 4 relevant
  failures. Nothing before 2022 can test the idea properly, because rates
  never rose fast enough while banks held long, low-yield loans.
- **Hindsight.** The method was designed by people who knew SVB failed.
- **Labels are thin.** Banks sold under stress count as survivors, the
  latest year's follow-up is not complete, and the API serves amended
  figures, not the originals.

## Files and how to run

From the repo root:
```sh
Rscript research/backtest/01_fetch.R     # FDIC 1996Q4..latest, failures, FRED, BTFP -> cache/ (gitignored)
Rscript research/backtest/02_backtest.R  # era_metrics.csv, era_compare.csv, rate_gap_by_quarter.csv, 2022-26 detail, summary.txt
Rscript research/backtest/03_chart.R     # auc_by_era.png, failed_bank_ranks.png
```
The settings (45-day lag, 1-year horizon, list sizes, era breaks) are at the
top of `02_backtest.R`. The estimator gained two extra output columns for
the symmetric variant. Its existing outputs are unchanged.
