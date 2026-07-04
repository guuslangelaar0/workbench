
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
