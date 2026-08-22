# osp_walker_tests.jac — the §8a payoff, tested headless against the MOCK
# adapter. Build a real ViewNode tree via the builders, then spawn the OSP
# query/restyle walkers over it and assert. No GTK.
import from jacket.reactive { signal }
import from jacket.mock_adapter { install_mock }
import from jacket.builders { Box, Label, Button, dispose_tree }
import from jacket.osp { ViewNode, query_by_class, flash_class, unflash_class, Restyle, collect }
import from jacket.runtime_graph { reset_session_store, session_store }


def count_kind(ops: list, kind: str) -> int {
    n = 0;
    for op in ops { if op[0] == kind { n += 1; } }
    return n;
}

# a small nested tree: a toolbar box with two `.action` buttons + a `.hint`
# label, plus a nested box holding one more `.action`. Returns the ui node.
def toolbar() -> ViewNode {
    return Box(class="toolbar", children=[
        Button(class="btn action", label="Save"),
        Button(class="btn action", label="Open"),
        Label(class="hint", text="ready"),
        Box(class="group", children=[
            Button(class="btn action", label="Close"),
        ]),
    ]);
}


# --- class recording ---------------------------------------------------------
test "static class prop is recorded on the ViewNode" {
    install_mock();
    n = Button(class="btn action", label="x");
    assert n.classes == ["btn", "action"];
    assert n.has_class("action");
    assert not n.has_class("nope");
}

test "no class prop leaves classes empty" {
    install_mock();
    n = Label(text="x");
    assert n.classes == [];
    assert not n.has_class("action");
}


# --- query-by-class (reuses Collect) ----------------------------------------
test "query_by_class finds every matching node across the subtree" {
    install_mock();
    ui = toolbar();
    hits = query_by_class(ui, "action");
    assert len(hits) == 3;               # 2 top-level + 1 nested
    for h in hits { assert h.has_class("action"); }
}

test "query_by_class returns empty for an absent class" {
    install_mock();
    ui = toolbar();
    assert query_by_class(ui, "ghost") == [];
}

test "query_by_class matches the ui node itself" {
    install_mock();
    ui = toolbar();
    assert len(query_by_class(ui, "toolbar")) == 1;
}


# --- flash-all-X restyle -----------------------------------------------------
test "flash_class adds a class to every match and reports them" {
    install_mock();
    ui = toolbar();
    touched = flash_class(ui, "action", "flash");
    assert len(touched) == 3;
    for t in touched { assert t.has_class("flash"); }
    # the query now sees the freshly-painted class too
    assert len(query_by_class(ui, "flash")) == 3;
}

test "flash_class pushes a set_prop to the widget for each match" {
    m = install_mock();
    ui = toolbar();
    n0 = len(m.ops);
    flash_class(ui, "action", "flash");
    # 3 matches -> 3 class set_props on the live widgets
    assert count_kind(m.ops[n0:], "set_prop") == 3;
}

test "unflash_class removes the class from every match" {
    install_mock();
    ui = toolbar();
    flash_class(ui, "action", "flash");
    unflash_class(ui, "action", "flash");
    assert query_by_class(ui, "flash") == [];
}

test "add_class is idempotent — no duplicate class, no extra set_prop" {
    m = install_mock();
    ui = toolbar();
    flash_class(ui, "action", "flash");
    n0 = len(m.ops);
    flash_class(ui, "action", "flash");     # already flashed
    assert count_kind(m.ops[n0:], "set_prop") == 0;
    hits = query_by_class(ui, "action");
    for h in hits { assert h.classes.count("flash") == 1; }
}


# --- the Restyle walker directly (predicate = None touches all) --------------
test "Restyle with no predicate touches every node in the subtree" {
    install_mock();
    ui = toolbar();
    w = Restyle(add_cls="seen");
    ui spawn w;
    # 1 toolbar + 2 buttons + 1 label + 1 group box + 1 nested button = 6
    assert len(w.touched) == 6;
    assert len(query_by_class(ui, "seen")) == 6;
}


test "dispose_tree clears owned binding nodes" {
    reset_session_store();
    install_mock();
    vol = signal(0.5);
    ui = Label(label=vol);
    dispose_tree(ui);
    assert len(session_store().binding_fns) == 0;
}
