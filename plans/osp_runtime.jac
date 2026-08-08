# osp_runtime.jac  —  DESIGN SKETCH (real Jac / real OSP this time)
# ---------------------------------------------------------------------------
# CORRECTS two errors in the earlier sketches:
#   (1) closures are `lambda x:`, NOT Rust `|x|`.
#   (2) the STRUCTURAL layer is actual OSP — node archetypes, typed `Child`
#       edges, and WALKERS (visit/spawn/abilities) — not plain recursion.
#
# THE BOUNDARY (the thing I blurred before):
#   • Reactive layer  (Signal/Effect/dep-graph)  = plain objects, NOT OSP.
#       Hot path is O(1); a signal tick must NOT traverse. Walkers are the
#       wrong tool here, on purpose.
#   • Structural layer (the widget tree)          = OSP.
#       Build / mount / dispose / theme / query ARE graph traversals -> walkers.
#
# So OSP earns its keep exactly where you WALK the tree, and stays out of the
# per-tick path where walking would be a cost, not a feature.
#
# (Exact edge-connect punctuation `+>:Child:...:+>` varies by Jac version —
#  reconcile with the installed jaclang; the SEMANTICS are what matter here.)
# ===========================================================================


# ---------------------------------------------------------------------------
# The structural graph: a node archetype + a TYPED, ORDERED edge.
# This is the persistent widget tree = the "fiber tree", for real now.
# ---------------------------------------------------------------------------
node ViewNode {
    has tag: str;
    has widget: any = None;       # GTK handle (adapter owns its guts)
    has key: any = None;          # identity within a For (else None)
    has cleanups: list = [];      # disconnect handlers / stop effects on dispose

    # SCOPE PROTOCOL: a ViewNode IS the reactive disposal scope (this replaces
    # the old separate Owner tree). effect()/on_* register their teardown here
    # via currentScope.on_cleanup(...); the Dispose walker runs them post-order.
    def on_cleanup(fn: any) { self.cleanups.append(fn); }

    # a NODE ABILITY: structural lifecycle triggered when a walker visits.
    # This is OSP's event model — node + walker meeting fires code.
    can teardown with Dispose exit {
        # `exit` = post-order: children already disposed. `visitor` = the walker.
        for fn in reversed(self.cleanups) { fn(); }
        adapter.remove(self.widget);       # one-parent rule: unparent + destroy
    }
}

edge Child {
    has order: int = 0;           # sibling order lives ON the edge
}


# ---------------------------------------------------------------------------
# Construction (builders) CREATES the graph: spawn nodes, connect typed edges.
# Construction is not a traversal (there's nothing to walk yet) — it's plain
# code that emits node+edge structure. Walkers operate on it AFTER it exists.
# ---------------------------------------------------------------------------
def element(tag: str, props: dict) -> ViewNode {
    n = ViewNode(tag=tag);
    n.widget = adapter.construct(tag, construct_props(props));
    apply_props(n, props);                       # reactive/static/event, as before
    let i = 0;
    for child in normalize_children(props) {
        n +>:Child(order=i):+> child;            # TYPED, ORDERED edge (OSP)
        adapter.insert(n.widget, child.widget, i);
        i += 1;
    }
    return n;
}


# ===========================================================================
# WALKERS — the actual OSP. Each is a mobile computation over the ViewNode graph.
# ===========================================================================

# --- 1. DISPOSE — post-order teardown of a subtree. Spawned on a subtree root
#        by unmount (For row removal, Show branch flip, window close).
#        This is the textbook walker: descend, then act on the way out.
walker Dispose {
    can descend with ViewNode entry {
        visit [-->:Child:->];      # go to children FIRST (ordered edge traversal)
        # ViewNode.teardown (a node ability) fires on `exit`, i.e. post-order,
        # so leaves are torn down before their parents. No manual recursion.
    }
}
# usage:  subtree_root spawn Dispose();


# --- 2. APPLY_THEME — a cross-cutting pass. THIS is what OSP buys you that a
#        React fiber tree can't do natively: launch a walker that rewrites a
#        property across the entire live tree, no framework re-render.
walker ApplyTheme {
    has palette: dict;
    can style with ViewNode entry {
        css = self.palette.get(here.tag);
        if css { adapter.set_prop(here.widget, "css", css); }
        visit [-->:Child:->];
    }
}
# usage:  root spawn ApplyTheme(palette=dark_palette);


# --- 3. QUERY — collect nodes matching a predicate (e.g. all on monitor 2).
#        A walker accumulates results as it traverses; disengage-free full walk.
walker Collect {
    has pred: any;
    has found: list = [];
    can gather with ViewNode entry {
        if self.pred(here) { self.found.append(here); }
        visit [-->:Child:->];
    }
}
# usage:  w = Collect(pred=lambda n: n.tag == "Window");  root spawn w;  w.found;


# --- 4. MOUNT (optional split) — if build defers widget insertion, a Mount
#        walker attaches widgets in edge order. Shown to make the point that
#        even mounting is a traversal; in practice build+mount fuse (above).
walker Mount {
    can attach with ViewNode entry {
        for e in [edge -->:Child:->] {           # iterate edges to read order
            adapter.insert(here.widget, e.target.widget, e.order);
        }
        visit [-->:Child:->];
    }
}


# ===========================================================================
# WHERE THE For DIFF MEETS OSP
#   The keyed two-ended algorithm is plain list logic (correct — it's math, not
#   traversal). Its RESULTS act on the graph via OSP:
#     • create row -> build subtree (nodes + Child edges), connect into parent
#     • remove row -> `row_root spawn Dispose()`   (walker does the teardown)
#     • move row   -> rewrite the Child edge's `order` + adapter.move
#   So the diff decides WHAT changes; OSP walkers/edges are HOW structure changes.
# ===========================================================================


# ===========================================================================
# CORRECTED AUTHORING SYNTAX (real Jac lambdas — no Rust pipes)
# ===========================================================================
#
#   @component
#   def Workspaces() -> ViewNode {
#       return Box(class="workspaces", children=[
#           For(hypr.workspaces,
#               key = lambda w: w["id"],
#               row = lambda w: Button(
#                   class    = when(w["active"], "ws active", "ws"),
#                   child    = Label(text = str(w["idx"])),
#                   on_click = lambda: hypr.focus(w["id"]),
#               )),
#       ]);
#   }
#
#   # operators/.map/when/fmt still remove MOST lambdas from prop position:
#   Label(text = time.map(lambda t: strftime("%H:%M", t)))   # derive
#   Icon(hidden = battery.percent > 0.8)                     # operator, no lambda
#   Label(text = fmt("{:.0%}", audio.volume))                # helper, no lambda
#
# ===========================================================================
# HONEST SUMMARY OF THE FIX
#   Before: I claimed OSP but wrote recursion; used Rust closure syntax.
#   Now:  structural tree = `node ViewNode` + typed `edge Child`; lifecycle =
#         node abilities (`can teardown with Dispose exit`); build/mount/dispose/
#         theme/query = `walker`s using `visit [-->:Child:->]` and `spawn`.
#         Reactivity stays deliberately non-OSP for the O(1) hot path.
#   OSP's real payoff here: cross-cutting walkers (theme, query, debug-dump)
#   over a persistent, introspectable widget graph — something a hidden VDOM
#   fiber tree cannot expose. THAT is why this is a graph, not just a tree.
# ===========================================================================
