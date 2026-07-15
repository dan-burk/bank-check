---
name: verify
description: Build/launch/drive recipe for verifying Bank Check app changes end-to-end from WSL
---

# Verifying the Bank Check app (WSL + Windows R)

## Launch

R lives on the Windows side only (no WSL R). From the repo root:

```bash
"/mnt/c/Program Files/R-aarch64/R-4.4.3/bin/Rscript.exe" -e "shiny::runApp('app', port = 7788, host = '0.0.0.0')"
```

- Use **R-4.4.3**, not 4.5.1 (4.5.1 has no packages installed).
- `host = '0.0.0.0'` is required: the default 127.0.0.1 binds to Windows
  loopback, unreachable from WSL2.
- Reach it from WSL at the gateway IP: `http://$(ip route show default | awk '{print $3}'):7788`
  (plain `localhost` and `<hostname>.local` both fail — NAT networking, not mirrored).
- Startup takes ~10s (loads rds panels + peer stats).

## Drive

Playwright (chromium already installed) lives in the npx cache, importable via:

```js
import { createRequire } from 'module';
const require = createRequire('/home/daniel/.npm/_npx/e41f203b7505f1fb/node_modules/');
const { chromium } = require('playwright');
```

If that hash is gone, re-find it: `for d in ~/.npm/_npx/*/node_modules; do ls "$d" | grep -x playwright && echo "$d"; done`

Gotchas:
- The DT column filters (directory modal, `filter = "top"`) show a visible
  `input.form-control` placeholder "All"; the selectize widget behind it is
  hidden until that input is clicked. Click the form-control, then type.
- Wait for bank loads via the fetch overlay:
  `page.waitForFunction(() => getComputedStyle(document.getElementById('fetch_overlay')).display === 'none')`
- Bank fetches write to `app/data-cache/` (gitignored) — harmless.

## Smoke test (CI parity, not a substitute for driving)

```bash
"/mnt/c/Program Files/R-aarch64/R-4.4.3/bin/Rscript.exe" app/tests/smoke.R
```

Note: `testServer` blocks in smoke.R cannot see app.R globals (only the
smoke script's own variables plus outputs/reactives).
