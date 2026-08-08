# osp.jac — LIBRARY: structural substrate; the widget tree IS an OSP graph.
# ---------------------------------------------------------------------------
# PLAN §2: the structural tree = OSP. `node ViewNode` connected by a typed,
# ordered `edge Child`. Build/mount/dispose/query are WALKERS. The ViewNode is
# ALSO the reactive disposal scope (current_scope = the ViewNode being built),
# so there is ONE tree, torn down post-order by the Dispose walker — no
# parallel Owner tree. (Reactivity stays deliberately NON-OSP; see reactive.jac.)
#
# Corrected from the sketch: real Jac edge syntax `+>:Child(order=i):+>`,
# typed-edge reads `->:Child:->`, post-order `exit` abilities.
import from src.adapter_api { adapter }


# ---------------------------------------------------------------------------
# The persistent widget tree = the "fiber tree", for real.
# ---------------------------------------------------------------------------
node ViewNode {
    has tag: str;
    has widget: any = None;       # GTK handle (adapter owns its guts)
    has key: any = None;          # identity within a For (else None)
    has cleanups: list[any] = [];      # disconnect handlers / stop effects on dispose
    has classes: list[str] = [];  # CSS classes this node carries — the queryable
                                  # face of the `class` prop, recorded at build
                                  # time (via set_classes, from builders) so walkers can
                                  # match without re-reading the widget. Kept in
                                  # sync with the widget by add_class/remove_class.

    # SCOPE PROTOCOL: a ViewNode IS the reactive disposal scope. effect()/on_*
    # register teardown here; the Dispose walker runs them post-order.
    def on_cleanup(fn: any) { self.cleanups.append(fn); }

    # CLASS PROTOCOL — the small structural face of the `class` prop. Query is a
    # pure read of self.classes (no widget touch); mutation goes through the
    # adapter so the live GTK widget stays in step. This is what makes the
    # walkers below meaningful: a ViewNode remembers its own classes.
    def set_classes(val: any) { self.classes = parse_classes(val); }
    def has_class(c: str) -> bool { return c in self.classes; }
    def add_class(c: str) {
        if c not in self.classes {
            self.classes.append(c);
            if self.widget is not None { adapter().set_prop(self.widget, "class", self.classes); }
        }
    }
    def remove_class(c: str) {
        if c in self.classes {
            self.classes.remove(c);
            if self.widget is not None { adapter().set_prop(self.widget, "class", self.classes); }
        }
    }

    # NODE ABILITY: structural lifecycle, fired when the Dispose walker visits.
    # `exit` = post-order (children already disposed). OSP's event model.
    can teardown with Dispose exit {
        for fn in reversed(self.cleanups) { fn(); }
        if self.widget is not None {
            adapter().remove(self.widget);     # one-parent rule: unparent + destroy
        }
    }
}

# typed, ordered edge. order lives ON the edge (sibling position).
edge Child: ViewNode --> ViewNode {
    has order: int = 0;
}


# ===========================================================================
# WALKERS — the actual OSP. Mobile computations over the ViewNode graph.
# ===========================================================================

# DISPOSE — post-order teardown of a subtree. Spawned on a subtree root by
# unmount (For row removal, Show branch flip, window close). The textbook
# walker: descend first, then the ViewNode.teardown exit ability fires on the
# way out — leaves torn down before parents, no manual recursion.
walker Dispose {
    can descend with ViewNode entry {
        visit [here ->:Child:->];
    }
}

# COLLECT — gather nodes matching a predicate (e.g. all on monitor 2). A walker
# accumulates results as it traverses; full walk, no disengage. The end-user
# OSP payoff: query your OWN live widget graph with no framework re-render.
walker Collect {
    has pred: any = None;
    has found: list = [];
    can gather with ViewNode entry {
        if self.pred is not None and self.pred(here) { self.found.append(here); }
        visit [here ->:Child:->];
    }
}

# convenience: spawn Collect from `root_node`, return the matched nodes.
def collect(root_node: ViewNode, pred: any) -> list {
    w = Collect(pred=pred);
    root_node spawn w;
    return w.found;
}


# ===========================================================================
# THE §8a PAYOFF — spawn walkers over your OWN UI for cross-cutting ops.
# An author who HOLDS a component's returned ViewNode (components run once and
# hand back their root) can traverse it with the SAME OSP idiom the framework
# uses internally (Child edges + accumulating/transforming walkers) — no
# framework re-render, no parallel tree. Two ops proven here: query-by-class
# (read) and flash-all-X restyle (transform).
# ===========================================================================

# normalize a `class` prop value (space-separated str OR list) to a class list.
def parse_classes(val: any) -> list {
    if val is None { return []; }
    if isinstance(val, str) { return val.split(); }
    return list(val);
}

# QUERY-BY-CLASS — reuse the Collect machinery: a predicate over here.has_class.
# Returns every ViewNode in root's subtree that carries `cls`.
def query_by_class(root_node: ViewNode, cls: str) -> list {
    return collect(root_node, lambda (n: ViewNode) { n.has_class(cls); });
}

# RESTYLE — a transforming walker: over the subtree, for each node the predicate
# accepts, add and/or remove a CSS class (mutating both the node's `classes` and,
# via the adapter, the live widget). Accumulates touched nodes so callers can
# assert / count. This is the "flash-all-X" shape as a first-class walker.
walker Restyle {
    has pred: any = None;         # which nodes to touch (None = all)
    has add_cls: any = None;      # class to add on match (or None)
    has remove_cls: any = None;   # class to remove on match (or None)
    has touched: list = [];
    can apply with ViewNode entry {
        if self.pred is None or self.pred(here) {
            if self.add_cls is not None { here.add_class(self.add_cls); }
            if self.remove_cls is not None { here.remove_class(self.remove_cls); }
            self.touched.append(here);
        }
        visit [here ->:Child:->];
    }
}

# FLASH-ALL-X — add `flash_cls` to every node that already has `target_cls`.
# Returns the touched nodes. `unflash_class` is the inverse (remove `flash_cls`).
def flash_class(root_node: ViewNode, target_cls: str, flash_cls: str) -> list {
    w = Restyle(pred=lambda (n: ViewNode) { n.has_class(target_cls); }, add_cls=flash_cls);
    root_node spawn w;
    return w.touched;
}

def unflash_class(root_node: ViewNode, target_cls: str, flash_cls: str) -> list {
    w = Restyle(pred=lambda (n: ViewNode) { n.has_class(target_cls); }, remove_cls=flash_cls);
    root_node spawn w;
    return w.touched;
}
