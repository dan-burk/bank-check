# Hidden losses at every US bank: a first prototype

**Question.** Many banks lent money or bought bonds when rates were 3-4%.
New loans now pay about 7%. If a bank had to sell those old loans and bonds
today, a buyer would pay less than face value, because the buyer could
earn more on a new loan. The gap between face value and what the asset would
sell for is an *unrealized loss*. Most of it is not subtracted from the
equity the bank reports. How large is it, bank by bank, and does it point
to the banks that failed in 2023?

This is an exploratory research script. It does not change the Shiny app
or the pipeline.

## Files

| File | What |
|---|---|
| `01_fetch.R` | Downloads the data into `cache/` (gitignored): 4 quarters of FDIC Call Report fields for all banks, plus FRED interest rates |
| `02_estimate.R` | Runs the estimate. All assumptions sit at the top of the file |
| `results_latest.csv` | One row per bank, 2026-09-30 (4,263 banks), sorted worst first by adjusted equity / assets |
| `top25_latest.csv` | 25 banks with the largest hidden loss relative to equity |
| `backtest_2022q4.csv` | SVB, Signature and First Republic at 2022-12-31 |
| `summary.txt` | The printed headline numbers and tables |

Run it from the repo root with `Rscript research/unrealized-losses/01_fetch.R`
and then `Rscript research/unrealized-losses/02_estimate.R`. Dollar amounts
are in **$ thousands**, as in the FDIC data.

## Data (all free, no keys)

- **FDIC BankFind API** (`api.fdic.gov/banks/financials`). This is the
  quarterly Call Report every insured bank files. The fields used:
  - Securities. `SCHA` and `SCHF` give held-to-maturity (HTM) at amortized
    cost and at fair value. `SCAA` and `SCAF` give the same for
    available-for-sale (AFS). Amortized cost is roughly what the bank paid,
    and fair value is what the bond would sell for today.
  - Loans by time until the rate resets. The bank reports how much of its
    loans either mature or get a new interest rate within ≤3 months,
    3-12 months, 1-3 years, 3-5 years, 5-15 years or more than 15 years.
    The fields are `LNRS*` for first-lien home mortgages and `LNOT*` for
    all other loans (Schedule RC-C, Memorandum 2). These buckets cover 98%
    of all loans. Securities have the same buckets (`SCNM*`, `SCPT*`, `SCO*`).
  - Loan interest income for the quarter (`ILNLSQ`) and total loans
    (`LNLSGR`). These give the bank's average loan yield.
  - Equity (`EQTOT`), Tier 1 capital (`RBCT1J`), estimated uninsured
    deposits (`DEPUNINS`), domestic deposits (`DEPDOM`).
- **FRED** (St. Louis Fed). `MORTGAGE30US` is the 30-year mortgage rate and
  `DGS10` is the 10-year Treasury yield. The script averages each over the
  last month of the quarter.
- The FFIEC bulk download was **not needed**, because the FDIC API already
  has every bucket field. (That site is a web form, not a simple URL, so
  scripting it would take more work.) The FDIC API has no separate
  interest-income field for real estate loans, so the script uses the yield
  on all loans.

## Method

1. **Securities losses are reported, not estimated.** HTM loss = `SCHA − SCHF`.
   AFS loss = `SCAA − SCAF`. The AFS loss is already subtracted from
   reported equity through "AOCI" (accumulated other comprehensive income,
   a line inside equity). The HTM loss is not subtracted anywhere.
2. **Loan losses are estimated, in the spirit of Jiang, Matvos, Piskorski
   and Seru (2023).**
   - *Rate gap* = 30-year mortgage rate today − the bank's own loan yield,
     floored at 0. This is the "3-4% versus 7%" idea. A bank that earns
     4.5% on its loans when new loans pay 6.9% has a 2.4-point gap.
   - *Duration* says how much a loan's price falls per 1-point rise in
     rates. A loan that resets in 3 months barely moves, and a 30-year
     mortgage moves a lot. The assumed effective durations are 0.1, 0.5,
     1.8, 3.5, 5.5 and 7.5 years for the six buckets. They sit below each
     bucket's midpoint because loans repay principal every month.
   - Loss for each bucket = balance × duration × rate gap, capped at a 50%
     price drop. The bank's loan loss is the sum over its buckets.
3. **Self-check on securities.** For securities we know the right answer,
   so the script runs the same method on them, using the bank's securities
   yield against the 10-year Treasury, and compares it with the reported
   losses. Across banks the correlation is **0.99**, but the method comes
   out low: 81% of the reported total in 2026Q3 and 55% in 2022Q4. A
   **calibrated** variant therefore multiplies each loan loss by
   reported ÷ modeled (×1.24 in 2026Q3, ×1.82 in 2022Q4).
4. **Per-bank outputs.**
   - `hidden_loss` = HTM loss + loan loss. This is the loss that equity does not show.
   - `adj_equity` = equity − hidden loss. AFS is not subtracted again.
   - `all_loss_to_tier1` = (HTM + AFS + loans) ÷ Tier 1. The AFS loss
     counts here because most banks chose to keep it out of regulatory
     capital (the "AOCI opt-out"). The API has no per-bank opt-out flag,
     so this ratio assumes every bank opted out.
   - `uninsured_share` = uninsured ÷ domestic deposits. Uninsured
     depositors have the most reason to run.
   - `run_risk_flag` = adjusted equity < 0 **and** uninsured share > 50%.
     `run_risk_flag_cal` applies the same test to the calibrated loss.

## Results

**Sanity check against the FDIC.** The FDIC's Q3 2026 Quarterly Banking
Profile reports **$486B** of unrealized securities losses. The bank-level
fields here sum to **$486B** ($296B HTM + $190B AFS). For 2022Q4 they sum
to $616B, close to the ~$620B the FDIC published then.

**Latest quarter (2026-09-30), 4,263 banks**

| | Base | Calibrated |
|---|---|---|
| Loan mark-to-market loss | $258B (1-4 family $141B, other $117B) | $320B |
| Hidden loss (HTM + loans) / industry equity | $554B / $2,582B = 21% | 24% |
| Banks with adjusted equity < 0 | 30 (all small, $43B assets) | 61 ($371B assets) |
| Run-risk flags | 0 | 0 |

- The rate gap at the median bank is now small, 0.2 points. Most loan books
  have repriced to about 6.6%. The losses sit in banks that still hold old,
  low-rate mortgages: savings banks, TrustCo, Bank of Hawaii, and Morgan
  Stanley Private Bank in the calibrated variant.
- TrustTexas Bank shows the thesis in one bank. AFS losses have cut its
  reported equity to $50K, yet its Tier 1 capital is still $34M because of
  the AOCI opt-out.
- Among the 10 largest banks, Bank of America has the largest hidden loss:
  $104B HTM + $44B loans = 62% of equity. After that, its adjusted equity is
  3.3% of assets.
- The top 25 are in `top25_latest.csv`. 24 of the 25 are small (under $1B).
  None has more than 50% uninsured deposits.

**Backtest at 2022-12-31 (4,735 banks; rank 1 = worst)**

| Bank | Hidden loss / equity | Adj. equity / assets | Uninsured share | Rank, adj. equity (of 4,735) | Rank among the 353 banks with >50% uninsured | Flag (base / calibrated) |
|---|---|---|---|---|---|---|
| Silicon Valley Bank | 99% | +0.1% | 94% | 230 | 11 | no / **yes** |
| First Republic | 145% | −3.7% | 68% | 30 | **3** | **yes / yes** |
| Signature | 34% | +4.8% | 90% | 1,631 | 93 | no / no |

- **First Republic is caught clearly.** It was 3rd of 353 high-uninsured
  banks, and the loss came from loans: old low-rate jumbo mortgages.
- **SVB is borderline.** Its hidden losses almost exactly erase its equity
  (+0.1% of assets), so the base flag misses it by a hair and the
  calibrated flag catches it. Nearly all of its loss is the reported $15B
  HTM loss, and its loans were mostly floating-rate.
- **Signature is missed.** Interest-rate loss explains little of its
  failure. The causes were concentrated crypto-linked deposits and a fast
  run, which this measure does not see.
- The flag is noisy. 10 banks were flagged in 2022Q4 in the base case, and
  33 in the calibrated case. Only First Republic (and SVB in the
  calibrated case) failed. Many flagged banks survived because their
  depositors never ran and the Fed's BTFP lending program (March 2023)
  removed the need to sell.

## Known errors and limits

- **The loan yield mixes every loan type.** Credit cards (about 13%) and
  floating C&I loans raise the yield, which shrinks the gap. As a result
  Capital One and Citi show zero loan loss, and the fixed-rate mortgages
  inside them are understated. The model also uses a single gap per bank,
  measured against the mortgage rate, even for CRE, ag and consumer loans.
- **The durations are assumptions.** Duration is not reported anywhere.
  The securities check says the method runs low overall, hence the
  calibrated variant.
- **Credit risk is ignored.** This is pure interest-rate loss. Loans that
  will default (office CRE, for example) lose more. Equally, rising rates
  also raise the value of deposits, because low-rate deposits are a cheap
  funding source the bank keeps. Drechsler and coauthors argue this deposit
  value offsets much of the asset loss. Leaving it out overstates insolvency.
- **The bucket groups are coarse.** "Other loans" lumps CRE, ag, C&I,
  consumer and foreign loans together, with one duration per bucket. It
  does not split out CRE, ag or foreign loans, but they are the natural
  next refinement.
- **AOCI opt-out is unknown per bank**, so the Tier 1 ratio assumes all
  banks opted out.
- Uninsured deposits are the banks' own estimates. 21 banks that lacked
  equity or assets were dropped, and 117 (latest quarter) had an
  implausible or missing loan yield and got the median instead (column
  `loan_yield_imputed`).
- The hidden loss / equity ratio explodes when equity is near zero
  (TrustTexas: 657×). For ranking, use `adj_equity_to_assets`.

## Next steps

1. Estimate a fixed-rate coupon: back out the floating-rate share using
   the ≤1-year buckets, then compute the gap on the fixed part only.
2. Pull loan-type interest income from the FFIEC bulk Call Report (it has
   RIAD4435/4436, real estate interest income) so that mortgage and CRE
   get their own yields and gaps.
3. Calibrate the durations bank by bank on securities, where the true loss
   is known, instead of one industry-wide factor.
4. Add the deposit franchise: the value of deposits that pay far below
   market. Then run the same flag on every quarter from 2022 to 2024 and
   score it against the actual failures and near-failures.

Sources: [FDIC Quarterly Banking Profile Q3 2026](https://www.fdic.gov/news/speeches/2026/fdic-quarterly-banking-profile-third-quarter-2026);
Jiang, Matvos, Piskorski & Seru (2023), *Monetary tightening and U.S. bank fragility in 2023: Mark-to-market losses and uninsured depositor runs?*
