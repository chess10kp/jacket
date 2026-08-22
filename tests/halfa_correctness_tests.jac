# halfa_correctness_tests.jac — PLAN "first working slice" proofs (§2, §3, §4, §5).
# ---------------------------------------------------------------------------
# These exercise the OSP-native engine directly and assert the four guarantees
# the plan demands of the first slice:
#   §3 exact dynamic dependency diff  (conditional branch removes the stale edge)
#   §2 derived equality cutoff        (unchanged derived -> zero binding runs / writes)
#   §4 ownership disposal             (disposed binding never runs again)
#   §1 session reset                  (create_desktop leaves no stale graph nodes)
import from jacket.topology_reactive {
    create_source, create_derived, create_binding, read, source_set,
    feed_sources, feed_targets, dispose_owned, reset_engine_state
}
import from jacket.runtime_graph {
    reset_session_store, DesktopSession, session_outputs
}
import from jacket.mock_adapter { install_mock }
import from jacket.desktop { create_desktop, bootstrap_reference_outputs }
import from jacket.projection { register_surface_builder, reset_projection }
import from jacket.builders { Window, Label }


def _reset() {
    reset_session_store();
    reset_engine_state();
}

def _count_setprop(ops: list) -> int {
    n = 0;
    for op in ops { if op[0] == "set_prop" { n += 1; } }
    return n;
}


# --- §3 exact dynamic dependency diff --------------------------------------
# condition=true : binding reads A
# condition=false: binding reads B
# after switch  : A has no Feeds path to the binding, and writing A no longer runs it
test "conditional binding diff removes the stale Feeds edge" {
    _reset();
    cond = create_source(True);
    a = create_source(1);
    b = create_source(2);
    last: list = [0];
    binding = create_binding(lambda {
        c = read(cond);
        if c {
            last[0] = read(a);
        } else {
            last[0] = read(b);
        }
    });

    # cond=True branch taken: binding fed by cond + a, NOT b
    assert a in feed_sources(binding);
    assert b not in feed_sources(binding);

    # flip the branch: exact edge diff must drop a and add b
    source_set(cond, False);
    assert b in feed_sources(binding);
    assert a not in feed_sources(binding);     # A has no path to binding

    # writing A must no longer run the binding (edge gone)
    before = binding.runs;
    source_set(a, 999);
    assert binding.runs == before;
    assert last[0] != 999;

    # writing B DOES run the binding through the new edge
    source_set(b, 5);
    assert last[0] == 5;
}


# --- §2 derived equality cutoff --------------------------------------------
# source: 2 -> 4
# derived: source % 2 remains 0
# binding: zero runs        adapter: zero writes
# (and when the derived DOES change, the binding runs once — proving the cutoff
#  is on value-change, not a blanket suppress)
test "derived equality cutoff runs zero bindings when value unchanged" {
    _reset();
    m = install_mock();
    w = m.construct("Label", {});
    src = create_source(2);
    even = create_derived(lambda { read(src) % 2; });       # 2 % 2 == 0
    binding = create_binding(lambda {
        m.set_prop(w, "text", read(even));
    });

    writes_after_prime = _count_setprop(m.ops);             # prime wrote once
    assert writes_after_prime == 1;

    source_set(src, 4);                                     # 4 % 2 == 0 : unchanged
    assert _count_setprop(m.ops) == writes_after_prime;     # ZERO adapter writes
    assert binding.runs == 1;                               # ZERO new binding runs

    source_set(src, 5);                                     # 5 % 2 == 1 : changed
    assert _count_setprop(m.ops) == writes_after_prime + 1; # exactly one write
}


# --- §4 ownership disposal prevents future execution -----------------------
test "ownership disposal prevents future binding execution" {
    _reset();
    owner = create_source(None);          # Owns-subtree root (an anchor)
    src = create_source(0);
    runs: list = [0];
    b = create_binding(lambda {
        read(src);
        runs[0] += 1;
    }, owner=owner);                      # b Owned by the anchor

    before = runs[0];                     # primed once
    dispose_owned(owner);                 # graph-native teardown: b's closure + Feeds gone

    source_set(src, 5);                   # must NOT revive the disposed binding
    assert runs[0] == before;
}


# --- §1 session reset leaves no stale graph nodes --------------------------
test "create_desktop disposes the prior session graph (no stale nodes)" {
    install_mock();
    reset_projection();
    register_surface_builder("full-bar", lambda (c: str) {
        return Window(class="bar", child=Label(text=c));
    });
    register_surface_builder("minimal-bar", lambda (c: str) {
        return Window(class="bar", child=Label(text=c));
    });

    s1 = create_desktop("first");
    bootstrap_reference_outputs(s1);
    assert len([root -->][?:DesktopSession]) == 1;

    s2 = create_desktop("second");        # must dispose s1's whole runtime subgraph
    bootstrap_reference_outputs(s2);

    assert s2 is not s1;
    # the old session node is gone (not leaked under root):
    assert len([root -->][?:DesktopSession]) == 1;
    # the new session's outputs are intact:
    assert len(session_outputs(s2)) == 2;
}
