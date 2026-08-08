# builders.jac  —  DESIGN SKETCH (real Jac / OSP-consistent)
# ---------------------------------------------------------------------------
# The layer that turns the authoring surface into the live OSP widget graph and
# drives effect() for reactive props. Closes the loop:
#   author code -> builders -> ViewNode graph (typed Child edges) -> effects/For
#
# CONSISTENT WITH:
#   osp_runtime.jac  — `node ViewNode`, `edge Child`, walkers (Dispose, ...)
#   reactive_core.jac — Signal/Derived/Effect + `currentScope` (a ViewNode here)
#   scheduler.jac     — mark-stale + flush
#
# CORRECTED from the first draft:
#   • closures are `lambda x:`  (no Rust `|x|`)
#   • ViewNode/Child/Dispose come from osp_runtime — no local redefinition
#   • the disposal scope is the ViewNode itself (currentScope), not an Owner
#   • For remove = `spawn Dispose` (walker), move = rewrite Child edge order
#
# NOT here (walled-off seam): the PyGObject `adapter`. See adapter.jac.
# ===========================================================================


# ===========================================================================
# BUILDERS — construct the OSP graph. Box/Label/Button wrap `element`.
# Each runs ONCE (fine-grained: components never re-run).
# ===========================================================================

def element(tag: str, props: dict) -> ViewNode {
    n = ViewNode(tag=tag);
    n.widget = adapter.construct(tag, construct_props(tag, props));

    # n scopes ITS OWN prop-effects + event handlers: set currentScope = n while
    # we wire it, so effect()/on_* register their teardown on this node. The
    # Dispose walker later runs those cleanups post-order. (No Owner tree.)
    prev = currentScope;
    globals()["currentScope"] = n;
    try {
        apply_props(n, props);
        attach_children(n, props);
    } finally {
        globals()["currentScope"] = prev;
    }
    return n;
}

def Box(**props: any)    -> ViewNode { return element("Box", props); }
def Label(**props: any)  -> ViewNode { return element("Label", props); }
def Button(**props: any) -> ViewNode { return element("Button", props); }
def Icon(**props: any)   -> ViewNode { return element("Icon", props); }
def Window(**props: any) -> ViewNode { return element("Window", props); }

def construct_props(tag: str, props: dict) -> dict {
    # construct-only props (orientation, ...) must be set at construction time.
    return {k: v for k, v in props.items() if adapter.is_construct_only(tag, k)};
}


# ---------------------------------------------------------------------------
# THE PROP RULE — classify by the value's SHAPE (except on_*). The entire
# reactive/static split; no compiler. (This layer is intentionally NOT OSP —
# it's the O(1) leaf-binding path; walking would defeat fine-grained.)
# ---------------------------------------------------------------------------
def apply_props(n: ViewNode, props: dict) {
    for name, val in props.items() {
        if name in ("children", "child") { continue; }             # structural

        elif name.startswith("on_") {
            # EVENT CHANNEL — connect; register disconnect on currentScope (= n)
            hid = adapter.connect(n.widget, name, val);            # arity-adapted (R2)
            n.on_cleanup(lambda: adapter.disconnect(n.widget, hid));
        }

        elif isinstance(val, Reactive) {
            # REACTIVE — one small effect; reads val() -> subscribes -> patches.
            # effect() attaches its teardown to currentScope (= n) automatically.
            effect(lambda name=name, val=val:
                adapter.set_prop(n.widget, name, val()));
        }

        elif callable(val) {
            # ESCAPE HATCH — a bare lambda for a gnarly expression.
            effect(lambda name=name, val=val:
                adapter.set_prop(n.widget, name, val()));
        }

        else {
            # STATIC — set once, no effect.
            if not adapter.is_construct_only(n.tag, name) {
                adapter.set_prop(n.widget, name, val);
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
    if children == None and props.get("child") != None { children = [props["child"]]; }
    if children == None { return; }

    i = 0;
    for c in children {
        if isinstance(c, ForMarker)  { expand_for(n, c);  continue; }
        if isinstance(c, ShowMarker) { expand_show(n, c); continue; }   # R1
        # c is an already-built ViewNode (builders run eagerly, depth-first)
        n +>:Child(order=i):+> c;                       # OSP typed/ordered edge
        adapter.insert(n.widget, c.widget, i);
        i += 1;
    }
}


# ===========================================================================
# For — the ONLY keyed diff. Identity + position only; never content.
# Authoring:  For(hypr.workspaces, key=lambda w: w["id"], row=lambda w: Button(...))
# ===========================================================================

obj ForMarker { has source: any; has key_fn: any; has row_fn: any; }

def For(source: any, key: any, row: any) -> ForMarker {
    return ForMarker(source=source, key_fn=key, row_fn=row);
}

def expand_for(parent: ViewNode, m: ForMarker) {
    rows: dict = {};     # key -> ViewNode (the row subtree root)
    order: list = [];    # current key order, mirrors Child-edge order

    # The For is an effect on `source`: re-run the diff when the list changes.
    effect(lambda: reconcile_list(parent, m, rows, order));
}

def reconcile_list(parent: ViewNode, m: ForMarker, rows: dict, order: list) {
    items = m.source();                                  # subscribe to the list
    new_keys = [m.key_fn(it) for it in items];

    # keyed TWO-ENDED diff (append/prepend/insert/remove/reverse in 0-1 moves).
    old = order; os_ = 0; oe = len(old) - 1; ns = 0; ne = len(new_keys) - 1;
    new_order: list = [];
    while os_ <= oe and ns <= ne {
        if old[os_] == new_keys[ns] {
            new_order.append(old[os_]); os_ += 1; ns += 1;
        } elif old[oe] == new_keys[ne] {
            oe -= 1; ne -= 1;
        } elif old[os_] == new_keys[ne] {
            move_row(parent, rows[old[os_]], len(items) - 1);
            new_order.append(old[os_]); os_ += 1; ne -= 1;
        } elif old[oe] == new_keys[ns] {
            move_row(parent, rows[old[oe]], len(new_order));
            new_order.append(old[oe]); oe -= 1; ns += 1;
        } else {
            k = new_keys[ns];
            if k in rows { move_row(parent, rows[k], len(new_order)); }
            else { create_row(parent, m, items[ns], k, rows, len(new_order)); }
            new_order.append(k); ns += 1;
        }
    }
    while ns <= ne {
        create_row(parent, m, items[ns], new_keys[ns], rows, len(new_order));
        new_order.append(new_keys[ns]); ns += 1;
    }
    while os_ <= oe { remove_row(parent, rows, old[os_]); os_ += 1; }
    order.clear(); order.extend(new_order);
    # surviving rows' CONTENT is untouched — each row's own effects patch it.
}

# ---- the four row ops (structure changes go through OSP) --------------------
def create_row(parent: ViewNode, m: ForMarker, item: any, k: any, rows: dict, pos: int) {
    view = m.row_fn(item);                   # builds subtree; each node self-scopes
    view.key = k;
    rows[k] = view;
    parent +>:Child(order=pos):+> view;      # connect into the OSP graph
    adapter.insert(parent.widget, view.widget, pos);
}

def remove_row(parent: ViewNode, rows: dict, k: any) {
    view = rows.pop(k);
    view spawn Dispose();                    # WALKER: post-order teardown (osp_runtime)
    # (Dispose's teardown ability runs each node's cleanups + adapter.remove;
    #  the Child edge is dropped with the node.)
}

def move_row(parent: ViewNode, view: ViewNode, pos: int) {
    # rewrite the Child edge's order + the real GTK reorder. Minimizing these is
    # why the two-ended pass exists (LIS min-move deferred; see PLAN).
    child_edge(parent, view).order = pos;
    adapter.move(parent.widget, view.widget, pos);
}


# ===========================================================================
# Show — conditional STRUCTURE primitive (R1). Sibling of For: mounts `then`
# when cond is true, `else_` when false, disposing the other branch.
# ===========================================================================

obj ShowMarker { has cond: any; has then: any; has else_: any; }

def Show(cond: any, then: any, else_: any = None) -> ShowMarker {
    return ShowMarker(cond=cond, then=then, else_=else_);
}

def expand_show(parent: ViewNode, m: ShowMarker) {
    state: dict = {"view": None, "shown": None};    # current branch + its bool
    def render() {
        want = bool(m.cond());
        if want == state["shown"] { return; }        # no change
        if state["view"] != None {
            state["view"] spawn Dispose();           # tear down old branch (walker)
        }
        branch = m.then if want else m.else_;
        view = branch() if branch != None else None;
        state["view"] = view; state["shown"] = want;
        if view != None {
            parent +>:Child(order=0):+> view;
            adapter.insert(parent.widget, view.widget, 0);
        }
    }
    effect(render);                                  # re-run when cond flips
}


# ===========================================================================
# @component — a run-ONCE factory. Body builds its subtree; free effect() calls
# in the body attach to a component-level scope tied to the returned root node.
# ===========================================================================
def component(fn: any) -> any {
    def wrapped(*a: any, **kw: any) -> ViewNode {
        s = Scope();                                 # generic scope for FREE effects
        prev = currentScope;
        globals()["currentScope"] = s;
        try { root = fn(*a, **kw); }                 # nodes self-scope; free effects -> s
        finally { globals()["currentScope"] = prev; }
        root.on_cleanup(s.dispose);                  # root disposed -> free effects stop
        return root;
    }
    return wrapped;
}


# small helper: find the Child edge from parent to view (to rewrite order)
def child_edge(parent: ViewNode, view: ViewNode) -> Child {
    for e in [edge parent -->:Child:-> view] { return e; }
    return None;
}
