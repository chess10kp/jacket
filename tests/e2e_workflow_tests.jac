# e2e_workflow_tests.jac — Steps A–G headless acceptance (E6).
import from jacket.desktop {
    create_desktop, bootstrap_reference_outputs, get_desktop, handle_graph_command
}
import from jacket.policy {
    enter_mode, exit_mode, inject_notification, policy_state,
    ROUTE_NOTIF_POPUP, ROUTE_NOTIF_HISTORY
}
import from jacket.outputs { apply_output_attach, apply_output_detach }
import from jacket.graph_query { status_dict, why_dict, affected_by_dict }
import from jacket.runtime_graph { session_store }


def _surface_kinds(st: dict, connector: str) -> list {
    for o in st["outputs"] as list {
        if o["connector"] == connector {
            return [s["kind"] for s in o["surfaces"]];
        }
    }
    return [];
}


test "step A boot and inspect" {
    s = create_desktop("reference");
    bootstrap_reference_outputs(s);
    st = status_dict(s);
    assert st["session_id"] != "";
    assert len(st["outputs"]) == 2;
    assert _surface_kinds(st, "eDP-1") == ["full-bar"];
    assert _surface_kinds(st, "HDMI-A-1") == ["full-bar"];
    assert st["modes"] == [];
    assert st["routes"]["notification-popup"] is True;
    assert st["routes"]["notification-history"] is True;
}


test "step C presentation mode" {
    s = create_desktop("reference");
    bootstrap_reference_outputs(s);
    enter_mode(s, "presentation");
    st = status_dict(s);
    assert "presentation" in st["modes"];
    assert _surface_kinds(st, "eDP-1") == ["full-bar"];
    assert _surface_kinds(st, "HDMI-A-1") == ["minimal-bar"];
    assert st["routes"]["notification-popup"] is False;
    assert st["routes"]["notification-history"] is True;
    enter_mode(s, "presentation");
    st2 = status_dict(s);
    assert len([m for m in st2["modes"] if m == "presentation"]) == 1;
}


test "step D notification routing not hiding" {
    s = create_desktop("reference");
    bootstrap_reference_outputs(s);
    enter_mode(s, "presentation");
    ps = policy_state();
    before_hist = ps.history_count;
    before_popup = ps.popup_runs;
    inject_notification();
    assert ps.history_count == before_hist + 1;
    assert ps.popup_runs == before_popup;
    why = why_dict("binding:notification-popup", s);
    assert why["active"] is False;
    assert "mode:presentation" in why["suppressed_by"];
}


test "step E hotplug in presentation mode" {
    s = create_desktop("reference");
    bootstrap_reference_outputs(s);
    enter_mode(s, "presentation");
    apply_output_attach(s, "DP-2", "projector");
    st = status_dict(s);
    assert _surface_kinds(st, "DP-2") == ["minimal-bar"];
    apply_output_detach(s, "DP-2");
    st2 = status_dict(s);
    assert _surface_kinds(st2, "DP-2") == [];
}


test "step F mode composition and rollback" {
    s = create_desktop("reference");
    bootstrap_reference_outputs(s);
    enter_mode(s, "presentation");
    enter_mode(s, "do-not-disturb");
    exit_mode(s, "presentation");
    st = status_dict(s);
    assert _surface_kinds(st, "HDMI-A-1") == ["full-bar"];
    assert st["routes"]["notification-popup"] is False;
    exit_mode(s, "do-not-disturb");
    st2 = status_dict(s);
    assert st2["routes"]["notification-popup"] is True;
}


test "step G explain queries are read-only" {
    s = create_desktop("reference");
    bootstrap_reference_outputs(s);
    ops_before = len(session_store().adapter_ops);
    why = why_dict("surface:HDMI-A-1/bar", s);
    aff = affected_by_dict("source:notifications", s);
    assert why["connector"] == "HDMI-A-1";
    assert ROUTE_NOTIF_HISTORY in aff["bindings"] or len(aff["bindings"]) >= 1;
    assert len(session_store().adapter_ops) == ops_before;
}


test "ipc graph commands" {
    create_desktop("reference");
    bootstrap_reference_outputs(get_desktop());
    r = handle_graph_command(["status"]);
    assert r["ok"] is True;
    r2 = handle_graph_command(["mode", "enter", "presentation"]);
    assert r2["ok"] is True;
    assert "presentation" in r2["data"]["modes"];
    r3 = handle_graph_command(["bogus"]);
    assert r3["ok"] is False;
}
