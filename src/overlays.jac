# overlays.jac — LIBRARY: Anchored-edge popover helpers (query only).
# ---------------------------------------------------------------------------
# Authors chain: trigger +>:Anchored(mode="hover", ...):+> panel
# mount_tree (src/mount.jac) spawns Mount, which dispatches typed-edge realizers.
import from src.osp { ViewNode, Anchored }


def anchored_panels(anchor: ViewNode) -> list {
    return [anchor ->:Anchored:->][?:ViewNode];
}


def anchored_edges(anchor: ViewNode) -> list {
    out: list = [];
    for p in anchored_panels(anchor) {
        for e in [edge anchor ->:Anchored:-> p] { out.append(e); }
    }
    return out;
}
