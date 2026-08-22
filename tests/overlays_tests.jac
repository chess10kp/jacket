# overlays_tests.jac — Anchored-edge overlay graph (mock adapter).
import from jacket.osp { Child, Anchored, ViewNode }
import from jacket.mock_adapter { install_mock }
import from jacket.builders { Button, Label, Box, Window, component }
import from jacket.overlays { anchored_panels, anchored_edges }


def _panel() -> ViewNode {
    return Box(class="panel", children=[Label(text="panel")]);
}


test "Anchored edge on trigger records hover metadata" {
    install_mock();
    trigger = Button(class="trigger", label="vol");
    panel = _panel();
    trigger +>:Anchored(mode="hover", position="bottom"):+> panel;
    assert len(anchored_panels(trigger)) == 1;
    assert anchored_panels(trigger)[0] is panel;
    edges = anchored_edges(trigger);
    assert len(edges) == 1;
    assert edges[0].mode == "hover";
    assert edges[0].position == "bottom";
}


test "component mount wires chained bar graph" {
    m = install_mock();
    @component
    def mini() -> any {
        win = Window(class="bar");
        btn = Button(class="trigger", label="wifi");
        btn +>:Anchored(mode="click", position="top"):+> Box(class="panel");
        win +>:Child(order=0):+> btn;
        return win;
    }
    ui = mini();
    assert ui.tag == "Window";
    assert m.child_tags(ui.widget) == ["Button"];
}
