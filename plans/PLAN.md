# Jacket — Jac-Native Topology-Reactive Desktop Runtime Plan

> Architecture pivot approved 2026-08-09. This document replaces the earlier
> plan in which OSP stored only the widget tree while reactivity lived in plain
> objects. The existing renderer is a completed foundation, not the product
> thesis.

Jacket is a library for constructing a Wayland desktop shell whose **live
runtime state and reactive computation routes are an OSP graph**. GTK remains
responsible for pixels. Jac owns desktop topology, dependency routing,
lifecycle, modes, reconciliation, queries, and external commands.

The end-user promise is not “GTK bindings in Jac.” It is:

- change the running desktop without editing and reloading a text file;
- compose temporary modes and remove each mode without undoing unrelated state;
- route widgets and events by output role, focus, and live device topology;
- ask the shell why a widget exists or which source updates it;
- hotplug outputs without duplicated surfaces or stale subscriptions.

---

## 1. Product thesis and locked decisions

### 1.1 The thesis

The graph is not only a representation of GTK containment. It is the shell's
execution model:

```text
DesktopSession
  ├─Contains──> Output / Surface / ViewNode
  ├─Provides──> SourceNode
  ├─Owns──────> DerivedNode / BindingNode
  └─Applies───> BasePolicy / Mode

SourceNode ─Feeds─> DerivedNode ─Feeds─> BindingNode
Policy/Mode ─Routes or Suppresses─> runtime regions
Surface ─Renders─> ViewNode ─Child─> ViewNode
```

A source write spawns propagation over `Feeds` edges. A topology change runs a
reconciliation walker that changes the active routes. A stable value update
must not traverse the `Child` tree or rebuild components.

### 1.2 Locked stack

| Tier | Decision | Reason |
|---|---|---|
| Product model | Live OSP desktop and computation graph | This is the Jac-specific capability |
| Reactive delivery | Topology-scoped, fine-grained | Walk only reachable computations and patch leaves |
| Desktop composition | OSP-native policies, modes, routes, and walkers | Relationships are the domain |
| Leaf widget authoring | Declarative `Box`/`Label`/`For`/`Show` | Tree description remains simpler than direct edge authoring |
| Rendering | GTK4 + gtk4-layer-shell | GTK owns layout and pixels |
| Binding | PyGObject | One CPython/Jac runtime and one stack trace |
| Host loop | GLib | Scheduler flush and GTK run on one main loop |
| DBus | Gio | Already in the GLib stack |
| Compiler sugar | None | Do not couple Jacket to Jac AST internals |

The old PLAN §8a decision is **narrowed**, not wholly reversed:

- widget authors still describe a leaf UI declaratively;
- shell authors compose outputs, sources, policies, modes, and routes through
  OSP;
- end users mutate and query that graph through stable commands;
- the GTK adapter is a terminal projection, never the source of truth.

### 1.3 Explicitly rejected

- OSP edges used only as slower replacements for subscriber sets;
- propagation through every `Child` edge, which would become a coarse rerender;
- `_bars`, getter registries, or GTK visibility as authoritative desktop state;
- a mode implemented as one global boolean read by every component;
- arbitrary remote execution of walker names or predicates;
- silently falling back to the old plain reactive engine if the OSP spike fails.

If the feasibility gates in Milestone T1 fail, stop and revisit the architecture
explicitly.

---

## 2. Current baseline and quantified progress

The repository already supplies a useful rendering foundation:

- fine-grained `signal` / `computed` / `effect` scheduler;
- declarative builders and keyed `For` / conditional `Show`;
- mock and GTK adapters;
- `ViewNode` / `Child` graph and disposal walkers;
- clock, compositor, battery, audio, MPRIS, notification, tray, and launcher
  sources;
- multi-monitor reference shell, hotplug handling, IPC transport, packaging;
- 100 tests reported by the current README.

It does **not** yet implement the new thesis:

| Concern | Current implementation | Target |
|---|---|---|
| Reactive dependencies | Plain object sets in `src/reactive.jac` | `ReactiveNode` + typed `Feeds` edges |
| Reactive ownership | Cleanup callback attached to a scope | Explicit `Owns` relationship |
| Propagation | Recursive mark loops + effect queue | Walker over affected computation cone |
| Desktop state | `_bars` dict and imperative `sync_bars()` | Output/surface/policy graph + convergence |
| Modes | No runtime concept | Composable policy subgraphs with provenance |
| IPC | Registered string getters | Typed graph commands spawning walkers |
| Introspection | CSS-class query over widget tree | Source-to-binding route and policy explanation |

### 2.1 Roadmap score

Progress changes only when a milestone's acceptance gate passes. Partial code
inside a milestone earns no points.

| ID | Deliverable | Points | Current |
|---|---|---:|---:|
| F0 | Existing renderer and source foundation | 20 | 20 |
| T1 | OSP reactive feasibility spike | 10 | 10 |
| T2 | Topology-reactive core and ownership | 20 | 20 |
| M3 | Route policy and composable modes | 15 | 15 |
| I4 | Graph IPC and explanation queries | 10 | 10 |
| H5 | Output graph and hotplug convergence | 10 | 10 |
| E6 | Reference-shell end-to-end workflow | 15 | 15 |
| **Total** |  | **100** | **100** |

The project is therefore **100% complete against the new product
thesis**. T2, H5 cycle tests, §5.3 benchmarks (with recorded results in
`benchmarks/RESULTS.md`), NotificationLayer route gating, and §5.4 live smoke
(`scripts/live_smoke.sh` + `examples/smoke/main.jac`) are in place. Live smoke
requires PyGObject (`gi`) and a Wayland compositor; it skips automatically when
those are unavailable.

---

## 3. End-to-end user workflow

This is the acceptance story for a shell constructed from Jacket. Command names
are the target v1 interface. Machine-readable `--json` output is mandatory for
tests; human output may be formatted differently.

The test scenario uses synthetic outputs so it is reproducible without physical
hardware:

```text
eDP-1     role=laptop
HDMI-A-1  role=projector
```

The reference shell installs these base policies:

1. one full bar on every output;
2. notification events feed both popup presentation and notification history;
3. `presentation` mode suppresses popup presentation and replaces the projector
   full bar with a minimal bar;
4. `do-not-disturb` mode suppresses popup presentation only.

Modes add policy relationships. They do not destructively delete base policy.
The reconciler derives active routes, so removing a mode reveals the remaining
base or mode policies.

### Step A — boot and inspect

```console
$ jacket status --json
```

Required state:

- exactly one `DesktopSession` is active;
- exactly one `OutputNode` exists per connector;
- exactly one full-bar surface exists per output;
- no modes are active;
- notification popup and history routes are active;
- every live binding has exactly one owning runtime node;
- every GTK root is represented by one surface node.

No GTK widget dictionary may be needed to reconstruct this answer.

### Step B — normal fine-grained update

A clock or audio source changes.

Required behavior:

- only bindings reachable through `Feeds` execute;
- unrelated output regions record zero binding executions and zero adapter
  writes;
- existing widgets receive `set_prop`; no root is rebuilt;
- a diamond dependency reaches each downstream computation at most once.

### Step C — enter presentation mode

```console
$ jacket mode enter presentation
$ jacket status --json
```

Required behavior after one scheduler idle turn:

- one `ModeNode(name="presentation")` exists;
- `eDP-1` retains its full bar;
- `HDMI-A-1` has one minimal bar and no full bar;
- popup presentation has no active route;
- notification history remains routed;
- entering the same mode again is idempotent: no duplicate mode, surface, or
  route nodes.

### Step D — prove routing, not hiding

Inject a notification while presentation mode is active.

Required behavior:

- notification history count increments once;
- popup binding executes zero times;
- GTK records zero popup visibility or construction operations;
- `jacket why binding:notification-popup --json` reports that the base route is
  suppressed by `mode:presentation`.

This must not be implemented by constructing the popup and setting
`visible=False` after delivery.

### Step E — hotplug while the mode is active

Attach synthetic output `DP-2` with `role=projector`.

Required behavior after one convergence pass:

- one new `OutputNode` and one minimal-bar surface appear;
- no full bar is briefly constructed on `DP-2`;
- existing outputs record zero construction or removal operations;
- the new bar receives only the sources reachable under presentation policy.

Detach `DP-2`:

- its surface, view, computation, and route subgraph disappears;
- subsequent source writes execute zero computations formerly owned by `DP-2`.

### Step F — prove mode composition and rollback

```console
$ jacket mode enter do-not-disturb
$ jacket mode exit presentation
```

Required behavior:

- projector outputs return to full bars;
- popup presentation remains suppressed by `do-not-disturb`;
- presentation-owned relationships are gone;
- do-not-disturb-owned relationships remain.

Then:

```console
$ jacket mode exit do-not-disturb
```

Popup presentation becomes active again. Exiting either inactive mode is
idempotent and returns success without graph mutation.

### Step G — explain the running shell

```console
$ jacket why surface:HDMI-A-1/bar --json
$ jacket why binding:notification-popup --json
$ jacket affected-by source:notifications --json
```

Each answer must contain stable node IDs and typed relationships sufficient to
show:

- which base policy requested a surface;
- which mode overrode or suppressed it;
- the source-to-derived-to-binding path;
- the output/surface that owns the binding.

The queries are read-only: zero graph mutations and zero adapter operations.

---

## 4. Runtime graph semantics

Names below describe responsibilities. Exact Jac spelling is pinned during T1.

### 4.1 Node families

| Family | Examples | Responsibility |
|---|---|---|
| Session | `DesktopSession` | Root of one running shell instance |
| Topology | `OutputNode`, `SurfaceNode`, `RegionNode` | Live desktop entities |
| Reactive | `SourceNode`, `DerivedNode`, `BindingNode` | Values and computations |
| Policy | `BasePolicy`, `ModeNode`, `RoutePolicy`, `SuppressionPolicy` | Desired topology and routing |
| Render | `ViewNode` | GTK handle and widget lifecycle scope |

All externally addressable nodes have a stable `runtime_id` unique within the
session. GTK handles, closures, DBus proxies, and sockets are session runtime
state and must never be treated as durable policy data.

T1 must determine how Jacket prevents stale process-local nodes from surviving
Jac graph persistence. Durable policy persistence is deferred until runtime
lifecycle is proven.

### 4.2 Edge families

| Edge | Meaning | Mutation frequency |
|---|---|---|
| `Contains` / `Child` | Desktop and render containment | structural changes |
| `Owns` | Lifecycle ownership of a computation or view | mount/dispose |
| `Feeds` | Active source/computation dependency | dependency changes only |
| `Requests` | Policy asks for a route or surface | mode/policy changes |
| `Suppresses` / `Overrides` | Policy changes effective desire | mode changes |
| `Renders` | Surface projects to a view root | convergence |

A stable value update creates or deletes **zero edges**. When a computation's
dynamic dependencies change, Jacket diffs the old and new `Feeds` edge sets
rather than dropping and rebuilding all edges.

### 4.3 Two execution paths

#### Data path: frequent

```text
SourceNode.set(value)
  -> equality cutoff
  -> spawn/queue Propagate at source
  -> follow Feeds only
  -> pull stale DerivedNodes in dependency order
  -> execute reachable BindingNodes once
  -> adapter leaf patches
```

Expected complexity is **O(Va + Ea)** for the affected computation cone, not
O(1). `Va` and `Ea` are visited reactive nodes and edges. Render `Child` edges
are excluded.

#### Control path: infrequent

```text
output/mode/policy mutation
  -> spawn ReconcileTopology
  -> resolve base + mode policy with provenance
  -> diff desired and active routes/surfaces
  -> mount/dispose only changed subgraphs
  -> update active Feeds relationships
```

Modes therefore pay graph-reconciliation cost when entered or exited; ordinary
clock/audio updates do not repeatedly evaluate all policies.

### 4.4 Ownership and disposal invariant

Every `DerivedNode`, `BindingNode`, and `ViewNode` has one lifecycle owner.
Disposing an output or surface walks `Owns` and `Child` post-order, disconnects
external handlers, removes incident `Feeds` edges, then releases GTK objects.

After disposal, a source update must be unable to reach any removed computation.
This is a graph invariant, not a best-effort cleanup callback convention.

### 4.5 Author-facing construction target

Ordinary widgets keep the existing declarative interface. A shell additionally
constructs a desktop graph, conceptually:

```jac
session = create_desktop("reference");
session add_source ClockSource();
session add_source NotificationSource();
session add_policy BarOnEachOutput(build=FullBar);
session add_mode PresentationMode(build=MinimalBar);
session add_mode DoNotDisturbMode();
session spawn Converge();
```

The final interface must expose OSP entities and relationships rather than hide
all composition in callback registries. The convenience functions may be deep
modules, but their result is always inspectable through the same live graph.

---

## 5. Quantitative acceptance contract

### 5.1 Correctness

| Property | Gate |
|---|---|
| Diamond safety | Each affected derived/binding executes at most once per flush |
| Glitch freedom | A binding observes only a fully current dependency state |
| Equality cutoff | Equal source/derived output causes zero downstream binding runs |
| Dynamic dependencies | Branch change produces the exact `Feeds` edge diff |
| Isolation | Updating one of 100 independent roots causes zero runs/writes in the other 99 |
| Ownership | Every computation has exactly one incoming `Owns` relationship |
| Disposal | 100 mount/dispose cycles leave zero owned computations or incident `Feeds` edges |
| Idempotence | Repeating mode enter/exit and output attach/detach creates no duplicates |
| Read-only queries | `status`, `why`, and `affected-by` create zero graph/adapter mutations |

### 5.2 Selectivity and operation counts

For a graph containing 500 reactive nodes where a source reaches 20 nodes:

- at most those 20 reactive nodes are entered by propagation;
- zero `Child` edges are traversed;
- zero topology edges mutate when dependencies are stable;
- adapter operations equal the number of changed leaf bindings, not total
  widgets or total outputs;
- an unrelated source cone records exactly zero visits.

Tests must assert walker visit counts and adapter operation streams. Wall-clock
numbers alone are insufficient.

### 5.3 Provisional performance gates

Record the current plain-object scheduler as the baseline before replacing it.
Use a committed benchmark workload and report machine/runtime metadata.

| Workload | Gate |
|---|---|
| 500 reactive nodes, 20-node affected cone | p95 propagation under 2 ms headless |
| Same workload versus current scheduler | no more than 5x p95 slowdown |
| Mode enter/exit with two outputs | converges in one idle turn and under 16.7 ms p95 headless |
| `why` on a 500-node graph | under 50 ms p95 |
| Stable 60 Hz source for 60 seconds | zero missed 16.7 ms scheduler deadlines caused by Jacket |
| Idle shell | zero reactive executions and zero adapter writes |

These are go/no-go budgets, not marketing claims. T1 may tighten them. Raising a
failed budget requires recorded evidence and an explicit plan change.

### 5.4 Live Wayland smoke gates

Headless tests own correctness. Live tests prove integration:

- shell starts with no duplicate surfaces;
- clock updates for 60 seconds using leaf `set_prop` only;
- presentation mode changes visible output surfaces without restart;
- notification history updates while popup delivery is suppressed;
- one physical or virtual output attach/detach completes without stale windows;
- shell remains responsive and emits no uncaught Jac/Python/GTK exceptions.

---

## 6. Milestone roadmap

### F0 — Existing foundation (20 points, complete)

Keep working:

- GTK and mock adapter seams;
- builders, `For`, `Show`, and component run-once semantics;
- service source modules;
- existing reference widgets;
- GLib scheduling hook and GApplication IPC transport;
- current tests as regression coverage.

Before T1, run and record the existing test and benchmark baseline. Correct the
README if its reported counts differ from reproducible output.

### T1 — OSP reactive feasibility spike (10 points)

Build a GTK-free spike, separate from the public engine:

- `SourceNode`, `DerivedNode`, `BindingNode`;
- typed `Feeds` and `Owns` edges;
- propagation walker with diamond deduplication;
- one route gate that can connect/disconnect a binding region;
- graph lifecycle experiment for process-local closures and handles;
- benchmark against the current scheduler.

Acceptance:

1. deleting one active route makes the formerly reachable binding execute zero
   times on the next source write;
2. reconnecting it restores delivery without rebuilding the binding;
3. a diamond binding executes exactly once;
4. 100 independent roots pass the isolation gate;
5. stable updates create/delete zero edges;
6. the 2 ms and 5x performance gates pass;
7. restart/lifecycle behavior cannot resurrect stale closures or GTK handles.

If any gate fails, document the result and stop before migrating public code.
Do not quietly retain plain subscriber sets behind an OSP facade.

### T2 — Topology-reactive core and ownership (20 points)

Replace the internals of the public reactive interface while preserving useful
author calls where possible:

- `signal`, `computed`, and `effect` create graph-native reactive nodes;
- dynamic reads maintain `Feeds` edges by set diff;
- tri-state stale/check/dirty semantics move into graph nodes/walkers;
- builders create `BindingNode`s rather than opaque `Effect` objects;
- `ViewNode` and surface ownership become explicit `Owns` edges;
- disposal removes the full owned reactive cone;
- developer trace hooks expose visit/run/edge-mutation counts.

Acceptance:

- all prior scheduler, builder, keyed-diff, and disposal tests pass or are
  intentionally replaced with equivalent graph assertions;
- every correctness and selectivity gate in §5.1–5.2 passes;
- 100 mount/dispose cycles leave no reachable reactive residue;
- a clock tick patches labels without structural graph mutation;
- no source module must know GTK or manually register a subscriber.

### M3 — Route policy and composable modes (15 points)

Add the control plane:

- output/region/surface policy node types;
- base route requests;
- mode-owned suppressions and overrides;
- deterministic precedence and provenance;
- `ReconcileTopology` desired-versus-active diff;
- `presentation` and `do-not-disturb` reference modes.

Acceptance:

- Steps C, D, and F of the end-to-end workflow pass headlessly;
- duplicate enter/exit is idempotent;
- two overlapping suppressions survive removal of either owner;
- removing a mode removes only relationships attributable to that mode;
- mode changes do not reconstruct unaffected output roots;
- convergence meets the one-idle-turn and 16.7 ms gates.

### I4 — Graph IPC and explanations (10 points)

Keep the GApplication transport, replace the string-getter registry with a
bounded command dispatcher that spawns typed operations:

- `status [--json]`;
- `mode enter NAME` / `mode exit NAME`;
- `why TARGET [--json]`;
- `affected-by TARGET [--json]`;
- `quit`.

Acceptance:

- malformed commands return structured errors and do not mutate the graph;
- commands cannot name arbitrary walker classes or execute predicates;
- all query commands are read-only by operation-count assertion;
- mode commands pass through the same graph operation used by in-process code;
- Step G passes with stable IDs and relationship provenance;
- the old hand-registered component getter registry is no longer required for
  graph state.

### H5 — Output graph and hotplug convergence (10 points)

Move monitor state out of `examples/reference/main.jac` globals:

- GDK output events create/update/remove `OutputNode`s;
- output role classification is explicit and testable;
- policies derive desired surfaces;
- convergence mounts/disposes render and computation subgraphs;
- `_bars` and `sync_bars()` cease to be the source of truth.

Acceptance:

- Steps A and E pass with synthetic output events;
- 100 attach/detach cycles produce no duplicate surfaces, leaked bindings, or
  stale adapter children;
- adding one output causes zero GTK operations on existing output roots;
- attaching a projector while presentation mode is active constructs only its
  minimal bar;
- one live Wayland hotplug smoke passes.

### E6 — Reference-shell end-to-end workflow (15 points)

Construct the full reference shell from the graph-native library:

- sources, outputs, surfaces, bindings, and modes are reachable from one
  `DesktopSession`;
- all workflow commands operate on that session;
- packaging exposes a stable `jacket` command;
- human documentation explains outcomes first and graph concepts second;
- benchmark and live-smoke results are recorded.

Acceptance:

- Steps A–G pass in one automated headless scenario;
- all §5 performance and live smoke gates pass;
- old library regression tests pass;
- no authoritative `_bars`, mode boolean, manual component getter registry, or
  hidden subscriber set remains;
- deleting OSP would require reimplementing routing, mode composition,
  introspection, lifecycle, and hotplug convergence across callers. This is the
  deletion test that proves Jac is load-bearing.

---

## 7. Planned module seams

Final names may change during T1, but responsibilities must remain local.

| Module | Responsibility |
|---|---|
| `src/runtime_graph.jac` | Session/topology node and edge archetypes, IDs, invariants |
| `src/topology_reactive.jac` | Reactive nodes, `Feeds`, propagation, scheduler |
| `src/policy.jac` | Base policy, modes, precedence, route/surface reconciliation |
| `src/graph_query.jac` | Status, why, affected-by walkers and typed results |
| `src/ipc.jac` | Command parsing and dispatch only |
| `src/outputs.jac` | Adapter events translated into output graph mutations |
| `src/builders.jac` | Declarative widgets producing owned bindings/views |
| `src/adapter.jac` | GTK projection and host integration only |
| `src/reactive.jac` | Compatibility/public facade if it remains useful |

The deep public seam should be small:

```text
create session
attach source/policy/mode
enter or exit mode
apply output event
query/explain
converge
```

GTK construction, edge diffs, traversal order, cleanup, and provenance stay
inside those modules.

---

## 8. Test and evidence matrix

| Layer | Evidence |
|---|---|
| Reactive graph | diamond, cutoff, dynamic edge diff, batching, loop detection |
| Isolation | 100 roots, one source write, 99 roots with zero visits/writes |
| Lifecycle | 100 mount/dispose and hotplug cycles, graph residue counts |
| Policy | overlapping modes, precedence, provenance, idempotence |
| Reconciliation | exact desired/active route and surface diffs |
| Adapter | exact mock operation stream; leaf versus structural operations |
| IPC | command parsing, authorization surface, typed JSON, read-only queries |
| E2E | Steps A–G with synthetic sources and outputs |
| Performance | committed workload, p50/p95/max, baseline comparison, metadata |
| Live | Wayland clock, modes, notifications, and hotplug smoke log |

Each milestone report must include:

1. commands executed;
2. tests and scenarios passed;
3. graph node/edge and adapter operation counts where relevant;
4. benchmark workload and machine/runtime metadata;
5. known failures and deferred risks;
6. roadmap score after the gate.

---

## 9. Main risks and stop conditions

| Risk | Consequence | Gate or mitigation |
|---|---|---|
| OSP edge/walker overhead on hot path | Missed frame deadlines | T1 benchmark; stop on failed budget |
| Jac graph persistence retains process objects | Invalid closures/GTK handles after restart | T1 lifecycle spike; keep durable policy separate |
| Diamond traversal visits shared nodes twice | Duplicate binding execution | Walker-local IDs plus tri-state tests |
| Dynamic dependency churn | Edge allocation on ordinary updates | Edge-set diff; stable-update zero-mutation gate |
| Policy precedence becomes implicit | Modes undo each other | Provenance and overlapping-mode tests |
| GTK state drifts from graph | Queries lie; duplicate windows | Reconciler invariants and adapter op tests |
| IPC exposes arbitrary graph execution | Unsafe mutation surface | Fixed typed command dispatcher only |
| OSP remains an invisible implementation detail | No user value despite rewrite | E2E mode/routing/explanation workflow is mandatory |

---

## 10. Deferred until E6 passes

- durable user policy persistence across process restarts;
- graphical graph inspector;
- arbitrary user-defined remote walkers;
- a text DSL or compiler for policy declarations;
- distributed or cross-process graph propagation;
- topology-based security/capability enforcement;
- reactive list virtualization and LIS move minimization;
- replacement of declarative leaf widget builders with direct OSP authoring;
- performance claims not backed by a committed reproducible workload.

---

## 11. Definition of done

Jacket reaches the intended product when an end user can enter presentation
mode, hotplug a projector, receive notifications into history without popup
delivery, inspect why each route is active or suppressed, compose that mode with
do-not-disturb, and exit each mode with exact rollback—while the shell keeps
running and unrelated widget regions do no work.

At that point Jac is not a language used to write GTK bindings. Its nodes,
edges, walkers, traversal semantics, and live graph are the desktop runtime.
