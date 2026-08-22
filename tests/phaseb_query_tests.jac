# phaseb_query_tests.jac — PLAN §6/I4 typed query guarantees (Change 6).
# ---------------------------------------------------------------------------
# Proves graph-native introspection: stable IDs, real edge paths, suppression
# provenance, read-only queries, and graph-default IPC routing.
import from jacket.desktop { create_desktop, bootstrap_reference_outputs, get_desktop }
import from jacket.graph_query {
    query_why_binding, query_affected_by, why_dict, affected_by_dict, status_dict
}
import from jacket.policy {
    enter_mode, exit_mode, policy_state,
    ROUTE_NOTIF_POPUP, ROUTE_NOTIF_HISTORY
}
import from jacket.runtime_graph { session_store }
import from jacket.ipc { ipc }
import json;


test "why query traces source route binding path with stable ids" {
    s = create_desktop("reference");
    bootstrap_reference_outputs(s);
    w = why_dict("binding:notification-popup", s);
    assert w["active"] is True;
    kinds = [p["kind"] for p in w["path"]];
    assert kinds == ["source", "route", "binding"];
    for p in w["path"] {
        assert p["runtime_id"] != "";
    }
    ps = policy_state();
    assert w["path"][0]["runtime_id"] == ps.notif_source.runtime_id;
    assert w["path"][1]["runtime_id"] == ps.popup_route.runtime_id;
    assert w["path"][2]["runtime_id"] == ps.popup_binding.runtime_id;
}


test "why query reports suppression provenance with mode id" {
    s = create_desktop("reference");
    bootstrap_reference_outputs(s);
    enter_mode(s, "presentation");
    w = why_dict("binding:notification-popup", s);
    assert w["active"] is False;
    assert "mode:presentation" in w["suppressed_by"];
    assert len(w["suppressed_by_modes"]) == 1;
    assert w["suppressed_by_modes"][0]["name"] == "presentation";
    assert w["suppressed_by_modes"][0]["mode_id"] != "";
}


test "affected-by returns route paths with binding ids" {
    s = create_desktop("reference");
    bootstrap_reference_outputs(s);
    a = affected_by_dict("source:notifications", s);
    assert ROUTE_NOTIF_HISTORY in a["bindings"];
    assert ROUTE_NOTIF_POPUP in a["bindings"];
    assert len(a["routes"]) == 2;
    for entry in a["routes"] {
        assert entry["runtime_id"] != "";
        assert len(entry["bindings"]) == 1;
    }
    # presentation suppresses popup feed but history remains
    enter_mode(s, "presentation");
    a2 = affected_by_dict("source:notifications", s);
    assert ROUTE_NOTIF_HISTORY in a2["bindings"];
    assert ROUTE_NOTIF_POPUP not in a2["bindings"];
}


test "typed query functions match dict seam" {
    s = create_desktop("reference");
    bootstrap_reference_outputs(s);
    r = query_why_binding(s, ROUTE_NOTIF_POPUP);
    d = why_dict("binding:notification-popup", s);
    assert d["target"] == r.target;
    assert d["active"] == r.active;
    assert d["path"] == r.path;
}


test "explain queries are read-only" {
    s = create_desktop("reference");
    bootstrap_reference_outputs(s);
    enter_mode(s, "presentation");
    ops_before = len(session_store().adapter_ops);
    why_dict("binding:notification-popup", s);
    affected_by_dict("source:notifications", s);
    status_dict(s);
    assert len(session_store().adapter_ops) == ops_before;
}


test "ipc routes graph commands by default" {
    create_desktop("reference");
    bootstrap_reference_outputs(get_desktop());
    out = ipc().handle(["status"]);
    data = json.loads(out);
    assert data["ok"] is True;
    assert data["data"]["session_id"] != "";
    assert len(data["data"]["outputs"]) == 2;
    mode_out = ipc().handle(["mode", "enter", "presentation", "--json"]);
    mode_data = json.loads(mode_out);
    assert mode_data["ok"] is True;
    assert "presentation" in mode_data["data"]["modes"];
    bad = ipc().handle(["bogus"]);
    assert bad == "unknown command: bogus";
}
