# mount.jac — LIBRARY: realize a wired ViewNode graph to GTK + popovers.
# ---------------------------------------------------------------------------
# Authors init nodes and chain typed edges; mount_tree spawns the Mount walker,
# which dispatches on outgoing edge archetype via register_edge_realizer.
import from jacket.osp {
    ViewNode, Mount, Dispose, Anchored,
    register_edge_realizer,
}
import from jacket.adapter { attach_hover_popover, attach_click_popover }


def realize_anchored_edges(source: ViewNode) {
    for panel in [source ->:Anchored:->][?:ViewNode] {
        for e in [edge source ->:Anchored:-> panel] {
            anchor = e.anchor if e.anchor is not None else source;
            if e.mode == "click" {
                cleanup = attach_click_popover(anchor.widget, panel.widget, e.position);
            } else {
                cleanup = attach_hover_popover(
                    anchor.widget,
                    panel.widget,
                    e.position,
                    e.show_delay_ms,
                    e.hide_delay_ms,
                );
            }
            if cleanup is not None {
                source.on_cleanup(cleanup);
            }
            source.on_cleanup(lambda (p: ViewNode = panel) { p spawn Dispose(); });
        }
    }
}

glob _anchored_realizer_installed: bool = False;

def _install_anchored_realizer() {
    if _anchored_realizer_installed { return; }
    _anchored_realizer_installed = True;
    register_edge_realizer(realize_anchored_edges, "Anchored");
}

def mount_tree(top: ViewNode) {
    _install_anchored_realizer();
    top spawn Mount();
}
