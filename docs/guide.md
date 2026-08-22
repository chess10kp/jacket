# The jacket guide

How to actually build things. This walks the authoring surface end to end:
components, reactivity, lists, conditionals, windows, animation, IPC, and
testing. API details live in [LIBRARY.md](../LIBRARY.md); start with
[getting-started.md](getting-started.md) if you have not run a bar yet.

## 1. The mental model

One-directional data flow:

```
sources (DBus, IPC, sysfs) ──writes──▶ Signals
                                        │ mark-stale (push)
                                        ▼
                              Scheduler (flush on GLib.idle)
                                        │ lazy pull, dep order
                                        ▼
                    Effects (one per reactive prop) + For (keyed diff)
                                        │ set_prop / insert / move
                                        ▼
                                  GTK4 widgets
```

Three consequences for you as an author:

1. **Components run once.** A `@component` body is a setup function, not a
   render function. There is no re-render; there are only signal writes.
2. **You hold the graph.** The `ViewNode` your component returns is yours —
   query it, walk it, dispose it.
3. **No direct GTK.** All pixels go through the adapter seam. Escape hatches
   exist (`::py::` against `node.widget`) but keep them small and local.

## 2. Components

```jac
@component
def MyWidget(arg: any = None) -> ViewNode {
    let n = signal(0);
    return Box(children=[ Label(text=n.map(str)) ]);
}
```

- State is created in the body (`signal`, `computed`, `effect`, `animated`)
  and lives for the lifetime of the returned tree — `@component` ties a
  disposal scope to the root node.
- Arguments are plain values passed at construction. If a widget must react to
  changing input, pass a `Signal` instead.

## 3. Reactivity (`jacket/reactive.jac`)

| Symbol | Role |
|---|---|
| `signal(initial)` | Writable value: `sig()`, `sig.set(v)`, `sig.update(fn)` |
| `computed(fn)` | Derived value; tracks what `fn` reads |
| `effect(fn)` | Side effect; re-runs when its deps change |
| `when(cond, a, b)` | Reactive ternary over signals |
| `fmt(spec, src)` | Reactive `str.format` |
| `batch(fn)` | Coalesce several writes into one flush |

Operator overloads (`+`, `*`, comparisons) and `.map(fn)` build deriveds
without extra lambdas.

```jac
count = signal(0);
label_text = count.map(lambda (n: int) { return f"clicks: {n}"; });
count.update(lambda (n: int) { return n + 1; });
```

**Authoring rule:** pass signals bare into props. `text=count` updates;
`text=count()` sets once and never again.

## 4. Widgets and props (`jacket/builders.jac`)

Builders: `Box`, `Label`, `Button`, `Icon`, `Entry`, `Slider`, `Window`.

Props fall into four channels, classified automatically:

| Form | Behavior |
|---|---|
| literal (`text="hi"`) | set once at construct |
| `Signal` / `Reactive` | effect → patch on every change |
| lambda (non-event) | effect re-running the lambda |
| `on_*` (`on_click`, …) | GTK signal connect, torn down on dispose |

```jac
Button(class="ws", label=ws_name, on_click=lambda () { wm.activate(ws_id); })
```

Style with CSS classes + your stylesheet (`apply_css` or `theme.css`); query
and restyle live via `query_by_class` / `flash_class` from `jacket/osp.jac`.

## 5. Lists: `For`

`For(source_signal, key_fn, row_fn)` does a keyed diff — at most one move per
edit, rows mount/dispose individually. Inside a row, `row_item()` returns the
current element (so closures stay fresh after reorder).

```jac
import from jacket.builders { For, row_item }

@component
def Workspaces() -> ViewNode {
    wm = get_wm();
    return Box(orientation="H", children=[
        For(
            wm.workspaces,
            key_fn=lambda (w: dict) { return w["id"]; },
            row_fn=lambda () {
                w = row_item();
                return Button(
                    class="ws",
                    label=w["name"].map(str),
                    on_click=lambda () { wm.activate(w["id"]); },
                );
            },
        ),
    ]);
}
```

## 6. Conditionals: `Show`

`Show(cond, then_fn, else_fn?)` mounts and disposes subtrees on bool flips —
the else branch's effects are fully torn down.

```jac
Show(bat.charging,
    then_fn=lambda () { return Icon(icon="battery-charging-symbolic"); });
```

## 7. Windows and layers (`Window`)

`Window` props understood by the adapter:

- `layer` (`"top"`, `"overlay"`, …), `anchor` / `anchor_corner`,
  `exclusive_zone`, `keyboard_mode`
- `monitor` — pin to an output from `list_monitors()` (keyed by
  `monitor_key(m)`, e.g. `"DP-1"`); use `connect_monitors_changed` for hotplug
- `visible` — reactive mapping flag (popups)
- `hidden` — bind to a transition's `shown` flag (§9)
- `opacity`, `margin_*` — bindable/animated on any widget

Multi-monitor bars: build one root per monitor inside `run_dynamic`'s
activate callback and present each; see `examples/reference/main.jac`.

## 8. Animation (`jacket/animation.jac`)

Animated values are ordinary bindable props — the builders route them through
the same effect → patch path.

```jac
import from jacket.animation { animated, follow, enter_tween, ease }

Box(
    opacity=enter_tween(0.0, 1.0, ms=200, ease_fn=ease.out),
    margin_top=enter_tween(24.0, 0.0, ms=280, ease_fn=ease.out),
    children=[ ... ],
)

# chase a source signal smoothly
Label(text=follow(vol.map(lambda (d: dict) { return d["percent"]; }),
                  ms=80, ease_fn=ease.out))
```

`animated(initial)` gives you a writable tweening value: `()` read, `.set(v)`
snap, `.to(target, ms, ease_fn, on_done)` animate. `on_done` never fires if
the tween was cancelled (a `.set()` or retarget), which makes gated follow-ups
like "hide after exit tween finishes" safe.

## 9. Popup transitions (`jacket/transition.jac`)

Binding `hidden = visible.map(not)` unmaps instantly, killing any exit tween.
`popup_transition` owns the timing for you:

```jac
import from jacket.transition { popup_transition }

tr = popup_transition(l.visible);
Window(class="launcher", layer="overlay", keyboard=l.visible,
    hidden=tr.shown.map(_not_visible),
    child=Box(class="launcher-box", opacity=tr.fade, margin_top=tr.slide,
              children=[ ... ]))
```

Open maps immediately and tweens the enter pose; close tweens the reverse then
unmaps via `on_done`; re-opening mid-exit cancels the pending hide.

## 10. IPC commands (`jacket/ipc.jac`)

Register named text getters and drive the shell from the CLI:

```jac
import from jacket.adapter { run_with_ipc }
import from jacket.ipc { ipc }

def on_activate(app: any) { ... }
ipc().register("volume", lambda () { return str(get_audio().volume()); });
run_with_ipc(on_activate,
             lambda (argv: list) { return ipc().handle(argv); },
             "org.example.my-shell");
```

Then `jacket-ctl status`, `jacket-ctl list`, `jacket-ctl volume`,
`jacket-ctl toggle`, `jacket-ctl quit`. Worked example: `examples/swaybar/`
(`./run.sh examples/swaybar/main.jac status`).

## 11. Teardown

Hold the roots you create. To remove a window (e.g. monitor hotplug):

```jac
import from jacket.builders { dispose_tree }
import from jacket.adapter { destroy_window }

dispose_tree(root);      # stop effects/handlers for the subtree
destroy_window(root.widget);
```

## 12. Testing without GTK

The reactive core, reconciler, animation, transitions, walkers, and source
parsers are all testable headlessly with the mock adapter:

```jac
import from jacket.mock_adapter { install_mock }
import from jacket.reactive { set_flush_hook, flush }

install_mock();          # records construct/set_prop/insert/move ops
set_flush_hook(None);    # synchronous flush
sig.set(42);
flush();
# assert against mock ops...
```

Run the suite with `jac test tests/reactive_tests.jac` etc., or see
LIBRARY.md §5 for the tier table.

## 13. Rules recap (locked)

1. Run once — state lives in `signal()`.
2. Pass signals bare — no auto-wrap of `sig()`.
3. Describe declaratively — `Box`/`For`/`Show`, not nodes and edges.
4. Hold the graph — the returned `ViewNode` is yours.
5. One adapter seam — no `import gi` outside walled `::py::` blocks.
