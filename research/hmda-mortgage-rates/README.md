# How far under water are banks' home loans? (HMDA)

Research. It is not part of the app.

**Pipeline status (spec PRs 9 and 10, 2026-11).** The data pull and the
valuation now live in the data pipeline. Once a year `hmda.yml` streams
the national HMDA snapshot for every bank, 2018 on (`pipeline/sources/hmda.R`),
and stores the loans and their groups (`hmda.lar.YYYY.parquet`,
`hmda.panel.parquet`, `hmda.groups.parquet` in the `data-raw` release).
Every night the `hmda_book` mart values those groups at the newest quarter
end with that night's FRED rates (`hb_value()` in `pipeline/R/hmda_book.R`,
every assumption in `HB_PARAMS`): book rate, loss, duration and the share
of the call-report book HMDA explains, for every HMDA-reporting bank. The
book rate changes once a year, and the loss follows rates every week. The mart is
published but not shown in the app. This folder fetches nothing:
`analyze.R` reads the mart and the stored files, and runs the parts that
stay research (prepayment sensitivity, vintages, the South Dakota
benchmark, the ranking) with the same functions.

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
| **HMDA** (Home Mortgage Disclosure Act) national snapshot files (CFPB/FFIEC), via the pipeline's `hmda.*` files | Every mortgage a lender originated in 2018–2025, with amount, interest rate, term, fixed or adjustable, and `purchaser_type` (who bought the loan; `0` = nobody that year) |
| HMDA public panel files (2018–2023) | Map each lender's LEI (the global ID in HMDA) to its RSSD (the Federal Reserve's bank ID) |
| FDIC call reports, via the pipeline's raw quarters | RSSD per CERT in each HMDA year (`RSSDID`), plus balances, equity and income at the valuation date |
| FRED `MORTGAGE30US`, `MORTGAGE15US`, via the `rates_monthly` mart | Freddie Mac's weekly survey rate: monthly averages for the history, the last weekly reading of the valuation month for "today" |

The bank ID chain uses exact IDs only, with no name matching: HMDA LEI →
panel `respondent_rssd` → the CERT whose call report carried that RSSD in
the HMDA year.

**Banks studied** (all still open):

| Bank | Why |
|---|---|
| Third Federal S&L (OH), CERT 30012, $18B | About 90% of assets are home loans. It is the textbook "holds its mortgages" thrift |
| Capitol Federal (KS), CERT 27981, $10B | About 60% home loans. A second thrift in a different region |
| Associated Bank (WI), CERT 5296, $51B | A mid-size regional bank with a mix of lending |
| Dacotah Bank (SD), CERT 17437, $5B | A community and farm bank that sells most of its mortgages |
| "All FDIC banks, SD properties" | Benchmark: every loan made by an FDIC-insured bank on a South Dakota home, valued as one book. The first pass used it as an industry stand-in; the `hmda_book` mart now covers every bank |

## Method

1. **Pick the loans a bank kept.** Keep originated (`action_taken=1`),
   first-lien, closed-end (no home-equity lines), non-business, 1–4 unit home
   loans. Count a loan as kept when `purchaser_type = 0`, meaning it wasn't
   sold in the year it was made.
2. **Rate by vintage.** For each origination year, the dollar-weighted
   average rate of kept loans: the vintage table in `summary.txt`.
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
   average rate on what is still owed. Loans with no rate, no term or an
   unknown fixed/adjustable status ("Exempt" small lenders, mostly) are
   left out and counted (`valued_share`), never given a default.
4. **Price it.** Present value = the remaining monthly payments discounted at
   today's rate: 7.03% for 30-year loans, 6.42% for loans of 15 years or less.
   Loss % = 1 − present value / balance owed. As a check we also compute
   **duration**, the % change in value for a 1-point change in rates, and the
   shortcut *loss ≈ duration × (today's rate − WAC)*. For the four banks the
   two methods agree within about 0.9 pt, and for all banks pooled within
   0.2 pt (the nightly check fails above 1 pt). For a single bank whose book mixes
   below-market 2020–21 loans with above-market 2023–25 loans they can be
   further apart (17% of banks, more than 1 pt): the shortcut credits the
   above-market loans with a gain they don't keep, because they prepay at
   20%, and one duration × one gap ignores how the gap varies across the
   book. The present value is the number to use.
5. **Scale to the bank** (research only, not in the mart). Apply the loss % to the bank's whole closed-end
   first-lien 1–4 family book from the call report (the `LNRS*` maturity
   buckets, RC-C memo 2.a, the same line the hidden-loss estimator uses), and
   compare that loss with the bank's equity (`EQTOT`).
6. **Cross-check** against the call report. The FDIC API has no
   "interest on 1–4 family loans" field, so we use the yield on *all* loans,
   `ILNLSQ×4 / average LNLSGR`.

## Run it

```sh
gh release download data-marts --dir pipeline/out/marts --pattern 'hmda_book.parquet'
gh release download data-marts --dir pipeline/out/marts --pattern 'rates_monthly.parquet'
gh release download data-raw   --dir pipeline/out/raw   --pattern 'hmda.groups.parquet'
gh release download data-raw   --dir pipeline/out/raw   --pattern 'hmda.lar.*.parquet'     # SD benchmark, ~80 MB
gh release download data-raw   --dir pipeline/out/raw   --pattern 'risdate.2026*.parquet'
Rscript research/hmda-mortgage-rates/analyze.R   # summary.txt, ~1 min; needs data.table
```

`summary.txt` has every table below, plus the prepayment sensitivity and
the industry ranking. The study banks, the benchmark state and the
sensitivity speeds are at the top of `analyze.R`; the model's assumptions
are `HB_PARAMS` in `pipeline/R/hmda_book.R`. The valuation date is the
mart's quarter, so a re-run after the next quarter gives new numbers.

## Results (valuation date 2026-09-30)

`summary.txt` (rounded):

| | WAC of kept 2018–25 loans | Today's rate | Duration (yrs) | Loss on those loans | First-lien home loans (call rpt) | Est. loss if whole book is like this | ÷ equity |
|---|---|---|---|---|---|---|---|
| Third Federal | 4.14% | 6.92% | 4.5 | **12.3%** | $10.7B | ~$1.32B | **71%** |
| Capitol Federal | 4.01% | 6.93% | 4.9 | **13.8%** | $5.6B | ~$0.78B | **82%** |
| Associated | 4.11% | 7.01% | 3.8 | **11.1%** | $6.7B | ~$0.74B | 14% |
| Dacotah | 6.04% | 6.77% | 2.0 | 2.4% | $0.19B | ~$4M | 1% |
| All banks, SD homes | 4.79% | 6.94% | 4.3 | 10.0% | n/a | n/a | n/a |

**What moved since the first pass** (same method, same rates; the
pipeline's code and inputs):
- Third Federal's ÷ equity fell from 79% to 71%, and every bank's book
  shrank a little, because the book is now the call report's first-lien
  line (`LNRS*`) instead of `LNRERES − LNRELOC`, which also counts closed-end
  junior liens (Third Federal has $1.1B of them). HMDA's kept loans are
  first liens, so this is the like-for-like book. (`LNRELOC` isn't in the
  pipeline's raw fields either.) HMDA's share of the book rose with it:
  Third Federal 53% → 58%, Associated 93% → 95%.
- Dacotah 6.05% → 6.04% and 2.3% → 2.4%: $0.67M of its kept loans have no
  term, which the first pass read as 30 years; now they are left out.
  Associated ($1M) and Third Federal ($0.4M) move by less than 0.001
  point, and Capitol Federal not at all.
- South Dakota benchmark: WAC 4.92% → 4.79%, loss 9.5% → 10.0%. The
  pipeline links each HMDA year to the banks insured that year, including
  banks that have merged since, where the first pass used today's active
  banks. Loans with no term or an unknown fixed/adjustable status are now
  left out instead of read as 30-year fixed.

**Every bank** (`hmda_book`, 2,435 banks with HMDA loans that filed in
2026 Q3): the 1,072 with valued loans hold $1.5T of kept 2018–25 loans
still outstanding at a WAC of 4.29%, worth 11.9% less than owed
(balance-weighted; the median bank 7.3%). 1,272 banks have no kept loans
with a rate (small lenders may report "Exempt"). Scaled to the first-lien
book and divided by equity, the largest are savings banks like the two
thrifts here: TrustCo (113%), Milford Federal, First Federal S&L, Capitol
Federal and Cape Cod Five (80–85%) (`summary.txt`, banks where HMDA
explains 50–110% of the book).

What the vintage table (`summary.txt`) shows:
- Kept 2020–2021 loans carry **2.7–3.3%** at every bank except Dacotah. Those
  vintages are now worth roughly **13–21 cents less per dollar** owed, and they
  make up the biggest share of what's left.
- Thrifts keep almost everything they make (Third Federal 66–99% of dollars,
  Capitol Federal ~100%). Associated keeps 47–80%. Dacotah and South Dakota
  banks as a group keep only about 20%. **Selling loans is the main protection.** A
  bank that sold its 3% loans to Fannie and Freddie doesn't carry this loss.
- Loans from 2023–2025 are near today's rate, so their loss is small (≈2–6%).

**Cross-check with the call report.** Third Federal's yield on all loans is
4.93%. Its book is $11.8B of closed-end mortgages plus $4.6B of home-equity
lines (`LNRELOC`, from the first pass's own FDIC pull), which earn a floating rate. If those lines earn about 7–7.5%, the closed-end loans must
be yielding about 3.9–4.1%, close to the HMDA WAC of 4.14%. Capitol Federal
(4.54% on all loans, about a third non-mortgage) implies about 3.7–4.0%, again close.
Associated (5.65%) and Dacotah (6.38%) are mostly business loans, so the
all-loan yield can't test the mortgage estimate there.

**Coverage.** The HMDA-tracked surviving balance explains 58% of Third
Federal's first-lien book, 69% of Capitol Federal's, 95% of Associated's and
24% of Dacotah's (`hmda_share`). The rest is pre-2018 loans or loans HMDA
doesn't capture. Across all banks 55 have a share above 1: they kept loans
in the HMDA year and sold them later.

## Known errors and limits (read before quoting a number)

- **"Kept" is approximate.** `purchaser_type=0` only means *not sold in the
  same calendar year*. A loan made in December and sold in January counts as
  kept. This overstates retention, most of all at sellers like Associated.
  Banks also sell or securitize older loans later, which HMDA doesn't show.
- **Pre-2018 loans are assumed to look like 2018–25 loans** when we scale
  to the whole book. Older loans had 3.5–4.5% rates and have paid down more,
  so their loss is probably similar or somewhat smaller.
- **Prepayment speeds are assumptions.** At 4% vs 10% a year the loss moves by
  about ±2 pt (columns `cpr04`/`cpr10` in `summary.txt`). Real refinance waves ran
  faster than 20%, so we probably keep too many 2018–19 loans alive.
- **Discount rate.** We discount at the rate a borrower pays (the Freddie Mac
  survey). A loan buyer would also charge for servicing and credit risk, and for
  non-agency (jumbo, portfolio) loans the spread over agency MBS (mortgage-backed
  securities) is wider. Both make the true loss somewhat larger.
- **Origination date** is assumed to be mid-year. The HMDA public file has
  no month.
- **Small lenders can skip the rate field.** Since 2018, small lenders may
  report "Exempt" for interest rate. Our four banks report rates for 100% of
  kept loans. The South Dakota benchmark has rates for only 61–89% of kept
  dollars, and 1,272 of the 2,435 banks in the mart have none.
- **Liabilities aren't marked.** A loss on assets isn't the same as insolvency.
  Cheap, sticky deposits (the "deposit franchise") are worth more than face
  value when rates are high and partly offset this loss. Hedges (interest-rate
  swaps) aren't visible here. Losses near 80% of equity for the two thrifts
  are a red flag, not proof of insolvency. Both thrifts publish loan fair values
  in their 10-K footnotes, so check those next.
- **The call report field `LNRERSF1`** ("1-4 family first liens-adjust") isn't
  the closed-end first-lien balance: for Capitol Federal it shows $0.9B out of a
  $5.75B book. The first pass used `LNRERES − LNRELOC`, which also includes
  junior closed-end liens; the pipeline uses the `LNRS*` maturity buckets,
  closed-end first liens only.
- **Merged banks.** The mart values the loans of each CERT that still
  files. Loans a bank made before it was acquired stay with its old CERT,
  which no longer files, so they are dropped (735 CERTs at 2026 Q3), not
  moved to the acquirer.

## Next steps

1. **Check against the banks' own fair values.** 10-K/10-Q filings (SEC EDGAR, free)
   give the "fair value of loans" for public banks. Third Federal (TFSL),
   Capitol Federal (CFFN) and Associated (ASB) all file. This is the best test
   of the model.
2. ~~**Industry-wide.**~~ Done: the `hmda_book` mart (spec PRs 9 and 10).
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
| `analyze.R` | Reads the `hmda_book` mart and the stored HMDA files, checks the mart against `hb_value()`, runs the sensitivity, vintage, benchmark and ranking tables |
| `summary.txt` | Its output: today's rates, the four banks, vintages, the SD benchmark, every bank |
| `pipeline/R/hmda_book.R` | The filter, the groups and the valuation (`hb_value()`, `HB_PARAMS`) |
| `pipeline/marts/hmda_book.R`, `pipeline/checks/hmda_book.R` | The nightly mart and its check |

The first pass's `01_fetch.R`, `02_analyze.R`, `config.R` and
`results/*.csv` are gone: `summary.txt` and the `gh release download` lines
above reproduce them.
