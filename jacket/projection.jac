# projection.jac — SurfaceNode → ViewNode via Renders (T2 step 3).
# ---------------------------------------------------------------------------
import from jacket.runtime_graph { SurfaceNode, Renders, trace_adapter, session_outputs, output_surfaces }
import from jacket.osp { ViewNode }
import from jacket.builders { dispose_tree }


glob _builders: dict = {};

def reset_projection() { _builders = {}; }

def register_surface_builder(kind: str, build_fn: any) {
    _builders[kind] = build_fn;
}

def surface_views(sn: SurfaceNode) -> list[ViewNode] {
    return [sn ->:Renders:->][?:ViewNode];
}

def dispose_surface_views(sn: SurfaceNode) {
    for v in list(surface_views(sn)) {
        trace_adapter("view_dispose:" + str(sn.connector));
        dispose_tree(v);
        for e in [edge sn ->:Renders:-> v] { del e; }
        del v;
    }
}

def mount_surface_view(sn: SurfaceNode) -> any {
    fn = _builders.get(sn.kind);
    if fn is None { return None; }
    view = fn(sn.connector);
    if view is None { return None; }
    sn +>:Renders:+> view;
    trace_adapter("view_mount:" + str(sn.connector) + ":" + sn.kind);
    return view;
}

def present_surface_views(session: any) {
    for out in session_outputs(session) {
        for sn in output_surfaces(out) {
            for v in surface_views(sn) {
                w = v.widget;
                if w is not None and hasattr(w, "present") {
                    w.present();
                }
            }
        }
    }
}
