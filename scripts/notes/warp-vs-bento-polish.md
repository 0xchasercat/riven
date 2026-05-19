# Why Warp's terminal feels more polished than Bento's

Investigative writeup for tracker #25.

> "Warp's terminal looks so much better ah, I mean Ghostty is nice but
> it feels like it's lacking smth, but it might js be my zshrc."

It's almost certainly not the zshrc — Bento's PTY pipes the same bytes
into the same Ghostty VT engine that ships in Warp, so the prompt
output is identical. The gap is in the **rendering layer**: how the
glyphs land on screen, how the cell grid is sized, and how the chrome
around the grid is spaced. This is a hypothesis-stack ordered by
expected impact; each item is small enough to land as its own ticket.

## H1 — Line height is too tight (highest impact)

**Symptom**: Bento glyphs look cramped vertically; Warp lines have
visible breathing room.

**Root cause**: `BrokeredTerminalView.recomputeCellMetrics` measures
`cellHeight = ceil(asc + desc + leading)` from CoreText's typographic
bounds. For SF Mono at 13pt that's roughly:
  - asc ≈ 13.0
  - desc ≈ 3.0
  - leading ≈ 0.0
  - cellHeight ≈ 16pt

Warp uses a **line-height multiplier** of ~1.15–1.25 (configurable per
theme), which adds ~3pt of inter-line gutter on the same font size.
Without it, glyphs sit flush against their cell boundaries and the
grid reads as "dense" rather than "comfortable".

**Fix**: add `lineHeightMultiplier: CGFloat = 1.15` to
`BrokeredTerminalView.Configuration`, multiply `cellHeight` by it.
Pin a default to 1.15 — matches Warp's resting setting. Verify the
cursor draw + underline/overline offsets still land correctly (they
all derive from `cellHeight` and `ascent`, so they should scale).

**Ticket size**: small (~20 lines of code, no model change).

## H2 — No horizontal text inset inside the grid

**Symptom**: leftmost glyph touches the left edge of the terminal
pane. Right edge has the same problem.

**Root cause**: `GhosttyRenderer.draw` paints cells at
`CGFloat(col) * cellWidth` starting at x=0. There's no per-frame
horizontal padding.

We _just_ landed `BentoSpacing.m` horizontal padding on the
TerminalPaneView's parent (#22), which fixes this at the *workspace*
level. But the workspace tab content background is also pushed in,
so Warp's "background extends edge-to-edge, glyphs are inset" effect
isn't quite what we have — instead our terminal background gets
clipped by the SwiftUI padding.

**Fix**: revert the SwiftUI padding from #22 and instead bake a
`textInset: CGFloat = 12` into the renderer that shifts the
coordinate space inward. Then `computeGridSize` subtracts 2 × textInset
from the width before dividing. The terminal background stays
edge-to-edge; glyphs get the inset.

**Ticket size**: small (~30 lines).

## H3 — ANSI palette defaults are too vivid

**Symptom**: ANSI red / green / blue land at full saturation; Warp
mutes them slightly so syntax highlighting feels less like a fruit
salad.

**Root cause**: `ThemeSpec`'s `terminal.ansi.*` slots ship pure SGR-
spec defaults — that's what every "default" palette looks like.
Warp ships curated palettes per theme that pull saturation back
~15–25%.

**Fix**: design pass on the four bundled themes (`bento`, `carbon`,
`tokyo`, `paper`) — drop a tuned `terminal.ansi.*` block into each
that knocks saturation down. There's no code change here; pure data.

**Ticket size**: medium (~80 lines of theme JSON, plus visual diffs).

## H4 — Cursor is a solid bar, not animated

**Symptom**: cursor blinks if and only if the shell asked for it
(DECTCEM `\e[?12h`). When it doesn't blink, Warp's cursor still has
a subtle 50%-opacity outline state that reads as "input is here";
ours is a flat solid block.

**Root cause**: `GhosttyRenderer.drawCursor` paints a single rect at
the cursor color. No second pass for "outline only" or "fade".

**Fix**: when the cursor's `blinking` flag is false, draw a 1px
inner outline at the cursor color and fill at 40% alpha. When true,
keep the wall-clock-driven blink from the SGR 5/6 implementation
(#8) but apply it to the cursor as well.

**Ticket size**: small (~40 lines, mostly in `drawCursor`).

## H5 — No font hinting / sub-pixel positioning hint set

**Symptom**: Bento glyphs occasionally land half a pixel off the
baseline depending on window position, reads as "shimmer" during
scroll.

**Root cause**: `CTLineDraw` honors `ctx.shouldAntialias` and
`ctx.allowsFontSubpixelPositioning` from the active graphics
context. We don't set them; they default to whatever NSView's
backing layer picked.

**Fix**: at the top of `GhosttyRenderer.draw`, after `ctx.saveGState`:
  - `ctx.setShouldAntialias(true)`
  - `ctx.setAllowsFontSubpixelPositioning(false)` — Warp's setting,
    keeps each glyph snapped to integer x-coordinates so wide
    runs are pixel-perfect aligned
  - `ctx.setShouldSubpixelPositionFonts(false)`

**Ticket size**: tiny (~5 lines).

## H6 — Block separators are too loud

**Symptom**: the OSC 133 "output → prompt" 1px separator line shows
up between every command block. At default `blockSeparator` alpha of
0.18, it reads as a visible divider rather than a subtle cue.

**Root cause**: `TerminalRenderConfiguration.blockSeparator` defaults
to `defaultForeground.withAlphaComponent(0.18)`. The themes pass a
real `theme.chrome.border` color through, but at the same opacity it
still reads as a hard line.

**Fix**: drop the per-cell alpha to 0.10 and use the theme's
hairline color directly (rather than chrome.border which is denser).
Warp's equivalent is barely visible until you focus the line.

**Ticket size**: tiny (~1 line).

## H7 — No font-weight variants for bold output

**Symptom**: bold glyphs (SGR 1) come through as the same weight as
regular text; only the color brightens.

**Root cause**: `GhosttyRenderer.font(base:bold:italic:)` derives a
bold variant via `NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)`.
SF Mono has only `Regular` and `Bold` faces (no `Heavy`, `Black`),
and the convert call sometimes returns the same regular face when no
bold variant is registered.

**Fix**: explicit lookup: try `NSFont(name: "SF Mono Bold", size:)`
and `NSFont(name: "SFMono-Bold", size:)` first, then fall back to
the trait-convert path. Same for italic — try `SF Mono Italic` /
`SFMono-RegularItalic` explicitly.

**Ticket size**: small (~15 lines in `font(base:bold:italic:)`).

## H8 — Window chrome is opinionated; Warp's blends better

**Symptom**: window edges are sharp. Warp's window background fades
the title bar into the content surface so it reads as one
continuous panel.

**Root cause**: BentoApp sets `window.titlebarAppearsTransparent = true`
and `window.styleMask.insert(.fullSizeContentView)` (correct) but
the `WorkspaceTabBar` background is `chrome.background`, which is
the same color as the title bar — almost. Warp uses a single
elevated surface that bleeds from titlebar → tab strip → tab content,
so there's no visible seam at y=titlebarHeight.

**Fix**: paint the tab bar's background with `chrome.elevated`
(one shade above background) and add a vibrancy effect underneath
that picks up the window's title bar tint. Subtle, but it's what
makes Warp's window "feel like one panel" rather than "tabs in a
window".

**Ticket size**: medium (~30 lines + an NSVisualEffectView wrapper).

## Recommended landing order

1. **H1** (line height) — biggest perceived difference; lowest risk.
2. **H5** (subpixel positioning) — 5-line change, eliminates shimmer.
3. **H4** (cursor outline) — flat cursor is the second-most-noticed
   thing after line height.
4. **H6** (separator opacity) — 1-line tweak.
5. **H7** (bold fonts) — fixes a real correctness issue (bold is
   currently invisible).
6. **H2** (inset bake-in) — needs a model adjustment.
7. **H8** (window vibrancy) — design pass, blocks on theme work.
8. **H3** (ANSI palette tuning) — last, since this is a design
   exercise and other themes are coming anyway (next major slice).

Each item above should become its own follow-up ticket so we can
quantify the visual impact one change at a time.
