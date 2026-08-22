# topology_reactive_tests.jac — T1 OSP reactive feasibility spike acceptance tests.
import from jacket.runtime_graph { reset_session_store, session_store }
import from jacket.topology_reactive {
    create_source, create_derived, create_binding, read, source_set,
    route_connect, route_disconnect, propagate_from, dispose_owned,
    feed_sources, reset_engine_state, CLEAN, DIRTY, SourceNode
}


def _reset() {
    reset_session_store();
    reset_engine_state();
}


test "source drives binding through feeds" {
    _reset();
    src = create_source(1);
    runs: list = [0];
    b = create_binding(lambda { runs[0] = read(src); });
    route_connect(src, b);
    source_set(src, 5);
    assert runs[0] == 5;
    assert b.runs >= 1;
}

test "route disconnect stops binding delivery" {
    _reset();
    src = create_source(0);
    runs: list = [0];
    b = create_binding(lambda { runs[0] += 1; read(src); });
    route_connect(src, b);
    source_set(src, 1);
    before = b.runs;
    route_disconnect(src, b);
    source_set(src, 2);
    assert b.runs == before;
}

test "route reconnect restores delivery without rebuild" {
    _reset();
    src = create_source(0);
    seen: list = [];
    b = create_binding(lambda { seen.append(read(src)); });
    route_connect(src, b);
    source_set(src, 1);
    route_disconnect(src, b);
    source_set(src, 2);
    route_connect(src, b);
    source_set(src, 3);
    assert seen[-1] == 3;
}

test "diamond derived executes once per propagation" {
    _reset();
    a = create_source(1);
    b = create_derived(lambda { read(a) * 2; });
    c = create_derived(lambda { read(a) * 3; });
    d_runs: list = [0];
    d = create_derived(lambda {
        d_runs[0] += 1;
        return read(b) + read(c);
    });
    assert d_runs[0] == 1;
    assert read(d) == 5;
    source_set(a, 5);
    assert read(d) == 25;
    assert d_runs[0] == 2;
    source_set(a, 10);
    assert read(d) == 50;
    assert d_runs[0] == 3;
}

def _make_chain(idx: int) -> dict {
    s = create_source(idx);
    acc: list = [0];
    b = create_binding(lambda { acc[0] = read(s); });
    route_connect(s, b);
    return {"src": s, "acc": acc};
}


test "100 independent roots isolation" {
    _reset();
    roots: list = [];
    for i in range(100) {
        roots.append(_make_chain(i));
    }
    target = roots[50] as dict;
    source_set(target["src"] as SourceNode, 999);
    for (j, raw_item) in enumerate(roots as list) {
        item = raw_item as dict;
        if j == 50 {
            assert (item["acc"] as list)[0] == 999;
        } else {
            assert (item["acc"] as list)[0] == j;
        }
    }
}

test "stable update creates zero new feeds edges" {
    _reset();
    src = create_source(5);
    d = create_derived(lambda { read(src); });
    before = len(feed_sources(d));
    source_set(src, 5);
    after = len(feed_sources(d));
    assert before == after;
}

test "dispose removes owned reactive residue" {
    _reset();
    owner = create_source(0);
    child = create_derived(lambda { read(owner); }, owner=owner);
    b = create_binding(lambda { read(child); }, owner=owner);
    route_connect(child, b);
    dispose_owned(owner);
    store = session_store();
    assert len(store.derived_fns) == 0;
    assert len(store.binding_fns) == 0;
}
