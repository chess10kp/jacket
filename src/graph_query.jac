# graph_query.jac — typed graph queries + dict seam (I4 / PLAN §5.3, §6).
# ---------------------------------------------------------------------------
# Each query traces typed graph relationships (Feeds / Suppresses / Activates)
# and collects a typed result object. Dicts are produced ONLY at the IPC seam
# (the *_dict adapters).
#
# These are graph-traversal FUNCTIONS, not spawned walkers: Jac's walker spawn
# is O(total-graph-nodes), which blows the §5.3 "why < 50ms on 500 nodes" gate.
# Queries are read-only introspection; the typed results + real edge traversal
# keep them graph-native. The control-plane ReconcileTopology remains a walker
# (it only runs on small per-output subgraphs).
#
#   why binding:X        source -Feeds-> RouteNode -Feeds-> BindingNode
#                        + ModeNode -Suppresses-> RoutePolicy (owning mode id)
#   affected-by source   source -Feeds-> RouteNode -Feeds-> BindingNode
import from src.runtime_graph {
    DesktopSession,
    session_outputs, session_modes, output_surfaces,
    route_policy_for, route_node_for_policy,
    Suppresses,
}
import from src.policy {
    policy_state, route_is_active,
    ROUTE_NOTIF_POPUP, ROUTE_NOTIF_HISTORY
}
import from src.topology_reactive { feed_sources, feed_targets }


# ===========================================================================
# Typed result objects
# ===========================================================================
obj StatusResult {
    has session_id: str = "";
    has outputs: list = [];
    has modes: list = [];
    has routes: dict = {};
    has history_count: int = 0;
    has popup_runs: int = 0;
}

obj WhyResult {
    has target: str = "";
    has active: bool = True;
    has base_route: str = "";
    has suppressed_by: list = [];      # [{"mode_id","name"}] from real Suppresses edges
    has path: list = [];               # [{"kind","runtime_id"[,"name"]}] source->route->binding
    has connector: str = "";
    has surface_kind: str = "";
    has modes: list = [];
    has error: str = "";
}

obj AffectedByResult {
    has target: str = "";
    has routes: list = [];             # [{"route","runtime_id","bindings":[ids]}]
}


# ===========================================================================
# StatusQuery — snapshot the session graph into a typed result
# ===========================================================================
def query_status(session: DesktopSession) -> StatusResult {
    r = StatusResult();
    r.session_id = session.runtime_id;
    r.modes = [m.name for m in session_modes(session)];
    r.routes = {};
    r.routes["notification-popup"] = route_is_active(session, ROUTE_NOTIF_POPUP);
    r.routes["notification-history"] = route_is_active(session, ROUTE_NOTIF_HISTORY);
    st = policy_state();
    r.history_count = st.history_count;
    r.popup_runs = st.popup_runs;
    for out in session_outputs(session) {
        surfaces: list = [];
        for s in output_surfaces(out) {
            surfaces.append({"runtime_id": s.runtime_id, "kind": s.kind});
        }
        r.outputs.append({
            "runtime_id": out.runtime_id,
            "connector": out.connector,
            "role": out.role,
            "surfaces": surfaces,
        });
    }
    return r;
}


# ===========================================================================
# WhyBindingQuery — trace source->RouteNode->BindingNode + suppression owners
# ===========================================================================
def _notification_route_handles(route_name: str) -> dict {
    st = policy_state();
    if route_name == ROUTE_NOTIF_POPUP {
        return {"route": st.popup_route, "binding": st.popup_binding};
    }
    if route_name == ROUTE_NOTIF_HISTORY {
        return {"route": st.history_route, "binding": st.history_binding};
    }
    return {};
}

def query_why_binding(session: DesktopSession, route_name: str) -> WhyResult {
    r = WhyResult();
    r.target = "binding:" + route_name;
    r.base_route = route_name;
    # owning modes via the REAL Suppresses edge (provenance with stable ids)
    for m in session_modes(session) {
        for sup in [m ->:Suppresses:->] {
            if sup.route_name == route_name {
                r.suppressed_by.append({"mode_id": m.runtime_id, "name": m.name});
            }
        }
    }
    r.active = len(r.suppressed_by) == 0;
    st = policy_state();
    r.path.append({"kind": "source", "runtime_id": st.notif_source.runtime_id});
    handles = _notification_route_handles(route_name);
    rn = handles.get("route");
    binding = handles.get("binding");
    if rn is None {
        # fallback for routes not wired through the reference notification source
        rp = route_policy_for(session, route_name);
        if rp is not None { rn = route_node_for_policy(rp); }
    }
    if rn is not None {
        r.path.append({"kind": "route", "runtime_id": rn.runtime_id, "name": rn.route_name});
        if binding is not None {
            r.path.append({"kind": "binding", "runtime_id": binding.runtime_id});
        } else {
            for b in feed_targets(rn) {
                r.path.append({"kind": "binding", "runtime_id": b.runtime_id});
            }
        }
    }
    return r;
}


# ===========================================================================
# AffectedByQuery — which routes/bindings a source currently feeds
# ===========================================================================
def query_affected_by(source: any) -> AffectedByResult {
    r = AffectedByResult();
    st = policy_state();
    # fast path: reference notification source uses session handles + active flags
    # (avoids O(graph) Feeds edge scans on large output topologies)
    if source is st.notif_source {
        for (name, rn, binding) in [
            (ROUTE_NOTIF_HISTORY, st.history_route, st.history_binding),
            (ROUTE_NOTIF_POPUP, st.popup_route, st.popup_binding),
        ] {
            if rn is not None and rn.active {
                r.routes.append({
                    "route": name,
                    "runtime_id": rn.runtime_id,
                    "bindings": [binding.runtime_id] if binding is not None else [],
                });
            }
        }
        return r;
    }
    for rn in feed_targets(source) {
        if not hasattr(rn, "route_name") { continue; }
        binds: list = [];
        for b in feed_targets(rn) { binds.append(b.runtime_id); }
        r.routes.append({
            "route": rn.route_name,
            "runtime_id": rn.runtime_id,
            "bindings": binds,
        });
    }
    return r;
}


# ===========================================================================
# Dict seam — typed results -> JSON-friendly dicts (IPC boundary only)
# ===========================================================================
def status_dict(session: DesktopSession) -> dict {
    r = query_status(session);
    return {
        "session_id": r.session_id,
        "outputs": r.outputs,
        "modes": r.modes,
        "routes": r.routes,
        "history_count": r.history_count,
        "popup_runs": r.popup_runs,
    };
}

def _why_binding_to_dict(r: WhyResult) -> dict {
    return {
        "target": r.target,
        "active": r.active,
        "base_route": r.base_route,
        "suppressed_by": ["mode:" + str(m["name"]) for m in r.suppressed_by],
        "suppressed_by_modes": r.suppressed_by,      # full provenance with stable ids
        "path": r.path,
    };
}

def why_dict(target: str, session: DesktopSession) -> dict {
    if target == "binding:notification-popup" {
        return _why_binding_to_dict(query_why_binding(session, ROUTE_NOTIF_POPUP));
    }
    if target.startswith("surface:") {
        rest = target.split("surface:", 1)[1];
        parts = rest.split("/");
        connector = parts[0];
        kind = parts[1] if len(parts) > 1 else "bar";
        return {
            "target": target,
            "connector": connector,
            "surface_kind": kind,
            "override": None,
            "modes": [m.name for m in session_modes(session)],
        };
    }
    return {"target": target, "error": "unknown target"};
}

def affected_by_dict(target: str, session: DesktopSession) -> dict {
    if target == "source:notifications" {
        st = policy_state();
        r = query_affected_by(st.notif_source);
        return {
            "target": target,
            "bindings": [entry["route"] for entry in r.routes],   # route names (compat)
            "routes": r.routes,                                    # full paths with ids
        };
    }
    return {"target": target, "bindings": []};
}
