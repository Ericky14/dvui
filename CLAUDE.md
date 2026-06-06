# CLAUDE.md

Guidance for Claude Code when working in **dvui** — here it is a *fork*
(`github.com/Ericky14/dvui`) of [david-vanderson/dvui](https://github.com/david-vanderson/dvui),
vendored as the UI foundation for the `zigame` engine and its `dvui-ds` design
system. dvui is an immediate-mode Zig GUI toolkit.

This is a large upstream library — don't re-document it. For depth, read:
- [README.md](README.md) — overview, examples, getting started
- [readme-implementation.md](readme-implementation.md) — how widgets/layout/render work internally
- [readme-accessibility.md](readme-accessibility.md) — AccessKit integration

## This is a customized fork

It diverges from upstream with engine-specific work (see `git log`): text-entry
cursor blinking / placeholder color, all font weights, RGBA8Unorm rendering, a
GPU SDF rounded-rect pipeline, `BoxWidget` gap support, and more. When changing
shared widgets, assume downstream (`dvui-ds`, `src/editor`) depends on current
behavior — check before altering public APIs or visuals.

## Build & test — IMPORTANT

**Do not trust `zig build test` in this directory.** The standalone dvui build
compiles *every* backend (sdl3, sdl3gpu, raylib, web, wio, dx11) and example
target; in this environment several fail for reasons unrelated to your change
(`sdl3gpu.zig` uses `@cImport`, raylib needs system libs, the testing-backend
target references tree-sitter/tinyfd C bindings that aren't generated under
`-Dbackend=testing`).

dvui is actually consumed through the **dvui-ds** package, which compiles the
dvui module with a known-good config (`backend=custom`, `render-backend=wgpu`,
`freetype=true`, `tree-sitter=false`, `tiny-file-dialogs=false`). To compile-check
a change to a dvui widget, build through dvui-ds:

```bash
cd ../..            # vendor/dvui-ds
zig build test      # compiles the dvui module (incl. your widget) + ds tests — verified green
zig build example   # storybook, to see widgets render
```

The whole engine (`zigame` at the repo root) is a third consumer.

## Immediate-mode model (orientation)

- A **widget** is a struct (e.g. `src/widgets/TextEntryWidget.zig`) with
  `init` / `processEvents` / `draw` / `deinit`, run every frame. Identity comes
  from `@src()` + `id_extra`.
- `WidgetData` holds rects/options; `borderAndBackground()` draws the frame.
  `Options` carries styling (colors, padding, border, corner_radius, expand…).
- **Coordinate spaces matter:** logical `Rect` vs `Rect.Physical`. Convert with
  `RectScale` (`rectScale()`, `contentRectScale()`, `borderRectScale()`); scale a
  logical rect to physical with `.scale(rs.s, Rect.Physical)`.
- **Clip stack:** `dvui.clip(rect)` intersects + returns the old clip;
  `dvui.clipSet(rect)` replaces; `dvui.clipGet()` reads. Text/children render
  clipped to the current clip — clipping bugs usually trace to which rect is set
  when. Note a scrollable child's content rect is the *virtual* (full) size, so it
  does not by itself constrain rendering to the visible viewport.
- **Scroll areas** wrap content; the viewport clip and the scrolled content rect
  are different rects — keep them straight when reasoning about what's visible.

## Conventions

- Zig 0.16/0.17-dev. `zig fmt` is the linter.
- Match upstream dvui style (it's a fork): widget-struct files, `///` doc
  comments, explicit `Options`, no hidden allocations.
- Prefer fixing shared behavior here only when it benefits all consumers;
  app-specific styling belongs in `dvui-ds`.
