# jacket

A **library for building Wayland desktop shells in Jac** — reactive engine, OSP
graph, declarative builders, GTK4 adapter, and optional service sources. See
**[LIBRARY.md](LIBRARY.md)** for the public API contract.

The full reference bar (multi-monitor, launcher, notifications, tray) lives in
`examples/reference/` — one consumer of the library, not the product. For a
minimal starting point, see `examples/minimal/main.jac` or LIBRARY.md §2.

## Status

| Phase | What | State |
|---|---|---|
| 0 | Spike: PyGObject + gtk4-layer-shell from Jac; Jac OSP/dunder spelling | ✅ done |
| 1 | Reactive core + tri-state scheduler (GTK-free unit tests) | ✅ done — 11 tests |
| 2 | Mock adapter + builders + `For`/`Show` (headless reconciler tests) | ✅ done — 12 tests |
| 3 | Real GTK adapter; live clock leaf-patch proven | ✅ done |
| 4 | Sources (Hyprland/sway IPC, UPower battery, audio) | ✅ done |
| 5 | Real widgets (notifications, MPRIS, tray, launcher) | ✅ done |
| 6 | Multi-monitor bars + StatusNotifier tray + packaging | ✅ done |

Phases 0–5 are complete and proven: all modules pass `jac check`, **69 tests
pass**, and the reactive→adapter→GTK path was verified against the live Wayland
session — the leaf-patch (a `Gtk.Label` over 5 ticks), the per-monitor bar build
(one bar per connected output, keyed by connector), and the full tray row
lifecycle (register → in-place `NewIcon` update → unregister) via widget-tree
probes. Sources that need live services (Hyprland/sway socket, UPower,
PulseAudio, the session bus for tray/notifications/MPRIS) degrade to quiet no-ops
when the service is absent, so the shell always comes up.

## Architecture (one-directional data flow)

```
sources (DBus/Gio, Hypr IPC, sysfs) ──writes──▶ Signals
                                                 │  mark-stale (push)
                                                 ▼
                                       Scheduler (flush on GLib.idle)
                                                 │  lazy pull, dep-order
                                                 ▼
                   Effects (one per reactive prop) + For (keyed diff)
                                                 │  set_prop / insert / move
                                                 ▼
                                   Adapter (the PyGObject seam)
                                                 │
                                                 ▼
                                           GTK4 widgets
```

**The OSP boundary (load-bearing):** the structural widget tree is an OSP graph
(`node ViewNode` + typed ordered `edge Child`); build/mount/dispose/query are
**walkers**. The reactive dep graph (signal↔effect links) is deliberately
**plain `obj`s, NOT OSP** — it churns every tick and the hot path stays O(1).

## Files

| File | Owns |
|---|---|
| `src/reactive.jac` | signal/derived/effect + tri-state scheduler (merged core+scheduler) |
| `src/osp.jac` | `node ViewNode`, typed `edge Child`, `Dispose`/`Collect` walkers |
| `src/adapter_api.jac` | swappable adapter handle (holder-obj + `adapter()` accessor) |
| `src/adapter.jac` | the PyGObject seam (`::py::` gi shim + the adapter contract) |
| `src/mock_adapter.jac` | recording adapter for headless reconciler tests |
| `src/builders.jac` | Box/Label/Button/Icon/Window, prop rule, `For`, `Show`, `@component` |
| `src/glib.jac` | GLib main-loop helpers (idle/timeout/run_for) |
| `src/sources.jac` | plain imperative sources feeding Signals (clock ticker) |
| `src/hyprland.jac` / `src/sway.jac` / `src/wm.jac` | workspace sources + per-compositor selector |
| `src/battery.jac` / `src/audio.jac` / `src/mpris.jac` | UPower / PulseAudio / MPRIS sources |
| `src/notifications.jac` | `org.freedesktop.Notifications` daemon (we own the name) |
| `src/tray.jac` | StatusNotifier tray: watcher server + host + item proxies |
| `src/launcher.jac` | `.desktop` scan + fuzzy app launcher source |
| `src/ipc.jac` | AGS-style IPC handler registry (`status` / `list` / named getters) |
| `examples/reference/` | full bar shell: `main.jac`, `components.jac`, popups, `style.jac` |
| `examples/swaybar/` | scroll/sway status-bar clone with IPC (`./run.sh examples/swaybar/main.jac`) |
| `examples/minimal/main.jac` | minimal bootstrap (LIBRARY.md §2) |
| `examples/reference/query_demo.jac` | demo: spawn walkers over your own ViewNode tree |
| `tests/reactive_tests.jac` | scheduler correctness (diamond, cutoff, disposal, loop) |
| `tests/builders_tests.jac` | prop classification, `For` keyed diff, disposal/leak |
| `tests/sources_tests.jac` | pure source parsers/reducers + tray icon-pixmap decode |
| `tests/adapter_tests.jac` | construct-only classifier (the one bit of pure adapter policy) |
| `tests/components_tests.jac` / `tests/ui_helpers_tests.jac` | the pure per-row widget helpers |
| `tests/osp_walker_tests.jac` | query/`Restyle` walkers over a held ViewNode tree (mock adapter) |
| `packaging/` | `jacket.service` (systemd --user) + `install.sh` (gi bootstrap + unit) |

## Run

```bash
./run.sh                                    # full reference bar (default)
./run.sh examples/minimal/main.jac          # minimal bootstrap
jac test tests/reactive_tests.jac tests/builders_tests.jac tests/sources_tests.jac \
         tests/adapter_tests.jac tests/components_tests.jac tests/ui_helpers_tests.jac \
         tests/osp_walker_tests.jac tests/ipc_tests.jac   # 69 tests
```

**Multi-monitor:** `examples/reference/main.jac` enumerates `Gdk.Display` monitors at activate and
pins a `Bar` to each (`Gtk4LayerShell.set_monitor`), keyed by connector name.
Monitor hotplug (`items-changed`) presents a bar for a new output and disposes
the bar of a removed one — no restart.

**System tray:** `tray.jac` plays both StatusNotifier roles — it serves
`org.kde.StatusNotifierWatcher` when no other shell owns it (bare wlroots), and
always runs as a *host*, so it works whether the watcher is ours or a
pre-existing waybar/plasma one. Icons resolve by themed `IconName`, falling back
to decoding the raw `IconPixmap` (ARGB→RGBA→`Gdk.Texture`). Left-click sends
`Activate`; right-click fetches the item's `com.canonical.dbusmenu` layout
(`GetLayout` → pure `parse_menu_layout` → a `Gio.Menu` model in a `PopoverMenu`)
and fires `Event(id, "clicked", …)` on selection. *(The popover's live
anchoring/teardown on a layer-shell surface still needs a session check; the
parse layer + Event plumbing are headless-tested.)*

**Walkers over your own UI (the OSP payoff):** a `@component` runs once and hands
back a real, walkable `ViewNode` graph. An author who HOLDS it can spawn OSP
walkers over their OWN subtree for cross-cutting ops — `query_by_class(ui, cls)`
reuses the `Collect` machinery; `flash_class(ui, target, flash)` / the `Restyle`
walker add/remove a CSS class across every match (and push it live through the
adapter). No framework re-render, no parallel tree. See `examples/reference/query_demo.jac`.

**Performance (profiled, `PROFILE.md`):** the `For` keyed diff holds at 0–1 moves
for every shell-shaped edit (append/prepend/remove) flat from N=100→1000; O(N)
shuffle "thrash" exists only under synthetic full-list reversal, which no real
`For` site does. All three PLAN §8 perf items (LIS min-move, list virtualization,
`__slots__` tuning) profiled as **not warranted** — gates unmet, kept deferred.

**Install (systemd + gi bootstrap):**

```bash
./packaging/install.sh                      # drops system_site.pth + the user unit
systemctl --user enable --now jacket.service
```

**Prerequisite (one-time):** Jac ships a bundled Python that can't see the system
`gi` (PyGObject). `install.sh` handles this by writing a `system_site.pth` into
Jac's runtime site-packages — **re-run it after any Jac upgrade**, which mints a
fresh runtime dir. To do it by hand instead:

```bash
python3 -c 'import gi,os;print(os.path.dirname(os.path.dirname(gi.__file__)))' \
  | tee ~/.cache/jac/rt/*/python/lib/python*/site-packages/system_site.pth
```

If gtk4-layer-shell warns about link order, set
`LD_PRELOAD=/path/to/libgtk4-layer-shell.so` so the layer surface anchors.

## Key Jac gotchas learned (see commit history / memory)

- Lambdas are braced: `lambda (v: any) { v + 1; }` (multi-stmt tail needs no `;`).
- Loop capture is late-binding — use `lambda (i: int = i) {...}` or a factory.
- `node`/`root`/`init` are special/reserved; `obj` `has` fields need defaults in
  order; `any > any` is a type error (route comparisons through a `::py::` helper).
- gi's `OverridesProxyModule` breaks under Jac attribute access — bootstrap gi in
  `::py::`, expose plain callables; widget **instances** are usable directly.
