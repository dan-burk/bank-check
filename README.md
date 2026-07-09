# Bank Check

Compare any FDIC-insured bank against its peers and against every US bank
failure since 2000. Quarterly Call Report data, CAMELS-style tabs, and a
failure-trajectory view, all from the public FDIC BankFind Suite API.

Plain R Shiny, no keys, no accounts.

## Two deployments, same code

- **shinyapps.io** (standard hosted Shiny, loads in seconds):
  link added after first deploy
- **GitHub Pages** (shinylive, R compiled to WebAssembly running in your
  browser; slow first load while the runtime downloads, then cached):
  https://dan-burk.github.io/bank-check/

If one is down, use the other.

## Run locally

From the repo root, with R installed:

```r
shiny::runApp("app", port = 7788)
```

## Deploy

Pushes to `main` that touch `app/` deploy BOTH targets:
`.github/workflows/deploy-shinyapps.yml` (needs the three SHINYAPPS_*
repo secrets described in that file) and `.github/workflows/deploy.yml`
(the shinylive/Pages build).

## Data

- `app/data/` ships the startup data: the latest all-bank cross-section,
  the institution directory, and pre-failure histories for every post-2000
  failure (rebuildable with `app/build/build_fail_panel.R`).
- Picking a bank fetches its full quarterly history live from
  `api.fdic.gov` (CORS-open, no auth) and caches it for the session.
- All dollar fields are $thousands, per FDIC convention.

Not affiliated with the FDIC. Informational only, not financial advice.
See `app/legal/` for the disclaimer and terms of use.
