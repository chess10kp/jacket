# Jac/GTK Desktop Shell — Complete Design & Build Plan

A Wayland desktop shell (bar, panels, notifications, launcher) written **entirely
in Jac** (a Python superset), reaching GTK4 through PyGObject. The novel part is
that we own the whole brain: a **fine-grained reactive reconciler** where the
**OSP graph *is* the fiber tree**. Nothing above the toolkit is borrowed.

---

## 1. Locked decisions (the stack, top to bottom)

| Tier | Choice | Rationale |
|---|---|---|
| **Framework** | **Own it — refuse Astal/AGS** | The reconciler + state model is the project's spine. Never outsource it. |
| **Reactivity** | **Fine-grained (Solid-style)** | Shell is ~90% static skeleton + few hot points. Build once, patch leaves, diff only in `For`. Fits GTK's expensive-reparent cost model. |
| **Sugar** | **No compiler.** Operator overloads + `.map`/`when`/`fmt` | ~90% lambda-free authoring with zero AST-pass coupling. `text=vol()` reactive is impossible without a compiler — accepted; pass signals bare instead. |
| **Binding** | **PyGObject (`gi`)** | Standard GObject-introspection mechanism, adds zero opinion. Same VM as Jac (CPython) — one runtime, one GC, one stack trace. |
| **Toolkit** | **GTK4 + gtk4-layer-shell** | The pixels. Not owned (renderer-from-scratch was killed — Skia = years). |
| **DBus** | **Gio** (in the GLib stack already) | Notifications daemon + MPRIS. Use the transport, own the logic. No `dbus-next`. |
| **Rejected** | GJS | More ergonomic binding, but drags in a 2nd VM (SpiderMonkey) → two-runtime architecture with a serialization seam. Fatal for a Jac stack. |

**The line:** own everything from the graph up through the reconciler; reach GTK
through a binding (not a framework); refuse Astal. When someone reads the code,
the state model, traversal engine, diff, and source adapters are all *ours*.

---

## 2. Architecture — one-directional data flow

```
   sources (DBus/Gio, Hypr IPC, sysfs)  ──writes──▶  Signals
                                                        │  mark-stale (push)
                                                        ▼
                                              Scheduler (flush on GLib.idle)
                                                        │  lazy pull, dep-order
                                                        ▼
                          Effects (one per reactive prop)  +  For (keyed diff)
                                                        │  set_prop / insert / move
                                                        ▼
                                        Adapter (the walled-off PyGObject seam)
                                                        │
                                                        ▼
                                                  GTK4 widgets
```

**The OSP boundary (load-bearing):**
- **Structural tree** = OSP. `node ViewNode` connected by typed, ordered
  `edge Child`. Build/mount/dispose/theme/query are **walkers** (`visit`/`spawn`/
  node-abilities). The ViewNode is also the reactive **disposal scope** — there
  is ONE tree, torn down post-order by the `Dispose` walker (no parallel Owner
  tree). This is where OSP earns its keep: a walker can sweep the whole live
  widget graph (restyle, query, debug-dump) with no framework re-render — a
  hidden VDOM fiber tree can't expose that.
- **Reactive dep graph** (signal↔effect links) = **plain Jac objects, NOT OSP
  edges**. It churns every tick and the hot path must stay O(1); walking it would
  defeat fine-grained. Deliberately non-OSP.

---

## 3. File inventory (the five sketches — all in scratchpad)

| File | Owns | Status |
|---|---|---|
| `osp_runtime.jac` | **structural substrate**: `node ViewNode`, typed `edge Child`, walkers (`Dispose`/`ApplyTheme`/`Collect`/`Mount`), node-ability lifecycle | sketched |
| `reactive_core.jac` | signal / derived / effect / **`Scope`** + operator overloads + `.map`/`when`/`fmt` (`currentScope` = a ViewNode in the real tree) | sketched |
| `scheduler.jac` | tri-state mark-stale → lazy pull (glitch-free) → batched `idle_add` flush; re-entrancy cap | sketched |
| `builders.jac` | `Box`/`Label`/`Button` over the OSP graph, prop-classification rule, `For` (keyed two-ended diff), **`Show`**, `@component` | sketched |
| `adapter.jac` | the PyGObject seam: construct/set_prop/insert/remove/move/connect (**arity-adapted events**), construct-only table, one-parent discipline, layer-shell, main loop | sketched |
| `sources.jac` | plain imperative Jac: Gio DBus, Hyprland socket, audio, battery → all expose `Signal`s; `on_main` threading choke point | sketched |
| `components.jac` | authoring cookbook: Clock/Counter/Volume/Workspaces/Notifications/Bar/Battery | sketched |

---

## 4. Build order (risk-ordered — prove the core before the seam)

**Phase 0 — Spike (de-risk the unknowns).** ~1 day.
- Confirm PyGObject + gtk4-layer-shell import and open a layer-shell window from Jac.
- Confirm Jac operator-overload dunders (`__mul__`, `__gt__`, `__call__`) work as expected on `obj`, and Jac `node`/edge spelling for ViewNode.
- *Kills the two real unknowns cheaply before building on them.*

**Phase 1 — Reactive core + scheduler.** The engine, GTK-free.
- Implement `reactive_core.jac` folding in the scheduler deltas (tri-state, pull-on-read).
- **Unit tests, no GTK:** counter, derived chain, **asymmetric diamond runs D once**, equality cutoff stops propagation, `when`/`.map`/operators.
- Milestone: reactive graph correct in isolation. This is where correctness is won.

**Phase 2 — Mock adapter + builders + `For`.** Engine end-to-end, still headless.
- Mock adapter records ops (construct/set_prop/insert/move/remove) into a list.
- Implement builders + `For`; assert the *op stream* for: append, prepend,
  single insert/remove, reverse, middle-insert → each in 0–1 moves.
- **Disposal/leak test:** mount+unmount a `For` list N times, assert subscriber
  sets and owner children return to baseline.
- Milestone: whole reconciler proven against a mock. No `gi` yet.

**Phase 3 — Real GTK adapter.** Swap the mock for `adapter.jac`.
- Implement construct/set_prop/insert/remove/move/connect against real GTK4.
- First visible artifact: a bar with a **live clock** (proves the leaf-patch path)
  and **static buttons** (proves construct + events).
- Milestone: pixels on screen, clock ticking via one `set_text`/sec.

**Phase 4 — Sources.** Plain imperative Jac feeding Signals.
- Hyprland IPC (workspaces → drives the first real `For`), audio (volume),
  battery, clock. Each source owns a socket/poll loop and `.set()`s signals.
- Milestone: workspaces list reacts live; volume label updates. **Full thesis demo.**

**Phase 5 — Real widgets.** Notifications (Gio DBus daemon), MPRIS, tray, launcher.
- Milestone: daily-drivable shell.

---

## 5. Testing strategy (what actually needs tests)

- **Scheduler correctness** — diamond (single run), deep chains, equality cutoff,
  re-entrant write convergence + loop → raises. *Highest-value tests in the repo.*
- **Keyed diff** — op-stream assertions per list-mutation shape (mock adapter).
- **Disposal** — subscriber/owner counts return to baseline after unmount cycles.
- **Prop classification** — Reactive→effect, lambda→effect, literal→static, `on_*`→event.
- GTK-level behavior is smoke-tested by eye (the clock, the workspace list), not unit-tested.

---

## 6. Risks & mitigations

| Risk | Severity | Mitigation |
|---|---|---|
| Jac operator-overload / node-edge spelling differs from sketch | med | Phase-0 spike confirms before building. |
| `set_property` segfaults on bad type (no exception) | med | All marshalling walled in `adapter.coerce_value`; special-case common props; expand coercion as cases surface. |
| Unmount leaks (orphaned effect pins subgraph) | med | Owner-scope disposal + explicit leak test (Phase 2). |
| `For` move-resolution (`reorder_child_after` needs prev *widget*) | low | Targeted reverse/middle-insert tests; `None`→head. |
| CPython set overhead per reactive node (216 B ×2) | low | `__slots__` on hot objects; `None\|single\|list` subscriber slot only if profiled. |
| Frame-timing: flush on `idle_add` vs GTK frame clock | low | idle_add commits once per tick after event handling; revisit only if jank appears. |

---

## 7. Memory profile (analyzed)

Design overhead ≈ **1–1.5 MB** for a ~500-widget shell; whole process ≈ 80–200 MB
(CPython + typelibs + GTK4). Reconciler is **~1–2% of RSS** — the bill is the
*stack choice*, not the design. Fine-grained *removes* per-tick allocation churn a
coarse re-render would impose (clock tick allocates nothing). One genuine leak
vector — unmount — is exactly what owner scopes prevent.

---

## 8. Explicitly deferred (do NOT build now)

- **LIS minimum-move refinement** for `For` — two-ended handles shell-shaped
  changes in 0–1 moves; add only if profiling shows shuffle thrash.
- **Jac compile-time transform** (`text=vol()` auto-wrap) — killed; would couple
  to `jaclang`'s least-stable AST-pass API. Operators + `.map` recover ~90%.
- **List virtualization** (windowed `For`) — only if a huge launcher list spikes.
- **`__slots__` / subscriber-slot tuning** — micro-optimizations, post-profile.
- **Reactive-graph debug walker** — expose a snapshot walker later; don't make the
  live dep graph pay OSP-edge cost for introspection.

---

## 8a. Decided: authoring surface is declarative, NOT OSP-native

The component-authoring surface is **declarative hyperscript** (`Box`/`Label`/
`For`/`Show` + lambdas), not OSP. Authors never write `node`/`edge`/`walker` to
describe UI. Rationale: **UI authoring is a description problem, not a traversal
problem** — OSP only earns its keep on traversal. OSP-native authoring was
considered and rejected: it costs the `For`/`Show` sugar, fine-grained props,
and the run-once model while buying nothing for tree description.

The split that keeps OSP honest:
- **Author WRITES** declaratively (input).
- **Author HOLDS** a real, walkable `ViewNode` OSP graph (result) — and can
  `spawn` walkers over their OWN UI for cross-cutting ops (query, restyle,
  flash-all-X). That opt-in walker-over-your-own-tree is a first-class feature,
  the end-user-facing OSP payoff.

So: description = declarative; traversal = OSP; each where it fits. This is a
LOCKED decision — do not relitigate without a new reason.

## 8b. Refinements folded in (found by writing real components / OSP audit)

- **Structural layer is now genuine OSP** — `node ViewNode` + typed `edge Child`
  + walkers, not plain recursion. Earlier drafts name-dropped OSP; corrected.
- **Owner tree removed** — the ViewNode *is* the reactive disposal scope
  (`currentScope`); `Dispose` walker tears the subtree down post-order via a node
  ability. One tree, not two. `Scope` remains only as the headless-test stand-in.
- **R1 — `Show(cond, then, else_)`** — conditional-structure primitive, sibling
  of `For` (owned subtree, mount/dispose on bool flip). In `builders.jac`.
- **R2 — event arity** — handlers receive the event payload; `adapter.connect`
  adapts arity so `lambda:` ignores it and `lambda e:` uses it (scroll delta,
  keyval).
- **Syntax** — all closures are `lambda x:` (Rust `|x|` was wrong).

## 9. Open items to pin before coding

1. Real Jac spelling: `node`/edge declaration, `obj` dunder support, module-global
   mutation (the `globals()[...]` placeholders), `import from gi.repository`.
2. Signal equality hook for container values (mutation-in-place won't propagate
   under `!=`) — decide per-signal `equals` now or defer.
3. Source→Signal threading model: GTK main loop is single-threaded; sources that
   poll/socket must marshal `.set()` back onto the main loop (`GLib.idle_add`).
```
