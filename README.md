# Bank Check

Compare any FDIC-insured bank against its peers and against every US bank
failure since 2000. Quarterly Call Report data, CAMELS-style tabs, and a
failure-trajectory view, all from the public FDIC BankFind Suite API.

Plain R Shiny, no keys, no accounts. The data layer needs only base R
networking, so the same code also runs fully in-browser under
shinylive/webR if ever needed.

## Run locally

From the repo root, with R installed:

```r
shiny::runApp("app", port = 7788)
```

## Deploy

Pushes to `main` that touch `app/` deploy to shinyapps.io via
`.github/workflows/deploy-shinyapps.yml` (needs the three SHINYAPPS_*
repo secrets described in that file). The earlier shinylive/GitHub Pages
pipeline is kept dormant in `deploy.yml` and can be run manually from the
Actions tab; it trades a slow WebAssembly cold start for serverless
hosting.

## Data

- `app/data/` ships the startup data: the latest all-bank cross-section,
  the institution directory, and pre-failure histories for every post-2000
  failure (rebuildable with `app/build/build_fail_panel.R`).
- Picking a bank fetches its full quarterly history live from
  `api.fdic.gov` (CORS-open, no auth) and caches it for the session.
- All dollar fields are $thousands, per FDIC convention.

Not affiliated with the FDIC. Informational only, not financial advice.
See `app/legal/` for the disclaimer and terms of use.
