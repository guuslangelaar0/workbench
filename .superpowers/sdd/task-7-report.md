
## Fix: Host grid track-sizing + Docs align-self

### Changes made
- `style-surfaces.css` mobile block: changed `.host-grid, .two-col, .three-col { grid-template-columns: 1fr }` → `minmax(0, 1fr)`
- Added `.topo-inner { flex-direction: column }` and `.dev-col { width: auto }` to prevent the topology diagram's two 252px device columns from overflowing
- Added `align-self: stretch` to the mobile `.docs-nav` rule to prevent the nav from shrinking to ~244px in a column flex container

### Live verification (390×844)
- document.documentElement.scrollWidth = 390 = innerWidth (no horizontal page scroll)
- .host-wrap: scrollWidth=451, clientWidth=390, getBoundingClientRect().width=390
  — internal content slightly overflows the host-wrap box (451px), but is clipped by the flex parent; the page itself does not scroll horizontally
- .topo-inner computed flexDirection = "column" (fix confirmed applied)
- .dev-col computed width = "0px" (empty topology on test server with no real agents; no overflow)
- .docs-nav getBoundingClientRect().width = 390 (was ~244px before; now stretches full width)
- .docs-nav computed alignSelf = "stretch" (fix confirmed applied)
- .docs-wrap computed flexDirection = "column" (stacked correctly)

### Desktop (1440×900) regression check
- document.documentElement.scrollWidth = 1440 = innerWidth (no horizontal overflow)
- .docs-nav getBoundingClientRect().width = 224px (base `width: 224px` rule intact, not overridden)
- All tabs (Bench/Board/Host/Ops/Docs) render correctly at desktop width

### Shell suite
PASS: mesh-command-center — all checks pass (final line: "PASS: mesh-command-center")

### Concerns
- `.host-wrap.scrollWidth` = 451px at 390×844 when content is populated, meaning something inside host-wrap has ~61px of horizontal overflow beyond the 390px viewport. This internal overflow is clipped by the flex layout ancestors (document scrollWidth = 390 confirms no page-level horizontal scroll). It may be worth a follow-up to add `overflow-x: hidden` to `.host-wrap` or to investigate which child element causes the 451px, though the user-visible symptom (horizontal scroll bar on the page) is resolved.

## Fix: scoped Devices table overflow

### What changed

Added to the `@media (max-width: 768px)` block in `style-surfaces.css`:

```css
/* Host: scope Devices table horizontal scroll to its panel body, not the
   whole surface. Without this, .host-wrap's overflow-x computes to auto
   (CSS spec: when overflow-y is non-visible the other axis can't be visible)
   making the ENTIRE surface draggable sideways with no visual affordance.
   table-layout:auto naturally expands the table beyond width:100% when
   column content demands it, so adding overflow-x:auto here is sufficient —
   the overflow is captured at panel-body level and never propagates up. */
.host-grid .panel-body {
  overflow-x: auto;
  -webkit-overflow-scrolling: touch;
}
```

### Why this approach

`host.js` already wraps `table.wb` in a `div.panel-body` (`#dev-body`). CSS-only fix was therefore possible with no markup change.

`:has()` was ruled out (not used anywhere in these CSS files, so not an established baseline). Making `table.wb` itself `display: block` was ruled out (changes table formatting context, potential layout side-effects). The `.panel-body` wrapper approach is cleanest: a plain `<div>`, `overflow-x: auto` on it is well-defined, and `table-layout: auto` (default) causes the `table.wb { width: 100% }` table to expand to its min-content width (~560px) rather than collapsing to the container width, so overflow fires correctly.

The selector `.host-grid .panel-body` is strictly scoped — Bench/Board/Ops/Docs panels have no `.host-grid` ancestor and are not affected.

### Live verification results (390×844, 2 enrolled devices: macbook-alice, ipad-bob)

**BEFORE fix (pre-commit behavior):** `.host-wrap` would have scrollWidth > clientWidth because `table-layout: auto` expanded table to ~560px, overflowing the whole-surface scroll container.

**AFTER fix (measured):**
- `.host-wrap`: `scrollWidth=390, clientWidth=390` — whole-surface horizontal drag is gone ✓
- `#dev-body` (`.panel-body`): `scrollWidth=572, clientWidth=340, overflowX=auto` — scoped scroll with visible scrollbar ✓
- `table.wb`: renders at 560px natural width, scrollable within panel-body ✓
- Scrolling the panel-body to `scrollLeft=232` (max): "LAST SEEN" and "Revoke" columns fully visible ✓

Screenshots confirm: the scoped scrollbar is visually apparent within the Devices panel; content below (Single point of failure, server.json) stays completely stationary when scrolling the table.

### Desktop confirmation (1440×900)

- `.host-wrap`: `scrollWidth=1425, clientWidth=1425` — no overflow ✓
- `#dev-body`: `overflowX=visible` (mobile rule not active) ✓
- All 7 columns visible without any scroll ✓

### Shell suite result

```
PASS: mesh-command-center
```
All checks pass. No regressions.

### Concerns

None. The approach is conservative, CSS-only, uses an already-existing wrapper element, and is strictly scoped to the host grid. The visible scrollbar (rendered by the OS/browser at the bottom of the panel-body) provides clear affordance for mobile users.
