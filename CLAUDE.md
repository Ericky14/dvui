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

Three divergences that change what a frame looks like or says (2026-09-24):

- **The layout keeps `snap_to_pixels`.** Min sizes are rounded UP to whole
  physical pixels (`WidgetData.minSizeSetAndRefresh`) and every laid-out
  widget's border rect is rounded half-up to whole physical pixels at
  `register` (`WidgetData.snappedRect`; subwindows and the root excluded). A
  fraction from a font's line box, a gravity or a 5 px inset at 175 % stops at
  the first widget. Turn `snap_to_pixels` off for sub-pixel motion.
  Tests: "under snap_to_pixels a laid-out widget's border lands on whole
  physical pixels", "without snap_to_pixels the layout keeps its fractions".
- **`SdfRect` is a CSS box; `Rect.stroke` is a centre line.** The SDF border is
  the band from the rect's edge inward (`wgpu_sdf_rect.wgsl`); `Rect.stroke`
  grows its path by half the thickness before using the SDF pipeline, and the
  CPU fallback (`Backend.drawSdfRectFallback`) strokes half a border inside the
  edge, so the testing backend draws the pixels wgpu does. Tests in
  `src/render.zig` ("an SDF rect's border runs inward…", "a rounded stroke is
  centred on its path…").
- **The frame capture records the margin rect and the text.**
  `Debug.CapturedWidget.rect_margin` (what the parent gave, margin included) and
  `.label` (a label's string, a text layout's runs, or `Options.label.text`,
  capped at `label_capture_max` bytes), both in `dumpFrame`/`dumpDiff`. Test:
  "a captured widget carries its margin rect and the text it shows".

## Build & test

**Compiler: Zig master only.** `build.zig` targets the 2026-05 configurer/maker
build system (`addPassthruArgs`, `std.builtin.Optimize`, make-time install
paths) and `build.zig.zon` pins `minimum_zig_version` to the dev build it was
ported with (`0.17.0-dev.1963`). Upstream dvui still targets Zig 0.16, so its
`build.zig` is not a drop-in on the next re-merge.

**Always pin a backend.** `zig build` / `zig build test` without `-Dbackend` is
refused on purpose: several upstream dependencies (SDL2, opengl, raylib, ...)
ship `build.zig` files that do not compile on master, and Zig compiles the build
script of *every fetched* lazy dependency into every later configure — one
all-backends run would break even `-Dbackend=testing` until those tarballs are
deleted from the global cache (`%LOCALAPPDATA%\zig\p\`) and from `zig-pkg/`.
`zig build --help` is safe (it fetches nothing).

`svg2tvg` and its `zig-xml` dependency are vendored under `vendor/` as path
dependencies with one-line `@splat` patches (`**` array repetition was removed
from the language); re-point `build.zig.zon` at upstream once they build on
master. On Windows with `core.autocrlf=true` a fresh checkout is CRLF and
`zig fmt --check` flags every file — run `zig fmt build.zig src/` once.

Two reliable ways to test:

```bash
# Headless logic + screenshot tests (CPU, no GPU/window). Fast and green.
zig build test -Dbackend=testing
zig build test -Dbackend=testing -Dtest-filter="<name>"

# Compile-check a widget against the real config the engine uses, via dvui-ds:
cd ../.. && zig build test      # dvui module + ds tests — verified green
cd ../.. && zig build example   # storybook, to see widgets render on the GPU
```

The whole engine (`zigame` at the repo root) is a third consumer.

## Headless screenshot / visual tests

The **testing backend rasterizes on the CPU** (`src/backends/testing.zig`), so
`dvui.testing` can produce real PNGs with no GPU or window — deterministic and
CI-friendly. Screen draws stay no-op (logic tests stay fast); only rendering into
a render *target* (which `Picture`/`capturePng`/`saveImage`/snapshot images use)
rasterizes.

```zig
test "my widget renders" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 200, .h = 80 } });
    defer t.deinit();
    const Local = struct {
        fn frame() !dvui.App.Result {
            _ = dvui.button(@src(), "Save", .{}, .{ .corner_radius = dvui.Rect.all(6) });
            return .ok;
        }
    };
    try dvui.testing.settle(Local.frame);
    try t.saveImage(Local.frame, null, "save_button.png"); // writes when -Dimage-dir is set
}
```

```bash
zig build test -Dbackend=testing -Dimage-dir=/tmp/shots -Dtest-filter="my widget renders"
```

`saveImage` is a no-op unless `-Dimage-dir` is given, so these tests stay cheap in
normal runs. See the example tests at the bottom of `src/backends/testing.zig`.

**Gotcha:** render components at a real size. `renderText` early-returns when its
clipped rect is empty, so a widget given `min_size_content = .{ .w = N }` (height
defaults to 0!) collapses its content area and its text won't appear. Pass a
height (or let the font set it) — e.g. `.{ .w = 150, .h = 18 }`. Labels, buttons,
panels, icons, scrolled content, and text entries all capture correctly when sized.

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

- Zig master (0.17-dev). `zig fmt` is the linter; it also applies builtin renames
  such as `@intFromEnum` -> `@backingInt`.
- Match upstream dvui style (it's a fork): widget-struct files, `///` doc
  comments, explicit `Options`, no hidden allocations.
- Prefer fixing shared behavior here only when it benefits all consumers;
  app-specific styling belongs in `dvui-ds`.
