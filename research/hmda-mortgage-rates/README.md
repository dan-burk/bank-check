# How far under water are banks' home loans? (HMDA prototype)

Exploratory research only. Nothing here touches the Shiny app or the pipeline.

**Pipeline status (spec PR 9, 2026-11).** The pipeline now pulls the
national HMDA snapshot for every bank, 2018-2025 (`pipeline/sources/hmda.R`,
`hmda.yml`): `hmda.lar.YYYY.parquet`, `hmda.panel.parquet` and
`hmda.groups.parquet` in the `data-raw` release, with the filter and
grouping in `pipeline/R/hmda_book.R`. For the four banks below it gives the
same loan counts, dollars and kept dollars as `results/vintages.csv` in
every year, and the same exact kept rate (the groups round coupons to 1/8
point, which moves Third Federal by about 0.01). The South Dakota
benchmark has 0.1-14% more loans there, because the pipeline links each
year to the banks insured that year, including ones that have merged
since; this prototype used today's active banks. Spec PR 10 moves the
valuation and trims this folder to read those files.

## The question

During 2020–2021 banks made a lot of 30-year home loans at about 3%. In
September 2026 a new 30-year loan costs about 7%. If a bank had to sell an old 3%
loan today, a buyer would pay much less than the amount still owed, because the
buyer could get 7% elsewhere. The bank's balance sheet still shows the full
amount owed (the "book value"). The gap between book value and what the loan
would sell for is an **unrealized loss**: a loss that is real in economic terms
but doesn't appear in reported earnings or capital.

The call report shows how many home loans a bank holds. It doesn't show their
interest rates. **HMDA** does show rates, loan by loan, so this prototype uses
it to estimate (1) the average interest rate on each bank's home-loan book and
(2) how much that book would lose if marked to today's market.

## Data (all free, no key)

| Source | What we take from it |
|---|---|
| **HMDA** (Home Mortgage Disclosure Act) loan-level data, CFPB Data Browser API | Every mortgage a lender originated in 2018–2025, with amount, interest rate, term, fixed or adjustable, and `purchaser_type` (who bought the loan; `0` = nobody that year) |
| HMDA public panel files (2018–2023) | Map each lender's LEI (the global ID in HMDA) to its RSSD (the Federal Reserve's bank ID) |
| FDIC BankFind API | CERT → RSSD (`FED_RSSD`), plus call report balances and income at 2026-09-30 |
| FRED `MORTGAGE30US`, `MORTGAGE15US` | Freddie Mac's weekly survey rate, both historical and "today" |

The bank ID chain uses exact IDs only, with no name matching: FDIC CERT → `FED_RSSD` →
HMDA panel `respondent_rssd` → LEI.

**Banks studied** (all still open):

| Bank | Why |
|---|---|
| Third Federal S&L (OH), CERT 30012, $18B | About 90% of assets are home loans. It is the textbook "holds its mortgages" thrift |
| Capitol Federal (KS), CERT 27981, $10B | About 60% home loans. A second thrift in a different region |
| Associated Bank (WI), CERT 5296, $51B | A mid-size regional bank with a mix of lending |
| Dacotah Bank (SD), CERT 17437, $5B | A community and farm bank that sells most of its mortgages |
| "All FDIC banks, SD properties" | Industry stand-in: every loan made by an FDIC-insured bank on a South Dakota home. The national file is several GB a year, so one small state was used for this first pass |

## Method

1. **Pick the loans a bank kept.** Keep originated (`action_taken=1`),
   first-lien, closed-end (no home-equity lines), non-business, 1–4 unit home
   loans. Count a loan as kept when `purchaser_type = 0`, meaning it wasn't
   sold in the year it was made.
2. **Rate by vintage.** For each origination year, the dollar-weighted
   average rate of kept loans: `results/vintages.csv`.
3. **Run the loans forward to today.** Loans with the same year, term, rate
   (rounded to 1/8 pt) and adjustable-rate reset date form one group. Each
   group is treated as one loan made on 1 July of its year with level monthly
   payments. Each month some borrowers repay early:
   - **6% a year** while the loan rate is below the going rate. Only people who
     move house pay off, and nobody refinances a 3% loan to get a 7% one.
   - **20% a year** when the loan rate is more than 0.5 pt above the going rate,
     because borrowers refinance. Past months use the actual FRED rate history,
     so the 2018–19 loans correctly mostly refinanced away in 2020–21.
     Future months assume today's rate stays where it is.
   - An adjustable-rate loan is treated as fixed until its first reset. After
     that it reprices, so it leaves the "under water" book at full value.

   The result is each group's estimated balance still outstanding at
   2026-09-30, and from that the book's **weighted average coupon (WAC)**, the
   average rate on what is still owed.
4. **Price it.** Present value = the remaining monthly payments discounted at
   today's rate: 7.03% for 30-year loans, 6.42% for loans of 15 years or less.
   Loss % = 1 − present value / balance owed. As a check we also compute
   **duration**, the % change in value for a 1-point change in rates, and the
   shortcut *loss ≈ duration × (today's rate − WAC)*. The two methods agree
   within about 0.5 pt.
5. **Scale to the bank.** Apply the loss % to the bank's whole closed-end 1–4
   family book from the call report (`LNRERES − LNRELOC`), and compare that loss
   with the bank's equity (`EQTOT`).
6. **Cross-check** against the call report. The FDIC API has no
   "interest on 1–4 family loans" field, so we use the yield on *all* loans,
   `ILNLSQ×4 / average LNLSGR`.

Run it:

```sh
Rscript research/hmda-mortgage-rates/01_fetch.R    # ~15 min first time, cached after
Rscript research/hmda-mortgage-rates/02_analyze.R  # ~1 min
```

Settings (banks, years, prepayment speeds) are in `config.R`.

## Results (valuation date 2026-09-30)

`results/book_summary.csv` (rounded):

| | WAC of kept 2018–25 loans | Today's rate | Duration (yrs) | Loss on those loans | Closed-end home loans (call rpt) | Est. loss if whole book is like this | ÷ equity |
|---|---|---|---|---|---|---|---|
| Third Federal | 4.14% | 6.92% | 4.5 | **12.3%** | $11.8B | ~$1.46B | **79%** |
| Capitol Federal | 4.01% | 6.93% | 4.9 | **13.8%** | $5.7B | ~$0.78B | **82%** |
| Associated | 4.11% | 7.01% | 3.8 | **11.1%** | $6.8B | ~$0.75B | 14% |
| Dacotah | 6.05% | 6.77% | 2.0 | 2.3% | $0.2B | ~$5M | 1% |
| All banks, SD homes | 4.92% | 6.95% | 4.3 | 9.5% | n/a | n/a | n/a |

What the vintage table (`results/vintages.csv`) shows:
- Kept 2020–2021 loans carry **2.7–3.3%** at every bank except Dacotah. Those
  vintages are now worth roughly **13–21 cents less per dollar** owed, and they
  make up the biggest share of what's left.
- Thrifts keep almost everything they make (Third Federal 66–99% of dollars,
  Capitol Federal ~100%). Associated keeps 47–80%. Dacotah and South Dakota
  banks as a group keep only about 20%. **Selling loans is the main protection.** A
  bank that sold its 3% loans to Fannie and Freddie doesn't carry this loss.
- Loans from 2023–2025 are near today's rate, so their loss is small (≈2–5%).

**Cross-check with the call report.** Third Federal's yield on all loans is
4.93%. Its book is $11.8B of closed-end mortgages plus $4.6B of home-equity
lines, which earn a floating rate. If those lines earn about 7–7.5%, the closed-end loans must
be yielding about 3.9–4.1%, close to the HMDA WAC of 4.14%. Capitol Federal
(4.54% on all loans, about a third non-mortgage) implies about 3.7–4.0%, again close.
Associated (5.65%) and Dacotah (6.38%) are mostly business loans, so the
all-loan yield can't test the mortgage estimate there.

**Coverage.** The HMDA-tracked surviving balance explains 53% of Third
Federal's closed-end book, 69% of Capitol Federal's, 93% of Associated's and
23% of Dacotah's. The rest is pre-2018 loans or loans HMDA doesn't capture.

## Known errors and limits (read before quoting a number)

- **"Kept" is approximate.** `purchaser_type=0` only means *not sold in the
  same calendar year*. A loan made in December and sold in January counts as
  kept. This overstates retention, most of all at sellers like Associated.
  Banks also sell or securitize older loans later, which HMDA doesn't show.
- **Pre-2018 loans are assumed to look like 2018–25 loans** when we scale
  to the whole book. Older loans had 3.5–4.5% rates and have paid down more,
  so their loss is probably similar or somewhat smaller.
- **Prepayment speeds are assumptions.** At 4% vs 10% a year the loss moves by
  about ±2 pt (columns `loss_pct_cpr04`/`cpr10`). Real refinance waves ran
  faster than 20%, so we probably keep too many 2018–19 loans alive.
- **Discount rate.** We discount at the rate a borrower pays (the Freddie Mac
  survey). A loan buyer would also charge for servicing and credit risk, and for
  non-agency (jumbo, portfolio) loans the spread over agency MBS (mortgage-backed
  securities) is wider. Both make the true loss somewhat larger.
- **Origination date** is assumed to be mid-year. The HMDA public file has
  no month.
- **Small lenders can skip the rate field.** Since 2018, small lenders may
  report "Exempt" for interest rate. Our four banks report rates for 100% of
  kept loans. The South Dakota benchmark has rates for only 56–88% of kept dollars.
- **Liabilities aren't marked.** A loss on assets isn't the same as insolvency.
  Cheap, sticky deposits (the "deposit franchise") are worth more than face
  value when rates are high and partly offset this loss. Hedges (interest-rate
  swaps) aren't visible here. Losses near 80% of equity for the two thrifts
  are a red flag, not proof of insolvency. Both thrifts publish loan fair values
  in their 10-K footnotes, so check those next.
- **The call report field `LNRERSF1`** ("1-4 family first liens-adjust") isn't
  the closed-end first-lien balance: for Capitol Federal it shows $0.9B out of a
  $5.75B book. We use `LNRERES − LNRELOC` instead, which also includes junior
  closed-end liens.
- Only four banks and one state. This tests the method; it isn't a census of
  the industry.

## Next steps

1. **Check against the banks' own fair values.** 10-K/10-Q filings (SEC EDGAR, free)
   give the "fair value of loans" for public banks. Third Federal (TFSL),
   Capitol Federal (CFFN) and Associated (ASB) all file. This is the best test
   of the model.
2. **Industry-wide.** Process the national HMDA snapshot files once a year (large,
   so stream them and keep only the bank and kept columns). Then compute WAC and
   loss % for every HMDA-reporting bank and rank by loss ÷ equity.
3. **Add the deposit side.** Estimate how fast each bank's deposits reprice from
   call report deposit costs, so assets *and* liabilities are both marked.
4. **Use real prepayment speeds.** Calibrate the speeds to observed agency MBS
   prepayments by coupon instead of using flat 6%/20%.
5. **Other loan types.** HMDA covers homes only. Commercial real estate, farm
   and foreign loans need other sources (e.g. call report maturity and repricing
   schedules) for the same exercise.

## Files

| File | What |
|---|---|
| `config.R` | Banks, years, valuation date, prepayment assumptions |
| `01_fetch.R` | Downloads and caches all inputs into `raw/` (gitignored) |
| `02_analyze.R` | Cleans HMDA, runs the cash-flow model, writes `results/` |
| `results/vintages.csv` | Per bank × year: loans made, kept, average rates, surviving balance, loss % |
| `results/book_summary.csv` | Per bank: WAC, today's rate, duration, loss %, sensitivity, call report cross-check |
| `results/market_rates.csv` | The FRED rates used as "today" |
