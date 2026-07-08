# FDIC Field Dictionary

Living document. Every field used in `analysis/` scripts is defined here before it is trusted. All codes verified against the live API (`https://api.fdic.gov/banks/financials`) on 2026-07-07, index `risview_20260608210616`. Titles come from the FDIC's own `risview_properties.yaml`; the caveats are ours.

## Ground rules that apply to every field

- **Dollar fields are $thousands.** `ASSET = 4867664` means $4.87B.
- **Unsuffixed ratio fields are year-to-date, annualized** (`ROA`, `NIMY`, `ELNATRY`, `NTLNLSR`). The `Q`-suffixed twins (`ROAQ`, `NIMYQ`, `ELNATRYQ`, `NTLNLSQR`) are single-quarter, annualized. Use Q variants for turning-point detection; YTD variants smooth within a calendar year and reset every January.
- **Income flows (`NETINC`, `INTINC`, `ELNATR`, `NTLNLS`, ...) are YTD**, not quarterly. To get a single quarter, difference consecutive quarters within the same year.
- `RISDATE` = `REPDTE` (aliases). Integer `YYYYMMDD`.
- Join key everywhere is `CERT`.
- A `0` is not always a zero. Small banks with no foreign offices report some fields as 0 rather than missing; pre-1990s quarters return NULL for fields that did not exist yet (e.g. `RBC1AAJ` pre-Basel, `DEPUNINS` early years).

## C: Capital

The bank's own money, the layer that absorbs losses before depositors take any. When it runs out, the bank is done.

| Code | What it is | Units | Watch out |
|---|---|---|---|
| EQ | Equity capital | $K | Book value, not market. Includes AOCI, so AFS securities losses show up here but HTM losses do not. |
| EQTOT | Total equity capital | $K | Same as EQ for nearly all banks; differs only with minority interest. |
| EQV | Equity / assets | % | Leverage without risk weights. Simple and hard to game. |
| RBC1AAJ | Tier 1 leverage ratio (PCA) | % | Regulatory trigger: <4% is undercapitalized, <2% is critical. But risk weights and AOCI opt-outs mean a bank can look fine here while sitting on unrealized losses. |
| RBCRWAJ | Total risk-based capital ratio (PCA) | % | Risk-weighted denominator is where the games live (what counts as low-risk). |

Game to watch: most community banks opted out of including AOCI in regulatory capital. A bank can have capital ratios untouched while its bond portfolio is deeply underwater. Check `SCAF - SCAA` against `EQ` yourself (see S section).

## A: Asset quality

Whether the money the bank lent out is coming back.

The delinquency pipeline, in order: current -> 30-89 days late (P3LNLS) -> 90+ days late (P9LNLS) -> nonaccrual (NALNLS) -> charge-off (NTLNLS). Each stage leads the next by one or more quarters; the 30-89 bucket is the earliest public warning.

| Code | What it is | Units | Watch out |
|---|---|---|---|
| LNLSNET | Net loans and leases | $K | Net of allowance. |
| NCLNLS | Noncurrent loans and leases | $K | 90+ days past due or nonaccrual. NCLNLS = P9LNLS + NALNLS (verified). |
| NCLNLSR | Noncurrent / gross loans | % | The headline asset-quality ratio. |
| P3LNLS | Loans 30-89 days past due | $K | The earliest public warning bucket. No ratio variant exists; divide by gross loans (LNLSNET + LNATRES). |
| P9LNLS | Loans 90+ days past due, still accruing | $K | Usually small; banks must move loans to nonaccrual unless well-secured. |
| NALNLS | Nonaccrual loans | $K | Interest recognition stopped. The bulk of NCLNLS at most banks. |
| P3ASSET | 30-89 days past due assets | $K | Asset-denominated twin of P3LNLS (includes debt securities); use the LNLS versions for loan-quality work. |
| P9ASSET | 90+ days past due assets | $K | |
| NTLNLS | Net charge-offs, YTD | $K | Realized losses. YTD; difference to get quarters. |
| NTLNLSR / NTLNLSQR | Net charge-offs / loans, annualized | % | YTD / single-quarter versions. |
| LNATRES | Allowance for credit losses | $K | The rainy-day fund for bad loans. Since each bank's CECL adoption (2023-01-01 for non-SEC filers like Dacotah) this is the ACL under ASC 326: lifetime expected losses on the whole book, not incurred losses. Same field code across the regime change; the definition underneath moved. Coverage below 1x of noncurrent is not mechanically underprovisioning (secured ag/CRE LGD runs 20-40%), but falling coverage against rising noncurrent is. |
| LNATRESR | Allowance / gross loans | % | Compare to NCLNLSR: allowance below noncurrent means the fund does not cover known problems. |
| RSLNLS / RSLNLSR | Restructured (modified) loans, $ and % | $K / % | Extend-and-pretend lives here. A loan reworked to avoid default counts as current but signals borrower distress. Rising RSLNLSR with flat NCLNLSR is a tell. |
| ELNATR | Provision for credit losses, YTD | $K | Management's estimate, and management chooses the timing. |
| ELNATRY / ELNATRYQ | Provision / avg assets, annualized | % | Provision spikes usually lag the actual deterioration. |

Games to watch: (1) provision timing is discretionary; under-provisioning flatters earnings until charge-offs force the issue. Coverage check: `LNATRES / NCLNLS` falling toward or below 1 means known bad loans exceed the fund. (2) Restructuring keeps loans out of NCLNLS. (3) The 30-89 bucket (P3ASSET) leads the 90+ bucket by a quarter or two; a clean NCLNLSR with a swelling P3ASSET is deterioration in transit.

## Concentration

| Code | What it is | Units | Watch out |
|---|---|---|---|
| LNRE | Total real-estate loans | $K | |
| LNCI | Commercial & industrial loans | $K | |
| LNAG / LNAGR | Agricultural loans, $ and % of loans | $K / % | Dacotah's book; ag failures cluster with farm-income cycles. |
| LNRECONS / LNRECONSR | Construction & land development | $K / % | The classic failure accelerant: 2008-2012 failures were soaked in construction lending. |
| LNRENRES / LNRENRESR | Nonfarm nonresidential (CRE) | $K / % | Regulatory concern threshold is CRE > 300% of capital. |
| LNREMULT / LNREMULTR | Multifamily | $K / % | |

## E: Earnings

The spread between what the bank pays for money and what it charges for it, which pays the bills.

| Code | What it is | Units | Watch out |
|---|---|---|---|
| NETINC | Net income, YTD | $K | |
| ROA / ROAQ | Return on assets, annualized | % | ~1% is healthy for a community bank. |
| ROE / ROEQ | Return on equity, annualized | % | Can be juiced by running thin capital; read with EQV. |
| INTINC / EINTEXP | Interest income / expense, YTD | $K | EINTEXP rising faster than INTINC = funding-cost squeeze. |
| NIMY / NIMYQ | Net interest margin, annualized | % | The core engine. Brokered/wholesale funding is expensive and eats this. |
| NONII / NONIX | Noninterest income / expense, YTD | $K | One-off gains in NONII can mask a weak margin. |
| ERNASTR | Earning assets / total assets | % | |

Game to watch: securities gains (`IGLSEC`) flow through earnings. A bank selling its winners to book gains while keeping losers at cost is converting balance-sheet quality into reported income.

## L: Liquidity and funding

Whose money funds the bank. Sticky money (local checking accounts) stays; hot money (bought deposits, borrowings) leaves at the first sign of trouble, exactly when the bank needs it most.

| Code | What it is | Units | Watch out |
|---|---|---|---|
| DEP / DEPDOM | Total / domestic deposits | $K | |
| DEPINS / DEPUNINS | Estimated insured / uninsured deposits | $K | Uninsured money runs (SVB). Estimates, self-reported. |
| COREDEP / COREDEPR | Core deposits, $ and % of total | $K / % | Core = local, insured-ish, sticky. The single best funding-quality summary. |
| BRO / BROR | Brokered deposits, $ and % of assets | $K / % | Bought money. Rate-shoppers with zero loyalty; regulators restrict access to it for weak banks, so dependence on it can become a death spiral. BROR's denominator is total assets, not deposits (verified: 862405/4867664 = 17.7, Dacotah 2026 Q1). |
| VOLIAB / VOLIABR | Volatile liabilities, $ and % | $K / % | Large time deposits + fed funds + repos + foreign deposits + other borrowings. |
| NTRTMLGJ | Time deposits > $250K | $K | Above the insurance limit, so hot. |
| OTHBFHLB | FHLB advances | $K | The polite word for "the bank had to borrow." Collateralized, so it quietly encumbers assets. |
| OTHBOR | Other borrowed money | $K | Includes Fed discount-window borrowing, which is not separately disclosed here (confidential for ~2 years). This is the closest public proxy. |
| FREPP | Fed funds purchased + repos | $K | Overnight wholesale funding. |
| LNLSDEPR | Loans / deposits | % | Above ~100% the bank cannot fund its own loan book with deposits. |
| DEPDASTR | Deposits / assets | % | |

Game to watch: total deposits can grow while funding quality collapses. Dacotah is the live example: `DEP` grew 2023 to 2026, but `BRO` went from $0 to $862M and `COREDEPR` fell 84% to 65%. The topline hides the substitution; always split DEP into core vs bought.

## S: Sensitivity and securities marks

Bonds bought before rates rose are worth less now, and accounting rules let the bank choose how visible that is.

| Code | What it is | Units | Watch out |
|---|---|---|---|
| SC | Total securities (carrying value) | $K | AFS at fair value + HTM at amortized cost. Mixed bases by construction. |
| SCAF / SCAA | AFS securities: fair value / amortized cost | $K | `SCAF - SCAA` = AFS unrealized gain(+)/loss(-). Already in EQ via AOCI, usually NOT in regulatory capital (opt-out). |
| SCHA / SCHF | HTM securities: amortized cost / fair value | $K | `SCHF - SCHA` = HTM unrealized gain/loss. In NOTHING: not earnings, not equity, not capital. This is where SVB hid $15B. |
| IGLSEC | Realized securities gains/losses, YTD | $K | Realized only. Selling winners to dress up earnings shows here. |

Derived check for any bank: `(SCAF - SCAA) + (SCHF - SCHA)` vs `EQ`. If total unrealized losses are a large fraction of equity, book capital is fiction. Dacotah Q4 2025: -$25.9M vs $462M equity (~6%, mild; no HTM book at all).

## Identifiers / metadata

| Code | What it is |
|---|---|
| CERT | FDIC certificate number. The join key. |
| NAMEFULL | Legal name. Not unique across time; never join on it. |
| RISDATE / REPDTE | Quarter-end, integer YYYYMMDD. Aliases. |
| STALP | State. |
| BKCLASS | Charter class (N, NM, SB, SM, ...). |
| REGAGNT | Primary regulator (FDIC / OCC / FED). |
| NUMEMP | Full-time-equivalent employees. |

## Failures endpoint (`/banks/failures`)

Verified 2026-07-07, index `failures_1779890467665`. 592 records with `FAILYR >= 2000`; filter `RESTYPE:"FAILURE"` to drop open-bank assistance deals. Key fields: `CERT` (join key), `FAILDATE` (text `M/D/YYYY`, not YYYYMMDD), `QBFASSET`/`QBFDEP`/`COST` ($thousands; COST = estimated loss to the insurance fund), `RESTYPE1` (PA/PI/PO = how it was resolved), `CHCLASS1`, `PSTALP`. Fetch via `R/fetch_failures.R`.

Survivorship gap restated: failed banks often stop filing 1-2 quarters before FAILDATE. The last filing is not the at-failure snapshot; it is rosier than the corpse.
