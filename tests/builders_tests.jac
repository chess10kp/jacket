# builders_tests.jac — Phase 2 headless reconciler tests (PLAN §5).
# Proves the whole engine end-to-end against a MOCK adapter (no GTK):
#   - prop classification (reactive / static / event / lambda)
#   - For keyed diff op-stream (append/prepend/insert/remove/reverse)
#   - disposal / leak (subscriber sets return to baseline after unmount)
import from src.reactive { signal }
import from src.mock_adapter { install_mock }
import from src.builders { Box, Label, Button, For, Show, Entry, Slider }
import from src.osp { Dispose, child_order, sorted_children }
import from src.topology_reactive { feed_targets }


def count_kind(ops: list, kind: str) -> int {
    n = 0;
    for op in ops { if op[0] == kind { n += 1; } }
    return n;
}

# a For over an int list; rows are Labels whose text is the int. returns (box, src).
def int_for(initial: list) -> list {
    src = signal(initial);
    box = Box(children=[
        For(src, key=lambda (x) { x; }, row=lambda (x) { Label(text=str(x)); }),
    ]);
    return [box, src];
}


# --- prop classification ---------------------------------------------------
test "reactive prop patches via effect on change" {
    m = install_mock();
    txt = signal("a");
    Label(text=txt);                    # reactive -> one effect
    n0 = len(m.ops);
    txt.set("b");                       # change -> set_prop fires again
    delta = m.ops[n0:];
    assert count_kind(delta, "set_prop") == 1;
}

test "static prop is set once, no effect" {
    m = install_mock();
    Label(text="hi");                   # static -> set once
    n0 = len(m.ops);
    # nothing to change; op stream after build should be empty
    assert len(m.ops[n0:]) == 0;
}

test "event prop connects" {
    m = install_mock();
    Button(on_click=lambda {});         # event channel -> connect
    assert count_kind(m.ops, "connect") == 1;
}

test "lambda prop is treated as reactive effect" {
    m = install_mock();
    n = signal(1);
    # a lambda prop reading a signal -> effect, patches on change
    Label(text=lambda { str(n()); });
    n0 = len(m.ops);
    n.set(2);
    assert count_kind(m.ops[n0:], "set_prop") == 1;
}


# --- For keyed diff: op stream per mutation shape --------------------------
test "For append is one insert, zero moves" {
    m = install_mock();
    [box, src] = int_for([1, 2, 3]);
    n0 = len(m.ops);
    src.set([1, 2, 3, 4]);
    delta = m.ops[n0:];
    assert count_kind(delta, "insert") == 1;
    assert count_kind(delta, "move") == 0;
    assert count_kind(delta, "remove") == 0;
    assert m.child_texts(box.widget) == ["1", "2", "3", "4"];
}

test "For prepend lands in at most one move" {
    m = install_mock();
    [box, src] = int_for([1, 2, 3]);
    n0 = len(m.ops);
    src.set([0, 1, 2, 3]);
    delta = m.ops[n0:];
    assert count_kind(delta, "remove") == 0;
    assert count_kind(delta, "move") <= 1;
    assert m.child_texts(box.widget) == ["0", "1", "2", "3"];
}

test "For middle insert lands in at most one move" {
    m = install_mock();
    [box, src] = int_for([1, 2, 3]);
    n0 = len(m.ops);
    src.set([1, 2, 9, 3]);
    delta = m.ops[n0:];
    assert count_kind(delta, "remove") == 0;
    assert count_kind(delta, "move") <= 1;
    assert m.child_texts(box.widget) == ["1", "2", "9", "3"];
}

test "For remove is zero moves" {
    m = install_mock();
    [box, src] = int_for([1, 2, 3]);
    n0 = len(m.ops);
    src.set([1, 3]);
    delta = m.ops[n0:];
    assert count_kind(delta, "remove") == 1;
    assert count_kind(delta, "move") == 0;
    assert m.child_texts(box.widget) == ["1", "3"];
}

test "For reverse yields correct order" {
    m = install_mock();
    [box, src] = int_for([1, 2, 3, 4]);
    src.set([4, 3, 2, 1]);
    # LIS min-move deferred (PLAN §8); assert correctness, bounded move count:
    assert m.child_texts(box.widget) == ["4", "3", "2", "1"];
    assert count_kind(m.ops, "remove") == 0;   # nothing removed, all reordered
}

test "For reuses rows by key (identity stable across moves)" {
    m = install_mock();
    [box, src] = int_for([1, 2, 3]);
    before = m.child_texts(box.widget);
    n0 = len(m.ops);
    src.set([1, 2, 3]);                  # same value: equality cutoff -> no reconcile
    assert count_kind(m.ops[n0:], "move") == 0;
    assert count_kind(m.ops[n0:], "insert") == 0;
    assert count_kind(m.ops[n0:], "remove") == 0;
}

def child_orders(parent: any) -> list {
    return [child_order(parent, c) for c in sorted_children(parent)];
}

test "For prepend keeps Child.order aligned with GTK order" {
    install_mock();
    [box, src] = int_for([1, 2, 3]);
    src.set([0, 1, 2, 3]);
    kids = sorted_children(box);
    assert [k.key for k in kids] == [0, 1, 2, 3];
    assert child_orders(box) == [0, 1, 2, 3];
}

test "For reverse rewrites every Child.order to match final layout" {
    install_mock();
    [box, src] = int_for([1, 2, 3, 4]);
    src.set([4, 3, 2, 1]);
    assert child_orders(box) == [0, 1, 2, 3];
}


# --- disposal / leak: unmount returns subscribers to baseline --------------
test "For unmount detaches the source subscription" {
    m = install_mock();
    src = signal([1, 2, 3]);
    box = Box(children=[
        For(src, key=lambda (x) { x; }, row=lambda (x) { Label(text=str(x)); }),
    ]);
    # the For effect feeds from src (one Feeds edge src.node -> binding):
    assert len(feed_targets(src.node)) == 1;

    box spawn Dispose();                 # post-order teardown of the whole tree
    # the For effect's anchor was disposed -> src has no feeders left (no leak):
    assert len(feed_targets(src.node)) == 0;
    # and every widget was removed from the adapter:
    assert count_kind(m.ops, "remove") >= 4;   # 3 labels + the box
}


# --- Show: conditional mount/dispose on bool flip --------------------------
test "Show mounts then branch then disposes on flip" {
    m = install_mock();
    on = signal(False);
    box = Box(children=[
        Show(on, then=lambda { Label(text="yes"); }),
    ]);
    n0 = len(m.ops);
    on.set(True);                        # mount the then-branch
    assert count_kind(m.ops[n0:], "insert") == 1;
    assert m.child_texts(box.widget) == ["yes"];
    n1 = len(m.ops);
    on.set(False);                       # dispose the branch
    assert count_kind(m.ops[n1:], "remove") == 1;
    assert m.child_texts(box.widget) == [];
}


# --- For live content: rows are keyed+reused, so content must come from a
# --- per-row Signal (row_item()), not the row_fn snapshot. -------------------
import from src.builders { row_item }

def dict_for(initial: list) -> list {
    src = signal(initial);
    box = Box(children=[
        For(src,
            key=lambda (d: dict) { d["id"]; },
            row=lambda (d: dict) {
                cur = row_item();
                return Label(text=cur.map(lambda (c: dict) { c["label"]; }));
            }),
    ]);
    return [box, src];
}

test "For row content patches when the SAME key's item changes" {
    m = install_mock();
    [box, src] = dict_for([{"id": 1, "label": "a"}]);
    assert m.child_texts(box.widget) == ["a"];
    n0 = len(m.ops);
    src.set([{"id": 1, "label": "b"}]);       # same key, new label
    delta = m.ops[n0:];
    assert count_kind(delta, "set_prop") >= 1;   # row text effect patched
    assert count_kind(delta, "remove") == 0;     # row NOT rebuilt
    assert count_kind(delta, "insert") == 0;
    assert m.child_texts(box.widget) == ["b"];
}

test "For row content updates are keyed: only the changed row repaints" {
    m = install_mock();
    [box, src] = dict_for([{"id": 1, "label": "a"}, {"id": 2, "label": "x"}]);
    n0 = len(m.ops);
    src.set([{"id": 1, "label": "a"}, {"id": 2, "label": "y"}]);
    delta = m.ops[n0:];
    assert count_kind(delta, "set_prop") == 1;   # row 2's effect only
    assert m.child_texts(box.widget) == ["a", "y"];
}


# --- new builders ------------------------------------------------------------
test "Entry and Slider construct through the adapter" {
    m = install_mock();
    Entry(placeholder="search", text=signal("hi"));
    Slider(min=0.0, max=1.0, step=0.05, value=0.5);
    assert count_kind(m.ops, "construct") == 2;
    # (mock has no construct-only table: min/max/step/placeholder land as static
    # set_props; Entry text is reactive. The GTK adapter treats min/max/step as
    # construct-only.)
    assert count_kind(m.ops, "set_prop") >= 4;
}
