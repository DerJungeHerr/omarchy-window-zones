# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Window Zones is an Omarchy shell plugin (Omarchy 4.5+) that adds Windows-style snapping (edges, corners, a layout panel, fans of shared zones, peek) to floating workspaces. No build step: QML and Lua are loaded as-is.

## Commands

```sh
lua test/window-zones.test.lua   # pure geometry, hit tests, JSON — no Hyprland needed
lua test/runtime.test.lua        # compositor-side lifecycle against a fake `hl` (timers, errors, sleep, monitor loss)
test/e2e/run.sh [workspace]      # real drags on the live session via a virtual pointer
test/e2e/demo.sh <mon> <ws>      # re-records demo.gif (README) with neutral terminals, dock cropped
```

- Never run `run.sh` or `demo.sh` unless the user says the desktop is free: both take over the mouse.

- CI (`.github/workflows/test.yml`) runs only the two unit tests with `lua5.4`. There is no test runner: each test file is a plain script of `assert`s; run one file to run its tests.
- e2e takes over the mouse for ~1 min on the focused monitor. The workspace must be empty, floating, and inside the focused monitor's block of ten (default: slot 9). Needs `foot`, `jq`, `lua`, `cc`, Wayland client headers. Expected geometry comes from the plugin's own functions via `test/e2e/expect.lua`.
- Local dev: link the checkout into `~/.config/omarchy/plugins/io.github.derjungeherr.window-zones`, enable it, and `omarchy restart shell` after adding files.

## Architecture

Three pieces, declared in `manifest.json` (kinds `service` + `bar-widget`):

- **`hypr/window-zones.lua`** — all logic. Runs *inside Hyprland's Lua* (loaded via `hyprctl eval ... dofile(...)`). Never call `hyprctl` from it. Hyprland has no drag events, so drags are detected by polling: an idle timer (50 ms) checks whether the active floating window moves in lockstep with the cursor; a drag timer (16 ms) tracks it. A release with a still cursor is detected by nudging the cursor 1 px (a held window follows, a dropped one doesn't).
  - The file has two halves split by `if not hl then return M end`: above it is pure geometry (`M.area`, `M.cell`, `M.panel`, `M.panel_hit`, `M.fan`, `M.edge_hit`, `M.json`, ...) used by the unit tests and e2e `expect.lua`; below it is the runtime that needs `hl`.
  - Reloads: every settings change re-`dofile`s into the same Lua state; the new load stops the previous `window_zones` and inherits `snapped` state. Timers can't be removed, so exactly two live in the global `window_zones_timers` and delegate to the current `window_zones`. A Hyprland config reload starts a fresh Lua state; `snapped` survives it via `$XDG_RUNTIME_DIR/window-zones-snapped.lua`, written on every change and read back (as data, empty env) only when there is no previous load.
  - Every callback into Hyprland goes through `safe()`: the first error stops the plugin, logs once to `$XDG_RUNTIME_DIR/window-zones-error.log`, notifies once.
  - Talks to the overlay by spawning `omarchy-shell -q window-zones show <gen> <seq> <json>`; `gen` identifies the loading service instance, `seq` lets the overlay drop out-of-order calls.
- **`Service.qml`** — loads the Lua (on start, on `configreloaded`, on dock/settings change) passing globals `window_zones_gen`, `window_zones_dock`, `window_zones_settings`, and draws the preview/panel overlay from IPC (`IpcHandler` target `window-zones`). It decides nothing itself; the Lua sends monitor-local geometry. Because settings and paths are spliced into Lua source, only booleans/finite numbers with `[A-Za-z]+` keys pass (plus `layouts`, rebuilt by `layoutsLua()` from numbers and booleans only), and the Lua path must match a safe regex — keep these guards.
- **Layouts:** `M.layouts(custom)` builds `M.LAYOUTS` = built-ins, up to 3 custom layouts (`{cols = {percent...}, split = {bool...}}` → `M.custom_cells`), scratchpad last. Edge/corner snapping refers to built-ins by index (`1` = Halves, `M.QUARTERS`), so custom ones must never go before them. e2e reads the live layouts via `test/e2e/plugin-env.sh`, so panel positions match whatever the user configured.
- **`BarWidget.qml`** — bar icon + settings popup (scrolls when taller than the screen). Settings are stored on the widget's entry in `~/.config/omarchy/shell.json` (`bar.layout.<section>[].id == manifest id`); `Service.qml` watches that file and reloads the Lua. Numeric ranges are clamped again in Lua (`within(...)`), since shell.json can be hand-edited.

Scope: only windows tagged `omarchy-floating-workspace`; pinned, fullscreen and grouped windows are ignored. The plugin adds no key bindings and writes no config files.

## Conventions

- Releases bump `version` in `manifest.json` (`chore: release x.y.z`).
- Comments explain *why* in plain prose; keep that style.
