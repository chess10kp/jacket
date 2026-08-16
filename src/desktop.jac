# desktop.jac — DesktopSession factory and convergence entry points.
# ---------------------------------------------------------------------------
import from src.runtime_graph {
    DesktopSession, reset_session_store, next_runtime_id,
    CollectSession, set_active_session_rid, active_session_rid,
    session_outputs, output_surfaces
}
import from src.runtime_graph { trace_adapter }
import from src.policy {
    reset_policy_state, install_base_policies, enter_mode, exit_mode,
    inject_notification, reconcile_topology
}
import from src.projection { reset_projection, dispose_surface_views }
import from src.topology_reactive { dispose_reactive_node }
import from src.outputs { apply_output_attach, apply_output_detach }
import from src.graph_query { status_dict, why_dict, affected_by_dict }
import from src.projection { present_surface_views }


glob _session: any = None;

# Dispose a session's complete runtime subgraph (PLAN §1): tear down every
# SurfaceNode's ViewNode subtree first (projection), then collect the remaining
# runtime nodes via the CollectSession walker and delete them post-order. This
# is what makes create_desktop() leave NO stale graph nodes behind.
def dispose_session(session: DesktopSession) {
    for out in list(session_outputs(session)) {
        for sn in list(output_surfaces(out)) {
            dispose_surface_views(sn);
        }
    }
    w = CollectSession();
    session spawn w;
    for n in reversed(w.nodes) {
        dispose_reactive_node(n);
        del n;
    }
}

def reset_desktop() {
    if _session is not None {
        old = _session;
        _session = None;
        dispose_session(old);
    }
    reset_session_store();
    reset_policy_state();
    reset_projection();
    set_active_session_rid("");
}

def create_desktop(label: str = "reference") -> DesktopSession {
    reset_desktop();
    s = DesktopSession(runtime_id=next_runtime_id("session"), label=label);
    s.session_id = s.runtime_id;
    root ++> s;
    set_active_session_rid(s.runtime_id);
    _session = s;
    install_base_policies(s);
    return s;
}

def get_desktop() -> DesktopSession {
    return _session;
}

def converge(session: DesktopSession = None) {
    s = session if session is not None else _session;
    reconcile_topology(s);
}

def bootstrap_reference_outputs(session: DesktopSession) {
    apply_output_attach(session, "eDP-1", "laptop");
    apply_output_attach(session, "HDMI-A-1", "projector");
}

def handle_graph_command(argv: list) -> dict {
    session = get_desktop();
    if session is None {
        return {"ok": False, "error": "no active session"};
    }
    if len(argv) == 0 {
        return {"ok": True, "data": status_dict(session)};
    }
    cmd = str(argv[0]);
    if cmd == "status" {
        return {"ok": True, "data": status_dict(session)};
    }
    if cmd == "mode" and len(argv) >= 3 {
        action = str(argv[1]);
        name = str(argv[2]);
        if action == "enter" {
            enter_mode(session, name);
            present_surface_views(session);
            return {"ok": True, "data": status_dict(session)};
        }
        if action == "exit" {
            exit_mode(session, name);
            present_surface_views(session);
            return {"ok": True, "data": status_dict(session)};
        }
        return {"ok": False, "error": "unknown mode action"};
    }
    if cmd == "why" and len(argv) >= 2 {
        return {"ok": True, "data": why_dict(str(argv[1]), session)};
    }
    if cmd == "affected-by" and len(argv) >= 2 {
        return {"ok": True, "data": affected_by_dict(str(argv[1]), session)};
    }
    if cmd == "quit" {
        return {"ok": True, "quit": True};
    }
    return {"ok": False, "error": "unknown command: " + cmd};
}
