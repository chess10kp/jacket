# Jacket — Killing GTK: the Wayland-client backend plan

> Plan, 2026-08-21. Executes the spike scoped in `plans/RENDERING.md` §7
> ("minimal CairoAdapter on the reference bar") and extends it into a full
> second backend. The GTK adapter stays working throughout; this is an
> extraction + parallel build, not a rewrite.

---

## 1. Goal

Render jacket shells as a **raw Wayland client** — `zwlr_layer_shell_v1` +
`wl_shm` buffers — with **no Gtk/Gdk/gtk4-layer-shell** in the process, behind
the existing adapter contract (`jacket/adapter_api.jac`). Same Jac `@component`
trees, same reconciler, same tests; a different terminal projection.

**Non-goals (for now)**

- Dropping GLib/Gio entirely (DBus sources and the main loop still use them;
  see §6 for the follow-on track).
- Full CSS, IME/complex text input, or accessibility trees.
- Compositor-integrated rendering (`DrawinAdapter`, RENDERING.md §5B) — later,
  separate track.

## 2. What GTK actually does for us today (the inventory to replace)

Measured against `jacket/adapter.jac` (696 lines) and the reference shell:

| Concern | Today | Size of real usage |
|---|---|---|
| Surfaces | Gtk.Window + gtk4-layer-shell: TOP layer, edge anchors, margins, exclusive zone, keyboard mode, per-monitor pinning | ~8 calls |
| Widget set | Box / Label / Button / Image(icon-name) / SearchEntry / Scale / Popover | 7 tags |
| Layout | GTK box layout: orientation, hexpand, margins, padding via CSS, min sizes | tiny subset |
| Paint | GSK scene graph → GPU; we never draw | n/a — replaced by cairo→shm |
| Text | Pango via Gtk.Label | font-family/size/weight only |
| Styling | One CssProvider, app-level; classes per widget | ~120-line stylesheet: bg/color/padding/border/radius/font/min-*/hover |
| Input | GestureClick, EventControllerMotion, entry text, slider drag, scroll | clicked / pressed / motion / scroll / search-changed / value-changed |
| Monitors | Gdk.Monitor list + items-changed hotplug | 3 calls |
| Main loop | GLib (also drives scheduler flush + all sources) | keep initially |
| IPC transport | GApplication command-line forwarding | keep initially |

The prop surface across `examples/` is ~25 distinct props. This is swaybar
scope, not toolkit scope.

## 3. Architecture

```text
reactive core / builders / For / Show / OSP      (unchanged)
              │  adapter contract (unchanged)
              ▼
   ┌────────────────────────┬──────────────────────────┐
   │ GtkAdapter             │ WlAdapter  (new)         │
   │  jacket/adapter.jac       │  jacket/wl_adapter.jac      │
   └────────────────────────┴──────────────────────────┘
        GLib main loop            pywayland event loop
        GSK → GPU                 cairo image surface → wl_shm
```

Selection at startup: `set_adapter(GtkAdapter())` or `set_adapter(WlAdapter())`
— same swap point the mock adapter already uses. The reference shell's `install`
grows a `--renderer wl|gtk` flag (env `JACKET_RENDERER`), defaulting to gtk
until W-parity lands.

### Backend selection rule

Anything above the seam may not import gi. Audit gate: `grep -rn "gi\|Gtk\|Gdk"
jacket --include="*.jac" -l` must return only `adapter.jac`, `glib.jac`, and the
DBus source modules (which use Gio, not Gtk).

## 4. Technology choices

| Layer | Choice | Why / alternative |
|---|---|---|
| Wayland wire | **pywayland** | ctypes-based client lib with protocol *scanner* — feed it `wlr-layer-shell-unstable-v1.xml` + `xdg-shell.xml` and it generates bindings. No C compile step. Alt: hand-rolled ctypes (rejected: weeks of wire-protocol work). |
| Pixels | **pycairo** image surfaces → `wl_shm` pool, ARGB8888, one buffer queue per surface (≥2 for double-buffering) | CPU rasterization is fine for bar-sized damage; no EGL/GL dependency. Alt: skia-python (heavier, better AA — revisit if text quality suffers). |
| Text | **PangoCairo via gi** in stage W2, then reassess | Pango is the only battle-tested shaper reachable from Python without vendoring C. It keeps a *narrow* gi slice (pangocairo only, no Gtk/Gdk). Escape hatch if we later want zero-gi: freetype-py + uharfbuzz + custom run layout (~2–3 weeks, worse quality initially). |
| Icons | Stage 1: PNG bytes decoded by cairo (`ImageSurface.create_from_png`) + icon-theme path lookup done manually. Tray SVG icons: last holdout — either ship `rsvg` via gi slice or request PNG fallback from StatusNotifierItem first | tray.jac already goes through Gdk.Texture.new_for_pixbuf — that call site moves behind the adapter. |
| Keyboard | **xkbcommon** python bindings for keymap/state; layer-shell keyboard_mode EXCLUSIVE/ON_DEMAND/NONE maps 1:1 | launcher needs full typing incl. modifiers; IME explicitly out of scope. |
| Layout | Own flexbox-lite pass over the ViewNode tree (H/V stacks, expand, margins/padding, min sizes, text measurement from Pango) | clay is the fallback if this grows past ~500 lines (RENDERING.md §4.5). |
| Styling | Parse the existing stylesheet's used subset into resolved node styles: background/color/border/border-radius/padding/margin/font-*/min-width/min-height/:hover | one parser, no cascade beyond class lists; specificity = later-rule-wins + hover override. |
| Event loop | Keep GLib loop; integrate Wayland via an fd source (`GLib.source_new` on the wl display fd) + `wl_display.flush()` on idle | sources/scheduler/IPC keep working unchanged; loop replacement is §6, not here. |

## 5. Milestones

Each milestone ends green: `jac check` clean, full test suite passing, GTK
adapter untouched-and-working.

**W0 — Seam hardening (no new code paths)**
- Move every remaining Gtk/Gdk touch above `adapter.jac` down behind the
  contract (tray.jac's `Gdk.Texture.new_for_pixbuf`, any stray enum refs).
- Add the audit grep from §3 as a test.
- Exit: mock adapter tests unchanged; grep gate passes.

**W1 — wl spike: one bar, one label**
- pywayland + layer-shell scanner XML; connect, bind registry, create ONE
  top-layer anchored surface per output; commit a solid-color shm buffer.
- Prove: bar appears on Hyprland/sway, correct exclusive zone, resize on
  output change.
- Exit: `examples/minimal` clock renders via WlAdapter with live updates
  (damage = full buffer; no text shaping yet — render "88:88" placeholder rects
  if needed).

**W2 — Text + the 7 tags**
- PangoCairo text runs (font desc from style), Label/Box/Button/Icon painted;
  flexbox-lite layout pass; per-widget damage rectangles composited into the
  surface buffer.
- Exit: minimal bar pixel-comparable to GTK version (manual A/B); leaf-patch
  test ported (label text change → damaged region only).

**W3 — Styling subset**
- CSS-subset parser + resolver feeding paint (bg, border, radius, padding,
  fonts, :hover). Stylesheet stays byte-identical (`style.jac` untouched).
- Exit: reference bar's static chrome matches GTK within tolerance.

**W4 — Input** *(implemented; live launcher round-trip pending compositor smoke)*
- Pointer: enter/leave/motion/button → map to `clicked`/`pressed`/hover styles
  via hit-testing the laid-out tree. Scroll → slider/value steps.
- Keyboard: xkbcommon; Entry (SearchEntry semantics: text, placeholder,
  search-changed, stop-search, activate); Slider drag.
- Exit: launcher round-trip (open EXCLUSIVE surface, type, filter, Enter
  launches, Esc closes) driven by real compositor input; headless tests inject
  synthetic events through the adapter contract.
- Status: dispatch core (`hit_test` + `wl_inject_*`) is pure and headless-tested;
  wl_pointer/wl_keyboard handlers route into it. `grab_focus` added to all three
  adapters; launcher_ui routes focus/text through `adapter()`.

**W5 — Popups, monitors, lifecycle** *(implemented; live multi-monitor smoke
pending compositor — environment-blocked)*
- Second surface class for popovers (launcher window, notif toasts): own
  layer-surface, corner anchoring, dismiss-on-click-outside.
- Monitor hotplug: rebuild bars per output (port outputs.jac behavior);
  `set_window_monitor` equivalent.
- Exit: multi-monitor reference shell survives `hyprctl output create/remove`.
- Status: PopoverSurface (overlay layer, exclusive -1, exact size, anchor +
  margins from pure `popover_geometry`, flips when clipped); click-toggle +
  hover show/hide-delay popovers via the adapter contract; press-outside and
  Escape dismiss. Hotplug: wl_output name/done events give connector names,
  registry global_remove destroys that output's surfaces, presented windows
  re-map on change; wl_list_monitors/wl_monitor_key/wl_connect_monitors_changed
  mirror the Gdk trio. set_visible(False) unmaps layer surfaces, True remaps.
  Headless: surface factory hands out DummySurfaces so all state transitions
  are testable without a compositor.

**W6 — Parity + flip** *(implemented; live latency comparison and dist-binary
relink are environment-blocked)*
- Tray icons (PNG-first path), notification action buttons, MPRIS controls —
  sweep every example feature on both adapters.
- Port the 23 test suites' widget-tree probes to a WlProbe headless mode
  (layout tree + op log instead of GTK widget tree).
- Flip default renderer to `wl`; GTK adapter demoted to legacy/fallback.
- Exit: dist binary builds without gtk4/gtk4-layer-shell linkage; cold-start
  and keystroke-latency comparison recorded vs RENDERING.md §7 metrics.
- Status: tray PNG path complete on wl — WlAdapter gained py_make_texture
  (RGBA → premultiplied-BGRA cairo surface, pure/headless) and an Image tag
  that blits it scale-to-fit; _pixmap_to_texture now asks the ACTIVE adapter
  first instead of hardcoding jacket.adapter. Renderer flip via new
  jacket/backend.jac shim (JACKET_RENDERER=auto|wl|gtk; auto = wl whenever
  WAYLAND_DISPLAY + pywayland are usable, else GTK): re-exports install /
  run_with_ipc / css / monitors / restart; bin/jacket grew --renderer; the
  config template imports switched to jacket.backend. Parity sweep of notif
  actions + MPRIS controls: both use tags/props the wl adapter fully supports
  (Button/Slider/label/hidden/child); no gaps found. wl_adapter also gained
  apply_css_file / request_restart / run_with_ipc shims so configs can swap
  imports 1:1. Deviation noted: the "23-suite WlProbe port" was folded into
  the existing headless probes (24 in tests/wl_adapter_tests.jac cover layout,
  paint, input, popovers, hotplug, lifecycle offscreen); per-suite ports
  would duplicate mock-adapter coverage above the seam. Live keystroke
  latency vs RENDERING.md §7 and the gtk4-free dist relink need a compositor
  session — DEFERRED.

## 6. Follow-on track (after W6, optional): zero-gi

Only if the narrow pangocairo slice or GLib itself becomes the next tax:

1. Loop: replace GLib mainloop with asyncio/epoll; scheduler flush hook and
   glib.jac shims are already isolated callables — re-point them.
2. DBus: migrate sources Gio→dbus-next (or sdbus). Sources already degrade to
   no-ops when services are absent, so migration can be per-source.
3. Text: uharfbuzz + freetype-py if Pango was the last gi consumer.
4. IPC: GApplication transport → plain unix socket (ipc.jac already owns the
   protocol).

## 7. Risks & decision gates

| Risk | Mitigation / gate |
|---|---|
| Text quality/shaping regressions vs Pango-in-GTK | W2 uses Pango too — parity by construction. Only §6.3 changes that. |
| Frame pacing: Python-side repaint on CPU | Damage tracking from W2; benchmark harness exists (`benchmarks/`). Gate: launcher keystroke→paint ≤ GTK numbers ±20%. |
| Tray SVG icons without GdkPixbuf | Ask SNI for IconPixmap/PNG path first; rsvg gi slice as fallback; gate at W6. |
| Layer-shell compositor quirks (gtk4-layer-shell papered over these) | W1 targets Hyprland+sway explicitly; quirks list maintained in this doc as found. |
| No cursor image set over Wl surfaces | Needs wl_cursor theme or wp_cursor_shape_v1; compositor default persists for now. Log at W5 if it bites. |
| Window layout gives EVERY visible child the full content area (GTK set_child analogue) → overlapping siblings | Hit-test picks the last sibling containing the point; bars must keep ONE root Box. Enforced by convention, not code. |
| pywayland proxy identity assumed stable across pointer-enter delivery | `_surf_for_wl` falls back to matching wire object ids. |
| xkb keymap fd is consumed by the handler | `_on_kb_keymap` reads + closes the fd exactly once; compositor sends a fresh one per state change. |
| Connector names need wl_output v3+ name event | Bound at min(version, 4); fallback "output-N" until the event arrives. |
| Popovers must not fan out across outputs on hotplug | WlPopupWindow.is_popup skips both map_surfaces fan-out and hotplug remap; popup lives on its anchor's output only. |
| wl_apply_css REPLACES the rule table | apply_css_file loads are whole-stylesheet swaps (same as GTK css provider reload semantics); failed loads keep the previous rules. |
| Scope creep toward "build a toolkit" | Hard rule: features land on GTK adapter first; WlAdapter chases parity, never new widgets. |
| Jac/pywayland interop friction (like the gi OverridesProxyModule bug) | All pywayland objects stay inside `::py::` blocks in wl_adapter.jac; only plain callables cross upward — same discipline as adapter.jac Phase-0 finding. |

## 8. What stays untouched

Reactive core, scheduler, OSP graph, builders/For/Show, all sources, ipc.jac,
config/dev_watch, mock_adapter, packaging (until W6), and every behavioral
test above the seam.
