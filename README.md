# Bank Check

Compare any FDIC-insured bank against its peers and against every US bank
failure since 2000. Quarterly Call Report data, CAMELS-style tabs, and a
failure-trajectory view, all from the public FDIC BankFind Suite API.

Plain R Shiny, no keys, no accounts.

## Two deployments, same code

- **shinyapps.io** (standard hosted Shiny, loads in seconds):
  https://danielburkhalter.shinyapps.io/bank-check/
- **GitHub Pages** (shinylive, R compiled to WebAssembly running in your
  browser; slow first load while the runtime downloads, then cached):
  https://dan-burk.github.io/bank-check/

If one is down, use the other.

## Run locally

From the repo root, with R installed:

```r
shiny::runApp("app", port = 7788)
```

## Test and deploy

Pushes to `main` that touch `app/` or `DESCRIPTION` run
`.github/workflows/deploy.yml`: the smoke test (`app/tests/smoke.R`)
runs first, and only if it passes do BOTH targets deploy — shinyapps.io
(needs the three SHINYAPPS_* repo secrets described in the workflow) and
the shinylive/Pages build. Pull requests run the test only.

Package versions are pinned: CI installs the direct dependencies listed
in `DESCRIPTION` as prebuilt binaries from a dated Posit Package Manager
snapshot (runner image and R version pinned to match), so the versions
the test validates are the versions that deploy. To upgrade packages,
bump the snapshot date in the workflow and let the gate validate the
new set.

## Data integrity check

The smoke test proves the charts *render*; the integrity test proves
they show the *right numbers*. It samples 10 banks (3 small, 2 medium,
3 large, 2 known-weird ones), recomputes every chart value straight
from the raw FDIC columns with independent arithmetic, and cross-checks
the y-values inside the built plotly traces. Real miscalculations fail
the run; genuinely strange-but-real data (a trust bank with no loans,
net recoveries) prints in a WEIRDNESS REPORT for human review.

It runs locally only (no CI — phase 2 needs the live FDIC API, and the
smoke test stays the sole deploy gate). From the repo root:

```sh
Rscript app/tests/integrity.R
```

Phase 1 runs offline against the shipped cross-section; phase 2 fetches
each roster bank's history from the live FDIC API (cached in
`app/data-cache/`, so reruns are fast) and self-skips politely when the
API is unreachable. Two optional env vars:

- `INTEGRITY_SEED` — every run prints its seed and roster; pass the same
  seed to reproduce the exact roster (default `20260716`).
- `INTEGRITY_SKIP_LIVE=1` — offline phase only, no API calls.

## Data

- `app/data/` ships the startup data: the latest all-bank cross-section,
  the institution directory, and pre-failure histories for every post-2000
  failure (rebuildable with `app/build/build_fail_panel.R`).
- Picking a bank fetches its full quarterly history live from
  `api.fdic.gov` (CORS-open, no auth) and caches it for the session.
- All dollar fields are $thousands, per FDIC convention.

Not affiliated with the FDIC. Informational only, not financial advice.
See `app/legal/` for the disclaimer and terms of use.
