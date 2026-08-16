# policy.jac — graph-native route policy, modes, ReconcileTopology (M3 / PLAN §6).
# ---------------------------------------------------------------------------
# Route truth is GRAPH REACHABILITY, not a dict:
#
#   BasePolicy  -Requests->  RoutePolicy
#   RoutePolicy -Activates-> RouteNode        (reactive gate; mirrors source)
#   RouteNode   -Feeds->     BindingNode      (bindings read the route, NEVER source)
#   ModeNode    -Suppresses-> RoutePolicy     (suppressing drops source->RouteNode Feeds)
#
# Because a binding reads the RouteNode and never the source, a suppressed route
# CANNOT be bypassed by dynamic-dependency tracking: the binding has no Feeds
# edge to the source to re-add. Reconciliation resolves desired routes/surfaces
# from the graph and mounts/disposes only changed subgraphs.
import from src.runtime_graph {
    DesktopSession, OutputNode, SurfaceNode, ModeNode, BasePolicy, RoutePolicy,
    RouteNode,
    SessionPolicy, SessionMode, SessionSource, SessionBinding, SessionOutput, OutputSurface,
    Suppresses, Requests, Activates,
    session_modes, session_outputs, output_surfaces,
    session_route_policies, route_policy_for, route_node_for_policy,
    next_runtime_id, trace_adapter
}
import from src.reactive { signal }
import from src.topology_reactive {
    create_source, create_binding, create_route, read, source_set,
    connect_feeds, disconnect_feeds, batch
}
import from src.projection { dispose_surface_views, mount_surface_view, surface_views }


glob ROUTE_FULL_BAR: str = "surface:full-bar";
glob ROUTE_MINIMAL_BAR: str = "surface:minimal-bar";
glob ROUTE_NOTIF_POPUP: str = "route:notification-popup";
glob ROUTE_NOTIF_HISTORY: str = "route:notification-history";


# Observability handles for tests/IPC. These are NOT routing truth — routing
# truth is the graph (Suppresses edges + RouteNode Feeds). popup_runs is also
# available as popup_binding.runs; popup_projection is a UI-visibility
# projection that the reconciler writes from resolved graph state.
obj PolicyState {
    has history_count: int = 0;
    has popup_runs: int = 0;
    has notif_source: any = None;
    has popup_projection: any = None;
    has popup_binding: any = None;
    has history_binding: any = None;
    has popup_route: any = None;
    has history_route: any = None;
    has modes_projection: any = None;
}


glob _policy: any = None;

def policy_state() -> PolicyState {
    if _policy is None { _policy = PolicyState(); }
    return _policy;
}

# UI-visibility projection for the popup route (Show cond). Written ONLY by the
# reconciler from resolved graph state — the graph is the source of truth.
def popup_route_active() -> any {
    st = policy_state();
    if st.popup_projection is None { st.popup_projection = signal(True); }
    return st.popup_projection;
}

# UI projection for active mode names (bar toggles, status mirrors).
def active_modes() -> any {
    st = policy_state();
    if st.modes_projection is None { st.modes_projection = signal([]); }
    return st.modes_projection;
}

def _sync_modes_projection(session: DesktopSession) {
    st = policy_state();
    if st.modes_projection is None { return; }
    names = mode_names(session);
    m = st.modes_projection;
    if m.peek() == names { return; }
    m.set(names);
}

def toggle_mode(session: DesktopSession, name: str) -> bool {
    if name in mode_names(session) { return exit_mode(session, name); }
    return enter_mode(session, name);
}

def reset_policy_state() { _policy = PolicyState(); }


def current_surface(out: OutputNode) -> any {
    surfs = output_surfaces(out);
    if len(surfs) > 0 { return surfs[0]; }
    return None;
}

def mode_names(session: DesktopSession) -> list[str] {
    return [m.name for m in session_modes(session)];
}

# A route is active iff no mode Suppresses its RoutePolicy (graph resolution).
def suppression_owners(session: DesktopSession, route_name: str) -> list[str] {
    owners: list = [];
    for m in session_modes(session) {
        for suppressed in [m ->:Suppresses:->] {
            if suppressed.route_name == route_name and m.name not in owners {
                owners.append(m.name);
            }
        }
    }
    return owners;
}

def route_is_active(session: DesktopSession, route_name: str) -> bool {
    return len(suppression_owners(session, route_name)) == 0;
}


# ---------------------------------------------------------------------------
# Base policy: one notification source, two route gates feeding two bindings.
# ---------------------------------------------------------------------------
def install_base_policies(session: DesktopSession) {
    st = policy_state();
    bp = BasePolicy(runtime_id=next_runtime_id("policy"), name="reference-base");
    session +>:SessionPolicy:+> bp;

    st.notif_source = create_source(0);
    session +>:SessionSource:+> st.notif_source;     # session-owned -> disposed on reset

    st.history_route = _make_route(session, bp, ROUTE_NOTIF_HISTORY);
    st.history_binding = create_binding(lambda {
        read(st.history_route);
        st.history_count += 1;
        trace_adapter("history_write");
    });
    session +>:SessionBinding:+> st.history_binding;

    st.popup_route = _make_route(session, bp, ROUTE_NOTIF_POPUP);
    st.popup_binding = create_binding(lambda {
        read(st.popup_route);
        st.popup_runs += 1;
        trace_adapter("popup_write");
    });
    session +>:SessionBinding:+> st.popup_binding;

    # Establish route Feeds edges immediately so a notification before the first
    # output attach still propagates. _sync_routes remains the sole owner of
    # source->RouteNode edges (idempotent connect on active routes).
    reconcile_topology(session);
    _sync_modes_projection(session);
}

# Build a route gate: BasePolicy -Requests-> RoutePolicy -Activates-> RouteNode.
# Bindings are created by the caller so it holds a direct handle; they read()
# the returned RouteNode, never the source.
def _make_route(session: DesktopSession, bp: BasePolicy, name: str) -> RouteNode {
    rp = RoutePolicy(runtime_id=next_runtime_id("routepolicy"), route_name=name);
    bp +>:Requests:+> rp;
    rn = create_route(name, policy_state().notif_source);
    rp +>:Activates:+> rn;
    return rn;
}


# ---------------------------------------------------------------------------
# Modes — add/remove mode-owned Suppresses relationships only.
# ---------------------------------------------------------------------------
def enter_mode(session: DesktopSession, name: str) -> bool {
    for m in session_modes(session) {
        if m.name == name { return True; }           # idempotent
    }
    m = ModeNode(runtime_id=next_runtime_id("mode"), name=name);
    session +>:SessionMode:+> m;
    if name == "presentation" or name == "do-not-disturb" {
        rp = route_policy_for(session, ROUTE_NOTIF_POPUP);
        if rp is not None { m +>:Suppresses:+> rp; }   # suppress the popup RoutePolicy
    }
    reconcile_topology(session);
    _sync_modes_projection(session);
    return True;
}

def exit_mode(session: DesktopSession, name: str) -> bool {
    found = False;
    for m in list(session_modes(session)) {
        if m.name == name { del m; found = True; }
    }
    if not found { return True; }                    # idempotent on inactive mode
    reconcile_topology(session);
    _sync_modes_projection(session);
    return True;
}


# ---------------------------------------------------------------------------
# Surface kind resolution — reads live graph state (modes + output role).
# Deterministic; Change 6 attributes provenance via real Override edges.
# ---------------------------------------------------------------------------
def desired_surface_kind(session: DesktopSession, connector: str, role: str) -> str {
    if "presentation" in mode_names(session) and role == "projector" {
        return "minimal-bar";
    }
    return "full-bar";
}


# ---------------------------------------------------------------------------
# Route gate sync — resolve each route's active state from the graph and make
# the source->RouteNode Feeds edge match. This is the data-path gate; the UI
# projection mirrors the resolved state for the popup Show.
# ---------------------------------------------------------------------------
def _sync_routes(session: DesktopSession) {
    st = policy_state();
    for rp in session_route_policies(session) {
        rn = route_node_for_policy(rp);
        if rn is None { continue; }
        active = route_is_active(session, rp.route_name);
        rn.active = active;
        if active {
            connect_feeds(st.notif_source, rn);
        } else {
            disconnect_feeds(st.notif_source, rn);
        }
        if rp.route_name == ROUTE_NOTIF_POPUP and st.popup_projection is not None {
            st.popup_projection.set(active);        # schedules its own flush
        }
    }
}


# ---------------------------------------------------------------------------
# ReconcileTopology — control-plane convergence (PLAN §4.3).
#   1. resolve route gates from graph policy state
#   2. for each output, diff desired vs active surface; mount/dispose only changes
# No data-path (Feeds) traversal happens here except the route gate edges, which
# are policy, not value, edges.
#
# Implemented as a direct output loop, NOT a spawned walker: Jac walker spawn is
# O(total-graph-nodes), which blows the §5.3 mode-convergence gate on realistic
# session sizes even when only two outputs reconcile.
# ---------------------------------------------------------------------------
def _reconcile_output(session: DesktopSession, out: OutputNode) {
    want = desired_surface_kind(session, out.connector, out.role);
    cur = current_surface(out);
    if cur is not None and cur.kind == want {
        # Surface may exist without a view if reconcile ran before builders registered.
        if len(surface_views(cur)) == 0 { mount_surface_view(cur); }
        return;
    }
    if cur is not None {
        dispose_surface_views(cur);
        trace_adapter("surface_dispose:" + str(out.connector));
        del cur;
    }
    sn = SurfaceNode(
        runtime_id=next_runtime_id("surface"),
        kind=want,
        connector=out.connector,
    );
    out +>:OutputSurface:+> sn;
    mount_surface_view(sn);
    trace_adapter("surface_mount:" + str(out.connector) + ":" + want);
}

def reconcile_topology(session: DesktopSession) {
    trace_adapter("reconcile");
    # One flush at batch end — avoid a mid-reconcile Propagate spawn from
    # popup_projection.set() while route Feeds edges are still being rewired.
    batch(lambda {
        _sync_routes(session);
        for out in session_outputs(session) {
            _reconcile_output(session, out);
        }
    });
}


def inject_notification() {
    st = policy_state();
    source_set(st.notif_source, st.notif_source.value + 1);
}
