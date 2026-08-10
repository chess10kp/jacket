# t2_selectivity_tests.jac — T2 step B: fine-grained update selectivity (PLAN §5.2).
import from src.reactive { signal }
import from src.mock_adapter { install_mock }
import from src.builders { Box, Label, Window }
import from src.runtime_graph { reset_session_store, session_store }
import from src.projection {
    register_surface_builder, surface_views, reset_projection
}
import from src.runtime_graph { session_outputs, output_surfaces }
import from src.policy { enter_mode }
import from src.desktop { create_desktop, bootstrap_reference_outputs }


def _count_ops(ops: list, kind: str) -> int {
    n = 0;
    for op in ops { if op[0] == kind { n += 1; } }
    return n;
}


test "step B clock tick patches one label without structural mutation" {
    reset_session_store();
    m = install_mock();
    clk = signal("12:00");
    idle = signal("idle");
    ui = Box(children=[
        Label(text=clk),
        Label(text=idle),
    ]);
    constructs = _count_ops(m.ops, "construct");
    runs_before = session_store().visit_counts.get("binding_run", 0);
    props_before = _count_ops(m.ops, "set_prop");
    clk.set("12:01");
    runs_after = session_store().visit_counts.get("binding_run", 0);
    props_after = _count_ops(m.ops, "set_prop");
    assert runs_after == runs_before + 1;
    assert props_after == props_before + 1;
    assert _count_ops(m.ops, "construct") == constructs;
}


test "reconcile remounts view on surface kind change" {
    reset_session_store();
    install_mock();
    s = create_desktop("reference");
    reset_projection();
    register_surface_builder("full-bar", lambda (c: str) {
        return Window(class="bar full", child=Label(text=c));
    });
    register_surface_builder("minimal-bar", lambda (c: str) {
        return Window(class="bar minimal", child=Label(text=c));
    });
    bootstrap_reference_outputs(s);
    for out in session_outputs(s) {
        if out.connector == "HDMI-A-1" {
            for sn in output_surfaces(out) {
                views = surface_views(sn);
                assert len(views) == 1;
                assert views[0].classes == ["bar", "full"];
            }
        }
    }
    enter_mode(s, "presentation");
    for out in session_outputs(s) {
        if out.connector == "HDMI-A-1" {
            for sn in output_surfaces(out) {
                assert sn.kind == "minimal-bar";
                views = surface_views(sn);
                assert len(views) == 1;
                assert views[0].classes == ["bar", "minimal"];
            }
        }
    }
}
