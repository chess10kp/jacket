# notification_route_tests.jac — Step D UI: popup route gates mount, not visibility.
import from src.mock_adapter { install_mock }
import from src.desktop { create_desktop, bootstrap_reference_outputs }
import from src.policy { enter_mode, exit_mode, popup_route_active }
import from src.builders { Box, Show, Window, Label }


def _popup_window() -> any {
    return Window(class="notif-layer", child=Label(text="popup"));
}

def _gated_popup() -> any {
    return Box(class="notif-route-gate", children=[
        Show(popup_route_active(), then=_popup_window),
    ]);
}


def _count_tag(ops: list, tag: str) -> int {
    n = 0;
    for op in ops {
        if op[0] == "construct" and op[1] == tag { n += 1; }
    }
    return n;
}


def _count_visible_ops(ops: list) -> int {
    n = 0;
    for op in ops {
        if op[0] == "set_prop" and (op[2] == "visible" or op[2] == "hidden") { n += 1; }
    }
    return n;
}


test "popup route suppression disposes notification layer" {
    m = install_mock();
    s = create_desktop("reference");
    bootstrap_reference_outputs(s);
    _gated_popup();
    assert _count_tag(m.ops, "Window") >= 1;
    n_before = len(m.ops);
    enter_mode(s, "presentation");
    windows_after_suppress = _count_tag(m.ops, "Window");
    assert _count_visible_ops(m.ops[n_before:]) == 0;
    exit_mode(s, "presentation");
    assert _count_tag(m.ops, "Window") > windows_after_suppress;
}
