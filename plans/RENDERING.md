# Jacket — Rendering and Adapter Strategy

> Decision record, 2026-08-19. Captures the rendering-stack discussion after
> T1–E6 completion. This does **not** replace the locked stack in
> `plans/PLAN.md` §1.2; it records rationale, alternatives, and when to revisit.

---

## 1. Current decision (locked for now)

| Tier | Choice | Role |
|---|---|---|
| Rendering | GTK 4 + gtk4-layer-shell | Layout, pixels, input, IME |
| Binding | PyGObject (`::py::` shim in `src/adapter.jac`) | One CPython/Jac runtime |
| Host loop | GLib | Scheduler flush + GTK main loop |
| Product thesis | OSP graph + reactive routing | Source of truth above the adapter |

**Next priority: ship shell features on this stack.** The adapter is a terminal
projection, not the product. T1–E6 are complete; the graph, modes, IPC,
hotplug, and reference shell are the foundation to build on.

**Not next priority:**

- Big-bang replacement of GTK with a from-scratch renderer
- Preemptive micro-optimizations without a measured bottleneck

---

## 2. How somewm widgets work (and why jacket can't copy them directly)

somewm is the **compositor**. Its bars/panels are **not** Wayland clients.

```text
Lua wibox widget tree
  → fit/layout in Lua
  → Cairo draw onto ARGB32 (drawable.c)
  → upload to wlr_scene_buffer
  → compositor scene graph (layers[LyrWibox])
```

Internal drawins bypass `wl_surface` and layer-shell entirely. External panels
(launchers, lock screens) may use `zwlr_layer_shell_v1` as normal clients.

jacket runs as a **separate Wayland client** and projects Jac `@component` trees
through GTK. That is a different seat at the table — not worse, just not
compositor-internal.

---

## 3. Industry landscape (corrected)

Most standalone Wayland shell UI **does** use GTK + gtk-layer-shell:

| Project | Stack |
|---|---|
| jacket | GTK 4 + PyGObject + gtk4-layer-shell |
| waybar | GTK 3 + gtkmm + gtk-layer-shell |
| eww | GTK 3 + gtk-rs + gtk-layer-shell |
| AGS | GTK 4 + GObject introspection |

The lean outlier is **compositor-integrated** UI (somewm wibox) or **raw client**
bars (swaybar: Cairo/Pango + layer-shell, no GTK).

Dropping GTK is not the common client-side path. Projects accept GTK as boring
infrastructure for text, focus, IME, CSS-ish theming, and tray icons.

jacket's extra weight vs waybar is mostly **PyGObject + embedded Python + GTK
4**, not "using a GUI toolkit at all."

---

## 4. Why a native renderer might still make sense (future track)

Valid reasons to build a non-GTK adapter **later**, not reasons to block
feature work now:

1. **somewm is in-tree** — drawin/wibox is a working compositor-internal path
   (Cairo → scene graph, no protocol round-trip).
2. **Adapter is already abstracted** — `mock_adapter.jac` proves the reconciler
   only needs `construct / set_prop / insert / remove / move / connect /
   disconnect`.
3. **PyGObject is impedance mismatch** — gi proxy quirks, `::py::` shims, Jac
   breaks on gi attribute access; this is ongoing tax, not one-time setup.
4. **Shell scope is narrow** — bars, launchers, notifications; not full GTK
   widget breadth. `Window` / `Box` / `Label` / `Button` / `Entry` covers most
   of it.
5. **Clay is vendored** — layout is the hard part of DIY rendering; `clay/` is a
   candidate layout engine for a Cairo backend.
6. **OSP work is above the adapter** — graph, propagation, modes, IPC do not
   require GTK.

A from-scratch backend still depends on Pango/Harfbuzz (text), Cairo or pixman
(pixels), and layer-shell client code. That is swaybar territory — lighter than
GTK+GLib+PyGObject, not zero-deps.

---

## 5. Two future adapter products (optional, not committed)

Same Jac `@component` tree, different backends:

### A. Portable client adapter

Runs on Sway, Hyprland, somewm, etc.

- Wayland client + `zwlr_layer_shell_v1` (or ext-layer-shell)
- Cairo/Pango/Clay for draw
- Own hit-testing, keyboard grabs, HiDPI buffer scale

Working name: `CairoAdapter` or `WaylandClientAdapter`.

### B. Compositor-integrated adapter

jacket views become somewm drawins.

- No GTK, no client protocol
- Same model as wibox/drawin
- somewm-only; fine if somewm is the primary target

Working name: `DrawinAdapter`.

Both can coexist behind `set_adapter()`. Neither requires throwing away OSP or
reactive work.

---

## 6. Priority order

```text
1. Shell features     — new surfaces, sources, modes, launcher/notif polish, UX
2. Native adapter     — only when PyGObject/GTK friction blocks feature velocity
                        or somewm integration becomes the primary product
3. Optimizations      — when measured (launcher filter, frame drops, hot paths)
```

Do **not** treat native rendering as a prerequisite for adding shell functionality.
Do **not** rewrite the adapter while landing unrelated product features unless
GTK is the explicit blocker.

---

## 7. When to revisit this plan

Reopen and choose an adapter track when **any** of:

- PyGObject/gi bugs consume disproportionate time vs feature work
- A feature GTK cannot do cleanly (or only with unacceptable hacks)
- somewm integration becomes a first-class product goal
- Profiling shows GTK/PyGObject as the dominant latency (not Jac reactive path)
- A minimal `CairoAdapter` spike on the reference bar is requested

Spike scope if revisiting:

1. Keep GTK adapter working.
2. Implement bar-sized subset only (`Window`, `Box`, `Label`, margins, layer-shell).
3. Prove on `examples/reference/main.jac` behind the same adapter contract.
4. Compare: binary size, cold start, launcher keystroke latency, maintainer burden.

---

## 8. References in-repo

| Path | Relevance |
|---|---|
| `plans/PLAN.md` §1.2 | Locked stack (GTK terminal projection) |
| `src/adapter.jac` | Current GTK/PyGObject seam |
| `src/mock_adapter.jac` | Adapter contract without GTK |
| `somewm/objects/drawin.c` | Compositor-internal rendering |
| `somewm/objects/drawable.c` | Cairo surface → wlr buffer |
| `somewm/lua/wibox/` | Lua widget/layout layer |
| `clay/` | Optional layout engine for a future Cairo backend |
| `somewm/DEVIATIONS.md` | Why somewm avoids GTK inside the compositor |

---

## 9. One-line summary

**Build shell features on GTK now; native rendering is an optional second adapter
when pain or product direction justifies it, not a milestone gate.**
