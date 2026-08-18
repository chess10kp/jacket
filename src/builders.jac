# builders.jac — LIBRARY: OSP authoring → live ViewNode graph → mount.
# ---------------------------------------------------------------------------
# Authors init widget nodes and chain typed edges (Child, Anchored). Structure
# is the OSP graph; mount_tree (end of @component) projects to GTK.
#
# Legacy sugar: child= / children= on init still works (edges + immediate mount
# for static nodes). Prefer edge chains in composition roots.
#
# Props/reactivity stay on node init — not walked on update (fine-grained).
import from src.reactive { effect, enter_scope, exit_scope, create_scope, Reactive, signal }
import from src.adapter_api { adapter }
import from src.osp { ViewNode, Child, Dispose, mount_child, set_child_order, sync_child_orders }
import from src.mount { mount_tree }


# ===========================================================================
# BUILDERS — construct the OSP graph. Each runs ONCE (fine-grained: components
# never re-run). Box/Label/Button wrap `element`.
# ===========================================================================
def element(tag: str, props: dict) -> ViewNode {
    n = ViewNode(tag=tag);
    n.widget = adapter().construct(tag, construct_props(tag, props));

    prev = enter_scope(n);
    try {
        apply_props(n, props);
        attach_children(n, props);
    } finally {
        exit_scope(prev);
    }
    return n;
}

def Box(**props: any)    -> ViewNode { return element("Box", props); }
def Label(**props: any)  -> ViewNode { return element("Label", props); }
def Button(**props: any) -> ViewNode { return element("Button", props); }
def Icon(**props: any)   -> ViewNode { return element("Icon", props); }
def Entry(**props: any)  -> ViewNode { return element("Entry", props); }
def Slider(**props: any) -> ViewNode { return element("Slider", props); }
def Window(**props: any) -> ViewNode { return element("Window", props); }

def construct_props(tag: str, props: dict) -> dict {
    out: dict = {};
    for (k, v) in props.items() {
        if adapter().is_construct_only(tag, k) { out[k] = v; }
    }
    return out;
}


# ---------------------------------------------------------------------------
# THE PROP RULE — classify by the value's SHAPE (except on_*). The entire
# reactive/static split; no compiler.
# ---------------------------------------------------------------------------
def apply_props(n: ViewNode, props: dict) {
    for (name, val) in props.items() {
        if name == "children" or name == "child" { continue; }
        # Record the `class` prop onto the node so the OSP query/restyle walkers
        # (osp.jac) can match on it without re-reading the widget. Only the
        # static/list form is snapshotted; a reactive class is left to its effect.
        if name == "class" and not isinstance(val, Reactive) and not callable(val) {
            n.set_classes(val);
        }
        if name.startswith("on_") {
            # EVENT CHANNEL — connect; register disconnect on current_scope (= n).
            hid = adapter().connect(n.widget, name, val);
            n.on_cleanup(lambda (w: any = n.widget, h: int = hid) { adapter().disconnect(w, h); });
        } elif isinstance(val, Reactive) {
            # REACTIVE — one small effect; reads val() -> subscribes -> patches.
            # default-arg capture: the loop rebinds name/val each iteration.
            effect(lambda (nm: any = name, v: any = val, w: any = n.widget) {
                adapter().set_prop(w, nm, v());
            });
        } elif callable(val) {
            # ESCAPE HATCH — a bare lambda for a gnarly expression.
            effect(lambda (nm: any = name, v: any = val, w: any = n.widget) {
                adapter().set_prop(w, nm, v());
            });
        } else {
            # STATIC — set once, no effect.
            if not adapter().is_construct_only(n.tag, name) {
                adapter().set_prop(n.widget, name, val);
            }
        }
    }
}


# ---------------------------------------------------------------------------
# CHILDREN — connect built child nodes with TYPED, ORDERED `Child` edges (OSP).
# Static list connects once; For/Show markers expand into live regions.
# ---------------------------------------------------------------------------
def attach_children(n: ViewNode, props: dict) {
    children = props.get("children");
    if children is None and props.get("child") is not None { children = [props["child"]]; }
    if children is None { return; }
    i = 0;
    for c in children {
        if isinstance(c, ForMarker) { expand_for(n, c); continue; }
        if isinstance(c, ShowMarker) { expand_show(n, c); continue; }
        # c is an already-built ViewNode (builders run eagerly, depth-first)
        n +>:Child(order=i):+> c;
        mount_child(n, c, i);
        i += 1;
    }
}


# ===========================================================================
# For — the ONLY keyed diff. Identity + position only; never content.
#   For(source, key=lambda (w) { w["id"]; }, row=lambda (w) { Button(...); })
# State is held on a ForState obj so the reconcile effect closes over a single
# stable binding (not loop-rebound names).
#
# LIVE CONTENT: rows are keyed and REUSED across reconciles, so a row's data
# must come from a reactive binding, not the row_fn snapshot. The For engine
# gives each row a per-row Signal (st.item_sig[k]); row_fn runs with that
# signal current, so a row can grab it via row_item() and derive:
#     row=lambda (w: dict) {
#         cur = row_item();                  # Signal of the CURRENT item for my key
#         return Button(class=cur.map(lambda (c) { "on" if c["active"] else "off"; }));
#     }
# The row_fn's `w` arg stays useful for keying + event closures (snapshots).
# ===========================================================================
obj ForMarker { has source: any = None; has key_fn: any = None; has row_fn: any = None; }
obj ForState {
    has parent: any = None;
    has marker: ForMarker = ForMarker();
    has rows: dict = {};         # key -> ViewNode (the row subtree root)
    has item_sig: dict = {};     # key -> Signal of the current item for that row
    has order: list = [];        # current key order, mirrors Child-edge order
}

# the per-row item signal currently being built (set during row_fn execution).
glob _row_item: any = None;

def row_item() -> any { return _row_item; }

def For(source: any, key: any, row: any) -> ForMarker {
    return ForMarker(source=source, key_fn=key, row_fn=row);
}

def expand_for(parent: ViewNode, m: ForMarker) {
    st = ForState(parent=parent, marker=m);
    effect(lambda { reconcile_list(st); });
}

def reconcile_list(st: ForState) {
    items = st.marker.source();                  # subscribe to the list
    new_keys: list = [st.marker.key_fn(it) for it in items];
    new_set: set = set(new_keys);

    # 1. MEMBERSHIP — remove dead rows, create new ones.
    for k in list(st.order) {
        if k not in new_set { remove_row(st, k); }
    }
    for i in range(len(new_keys)) {
        k = new_keys[i];
        if k not in st.rows { create_row(st, items[i], k, len(new_keys)); }
    }

    # 2. POSITION — for each desired slot, move the wanted row into place if it
    #    isn't already there. O(n) moves worst case; append/remove/prepend/
    #    middle-insert land in 0-1. (Two-ended/LIS min-move deferred — PLAN §8.)
    parent_w = st.parent.widget;
    for i in range(len(new_keys)) {
        view = st.rows[new_keys[i]];
        if adapter().child_at(parent_w, i) is not view.widget {
            move_row(st, view, i);
        }
    }
    sync_child_orders(st.parent, [st.rows[k] for k in new_keys]);

    # 3. CONTENT — surviving rows get their CURRENT item pushed through their
    #    per-row Signal. Equality cutoff skips identical items; each row's own
    #    effects patch only what changed. (The row_fn snapshot stays stale by
    #    design — live content reads row_item().)
    for i in range(len(new_keys)) {
        k = new_keys[i];
        if k in st.item_sig { st.item_sig[k].set(items[i]); }
    }

    st.order = list(new_keys);
}

# ---- the row ops (structure changes go through the adapter + OSP graph) ----
def create_row(st: ForState, item: any, k: any, pos: int) {
    sig = signal(item);                          # per-row item Signal
    prev = _row_item;
    _row_item = sig;
    view: any = None;
    try { view = st.marker.row_fn(item); }       # builds subtree; reads row_item()
    finally { _row_item = prev; }
    view.key = k;
    st.rows[k] = view;
    st.item_sig[k] = sig;
    st.parent +>:Child(order=pos):+> view;
    mount_child(st.parent, view, pos);
}

def remove_row(st: ForState, k: any) {
    view: ViewNode = st.rows.pop(k);
    st.item_sig.pop(k, None);
    if view is None { return; }
    view spawn Dispose();                     # WALKER: post-order teardown
    del view;                                 # drop the node + its Child edges
}

def move_row(st: ForState, view: ViewNode, pos: int) {
    set_child_order(st.parent, view, pos);
    adapter().move(st.parent.widget, view.widget, pos);
}


# ===========================================================================
# Show — conditional STRUCTURE primitive. Mounts `then` when cond is true,
# `else_` when false, disposing the other branch.
# ===========================================================================
obj ShowMarker { has cond: any = None; has then: any = None; has else_: any = None; }
obj ShowState {
    has parent: any = None;
    has cond: any = None;
    has then: any = None;
    has else_: any = None;
    has view: any = None;
    has shown: any = None;
}

def Show(cond: any, then: any, else_: any = None) -> ShowMarker {
    return ShowMarker(cond=cond, then=then, else_=else_);
}

def expand_show(parent: ViewNode, m: ShowMarker) {
    st = ShowState(parent=parent, cond=m.cond, then=m.then, else_=m.else_);
    effect(lambda { render_show(st); });
}

def render_show(st: ShowState) {
    want = bool(st.cond());
    if want == st.shown { return; }                  # no change
    if st.view is not None {
        old: ViewNode = st.view;
        old spawn Dispose();                     # tear down old branch
        st.view = None;
        del old;
    }
    branch = st.then if want else st.else_;
    if branch is not None {
        view = branch();
        st.view = view;
        st.shown = want;
        st.parent +>:Child(order=0):+> view;
        mount_child(st.parent, view, 0);
    } else {
        st.shown = want;
    }
}


# ===========================================================================
# @component — a run-ONCE factory. Body builds its subtree; free effect() calls
# in the body attach to a component-level scope tied to the returned root node,
# so unmounting the root stops its free effects too.
# ===========================================================================
# dispose_tree — tear down a whole subtree (stop its effects, disconnect its
# handlers) via the OSP Dispose walker. Used when a root is unmounted at runtime
# (e.g. a per-monitor bar whose monitor was unplugged). Structural children go
# with it; the caller destroys the GTK widget separately.
def dispose_tree(n: ViewNode) { n spawn Dispose(); }


def component(fn: any) -> any {
    def wrapped(*a: any, **kw: any) -> ViewNode {
        s = create_scope();
        prev = enter_scope(s);
        top: any = None;
        try { top = fn(*a, **kw); }
        finally { exit_scope(prev); }
        if top is not None {
            mount_tree(top);
            top.on_cleanup(s.dispose);
        }
        return top;
    }
    return wrapped;
}
