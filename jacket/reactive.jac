# reactive.jac — LIBRARY: public reactive facade (T2 bridge over topology_reactive).
# ---------------------------------------------------------------------------
# signal/computed/effect retain the Phase 1 authoring surface; graph-native
# SourceNode/DerivedNode/BindingNode + Feeds edges live in topology_reactive.
# GTK-free; headless unit tests exercise both this facade and the OSP engine.
#
# Wrapper objects (Signal/Derived/Effect) track subscriber sets for the legacy
# API and tests; propagation, tri-state staleness, and flush batching delegate
# to the topology engine.
# ===========================================================================

import from jacket.topology_reactive {
    create_source, create_derived, create_binding, read_reactive, peek,
    source_set, dispose_owned, batch as topo_batch, flush, set_flush_hook
}

::py::
def _cmp_gt(a, b): return a > b
def _cmp_lt(a, b): return a < b
def _cmp_ge(a, b): return a >= b
def _cmp_le(a, b): return a <= b
::py::

glob CLEAN: int = 0;
glob CHECK: int = 1;
glob DIRTY: int = 2;

glob current_scope: any = None;


# ===========================================================================
# Reactive — wrapper base; each instance owns a graph node in topology_reactive.
# ===========================================================================
obj Reactive {
    has node: any = None;

    # Tracking lives in the topology engine (Feeds edges via the evaluation
    # context). The wrapper is a thin handle: a call is a tracked read.
    def __call__() -> any {
        return read_reactive(self.node);
    }

    # untracked read — the supported signal.value replacement (PLAN §4)
    def peek() -> any { return peek(self.node); }
    def _peek() -> any { return peek(self.node); }

    def map(fn: any) -> any { return computed(lambda { fn(self()); }); }

    def __mul__(o: any)      -> any { return computed(lambda { self() * _v(o); }); }
    def __rmul__(o: any)     -> any { return computed(lambda { _v(o) * self(); }); }
    def __add__(o: any)      -> any { return computed(lambda { self() + _v(o); }); }
    def __radd__(o: any)     -> any { return computed(lambda { _v(o) + self(); }); }
    def __sub__(o: any)      -> any { return computed(lambda { self() - _v(o); }); }
    def __rsub__(o: any)     -> any { return computed(lambda { _v(o) - self(); }); }
    def __truediv__(o: any)  -> any { return computed(lambda { self() / _v(o); }); }
    def __rtruediv__(o: any) -> any { return computed(lambda { _v(o) / self(); }); }
    def __floordiv__(o: any) -> any { return computed(lambda { self() // _v(o); }); }
    def __mod__(o: any)      -> any { return computed(lambda { self() % _v(o); }); }
    def __neg__()            -> any { return computed(lambda { -self(); }); }
    def __gt__(o: any)       -> any { return computed(lambda { _cmp_gt(self(), _v(o)); }); }
    def __lt__(o: any)       -> any { return computed(lambda { _cmp_lt(self(), _v(o)); }); }
    def __ge__(o: any)       -> any { return computed(lambda { _cmp_ge(self(), _v(o)); }); }
    def __le__(o: any)       -> any { return computed(lambda { _cmp_le(self(), _v(o)); }); }
}

def _v(o: any) -> any {
    if isinstance(o, Reactive) { return o(); }
    return o;
}

def _scope_reactive_owner() -> any {
    s = current_scope;
    if s is None { return None; }
    if not hasattr(s, "reactive_anchor") { return None; }
    if s.reactive_anchor is None {
        s.reactive_anchor = create_source(None);
        # Graph-native collective disposal: one cleanup walks the anchor's Owns
        # subtree and tears every scoped reactive node down (dispose_owned clears
        # Feeds + pops closures). ViewNode/Scope both run cleanups on dispose.
        s.on_cleanup(lambda {
            a = s.reactive_anchor;
            if a is not None {
                dispose_owned(a);
                s.reactive_anchor = None;
            }
        });
    }
    return s.reactive_anchor;
}


# ===========================================================================
# Signal — writable leaf backed by SourceNode.
# ===========================================================================
obj Signal(Reactive) {
    def set(v: any) { source_set(self.node, v); }
    def update(fn: any) { self.set(fn(self._peek())); }
}

def signal(initial: any) -> Signal {
    n = create_source(initial, owner=_scope_reactive_owner());
    return Signal(node=n);
}


# ===========================================================================
# Derived — read-only computed value backed by DerivedNode.
# ===========================================================================
obj Derived(Reactive) {
    has fn: any = None;
}

def computed(fn: any) -> Derived {
    d = Derived(fn=fn);
    d.node = create_derived(fn, owner=_scope_reactive_owner());
    return d;
}


# ===========================================================================
# Effect — side-effect leaf backed by BindingNode. Tracking is graph-native
# (Feeds edges); there are no subscriber/deps sets to clear.
# ===========================================================================
obj Effect {
    has fn: any = None;
    has node: any = None;
    has owned_by_anchor: bool = False;

    def run() { self.fn(); }
}

def effect(fn: any) -> Effect {
    owner = _scope_reactive_owner();
    e = Effect(fn=fn, owned_by_anchor=(owner is not None));
    e.node = create_binding(lambda { e.run(); }, owner=owner);
    if current_scope {
        current_scope.on_cleanup(lambda { dispose_effect(e); });
    }
    return e;
}

def dispose_effect(e: Effect) {
    # Anchored effects are torn down with their anchor (graph-native). Standalone
    # effects (no view anchor) dispose their own binding node here.
    if not e.owned_by_anchor and e.node is not None { dispose_owned(e.node); }
}


# ===========================================================================
# Scope — headless disposal unit (ViewNode provides the same protocol in osp).
# ===========================================================================
obj Scope {
    has children: list[any] = [];
    has cleanups: list[any] = [];

    def on_cleanup(fn: any) { self.cleanups.append(fn); }

    def dispose() {
        for c in self.children {
            # ViewNode children are torn down by the root ViewNode's Dispose walk;
            # only nested Scope units recurse here.
            if not hasattr(c, "tag") { c.dispose(); }
        }
        for fn in reversed(self.cleanups) { fn(); }
        self.children = [];
        self.cleanups = [];
    }
}

def create_scope() -> Scope { return Scope(); }

def with_scope(scope: any, fn: any) -> any {
    prev = enter_scope(scope);
    try { return fn(); }
    finally { exit_scope(prev); }
}

def enter_scope(scope: any) -> any {
    prev = current_scope;
    if prev is not None and hasattr(prev, "children") {
        prev.children.append(scope);
    }
    current_scope = scope;
    return prev;
}

def exit_scope(prev: any) { current_scope = prev; }

def on_scope_cleanup(fn: any) {
    if current_scope { current_scope.on_cleanup(fn); }
}


# ===========================================================================
# Ergonomic helpers
# ===========================================================================
def when(cond: any, a: any, b: any) -> any {
    return computed(lambda { _v(a) if _v(cond) else _v(b); });
}

def fmt(spec: str, src: any) -> any {
    return src.map(lambda (v: any) { spec.format(v) if "{" in spec else format(v, spec); });
}

def batch(fn: any) { topo_batch(fn); }
