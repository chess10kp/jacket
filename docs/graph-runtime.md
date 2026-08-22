# The graph runtime

How jacket's runtime actually works inside. This is the contributor/extender
view of the OSP-native engine that replaced the procedural scheduler: typed
session graph, `Propagate` walker over `Feeds` edges, exact dependency
diffing, policy reconciliation, and query commands. For *authoring* widgets,
read [guide.md](guide.md); for the public API contract, [LIBRARY.md](../LIBRARY.md).

Modules: `jacket/runtime_graph.jac` (schema), `jacket/topology_reactive.jac`
(engine), `jacket/policy.jac` (modes/reconciliation), `jacket/outputs.jac` (hotplug),
`jacket/projection.jac` (surface → view), `jacket/graph_query.jac` (queries),
`jacket/desktop.jac` (lifecycle), `jacket/ipc.jac` (command dispatch).

## 1. Overview

One-directional dataflow, walker-driven:

```
DATA PATH (every source write)
  SourceNode.set ──equality cutoff──▶ dirty_sources queue
        │  flush on GLib.idle (set_flush_hook)
        ▼
  spawn Propagate(seeds) ── Feeds edges ONLY (never Child)
        │  pull DerivedNode / RouteNode (memoized per pass)
        ▼
  run each changed BindingNode once ──▶ adapter leaf patch

CONTROL PATH (mode enter/exit, output attach/detach)
  graph mutation ──▶ reconcile_topology()
        │  resolve routes from Suppresses edges
        │  diff desired vs active surfaces
        ▼
  mount/dispose SurfaceNode + ViewNode, rewire route Feeds gates
```

The widget tree (`node ViewNode`, `edge Child` in `jacket/osp.jac`) remains a
separate structural projection — data updates never traverse it. Graph state
is process-local by design: `jacket/osp_local.jac` detaches the embedded SQL
store so edge hops walk in-memory topology.

## 2. Session lifecycle (`jacket/desktop.jac`)

| Entry point | What it does |
|---|---|
| `create_desktop(label)` | Disposes any prior session, creates a `DesktopSession`, sets it active via `set_active_session_rid()`, installs base policies |
| `get_desktop()` | Returns the live session (or `None`) |
| `converge(session=None)` | Runs `reconcile_topology()` — the manual convergence entry |
| `dispose_session(session)` | Tears down every surface's views (`dispose_surface_views`), then spawns the `CollectSession` walker and deletes its collected nodes **in reverse** (post-order), calling `dispose_reactive_node` on each |
| `reset_desktop()` | `dispose_session` + `reset_session_store()` + `reset_policy_state()` + `reset_projection()` |

Runtime identity rules (`jacket/runtime_graph.jac`):

- Every runtime node extends `RuntimeBase` and carries a `session_id`; the
  active session's id is stamped onto each node at creation.
- IDs come from `next_runtime_id(prefix)` backed by `_rid_seq`, which is
  **monotonic — never reset**. `reset_session_store()` deliberately does not
  zero the counter, so cross-session keys cannot collide.
- Process-local closures never live on nodes. They live in the `SessionStore`
  obj (`derived_fns`, `binding_fns`, `route_sources`, trace counters), keyed by
  `runtime_id`. A node holding a Python callable/GTK handle would poison graph
  serialization.

`CollectSession` reaches the whole runtime subgraph through typed edges only:
session → outputs/policies/modes/sources/bindings, output → surfaces, policy →
`Requests` → RoutePolicy → `Activates` → RouteNode, mode → `Suppresses`.

## 3. Graph schema (`jacket/runtime_graph.jac`)

### Node types

| Node | Extends | Key fields | Role |
|---|---|---|---|
| `DesktopSession` | `RuntimeBase` | `label` | Root of one running shell |
| `OutputNode` | `RuntimeBase` | `connector`, `role` | One per connected output |
| `SurfaceNode` | `RuntimeBase` | `kind`, `connector` | Desired + active bar surface |
| `RegionNode` | `RuntimeBase` | `name` | Region archetype *(declared; unused by current code)* |
| `SourceNode` | `ReactiveNode` | `value` | Writable reactive leaf |
| `DerivedNode` | `ReactiveNode` | `cached`, `state` | Computed value; `state`: CLEAN=0/CHECK=1/DIRTY=2 |
| `BindingNode` | `ReactiveNode` | `enabled`, `runs` | Side-effect leaf |
| `RouteNode` | `ReactiveNode` | `route_name`, `cached`, `state`, `active` | Reactive GATE between route policy and bindings |
| `BasePolicy` | `RuntimeBase` | `name` | Base routing desires (`reference-base`) |
| `ModeNode` | `RuntimeBase` | `name` | An entered mode |
| `RoutePolicy` | `RuntimeBase` | `route_name` | A named route request |
| `SuppressionPolicy` | `RuntimeBase` | `route_name`, `owner_mode` | *(declared; suppression is done via `ModeNode -Suppresses->`)* |
| `OverridePolicy` | `RuntimeBase` | `route_name`, `surface_kind`, `owner_mode` | *(declared; unused by current code)* |
| `ViewNode` (`jacket/osp.jac`) | — | `tag`, `widget`, `cleanups` | GTK handle + disposal scope |

### Relationships

| Edge | Signature | Written by |
|---|---|---|
| `SessionOutput` | DesktopSession → OutputNode | `apply_output_attach` |
| `SessionPolicy` | DesktopSession → BasePolicy | `install_base_policies` |
| `SessionMode` | DesktopSession → ModeNode | `enter_mode` |
| `SessionSource` | DesktopSession → SourceNode | `install_base_policies` |
| `SessionBinding` | DesktopSession → BindingNode | `install_base_policies` |
| `OutputSurface` | OutputNode → SurfaceNode | `_reconcile_output` |
| `SurfaceRegion` | SurfaceNode → RegionNode | *(declared; unused)* |
| `Owns` | ReactiveNode → ReactiveNode | `create_source/create_derived/create_binding(owner=…)`, `own_node` |
| `Feeds` | ReactiveNode → ReactiveNode | `diff_feeds` (data path), `_sync_routes` (route gates) |
| `Requests` | any → any | `_make_route` (BasePolicy → RoutePolicy) |
| `Suppresses` | ModeNode → RoutePolicy | `enter_mode` |
| `Overrides` | ModeNode → OverridePolicy | *(declared; unused)* |
| `Activates` | RoutePolicy → RouteNode | `_make_route` |
| `Renders` | SurfaceNode → ViewNode | `mount_surface_view` |

Route truth is graph reachability:

```
BasePolicy -Requests-> RoutePolicy -Activates-> RouteNode -Feeds-> BindingNode
ModeNode   -Suppresses-> RoutePolicy          (suppressing drops source→RouteNode Feeds)
```

Because bindings `read()` the `RouteNode` — never the source — a suppressed
route cannot be re-connected by dynamic dependency tracking: the binding has no
`Feeds` edge to the source to re-add.

## 4. Propagation (`jacket/topology_reactive.jac`)

The full path for one source write:

1. **Equality cutoff at the source** — `source_set(src, v)` returns early if
   `v == src.value`; no enqueue, no traversal.
2. **Seed enqueue** — `enqueue_dirty` appends to `dirty_sources` (dedup'd) and
   calls `schedule()`. The queue holds **dirty source roots only**; the walker
   owns traversal. `schedule()` defers while an evaluation is on the stack
   (`_eval_depth > 0`), inside `batch()`, or mid-flush.
3. **Flush** — `flush()` loops until `dirty_sources` is empty (bounded by
   `MAX_FLUSH_PASSES = 100`; exceeding it raises
   `RuntimeError("reactive flush did not converge — write-loop?")`). Each pass
   bumps `_flush_gen`, clears `_changed`, snapshots the roots, and spawns
   **one** `Propagate(seeds=roots)` from `root`. Outside tests/headless runs,
   `flush_hook` (see `set_flush_hook`) redirects this onto `GLib.idle`.
4. **Walker traversal** — `Propagate` follows **`Feeds` edges only**:

```jac
walker Propagate {
    has visited: list = [];
    has seeds: list = [];
    can launch with Root entry { visit self.seeds; }
    can root with SourceNode entry { visit [here ->:Feeds:->]; }
    can pull with DerivedNode entry {
        rid = here.runtime_id;
        if rid in self.visited { skip; }
        self.visited.append(rid);
        ensure_fresh(here);                 # recompute, memoized per pass
        if _changed.get(rid) { visit [here ->:Feeds:->]; }   # equality cutoff
    }
    can bind with BindingNode entry {
        if here.runtime_id in self.visited { skip; }
        if not here.enabled { skip; }
        self.visited.append(rid);
        run_binding(here);
    }
}
```

- **Diamond dedup**: the single shared `visited` list plus the per-pass
  `_recomputed[rid] == _flush_gen` memo mean a derived node reachable through
  two paths recomputes once and a multi-source binding runs once.
- **Equality cutoff downstream**: `recompute()` sets `_changed[rid]` only when
  the new value differs; unchanged derived nodes do not propagate further.
- **Loop detection** is the pass bound above, not visitor bookkeeping.
- Complexity is O(Va + Ea) over the affected cone; zero `Child`, policy, or
  topology edges are touched.

`RouteNode` handling mirrors deriveds via `ensure_route_fresh`, but its
recompute reads the source with `peek()` (**untracked**), so the
source→RouteNode `Feeds` edge is owned exclusively by `_sync_routes`, never by
dependency tracking.

## 5. Dependency tracking — collect, then diff

Reads during a derived/binding evaluation are collected into an evaluation
context; edges are committed **once after evaluation**, never mid-read:

1. `evaluate(target, fn)` pushes an `EvalContext(target, reads)` onto
   `_eval_stack`.
2. `read_reactive(g)` (aliased as `read`) appends `g` to the innermost context
   and pulls freshness — it does not mutate edges.
3. In `finally`, `evaluate` pops the stack and calls
   `diff_feeds(target, ctx.reads)`.

`diff_feeds(dst, new_deps)` is an exact set diff against `feed_sources(dst)`:

```jac
def diff_feeds(dst: any, new_deps: list) {
    old = feed_sources(dst);
    for o in old { if o not in new_deps { disconnect_feeds(o, dst); } }
    for d in new_deps { if d not in old { connect_feeds(d, dst); } }
}
```

Consequences:

- A **stable dependency set mutates zero edges** across arbitrarily many
  re-evaluations — ordinary clock/audio ticks create/delete nothing.
- A conditional branch change produces exactly the minimal edge diff: stale
  edges removed, new edges added.
- `peek(g)` is the supported untracked read (e.g. `signal.peek()`); reads made
  with it never become dependencies.

## 6. Ownership & disposal

Two layers:

**Reactive cone — graph-native, callback-free.** `create_source`,
`create_derived`, and `create_binding` all accept an `owner: ReactiveNode` and
attach an `Owns` edge. The authoring facade (`jacket/reactive.jac`) wires this
automatically: a component's scope gets a hidden anchor source
(`ViewNode.reactive_anchor`) whose cleanup runs `dispose_owned(anchor)`.
`DisposeOwned` walks `Owns` post-order (`exit` abilities) and for each node
`dispose_reactive_node` pops its closure from `SessionStore` and disconnects
all incident `Feeds` edges in both directions, so disposed computations are
unreachable by construction — a later source write cannot reach them.

**Views — external resources.** `ViewNode.cleanups` (registered via
`on_cleanup`) exist for resources the graph cannot express: DBus handler
disconnects, socket closes, tween stops. The teardown order at session level
(`dispose_session`) is views first (`dispose_surface_views` → `dispose_tree`),
then the `CollectSession` collection, then reverse-order node deletion.

Output detach (`apply_output_detach`) disposes the output's surface views and
deletes the `OutputNode`; the next `reconcile_topology` pass sees the smaller
graph.

## 7. Policy graph (`jacket/policy.jac`)

The reference session ships one notification source feeding two route gates
(`ROUTE_NOTIF_POPUP`, `ROUTE_NOTIF_HISTORY`), built by `_make_route`:
`BasePolicy -Requests-> RoutePolicy -Activates-> RouteNode`.

**Modes** add relationships, they never delete base policy:

- `enter_mode(session, name)` is idempotent; it attaches a `ModeNode` and, for
  `"presentation"` / `"do-not-disturb"`, adds
  `m +>:Suppresses:+> popup_route_policy`.
- `exit_mode(session, name)` deletes mode-owned nodes/edges and is idempotent
  on inactive modes.
- Route activity is resolved from the graph: `suppression_owners` walks real
  `Suppresses` edges; `route_is_active` is true iff no mode suppresses it.
- Surface kind comes from `desired_surface_kind(session, connector, role)` —
  deterministic resolution over live mode names + output role
  (`presentation` + `role == "projector"` → `"minimal-bar"`, else
  `"full-bar"`).

**`reconcile_topology(session)`** is the control-plane convergence step,
run inside `batch()` so route rewiring and projections commit as one flush:

1. `_sync_routes` — for each `RoutePolicy`, set `RouteNode.active` and connect/
   disconnect the source→RouteNode `Feeds` gate to match resolved activity;
   mirror the popup route into the `popup_route_active()` UI projection signal.
2. Per output, `_reconcile_output` diffs desired vs active surface kind and
   mounts/disposes **only changes**, remounting a view if a surface exists but
   has none yet.

Note: despite the PLAN's "spawn `ReconcileTopology`" phrasing, it is a plain
function looping outputs, not a spawned walker — Jac walker spawn is
O(total-graph-nodes), which blows the §5.3 mode-convergence budget even for two
outputs. The same reasoning applies to the queries below.

UI-visible state (`popup_projection`, `modes_projection`) is written **only**
by the reconciler from resolved graph state — the graph stays the source of
truth. The DBus side bridges in via `wire_notification_source`
(`jacket/notifications_policy.jac`), which pushes `len(d.notifications())` into
the policy source through an effect.

## 8. Query walkers (`jacket/graph_query.jac`)

Queries are read-only graph-traversal **functions** (not spawned walkers — same
O(graph) spawn cost rationale), producing typed results; dicts are built only
at the IPC seam.

| Query | Result obj | Contents |
|---|---|---|
| `query_status(session)` | `StatusResult` | `session_id`, outputs (connector/role/surfaces with ids), `modes`, `routes` (popup/history activity), `history_count`, `popup_runs` |
| `query_why_binding(session, route_name)` | `WhyResult` | `active`, `base_route`, `suppressed_by` (mode id + name from real `Suppresses` edges), `path` (`source` → `route` → `binding` entries with `runtime_id`s) |
| `query_affected_by(source)` | `AffectedByResult` | Active routes fed by the source, each with `route`, `runtime_id`, `bindings` |

Dict seams: `status_dict`, `why_dict`, `affected_by_dict`. `why_dict` accepts
`binding:notification-popup` and `surface:<connector>/<kind>` targets;
`affected_by_dict` accepts `source:notifications` (fast-pathed off the
reference handles, avoiding O(graph) `Feeds` scans).

## 9. IPC surface (`jacket/ipc.jac`)

Graph commands are the core truth; the legacy getter registry is isolated
behind a flag:

- `IPC._use_graph` defaults to `True`. When a desktop exists
  (`get_desktop() is not None`), the command verbs `status`, `mode`, `why`,
  `affected-by`, `quit`, `reload` dispatch to
  `handle_graph_command(argv)` (`jacket/desktop.jac`) and never touch the legacy
  registry.
- `handle_graph_command` is a bounded dispatcher over a fixed verb table —
  there is no path from IPC to arbitrary walker names or predicates.
  Unknown verbs return structured errors without mutating the graph; queries
  are read-only.
- With no active session, or for non-graph commands, the legacy registry
  (`IPC.register` string getters, `list`, `toggle`, `launcher`) still serves
  swaybar-style consumers.
- Transport: GApplication remote activation plus a local Unix socket at
  `$XDG_RUNTIME_DIR/jacket.sock` (`start_ipc_socket`), handled on the GLib
  main thread.
