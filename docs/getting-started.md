# Getting started with jacket

jacket is a library for building Wayland desktop shells (bars, launchers,
notification layers) in Jac. You compose `@component` trees with fine-grained
reactivity; the runtime builds the GTK4 widgets once and patches leaves when
signals change.

This guide gets a bar on screen in ~10 minutes. For the full API contract see
[LIBRARY.md](../LIBRARY.md); for a guided tour of every feature see
[guide.md](guide.md).

## Prerequisites

- A Wayland compositor (Hyprland or sway recommended; anything supporting
  layer-shell works)
- GTK4 and gtk4-layer-shell
- PyGObject (`gi`) available to your system Python
- The Jac runtime

On Arch:

```bash
sudo pacman -S gtk4 gtk4-layer-shell python-gobject
```

## Run the minimal example

From the repo root:

```bash
jac run examples/minimal/main.jac
```

You should see a thin top bar saying "hello". That file is the whole
bootstrap — read it top to bottom, it is ~30 lines:

```jac
import from src.adapter { install, run_dynamic, apply_css }
import from src.glib { idle_add }
import from src.reactive { set_flush_hook }
import from src.builders { component, Window, Box, Label }

glob MY_CSS: str = """
window { background: #1e1e2e; }
.clock { color: #e6e6e6; font-family: monospace; padding: 4px 12px; }
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
    install();                                          # gtk init + adapter
    apply_css(MY_CSS);
    set_flush_hook(lambda (f: any) { idle_add(f); });   # one flush per idle tick
    run_dynamic(on_activate, "org.example.my-shell");
}
```

The four bootstrap lines are always the same; everything you write lives
between them and `on_activate`.

## Make it reactive

Component bodies run **once**. State lives in signals, and reactive props
update themselves:

```jac
import from time { strftime, localtime }
import from src.reactive { computed }
import from src.sources { ticker }

@component
def Clock() -> ViewNode {
    now = ticker(1000);
    text = computed(lambda () { return strftime("%H:%M", localtime(now())); });
    return Label(class="clock", text=text);
}
```

Swap `Label(text="hello")` for `Clock()` inside the `Box` and restart. Rules
to remember:

- `sig()` reads (and subscribes); `sig.set(v)` / `sig.update(fn)` write.
- Pass signals **bare** to props (`text=now`), never call them inline.
- `.map(fn)` derives a new signal without writing a lambda by hand.

## Add live data sources

Sources are lazy singletons exposing `Signal` fields. They degrade to quiet
defaults when the backing service is missing, so your bar always comes up:

```jac
import from src.wm { get_wm }
import from src.battery { get_battery, battery_icon }

@component
def Status() -> ViewNode {
    wm = get_wm();
    bat = get_battery();
    return Box(orientation="H", children=[
        Label(text=wm.active.map(lambda (w: any) { return str(w["name"]); })),
        Icon(icon=battery_icon(bat)),
        Label(text=bat.percent.map(str)),
    ]);
}
```

Available sources: `wm`, `battery`, `power_profiles`, `audio`, `brightness`,
`bluetooth`, `pipewire`, `mpris`, `notifications`, `launcher`, `tray`,
`network`. See LIBRARY.md §3.7 for each module's signal fields.

## Your own config directory (the normal workflow)

For daily use, scaffold a shell in your config dir instead of running from the
repo:

```bash
jacket init mybar          # creates ~/.config/jacket/mybar/
jacket run -c mybar        # start it
jacket run -c mybar --watch  # dev mode
```

In `--watch` mode, edits to `theme.css` hot-apply without a restart, and edits
to any `.jac` file trigger a `jac check`; if it passes the shell restarts, if
not the last good bar keeps running. `jacket reload` restarts manually.

## Where to go next

- [guide.md](guide.md) — lists with `For`, conditionals with `Show`, windows
  and popups, animation, transitions, IPC, testing without GTK
- [LIBRARY.md](../LIBRARY.md) — complete public API reference
- `examples/reference/` — a full multi-monitor bar (launcher, notifications,
  tray) built entirely on this library; copy patterns from it
