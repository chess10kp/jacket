# reactive_tests.jac — Phase 1 unit tests for the reactive engine + scheduler.
# GTK-free. These are the highest-value tests in the repo (PLAN §5): scheduler
# correctness (diamond, equality cutoff, write-loop), combinators, disposal.
import from src.reactive {
    signal, computed, effect, when, fmt, batch, with_scope, enter_scope, exit_scope,
    create_scope, flush, Reactive
}
import from src.topology_reactive { feed_targets }


# --- basic: a signal drives an effect -------------------------------------
test "signal drives effect and updates on set" {
    count = signal(0);
    seen: list = [];
    effect(lambda { seen.append(count()); });

    assert seen == [0];            # primed
    count.set(1);
    assert seen == [0, 1];
    count.set(2);
    assert seen == [0, 1, 2];
}

# --- derived chain recomputes transitively --------------------------------
test "derived chain recomputes transitively" {
    a = signal(10);
    b = computed(lambda { a() * 2; });
    c = computed(lambda { b() + 1; });      # 2a+1
    assert c() == 21;
    a.set(3);
    assert c() == 7;                        # 2*3+1
}

# --- equality cutoff: setting the same value runs nothing ------------------
test "equality cutoff stops propagation" {
    a = signal(5);
    runs: list = [0];
    effect(lambda { a(); runs[0] += 1; });
    assert runs[0] == 1;
    a.set(5);                               # unchanged -> no run
    assert runs[0] == 1;
    a.set(6);                               # changed -> one run
    assert runs[0] == 2;
}

# --- THE diamond: D fed by two paths from A recomputes EXACTLY once --------
#   A -> B -> D
#    \-> C --/^
test "asymmetric diamond recomputes D exactly once" {
    a = signal(1);
    b = computed(lambda { a() * 2; });
    c = computed(lambda { a() * 3; });
    d_runs: list = [0];
    d = computed(lambda { d_runs[0] += 1; b() + c() });   # counts its recomputes

    e_runs: list = [0];
    effect(lambda { d(); e_runs[0] += 1; });               # effect reads D

    assert d_runs[0] == 1;                  # D primed once
    assert e_runs[0] == 1;                  # effect primed once

    a.set(5);                               # synchronous flush
    # D recomputed exactly once more (not twice despite two paths), effect once:
    assert d_runs[0] == 2;
    assert e_runs[0] == 2;
    assert d() == 25;                       # 5*2 + 5*3
}

# factory: each call captures its OWN prev (avoids loop late-binding capture).
def step(prev: any) -> any { return computed(lambda { prev() + 1; }); }

# --- deep chain pulls in order, value consistent --------------------------
test "deep chain pulls in dependency order" {
    x = signal(1);
    d1 = step(x);
    d2 = step(d1);
    d3 = step(d2);
    d4 = step(d3);
    d5 = step(d4);
    assert d5() == 6;                       # 1 + 5
    x.set(10);
    assert d5() == 15;
}

# --- operators stay reactive and chainable --------------------------------
test "operator overloads derive reactively" {
    vol = signal(0.5);
    pct = vol * 100;                        # Derived
    loud = vol > 0.8;                       # Derived (via _cmp_gt)
    assert pct() == 50.0;
    assert loud() == False;
    vol.set(0.9);
    assert pct() == 90.0;
    assert loud() == True;
    vol.set(1.5);
    assert (vol + 1)() == 2.5;              # reactive+literal
}

# --- .map / when / fmt combinators ----------------------------------------
test "map when fmt combinators" {
    vol = signal(0.25);
    pct = vol.map(lambda (v) { f"{v:.0%}"; });
    assert pct() == "25%";
    muted = signal(False);
    cls = when(muted, "vol muted", "vol");
    assert cls() == "vol";
    muted.set(True);
    assert cls() == "vol muted";
    n = signal(3);
    label = fmt("n={}", n);
    assert label() == "n=3";
    n.set(42);
    assert label() == "n=42";
}

# --- batch: multiple writes commit one effect run -------------------------
test "batch groups writes into one flush" {
    a = signal(0);
    b = signal(0);
    runs: list = [0];
    effect(lambda { a(); b(); runs[0] += 1; });
    assert runs[0] == 1;
    batch(lambda {
        a.set(1);
        b.set(1);
        a.set(2);
    });
    assert runs[0] == 2;                    # one combined run, not three
}

# --- disposal: scope.dispose stops the effect (no more runs) --------------
test "scope disposal detaches effect" {
    a = signal(0);
    runs: list = [0];
    scope = create_scope();
    prev = enter_scope(scope);
    effect(lambda { a(); runs[0] += 1; });
    exit_scope(prev);
    assert runs[0] == 1;
    a.set(1);
    assert runs[0] == 2;
    scope.dispose();                        # teardown: effect unsubscribed
    a.set(2);
    assert runs[0] == 2;                    # no further runs
}

# --- re-entrant write loop converges to a raised error (backstop) ---------
test "write loop raises after flush cap" {
    a = signal(0);
    raised = False;
    try {
        effect(lambda { cur = a(); a.set(cur + 1); });   # effect writes its own dep
        assert False, "should have raised";
    } except RuntimeError {
        raised = True;
    }
    assert raised;
}

# --- no-op when no computation is tracking (peek is safe) ------------------
test "reading without tracking does not subscribe" {
    a = signal(7);
    # read inside NO evaluation -> no Feeds edge recorded (PLAN §3)
    val = a();
    assert val == 7;
    assert len(feed_targets(a.node)) == 0;
}
