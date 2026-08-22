# h5_hotplug_tests.jac — H5 hotplug edge cases (Change 7).
# ---------------------------------------------------------------------------
import from jacket.mock_adapter { install_mock }
import from jacket.desktop { create_desktop, bootstrap_reference_outputs }
import from jacket.outputs { apply_output_attach, apply_output_detach, list_outputs }
import from jacket.policy { enter_mode }
import from jacket.projection { register_surface_builder, reset_projection }
import from jacket.runtime_graph { session_store, session_outputs, output_surfaces }
import from jacket.graph_query { status_dict }
import from jacket.builders { Window, Label }


def _surface_kinds(st: dict, connector: str) -> list {
    for o in st["outputs"] {
        if o["connector"] == connector {
            return [s["kind"] for s in o["surfaces"]];
        }
    }
    return [];
}


test "repeated attach updates output role and reconciles surface" {
    install_mock();
    s = create_desktop("reference");
    bootstrap_reference_outputs(s);
    reset_projection();
    register_surface_builder("full-bar", lambda (c: str) {
        return Window(class="bar full", child=Label(text=c));
    });
    register_surface_builder("minimal-bar", lambda (c: str) {
        return Window(class="bar minimal", child=Label(text=c));
    });
    apply_output_attach(s, "DP-2", "unknown");
    st = status_dict(s);
    assert _surface_kinds(st, "DP-2") == ["full-bar"];
    apply_output_attach(s, "DP-2", "projector");
    enter_mode(s, "presentation");
    st2 = status_dict(s);
    assert _surface_kinds(st2, "DP-2") == ["minimal-bar"];
    for o in list_outputs(s) {
        if o.connector == "DP-2" { assert o.role == "projector"; }
    }
}


test "detach removes output subgraph with zero residue surfaces" {
    install_mock();
    s = create_desktop("reference");
    bootstrap_reference_outputs(s);
    reset_projection();
    register_surface_builder("full-bar", lambda (c: str) {
        return Window(class="bar", child=Label(text=c));
    });
    register_surface_builder("minimal-bar", lambda (c: str) {
        return Window(class="bar minimal", child=Label(text=c));
    });
    apply_output_attach(s, "DP-2", "projector");
    apply_output_detach(s, "DP-2");
    assert len([o for o in session_outputs(s) if o.connector == "DP-2"]) == 0;
    st = status_dict(s);
    assert _surface_kinds(st, "DP-2") == [];
}


test "session reset clears route_sources process-local registry" {
    install_mock();
    s1 = create_desktop("first");
    bootstrap_reference_outputs(s1);
    assert len(session_store().route_sources) == 2;
    s2 = create_desktop("second");
    bootstrap_reference_outputs(s2);
    assert len(session_store().route_sources) == 2;
    assert s2 is not s1;
}
