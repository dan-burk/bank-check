# Back-to-home button mockup: Bank Check

A "← Home" button that takes people from Bank Check back to the portfolio at danielburkhalter.dev.

**Live mockup (private Claude artifact):** https://claude.ai/artifact/R5R3SJEbuUwrEsUq8pAots

## Status

Mocked up on November 11, 2026. **Not implemented.** We decided not to ship it for now; this folder keeps the mockup so it can be picked up later.

## What we decided

- **Label:** "← Home" (arrow icon plus the word Home).
- **Goes to:** https://danielburkhalter.dev/ in the **same tab**. The portfolio already opens every app in a new tab, so the portfolio stays open in the earlier tab; ending up with two portfolio tabs is fine.
- **Desktop:** pinned **32px from the left edge of the window**, level with the app's top row, so it sits clearly apart from the content.
- **Phone:** no margin to use, so it changes shape (see below).
- **Look:** 32px tall, using the app's own font and button colors so it reads as part of the app.
- **Scope:** Bank Check, CDL Prep, US Coin Value, Stocks vs. Metals (investing), Math Scribe and SD XC. Not Agent Sessions (claude-gui demo) and not Dairy Translate.

## Files

- `index.html`: the mockup. Open it in a browser. It's self-contained: real screenshots of the live app (taken November 11, 2026) with a working button placed on top, shown at desktop size, at actual size, and on a 390px phone.

## Placement in Bank Check

The blue navbar runs edge to edge and is full of tabs, so the margin approach used by the other apps doesn't fit. The mockup has a toggle between two options:

1. **In the blue bar (recommended).** "← Home" at the far left of the navbar, 16px from the window edge, with a faint white outline; "Bank Check" and the tabs move about 100px right. On a phone it's just the arrow in front of "Bank Check", and the menu button stays on the right. It's visible on every tab, even with the sidebar collapsed, and works the same way as CDL Prep and SD XC.
2. **Top of the sidebar.** In the empty strip across from the ‹ collapse arrow, lined up with "Find a bank". The navbar isn't touched, but the button disappears when the sidebar is collapsed, and on a phone it ends up partway down the screen.

No final pick was made between the two.

## How to build it

In `app/app.R` (`page_navbar(title = "Bank Check", ...)`).

**Important:** on danielburkhalter.dev the app runs inside an iframe (`pages/loading.html` → shinyapps.io), so the link needs `target = "_top"`. Otherwise the portfolio would load inside the frame.

Option 1, in the navbar:

```r
home_link <- tags$a(
  href = "https://danielburkhalter.dev/", target = "_top",
  class = "home-link", `aria-label` = "Back to danielburkhalter.dev",
  HTML('<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M19 12H5"/><path d="m12 19-7-7 7-7"/></svg>'),
  tags$span(class = "home-label", "Home")
)

ui <- page_navbar(
  title = tagList(home_link, "Bank Check"),
  ...
)
```

```css
.home-link {
  display: inline-flex; align-items: center; gap: 6px;
  height: 32px; padding: 0 12px 0 9px; margin-right: 16px;
  border: 1px solid rgba(255,255,255,.28); border-radius: 6px;
  background: rgba(255,255,255,.10); color: rgba(255,255,255,.82);
  font-size: 14px; font-weight: 500; text-decoration: none; vertical-align: middle;
}
.home-link:hover { background: rgba(255,255,255,.20); color: #fff; }
@media (max-width: 575.98px) {
  .home-link { width: 32px; padding: 0; justify-content: center; margin-right: 10px; }
  .home-link .home-label { display: none; }
}
```

Check how bslib renders `title`. If it ends up inside a `navbar-brand` link, nesting an `<a>` there is invalid HTML; in that case, put the link in as a sibling before `.navbar-brand` (for example with a small script in `header`).

Option 2, sidebar: add `home_link` (styled with `color: #2c5f8a; background: #f1f5f9; border-color: transparent`) as the first element of `sidebar(...)`.
