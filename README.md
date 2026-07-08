# Bank Check

Compare any FDIC-insured bank against its peers and against every US bank
failure since 2000. Quarterly Call Report data, CAMELS-style tabs, and a
failure-trajectory view, all from the public FDIC BankFind Suite API.

Runs entirely in the browser: the app is R (Shiny) compiled to WebAssembly
with shinylive and served as static files. No server, no accounts, no keys.

## Run locally

From the repo root, with R installed:

```r
shiny::runApp("app", port = 7788)
```

## Deploy

Pushes to `main` that touch `app/` rebuild and publish the site to GitHub
Pages via `.github/workflows/deploy.yml`. Repo Settings > Pages must be set
to "GitHub Actions".

## Data

- `app/data/` ships the startup data: the latest all-bank cross-section,
  the institution directory, and pre-failure histories for every post-2000
  failure (rebuildable with `app/build/build_fail_panel.R`).
- Picking a bank fetches its full quarterly history live from
  `api.fdic.gov` (CORS-open, no auth) and caches it for the session.
- All dollar fields are $thousands, per FDIC convention.

Not affiliated with the FDIC. Informational only, not financial advice.
See `app/legal/` for the disclaimer and terms of use.
