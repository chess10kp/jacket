# jacket — Library API

jacket is a **library for building Wayland desktop shells in Jac**. Authors
compose `@component` trees with fine-grained reactivity; the runtime reconciles
once and patches leaves. The reference bar in `examples/reference/main.jac` is
**one consumer** of this library — not the product.

```
┌─────────────────────────────────────────────────────────────┐
│  YOUR SHELL (your main.jac + your @components)              │
├─────────────────────────────────────────────────────────────┤
│  PUBLIC LIBRARY                                             │
│    builders   — Box/Label/For/Show/@component               │
│    reactive   — signal/computed/effect/when/fmt             │
│    animation  — animated/follow/enter_tween/ease            │
│    transition — popup_transition enter/exit + delayed hide  │
│    osp        — ViewNode, walkers, query_by_class           │
│    adapter    — install/run/apply_css/monitor helpers       │
│    sources    — ticker + optional get_*() service modules   │
├─────────────────────────────────────────────────────────────┤
│  INTERNAL (import only if extending the runtime)            │
│    adapter_api — set_adapter/adapter() slot                 │
│    glib        — test/main-loop helpers                     │
│    mock_adapter — headless test harness                     │
└─────────────────────────────────────────────────────────────┘
```

---

## 1. What authors own vs what the library owns

| You write | Library provides |
|---|---|
| `@component` functions returning `ViewNode` | Builders, prop classification, disposal |
| Which roots to present (bars, popups) | GTK adapter, layer-shell wiring |
| CSS in your own stylesheet string | `apply_css()` loader |
| Optional: custom sources feeding `Signal`s | `signal`, scheduler, `For` keyed diff |
| Optional: walkers over your held `ViewNode` | `query_by_class`, `flash_class`, `Restyle` |

**Not library scope:** a fixed bar layout. Files under `examples/reference/`
(`components.jac`, `launcher_ui.jac`, `notif_ui.jac`, `style.jac`, `main.jac`)
and `examples/reference/query_demo.jac` are **reference implementations** —
copy patterns from them, do not treat them as the public contract.

---

## 2. Minimal bootstrap

Every shell app follows this shape:

```jac
import from src.adapter { install, run_dynamic, apply_css }
import from src.glib { idle_add }
import from src.reactive { set_flush_hook }
import from src.builders { component, Window, Box, Label }

glob MY_CSS: str = """
window { background: #1e1e2e; }
""";

@component
def MyBar() -> ViewNode {
    return Window(
        layer="top",
        anchor="top",
        height=32,
        child=Box(orientation="H", children=[
            Label(class="clock", text="hello"),
        ]),
    );
}

def on_activate(app: any) {
    bar = MyBar();
    bar.widget.present();
}

with entry {
    install();                                          # gtk init + GtkAdapter
    apply_css(MY_CSS);
    set_flush_hook(lambda (f: any) { idle_add(f); });   # one flush per idle tick
    run_dynamic(on_activate, "org.example.my-shell");
}
```

**Prerequisites:** system `gi` (PyGObject), GTK4, gtk4-layer-shell. See
`packaging/install.sh` for the Jac-runtime `system_site.pth` bootstrap.

**Launch (library dev):** `jac run examples/reference/main.jac` or
`./run.sh examples/reference/main.jac` when hacking the library in-tree.

---

## 2a. User config and dev watch (HMR)

Authors run their bar from **`~/.config/jacket/<name>/`**, not the repo
`examples/` tree.

```bash
jacket init mybar              # scaffold ~/.config/jacket/mybar/
jacket run -c mybar            # start
jacket run -c mybar --watch    # dev: theme.css hot-applies; .jac → restart
jacket reload                  # manual restart (same as a successful .jac save)
```

Layout:

```
~/.config/jacket/mybar/
  shell.jac        # entry bootstrap
  components.jac   # your bar widgets
  launcher_ui.jac  # optional overlays (copied from template)
  notif_ui.jac
  theme.css        # GTK4 CSS — hot reload in --watch mode
```

| Change | `--watch` behavior |
|---|---|
| `theme.css` | `apply_css_file()` in-process (no restart) |
| any `.jac` in config dir | debounced `jac check`; on success `request_restart()` |
| syntax error on save | stderr message; last good bar keeps running |

`src/config.jac` resolves paths; `src/dev_watch.jac` owns the monitors.
`packaging/config-template/` is the `jacket init` scaffold.

---

## 3. Public API by module

### 3.1 `src/reactive.jac` — state graph

Writable and derived values. GTK-free; fully unit-tested.

| Symbol | Role |
|---|---|
| `signal(initial)` | Writable `Signal` |
| `computed(fn)` | Derived value; tracks reads inside `fn` |
| `effect(fn)` | Side effect; re-runs when deps change |
| `when(cond, a, b)` | Reactive pick (ternary) |
| `fmt(spec, src)` | Reactive `str.format` |
| `batch(fn)` | Coalesce multiple writes into one flush |
| `set_flush_hook(fn)` | Defer `flush()` (use `idle_add` in GTK apps) |
| `flush()` | Drain effect queue (sync; tests call directly) |
| `create_scope()` / `enter_scope` / `exit_scope` | Manual disposal scopes (rare; `ViewNode` is the real scope) |

**Calling convention:** `sig()` reads and subscribes; `sig.set(v)` or
`sig.update(fn)` writes. Operator overloads (`*`, `+`, comparisons) and
`.map(fn)` build deriveds without extra lambdas in simple cases.

**Stability:** public. Do not depend on module globals (`effect_queue`, etc.).

---

### 3.2 `src/animation.jac` — tweens over reactive props

GTK-free tween scheduler. Animated values are bindable widget props — the
builders route them through `effect → adapter.set_prop` like any other reactive
leaf. Production apps advance tweens on a GLib 16 ms timer; tests call
`advance_animations(ms)` with a fake clock.

| Symbol | Role |
|---|---|
| `animated(initial)` | Writable animated value; bind to a prop |
| `follow(target, ms, ease_fn)` | Chase a `Signal`/`Reactive` with eased tweens |
| `enter_tween(from, to, ms, ease_fn)` | One-shot mount animation (`from` → `to`) |
| `ease.linear` / `.in_` / `.out` / `.in_out` | Cubic easing callables |
| `advance_animations(ms)` | Test helper: advance fake clock and tick tweens |

`AnimatedSignal` API: `()` read (tracked), `.peek()`, `.set(v)` snap,
`.to(target, ms, ease_fn, on_done)`, `.is_running()`. `on_done` fires when
the tween reaches its target (immediately if already there); cancelling —
`.set()`, a retargeting `.to()`, scope disposal — drops the pending callback,
so a gated follow-up (e.g. a delayed window hide after an exit tween) never
runs for an animation that did not complete. Callbacks run after the tick's
unregistration, so they may safely start chained tweens.

**Adapter props:** `opacity` → `set_opacity`; `margin_top` / `margin_bottom` /
`margin_start` / `margin_end` → the matching `set_margin_*` (or the layer-shell
edge-margin fallback on windows).

```jac
import from src.animation { animated, follow, enter_tween, ease, advance_animations }

# Enter animation on mount (notification row)
Box(
    opacity=enter_tween(0.0, 1.0, ms=200, ease_fn=ease.out),
    margin_top=enter_tween(24.0, 0.0, ms=280, ease_fn=ease.out),
    children=[ ... ],
)

# Smooth chase of a source signal
vol = get_audio().volume;
Label(text=follow(vol.map(lambda (d: dict) { d["percent"]; }), ms=80, ease_fn=ease.out))
```

Re-exported from `src/authoring.jac` for convenience.

**Stability:** public. Do not depend on `active_tweens` or timer globals.

---

### 3.2b `src/transition.jac` — popup enter/exit with delayed hide

Binding `hidden = visible.map(not)` unmaps the window the instant `visible`
flips False, so an exit tween would never be seen. `popup_transition`
owns a `shown` Signal instead: open maps immediately and tweens the enter
pose; close tweens the reverse, then unmaps via the tween's `on_done`.
Re-opening mid-exit cancels the pending hide and replays the enter.

| Symbol | Role |
|---|---|
| `popup_transition(visible, offset, enter_ms, exit_ms, ...)` | State machine for one popup shell |
| `tr.fade` / `tr.slide` | `AnimatedSignal`s to bind `opacity` / `margin_*` |
| `tr.shown` | Window-mapped flag — bind `hidden=tr.shown.map(not)` |

```jac
import from src.transition { popup_transition }

tr = popup_transition(l.visible);          # offset=24, enter 280/200, exit 220/160
Window(class="launcher", layer="overlay", keyboard=l.visible,
    hidden=tr.shown.map(_not_visible),
    child=Box(class="launcher-box", opacity=tr.fade, margin_top=tr.slide,
              children=[ ... ]))
```

Notification rows use the row-level variant of the same pattern: a `closing`
flag on the notification dict drives per-row exit tweens while the daemon
holds the row for a grace period (`begin_close`) before real removal — see
`src/notifications.jac` and `examples/reference/notif_ui.jac`.

Headless tests: `tests/transition_tests.jac` drives `advance_animations(ms)`
and asserts `shown` timing; no GTK required.

Re-exported from `src/authoring.jac` for convenience.

**Stability:** public.

---

### 3.3 `src/builders.jac` — authoring surface

Declarative hyperscript → live `ViewNode` OSP graph. Component bodies run **once**.

#### Widget builders

`Box`, `Label`, `Button`, `Icon`, `Entry`, `Slider`, `Window`

Props fall into four channels (classified automatically):

| Form | Behavior |
|---|---|
| literal (`text="hi"`) | Set once at construct |
| `Signal` / `Reactive` | `effect` → `adapter().set_prop` on change |
| `lambda ...` (non-event) | `effect` re-running the lambda |
| `on_*` (`on_click`, …) | GTK signal connect; torn down on dispose |

#### Structural primitives

```jac
For(source_signal, key_fn, row_fn)    # keyed list; 0–1 moves per edit
Show(cond, then_fn, else_fn?)         # mount/dispose on bool flip
```

Inside a `For` row, `row_item()` returns the current list element.

#### Components

```jac
@component
def MyWidget(arg: any = None) -> ViewNode {
    let n = signal(0);
    return Box(children=[ Label(text=n.map(str)) ]);
}
```

`@component` wraps the factory in a disposal scope tied to the returned root.

#### Teardown

`dispose_tree(root: ViewNode)` — stop effects/handlers for a subtree (e.g. monitor
hotplug). Destroy the GTK widget separately via `destroy_window(root.widget)`.

**Stability:** public. `element`, `apply_props`, `ForState` internals are not.

---

### 3.4 `src/osp.jac` — structural graph + walkers

The widget tree **is** an OSP graph. Authors hold the root `ViewNode` their
`@component` returns.

| Symbol | Role |
|---|---|
| `ViewNode` | Node: `tag`, `widget`, `key`, `on_cleanup` |
| `Child` | Typed ordered edge (internal to builders) |
| `query_by_class(root, cls)` | Collect nodes whose CSS class list contains `cls` |
| `flash_class` / `unflash_class` | Add/remove a class across matches (live patch) |
| `collect(root, pred)` | Generic predicate collect |
| `Dispose` walker | Post-order teardown (used by `dispose_tree`) |

See `examples/reference/query_demo.jac` for the author-facing pattern: build once, spawn
walkers over your own tree — no re-render.

**Stability:** `ViewNode`, query/flash helpers, `dispose_tree` are public.
Walker definitions are stable but rarely imported directly.

---

### 3.5 `src/adapter.jac` — runtime + GTK seam

The **only** supported path to pixels. All `gi` bootstrap lives here (`::py::`).

| Symbol | Role |
|---|---|
| `install()` | `gtk_init()` + install `GtkAdapter` |
| `apply_css(text)` | App-level stylesheet |
| `apply_css_file(path)` | Load CSS from a file (used by `theme.css` hot reload) |
| `request_restart()` | Re-exec the process (dev watch / `jacket reload`) |
| `run(build_roots, app_id)` | Simple: `build_roots()` → list of roots, present all |
| `run_dynamic(on_activate, app_id)` | Full control in `on_activate` (multi-monitor, hotplug) |
| `run_with_ipc(on_activate, on_request, app_id)` | IPC server + AGS-style client requests (see `src/ipc.jac`) |
| `list_monitors()` | `Gdk.Monitor` list |
| `monitor_key(m)` | Stable connector name (`"DP-1"`, …) |
| `set_window_monitor(w, m)` | Pin layer-shell window to output |
| `destroy_window(w)` | GTK destroy |
| `connect_monitors_changed(cb)` | Hotplug callback |

`Window` builder props understood by the adapter:

- `layer`, `anchor` / `anchor_corner`, `exclusive_zone`, `keyboard_mode`
- `monitor` (pass a `Gdk.Monitor` from `list_monitors()`)
- `visible` (reactive; for popups)
- `opacity`, `margin_top` (animated slide/fade on any widget; see §3.2)

**Stability:** `install`, `run*`, `apply_css`, monitor helpers are public.
Low-level `construct`/`set_prop` are adapter internals — extend via new widget
tags in `adapter.jac`, not by calling through from author code.

**Escape hatch:** when builders lack a widget (popover menus, gestures), authors
may use `::py::` against `node.widget` directly. Keep escapes local and small
(see tray menu in `examples/reference/components.jac`). Prefer extending builders + adapter.

---

### 3.6 `src/sources.jac` — clock helper

| Symbol | Role |
|---|---|
| `ticker(interval_ms)` | `Signal` of epoch seconds, GLib timeout |

---

### 3.6b `src/ipc.jac` — AGS-style request handler

Transport is `run_with_ipc` in `adapter.jac` (GApplication `HANDLES_COMMAND_LINE`).
This module owns the handler registry.

| Symbol | Role |
|---|---|
| `ipc()` | Lazy singleton `IPC` instance |
| `IPC.register(name, getfn)` | Register a named text getter |
| `IPC.set_bar(b)` / `set_app(a)` | Wire bar toggle + quit |
| `IPC.handle(argv)` | `status`, `list`, `<name>`, `toggle`, `quit` |

Worked example: `examples/swaybar/` (`./run.sh examples/swaybar/main.jac status`).

---

### 3.7 Optional service modules — `Signal` feeds

Each module exposes a lazy singleton `get_*()` returning an object with public
`Signal` fields. Sources are imperative; they `.set()` on the main loop. Missing
services degrade to empty/zero defaults.

| Module | `get_*()` | Signals (typical) |
|---|---|---|
| `wm.jac` | `get_wm()` | `workspaces`, `active` (Hyprland or sway) |
| `battery.jac` | `get_battery()` | `percent`, `charging`, … |
| `power_profiles.jac` | `get_power_profiles()` | `available`, `profile`, `has_performance`, `degradation_reason` |
| `audio.jac` | `get_audio()` | `volume`, `muted` |
| `brightness.jac` | `get_brightness()` | `available`, `percent`, `raw`, `max`, `device` |
| `bluetooth.jac` | `get_bluetooth()` | `available`, `adapters`, `devices`, `default_adapter`, `powered`, `discovering`, `connected`, `primary_device` |
| `pipewire.jac` | `get_pipewire()` | `ready`, `default_sink`, `default_source`, `sinks`, `sources` |
| `mpris.jac` | `get_mpris()` | `player`, `status`, … |
| `notifications.jac` | `get_notifications()` | `active`, daemon API |
| `launcher.jac` | `get_launcher()` | `query`, `results`, `visible` |
| `tray.jac` | `get_tray()` | `items`, activate/menu methods |
| `network.jac` | `get_network()` | `available`, `wifi_enabled`, `connected`, `connection_type`, `ssid`, `signal_strength`, `primary_device`, `networks` |

Pure parsers in these modules (e.g. `parse_workspaces`, `filter_apps`) are
public and headless-testable — use them in your own sources or tests.

**Stability:** `get_*()` accessors and documented `Signal` fields are public.
Private `_` helpers and DBus wiring are internal.

---

## 4. Authoring rules (locked)

1. **Run once.** `@component` body does not re-run. State lives in `signal()`.
2. **Pass signals bare.** No `text=vol()` auto-wrap (no compiler). Use
   `text=vol` or `text=vol.map(fmt_fn)`.
3. **Describe declaratively.** Authors write `Box`/`For`/`Show`, not `node`/`edge`.
4. **Hold the graph.** The returned `ViewNode` is yours — walkers, dispose, debug.
5. **One adapter seam.** No `import gi` in author code unless walled in `::py::`.

---

## 5. Testing without GTK

```jac
import from src.mock_adapter { install_mock }
import from src.reactive { set_flush_hook, flush }
# install_mock() -> records construct/set_prop/insert/move ops
# set_flush_hook(None) -> synchronous flush in tests
```

Test tiers:

| Tier | What | Files |
|---|---|---|
| Reactive | scheduler, diamond, disposal | `tests/reactive_tests.jac` |
| Animation | tweens, follow, enter, builder bind | `tests/animation_tests.jac` |
| Popup transitions | enter/exit state machine, delayed hide | `tests/transition_tests.jac` |
| Reconciler | prop rules, `For` diff, leaks | `tests/builders_tests.jac` |
| Parsers | source pure functions | `tests/sources_tests.jac` |
| Walkers | query/restyle on mock tree | `tests/osp_walker_tests.jac` |

---

## 6. Package layout (intent)

```
shell/
  LIBRARY.md          ← this file (public contract)
  src/
    reactive.jac      ← LIBRARY
    animation.jac     ← LIBRARY
    osp.jac           ← LIBRARY
    builders.jac      ← LIBRARY
    adapter.jac       ← LIBRARY (runtime entry)
    adapter_api.jac   ← INTERNAL
    sources.jac       ← LIBRARY (minimal)
    hyprland.jac …    ← LIBRARY (optional sources)
    mock_adapter.jac  ← TEST ONLY
  examples/
    minimal/main.jac  ← minimal bootstrap (LIBRARY.md §2)
    reference/        ← full bar + cookbook widgets (REFERENCE)
  tests/              ← library correctness
  packaging/          ← deploy helper, not API
```

Reference shells live under `examples/`, not in the core `src/` import path.

---

## 7. Comparison to Quickshell (expressiveness axis)

Quickshell expressiveness = **breadth of QML types and platform services**.

jacket expressiveness = **depth of the reconciler** (fine-grained patch,
OSP walkers) plus **whatever you build** on the builders/adapter/sources
surface. Parity with Quickshell's full service catalog is a library expansion
goal, not a property of the reference bar.

To grow the library:

1. New widget tags in `adapter.jac` + builder in `builders.jac`
2. New `get_*()` source modules exposing `Signal`s
3. Keep reference shells in `examples/`, not in the core `src/` import path

---

## 8. Quick reference — imports for a new shell

```jac
# Runtime
import from src.adapter { install, run_dynamic, apply_css, list_monitors,
    monitor_key, destroy_window, connect_monitors_changed }
import from src.glib { idle_add }
import from src.reactive { set_flush_hook, signal, computed, effect, when, fmt }
import from src.animation { animated, follow, enter_tween, ease, advance_animations }
import from src.builders { component, Box, Label, Button, Icon, Window,
    For, Show, row_item, dispose_tree }
import from src.osp { ViewNode, query_by_class, flash_class, unflash_class }
import from src.sources { ticker }

# Optional services (pick what you need)
import from src.wm { get_wm }
import from src.battery { get_battery, battery_icon }
import from src.power_profiles { get_power_profiles }
import from src.audio { get_audio }
import from src.brightness { get_brightness }
import from src.bluetooth { get_bluetooth }
import from src.pipewire { get_pipewire }
import from src.mpris { get_mpris, format_status }
import from src.notifications { get_notifications }
import from src.launcher { get_launcher }
import from src.tray { get_tray }
import from src.network { get_network }
```
