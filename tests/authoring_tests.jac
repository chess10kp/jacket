# authoring_tests.jac — OSP edge-chain authoring + mount_tree.
import from src.osp { ViewNode, Child, Anchored }
import from src.mock_adapter { install_mock }
import from src.builders { Button, Label, Box, Window, component }
import from src.mount { mount_tree }
import from src.overlays { anchored_panels, anchored_edges }


test "edge chain wires Child graph and mount inserts widgets" {
    m = install_mock();
    win = Window(class="bar");
    inner = Box(class="inner");
    win +>:Child(order=0):+> inner;
    inner +>:Child(order=0):+> Button(class="a", label="A");
    inner +>:Child(order=1):+> Label(text="B");
    mount_tree(win);
    assert m.child_tags(win.widget) == ["Box"];
    assert m.child_tags(inner.widget) == ["Button", "Label"];
}


test "Anchored edge on trigger mounts under component" {
    install_mock();
    @component
    def panel_bar() -> any {
        win = Window(class="bar");
        btn = Button(class="vol", label="50");
        btn +>:Anchored(mode="hover", position="bottom"):+> Box(class="panel");
        win +>:Child(order=0):+> btn;
        return win;
    }
    ui = panel_bar();
    kids = [ui ->:Child:->][?:ViewNode];
    assert len(kids) == 1;
    assert len(anchored_panels(kids[0])) == 1;
    assert anchored_edges(kids[0])[0].mode == "hover";
}
