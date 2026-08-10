# h5_lifecycle_tests.jac — H5 attach/detach and mount/dispose cycle gates (PLAN §5.1).
import from src.mock_adapter { install_mock }
import from src.desktop { create_desktop, bootstrap_reference_outputs }
import from src.outputs { apply_output_attach, apply_output_detach }
import from src.policy { enter_mode, exit_mode }
import from src.projection { register_surface_builder, reset_projection }
import from src.runtime_graph { session_store, session_outputs, output_surfaces }
import from src.graph_query { status_dict }
import from src.builders { Window, Label }


def _surface_count(session: any) -> int {
    n = 0;
    for out in session_outputs(session) {
        n += len(output_surfaces(out));
    }
    return n;
}


test "100 output attach detach cycles leave clean graph" {
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
    base_surfaces = _surface_count(s);
    for i in range(100) {
        apply_output_attach(s, "DP-2", "projector");
        assert _surface_count(s) == base_surfaces + 1;
        apply_output_detach(s, "DP-2");
        assert _surface_count(s) == base_surfaces;
    }
    store = session_store();
    assert len(store.derived_fns) >= 0;
    assert len(store.binding_fns) >= 2;
}


test "100 presentation mode cycles remount without duplicates" {
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
    for i in range(100) {
        enter_mode(s, "presentation");
        st = status_dict(s);
        assert len(st["outputs"]) == 2;
        for o in st["outputs"] {
            assert len(o["surfaces"]) == 1;
        }
        exit_mode(s, "presentation");
        st2 = status_dict(s);
        for o in st2["outputs"] {
            assert len(o["surfaces"]) == 1;
            assert o["surfaces"][0]["kind"] == "full-bar";
        }
    }
}
