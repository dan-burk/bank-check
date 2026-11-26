# Run stress: how big a deposit run breaks each bank?

Research prototype. It is not part of the app.

Hidden losses on bonds and loans only kill a bank when it is **forced to
sell**. This simulator forces the sale. You pull one lever, the share of
deposits that walk out (**s**), and each bank pays them by selling assets in
a fixed order. The losses it realizes come out of capital. If capital ends
below **2% of assets**, the bank is *critically undercapitalized*, and prompt
corrective action law (12 U.S.C. 1831o) requires the regulator to put it into
receivership within about 90 days. A bank that runs out of things to sell
also fails ("can't pay").

**Breaking point** is the headline number: the smallest run (in steps of
0.5%) that breaks the bank. Two versions:
- **uninsured run** (realistic): s of *uninsured* deposits leave
- **all-deposit run**: s of *all* deposits leave

## Run it

The simulator lives in the data pipeline: `pipeline/R/run_stress.R`, with
every assumption in one list at the top (`RS_PARAMS`). Each night it runs
on the newest quarter and publishes the `run_stress` mart (one row per
bank: breaking point, how it breaks, lowest ratio and percentile, for each
of the four runs). The loan sale discount comes from the `hidden_loss`
mart. This folder fetches nothing. `analyze.R` runs the same functions on
the older quarters from the published raw files and `hidden_loss_history`,
and checks that the newest quarter matches the mart.

```sh
gh release download data-marts --dir pipeline/out/marts --pattern 'hidden_loss_history.parquet'
gh release download data-marts --dir pipeline/out/marts --pattern 'run_stress.parquet'
gh release download data-marts --dir pipeline/out/marts --pattern 'bank_ids.parquet'
gh release download data-raw   --dir pipeline/out/raw   --pattern 'risdate.20*.parquet'
gh release download data-raw   --dir pipeline/out/raw   --pattern 'failures.parquet'
Rscript research/run-stress/analyze.R   # summary.txt, example.txt, ~1 min
Rscript research/run-stress/chart.R     # run_curves.png
```

`summary.txt` has every table below (banks that break at s = 5/10/20/30/50%
for both run types with FHLB off and on, the top 20, the validation).
`analyze.R` also writes `out/curves.csv` and `out/validation.csv` for the
chart (gitignored). The failures come from the FDIC list
(`failures.parquet`, `RESTYPE == "FAILURE"` since 2022). Each one is scored
on the last quarter that was public 45 days after quarter end before it
failed, picked from every raw quarter on hand.

## How the simulator works: Silicon Valley Bank, 2022Q4, 40% uninsured run

All numbers are from SVB's 2022Q4 call report, in $ billions (`example.txt`).

| Step | | |
|---|---|---|
| Start | assets 209.0, deposits 175.4 (151.6 uninsured, 93.9% of domestic deposits), Tier 1 capital 17.0 | ratio **8.13%** |
| Run | 40% of 151.6 uninsured leave | needs **60.6** in cash |
| 1. Cash above a 2% operating floor | 12.5 on hand minus 4.2 kept back | 8.3, no loss |
| 2. Fed funds sold and reverse repos | | 0.7, no loss |
| (FHLB borrowing, OFF here) | | |
| 3. Trading assets | | 0.1, no loss |
| 4. All AFS securities at fair value | worth 26.0, cost 28.5 | 26.0, **loss 2.5** |
| 5. HTM securities at fair value, pro rata | 25.5 of 76.2 fair value; the book is 91.3, so each $1 sold carries $0.20 of loss | 25.5, **loss 5.1** |
| 6. Loans (not reached) | | |
| After | Tier 1 = 17.0 − 7.6 = 9.4; assets = 209.0 − 60.6 paid − 5.1 written off = 143.3 | ratio **6.56%** |

SVB survives 40%. Raising s step by step, it first falls below 2% at **65% of
uninsured deposits**, its breaking point. For scale: on March 9–10, 2023,
SVB's customers withdrew or asked to withdraw about $142 billion, which is
over 90% of its uninsured deposits.

Paying out deposits from cash *raises* the ratio, because the balance sheet
shrinks and capital does not. Only realized losses push it down. That is why
a bank needs both large hidden losses and a large run to break.

## Results

**Latest quarter (2026Q3), FHLB off.** Number of banks (and their assets) that break:

| run size s | uninsured run | all-deposit run |
|---|---|---|
| 5% | 0 | 0 |
| 10% | 0 | 0 |
| 20% | 0 | 2 ($0.1B) |
| 30% | 0 | 3 ($0.2B) |
| 50% | 1 ($0.1B)* | 14 ($10.5B) |

For contrast, at 2022Q4 a 50% uninsured run breaks 1 bank (Republic First,
$6B), and a 50% all-deposit run breaks 46 banks ($57B). Today an uninsured run
of any size breaks only 2 banks. Unrealized losses have shrunk since 2022, and
most banks hold enough capital to absorb what is left.
*\*a small trust company whose assets are mostly not cash, securities or
loans. This is an artifact of the "can't pay" rule, not a capital problem,
so banks with no loans and no securities are not ranked.*

With **FHLB borrowing ON** (cap 25% of assets), almost nothing breaks: 2026Q3
at a 50% all-deposit run drops from 14 banks to 1. In 2022Q4, SVB's breaking
point moves from 65% to 89.5%, and First Republic's from 85% to never. The
backstop matters most because it lets a bank meet the run without selling.

**Validation.** Rank 1 = most fragile, ranked by breaking point (banks that
never break are ordered after those that do, by the lowest ratio they hit).
Banks with missing inputs, or no loans and no securities, are not ranked.

| bank (failed) | quarter used | breaking point, uninsured | rank | Tier 1 leverage rank |
|---|---|---|---|---|
| Republic First (2024-04) | 2022Q4 | 38% | **1** of 4,692 | 6 |
| Silicon Valley (2023-03) | 2022Q4 | 65% | **2** | 281 |
| First Republic (2023-05) | 2022Q4 | 85% | **4** | 603 |
| Signature (2023-03) | 2022Q4 | never | 1,054 | 838 |
| SVB / Signature / First Republic | 2021Q4 | never | 131 / 108 / 1,240 | 143 / 159 / 1,183 |
| Republic First | 2023Q4 | 47% | 1 of 4,576 | 2 |

In 2022Q4, 11 banks had an uninsured breaking point at or below 100%. One of
them was the trust-company artifact (not ranked). Of the other 10, 3 failed:
SVB and First Republic within five months, Republic First within 16 months.

*What changed when the simulator moved into the pipeline (PR 6):* the
breaking points of the failed banks, and the SVB walk-through, are
unchanged. The banks counted changed. The estimator used to drop banks
whose total equity was zero or negative. These are mostly banks with large
AOCI losses whose Tier 1 is still 7 to 14%. Now they are kept: 21 more in
2022Q4 and 4 in 2026Q3. Several of them break in an all-deposit run, so
the 50% counts rose from 38 to 46 (2022Q4) and from 12 to 14 (2026Q3). The
trust company is no longer ranked, so First Republic moved from 5th to 4th.
Uninsured share is now uninsured / *domestic* deposits (SVB 93.9%, was
86.4% of all deposits). The run itself always used the uninsured dollar
amount, so no breaking point moved.

At 2021Q4, before rates rose, the simulator sees nothing. Losses were small
then, so no run breaks SVB.

Signature is a miss. Its securities losses were small relative to its
capital. It failed from the speed of the run and from management problems,
which this model does not capture.

**Any-era check: all 13 failures since 2022**, each from the last call report
that was public before it failed (`validation.csv`, "last public quarter"):
- **Rate-plus-run failures:** the breaking point clearly beats Tier 1. SVB
  ranks 2 vs 281, First Republic 4 vs 603, Republic First 1 vs 2.
- **Credit and fraud failures (9 banks):** it adds nothing. None of them has a
  breaking point, except Kentland, which was already below 2% before any run.
  Their ranks track Tier 1, for example Metropolitan 9 vs 5 and Small
  Business Bank 10 vs 9.

This is a tool for one failure mode, not a general failure predictor.

## Assumptions and direction of bias

| Assumption | Bias |
|---|---|
| Everything sells at today's fair value, with no fire-sale discount (`FIRE_HAIRCUT` = 0) | breaking points too **high** (too safe) |
| Loans sell at the hidden-loss estimator's rate discount, which has no credit loss | too safe |
| Solvency only. A bank that can sell in time is assumed fine, although real runs kill through timing (SVB could not sell $100B in a day) | too safe |
| Pledged securities (`SCPLEDGE`) are treated as sellable | too safe |
| Loans can be sold in any amount; operating cash floor of 2% of assets, used as the last resort | too safe |
| AOCI opt-out for everyone: selling AFS realizes its loss into Tier 1. The few very large banks that already count AFS losses in Tier 1 take a loss twice | too **fragile** for the largest banks |
| Tier 1 / period-end assets used for both the 2% tangible-equity test and the 4% leverage test (the law uses average assets; tangible equity ≈ Tier 1) | small, either way |
| HTM sold pro rata, no "tainting" of the rest of the HTM book (for opt-out banks tainting would not hit Tier 1 anyway) | small |
| FHLB, when ON: total advances up to 25% of assets, with no collateral check | too safe when ON |
| No other help: no discount window, no BTFP, no capital raise, no merger | too **fragile** |
| No income or expenses during the run; the run is one instant | small |
| Banks with zero deposits (trust companies, ~60), and the 17 insured branches of foreign banks (no Tier 1), get NA with a reason, not "never breaks" | none |

Overall the model leans **safe**: a bank it breaks is in real trouble, and a
bank it passes may still fail from speed, credit losses or fraud.
