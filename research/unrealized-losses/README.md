# Hidden losses at every US bank

**Question.** Many banks lent money or bought bonds when rates were 3-4%.
New loans now pay about 7%. If a bank had to sell those old loans and bonds
today, a buyer would pay less than face value, because the buyer could
earn more on a new loan. The gap between face value and what the asset would
sell for is an *unrealized loss*. Most of it is not subtracted from the
equity the bank reports. How large is it, bank by bank, and does it point
to the banks that failed in 2023?

The estimate is computed by the data pipeline (`pipeline/R/hidden_loss.R`)
and published every night as two marts: `hidden_loss` (last 20 quarters)
and `hidden_loss_history` (every quarter since 1997 Q2). This folder holds the
method, the findings and a script that summarizes the published history. It
fetches nothing and computes no losses itself. The app does not show
these numbers yet.

## Files

| File | What |
|---|---|
| `analyze.R` | Reads `hidden_loss_history`, `bank_ids` and the FDIC failures list, and prints the headline numbers |
| `summary.txt` | Its output for the newest quarter and 2022-12-31 |

To reproduce from the published releases (repo root):

```sh
gh release download data-marts --dir pipeline/out/marts --pattern 'hidden_loss_history.parquet'
gh release download data-marts --dir pipeline/out/marts --pattern 'bank_ids.parquet'
gh release download data-raw   --dir pipeline/out/raw   --pattern 'failures.parquet'
Rscript research/unrealized-losses/analyze.R
```

The per-bank table that used to be committed here (`results_latest.csv`)
is `hidden_loss` filtered to the newest quarter. Dollar amounts are in
**$ thousands**, as in the FDIC data. Column definitions are at the top of
`pipeline/marts/hidden_loss.R`.

## Data (all free, no keys)

- **FDIC Call Reports**, from the pipeline's raw quarter files (every bank,
  1984 on). The fields used:
  - Securities. `SCHA` and `SCHF` give held-to-maturity (HTM) at amortized
    cost and at fair value. `SCAA` and `SCAF` give the same for
    available-for-sale (AFS).
  - Loans by time until the rate resets: ≤3 months, 3-12 months, 1-3 years,
    3-5 years, 5-15 years, over 15 years. `LNRS*` for first-lien home
    mortgages, `LNOT*` for all other loans (Schedule RC-C, Memorandum 2).
    Securities have the same buckets (`SCNM*`, `SCPT*`, `SCO*`). The buckets
    start in 1997 Q2, and the OTS thrifts reported none until 2012.
  - Loan interest income for the quarter (`ILNLSQ`) and total loans
    (`LNLSGR`), for the bank's average loan yield.
  - Equity (`EQTOT`), Tier 1 capital (`RBCT1J`), estimated uninsured
    deposits (`DEPUNINS`), domestic deposits (`DEPDOM`).
- **FRED** `MORTGAGE30US` and `DGS10`, from the pipeline's `rates_monthly`
  mart: each averaged over the last month of the quarter.

## Method

1. **Securities losses are reported, not estimated.** HTM loss = `SCHA − SCHF`.
   AFS loss = `SCAA − SCAF`. The AFS loss is already subtracted from
   reported equity through AOCI. The HTM loss is not subtracted anywhere.
2. **Loan losses are estimated**, in the spirit of Jiang, Matvos, Piskorski
   and Seru (2023).
   - *Rate gap* = 30-year mortgage rate − the bank's own loan yield,
     floored at 0.
   - *Duration* per bucket: 0.1, 0.5, 1.8, 3.5, 5.5 and 7.5 years (below
     each bucket's midpoint, because loans repay principal every month).
   - Loss per bucket = balance × duration × rate gap, capped at a 50% price
     drop, summed over the buckets.
3. **Self-check on securities.** The same method on securities (bank's
   securities yield against the 10-year Treasury) correlates 0.99 with the
   reported losses across banks but runs low: 81% of the reported total in
   2026Q3 and 55% in 2022Q4. The **calibrated** variant multiplies loan
   losses by reported ÷ modeled (×1.24 in 2026Q3, ×1.82 in 2022Q4).
4. **Per-bank outputs.** `hidden_loss` = HTM loss + loan loss (what equity
   does not show). `adj_equity_to_assets` = (equity − hidden loss) ÷ assets.
   `pct_worst` = the share of that quarter's banks at or below the bank's
   adjusted equity / assets (0.01 = in the worst 1%). `uninsured_share` =
   `DEPUNINS / DEPDOM`. `run_risk_flag` = adjusted equity < 0 **and**
   uninsured share > 50%.

**What changed when this moved into the pipeline.** On every bank the
research and the pipeline both cover, the numbers are the same: all
4,263 banks of 2026Q3 and SVB, Signature and First Republic at 2022Q4
match the old CSVs to their rounding. The differences are fixes:

- **Missing is NA, not 0.** Banks that did not report the loan buckets or
  the HTM fair value (the OTS thrifts before 2012, about 55,000
  bank-quarters) used to get a loan loss of 0, or an NA that sorted last,
  so they ranked as the *safest* banks. Now their loss and `pct_worst` are
  NA, with an `na_reason`.
- **No bank is dropped.** The research kept only banks with equity > 0.
  That removed the banks whose reported equity AFS losses had wiped out.
  These are the banks the question is about: 21 at 2022Q4 and 4 at 2026Q3.
  They are now in the table, and in the worst percentiles. The 17 insured
  US branches of foreign banks (no equity reported) are rows with NA ratios,
  so the industry securities loss equals the raw sum.
- **The calibration factor is NA when it means nothing.** In 65 of 118
  quarters the industry had a net securities *gain*, and in 12 more the
  factor was above 5 (×1,146 in 2008Q4, when the modeled loss was near 0).
  The calibrated variant is NA in those quarters instead of scaling loan
  losses by a huge or negative number.
- **No hard-coded dates or lists.** The newest quarter comes from the
  data, the rates from the nightly FRED pull (the research cache never
  refreshed), and the 2023 failures from the FDIC failures list.

## Results

**Sanity check against the FDIC.** The Quarterly Banking Profile reports
**$486B** of unrealized securities losses for 2026Q3, and the bank fields
sum to $487B ($296B HTM + $191B AFS). For 2022Q4 they sum to $619B, against
the $620.4B the FDIC published. The pipeline check fails if either
quarter is more than 2% off.

**Latest quarter (2026-09-30): 4,284 filers, 4,267 with an estimate**

| | Base | Calibrated |
|---|---|---|
| Loan mark-to-market loss | $258B (1-4 family $141B, other $117B) | $320B |
| Hidden loss (HTM + loans) / industry equity | $554B / $2,582B = 21% | 24% |
| Banks with adjusted equity < 0 | 34 (all small, $46B assets) | 65 ($374B assets) |
| Run-risk flags | 1 | 1 |

- The rate gap at the median bank is now small, 0.2 points. Most loan books
  have repriced to about 6.6%. The losses sit in banks that still hold old,
  low-rate mortgages: savings banks, TrustCo, Bank of Hawaii, and Morgan
  Stanley Private Bank in the calibrated variant.
- The one run-risk flag is Phenix-Girard Bank ($0.3B, 52% uninsured).
  Its reported equity is already negative, so the old filter dropped it.
- TrustTexas Bank shows the thesis in one bank. AFS losses have cut its
  reported equity to $50K, yet its Tier 1 capital is still $34M because of
  the AOCI opt-out.
- Among the 10 largest banks, Bank of America has the largest hidden loss:
  $104B HTM + $44B loans = 62% of equity. After that, its adjusted equity is
  3.3% of assets.
- Two South Dakota examples: Dacotah Bank's hidden loss is $30.4M (its
  $46.8M AFS loss is already in equity, so all three losses come to $77.2M).
  First Bank & Trust's is $73.6M (all three: $90.8M).

**At 2022-12-31 (4,756 banks with an estimate; `pct_worst` 0.01 = worst 1%)**

| Bank | Hidden loss | Adj. equity / assets | Uninsured share | `pct_worst` | Place among the 353 banks with >50% uninsured | Flag (base / calibrated) |
|---|---|---|---|---|---|---|
| Silicon Valley Bank | $15.3B | +0.1% | 94% | 5.3% | 3.1% (11th) | no / **yes** |
| First Republic | $25.2B | −3.7% | 68% | **0.7%** | **0.8% (3rd)** | **yes / yes** |
| Signature | $2.7B | +4.8% | 90% | 35% | 26% | no / no |

- **First Republic is caught clearly.** It was 3rd of 353 high-uninsured
  banks, and the loss came from loans: old low-rate jumbo mortgages.
- **SVB is borderline.** Its hidden losses almost exactly erase its equity
  (+0.1% of assets), so the base flag misses it by a hair and the
  calibrated flag catches it. Nearly all of its loss is the reported $15.2B
  HTM loss, and its loans were mostly floating-rate.
- **Signature is missed.** Interest-rate loss explains little of its
  failure. The causes were concentrated crypto-linked deposits and a fast
  run, which this measure does not see. Neither do the other two 2023
  failures (Heartland Tri-State and Citizens Bank, both fraud or credit).
- The flag is noisy: 10 banks flagged in the base case and 33 in the
  calibrated case. Many survived because their depositors never ran and the
  Fed's BTFP lending program (March 2023) removed the need to sell.
- With the dropped banks restored, 243 banks had adjusted equity < 0 at
  2022Q4 (222 before), all 21 additions small banks with negative reported
  equity.

## Known errors and limits

- **The loan yield mixes every loan type.** Credit cards and floating C&I
  loans raise the yield, which shrinks the gap. Capital One and Citi show
  zero loan loss, so the fixed-rate mortgages inside them are understated.
  One gap per bank, against the mortgage rate, even for CRE, ag and
  consumer loans.
- **The loan yield is distorted by mergers.** The average balance is
  (this quarter + last) / 2. In a merger quarter the acquirer's average
  understates the loans that earned the income, so its yield runs high and
  its gap low.
- **The durations are assumptions.** Duration is not reported anywhere.
  The securities check says the method runs low overall, hence the
  calibrated variant.
- **Credit risk and the deposit franchise are ignored.** Loans that will
  default lose more, while low-rate deposits gain value as rates rise
  (Drechsler and coauthors), which offsets much of the asset loss. Leaving
  that out overstates insolvency.
- **Cross-section values move as late filers arrive.** The median imputed
  yield, the calibration factor and `pct_worst` depend on which banks have
  filed, so the newest quarter shifts slightly for a few weeks.
- **The FDIC serves amended figures**, so past quarters show data the
  market may not have seen. The pipeline's `revisions.csv` measures this
  from now on.
- **Freddie Mac changed the `MORTGAGE30US` method** in November 2022
  (`rates_monthly.method_break`), a small level break in every rate gap
  that spans it.
- About 3% of banks get the median loan yield (missing or implausible
  yield, `loan_yield_imputed`). The pipeline fails if this passes 5% in
  any of the last 20 quarters.

## Next steps

1. Estimate a fixed-rate coupon: back out the floating-rate share using
   the ≤1-year buckets, then compute the gap on the fixed part only.
2. Loan-type interest income from the FFIEC bulk Call Report
   (RIAD4435/4436), so mortgages and CRE get their own yields and gaps.
3. Calibrate the durations bank by bank on securities instead of one
   industry-wide factor.
4. Add the deposit franchise.

Sources: [FDIC Quarterly Banking Profile Q3 2026](https://www.fdic.gov/news/speeches/2026/fdic-quarterly-banking-profile-third-quarter-2026);
FDIC Quarterly Banking Profile Q4 2022 ($620.4B unrealized securities losses);
Jiang, Matvos, Piskorski & Seru (2023), *Monetary tightening and U.S. bank fragility in 2023: Mark-to-market losses and uninsured depositor runs?*
