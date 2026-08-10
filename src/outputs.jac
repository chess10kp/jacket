# outputs.jac — output graph mutations and hotplug convergence (H5).
# ---------------------------------------------------------------------------
import from src.runtime_graph {
    DesktopSession, OutputNode, SessionOutput, next_runtime_id, trace_adapter,
    session_outputs, output_surfaces
}
import from src.policy { reconcile_topology }
import from src.projection { dispose_surface_views }


def classify_role(connector: str) -> str {
    if connector == "eDP-1" { return "laptop"; }
    if connector.startswith("HDMI") or connector.startswith("DP") {
        return "projector";
    }
    return "unknown";
}


def apply_output_attach(session: DesktopSession, connector: str, role: str = "") -> OutputNode {
    for o in session_outputs(session) {
        if o.connector == connector {
            # H5: update role on repeated attach instead of ignoring the event
            if role != "" and o.role != role {
                o.role = role;
                reconcile_topology(session);
            }
            return o;
        }
    }
    r = role if role != "" else classify_role(connector);
    out = OutputNode(runtime_id=next_runtime_id("output"), connector=connector, role=r);
    session +>:SessionOutput:+> out;
    trace_adapter("output_attach:" + connector);
    reconcile_topology(session);
    return out;
}


def apply_output_detach(session: DesktopSession, connector: str) -> bool {
    for o in session_outputs(session) {
        if o.connector == connector {
            for sn in output_surfaces(o) { dispose_surface_views(sn); }
            trace_adapter("output_detach:" + connector);
            del o;
            reconcile_topology(session);
            return True;
        }
    }
    return False;
}


def list_outputs(session: DesktopSession) -> list {
    return session_outputs(session);
}
