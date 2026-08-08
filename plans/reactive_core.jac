# reactive_core.jac  —  DESIGN SKETCH (illustrative pseudo-Jac)
# ---------------------------------------------------------------------------
# The fine-grained reactive primitive for the Jac/GTK shell.
# Goal of this file: show the SHAPE of the signal type + operator overloads
# + .map so you can judge how terse the authoring surface lands.
#
# Scope: reactive core ONLY (signal / derived / effect / owner + combinators).
# NOT here (separate pieces, by design):
#   - the scheduler/flush loop (mark-stale + pull, diamond fix, idle_add batching)
#   - the GTK adapter (set_prop, widget construction, the ugly PyGObject seam)
#   - the builders (Box/Label/...) and the `For` keyed diff
#
# Tokens/keywords are illustrative — reconcile with real Jac spelling later.
# The CONTRACT is what matters: everything callable is reactive; operators and
# .map return NEW reactive nodes; you never type `lambda` for simple cases.
# ===========================================================================


# ---------------------------------------------------------------------------
# Global tracking state
#   currentComputation : the effect/derived currently running, so signal reads
#                        know who to subscribe. A stack (nested effects).
#   currentOwner       : the disposal scope new reactives attach to.
# These are the entire "magic" of fine-grained reactivity.
# ---------------------------------------------------------------------------
glob currentComputation: list = [];   # stack of running computations
glob currentScope: any = None;        # disposal scope: a Scope (headless) or a
                                      # ViewNode (real tree). Both provide on_cleanup.


# ---------------------------------------------------------------------------
# Scope — the disposal unit (GENERIC / headless).
# Every effect runs inside a scope. Cleanups registered during its run are torn
# down (children first) on dispose. Used directly in headless reactive tests.
#
# IN THE REAL WIDGET TREE the scope is a `ViewNode` (osp_runtime.jac), which
# provides the SAME `on_cleanup(fn)` protocol and is torn down post-order by the
# `Dispose` WALKER via its `teardown` node-ability. So there is ONE tree (the
# OSP node graph), NOT a parallel owner tree — disposal is OSP. `Scope` below is
# just the generic stand-in the core uses when no widget graph is present.
# ---------------------------------------------------------------------------
obj Scope {
    has children: list = [];      # sub-scopes, disposed first
    has cleanups: list = [];      # fns run on dispose (disconnect signals, timers)

    def on_cleanup(fn: any) { self.cleanups.append(fn); }

    def dispose() {
        # children first (leaves up), then our own cleanups
        for c in self.children { c.dispose(); }
        for fn in reversed(self.cleanups) { fn(); }
        self.children = [];
        self.cleanups = [];
    }
}


# ---------------------------------------------------------------------------
# Reactive — common base for Signal and Derived.
# It is CALLABLE: `x()` reads the value AND subscribes the current computation.
# All the ergonomic sugar (operators, .map) lives here, so both writable
# signals and derived values get it for free.
# ---------------------------------------------------------------------------
obj Reactive {
    has subscribers: set = {};    # computations depending on this node

    # --- read + track -------------------------------------------------------
    def __call__() -> any {
        if currentComputation {
            comp = currentComputation[-1];
            self.subscribers.add(comp);
            comp.deps.add(self);      # so the effect can clear us on re-run
        }
        return self._peek();          # subclass supplies the raw value
    }

    def _peek() -> any { }            # override: raw value, no tracking

    def _notify() {
        # hand dirty subscribers to the scheduler (separate module).
        # Sketch: eager for readability; real impl marks-stale then pulls.
        for comp in list(self.subscribers) { schedule(comp); }
    }

    # --- combinator: the escape hatch for anything operators can't express --
    # vol.map(lambda v: f"{v:.0%}")  -> a Derived that re-runs the fn reactively
    def map(fn: any) -> Derived {
        return computed(lambda: fn(self()));
    }

    # --- operator overloads: simple derivations stay reactive, no lambda -----
    # `vol * 100` -> Derived(lambda: vol() * 100). Chainable (Derived is Reactive).
    def __mul__(o: any)  -> Derived { return computed(lambda: self() * _v(o)); }
    def __rmul__(o: any) -> Derived { return computed(lambda: _v(o) * self()); }
    def __add__(o: any)  -> Derived { return computed(lambda: self() + _v(o)); }
    def __radd__(o: any) -> Derived { return computed(lambda: _v(o) + self()); }
    def __sub__(o: any)  -> Derived { return computed(lambda: self() - _v(o)); }
    def __truediv__(o: any) -> Derived { return computed(lambda: self() / _v(o)); }
    def __gt__(o: any)   -> Derived { return computed(lambda: self() > _v(o)); }
    def __lt__(o: any)   -> Derived { return computed(lambda: self() < _v(o)); }
    def __ge__(o: any)   -> Derived { return computed(lambda: self() >= _v(o)); }
    def __le__(o: any)   -> Derived { return computed(lambda: self() <= _v(o)); }
    def __eq__(o: any)   -> Derived { return computed(lambda: self() == _v(o)); }
    def __neg__()        -> Derived { return computed(lambda: -self()); }
    # NOTE: no __str__/__format__ override — f-strings must return a real str,
    # so string building goes through .map (see authoring examples below).
}

# unwrap: allow operators to mix signals with plain values or other signals.
def _v(o: any) -> any {
    return o() if isinstance(o, Reactive) else o;
}


# ---------------------------------------------------------------------------
# Signal — the writable leaf. `count = signal(0)`.
# read: count()   write: count.set(3)  or  count.update(lambda n: n+1)
# ---------------------------------------------------------------------------
obj Signal(Reactive) {
    has value: any;

    def _peek() -> any { return self.value; }

    def set(v: any) {
        if v != self.value {
            self.value = v;
            self._notify();
        }
    }
    def update(fn: any) { self.set(fn(self.value)); }
}

def signal(initial: any) -> Signal {
    return Signal(value=initial);
}


# ---------------------------------------------------------------------------
# Derived — read-only reactive computed from other reactives.
# Produced by operators, .map, or computed(). Recomputes when its deps change.
# (Sketch recomputes eagerly on notify; real version is lazy pull + cached.)
# ---------------------------------------------------------------------------
obj Derived(Reactive) {
    has fn: any;
    has cached: any = None;
    has deps: set = {};       # reactives THIS node reads (cleared each run)

    def _peek() -> any { return self.cached; }

    def _recompute() {
        # clear old dep links, re-run under tracking, notify our own subscribers
        for d in self.deps { d.subscribers.discard(self); }
        self.deps = {};
        currentComputation.append(self);
        try { new = self.fn(); }
        finally { currentComputation.pop(); }
        if new != self.cached {
            self.cached = new;
            self._notify();
        }
    }
}

def computed(fn: any) -> Derived {
    d = Derived(fn=fn);
    d._recompute();           # prime it so _peek has a value + deps registered
    return d;
}


# ---------------------------------------------------------------------------
# effect — a computation run for its SIDE EFFECT (e.g. a prop binding).
# This is the bridge to the widget tree: a reactive prop compiles to
#   effect(lambda: adapter.set_prop(node, "label", text()))
# Auto-tracks deps; re-runs when any read changes; owner-scoped for cleanup.
# ---------------------------------------------------------------------------
obj Effect {
    has fn: any;
    has deps: set = {};

    def run() {
        for d in self.deps { d.subscribers.discard(self); }
        self.deps = {};
        currentComputation.append(self);
        try { self.fn(); }
        finally { currentComputation.pop(); }
    }
}

def effect(fn: any) -> Effect {
    e = Effect(fn=fn);
    if currentScope {
        # dispose = stop tracking this effect when the scope (Scope or ViewNode)
        # tears down. Same on_cleanup protocol either way.
        currentScope.on_cleanup(lambda: [d.subscribers.discard(e) for d in e.deps]);
    }
    e.run();
    return e;
}


# ---------------------------------------------------------------------------
# Ergonomic helpers — cover what operator overloading can't (ternary, etc.)
# All ordinary library code, no compiler involvement.
# ---------------------------------------------------------------------------

# reactive ternary:  when(muted, "on", "off")
def when(cond: any, a: any, b: any) -> Derived {
    return computed(lambda: (_v(a) if _v(cond) else _v(b)));
}

# reactive format:   fmt("{:.0%}", vol)
def fmt(spec: str, src: any) -> Derived {
    return src.map(lambda v: spec.format(v));
}

# generic scope runner (headless tests). In the REAL tree, builders set
# currentScope to the ViewNode being built (see builders.jac), and disposal is
# the Dispose walker — not Scope.dispose.
def with_scope(scope: any, fn: any) -> any {
    prev = currentScope;
    if prev and hasattr(prev, "children") { prev.children.append(scope); }
    globals()["currentScope"] = scope;   # illustrative; real Jac scoping differs
    try { return fn(); }
    finally { globals()["currentScope"] = prev; }
}


# ===========================================================================
# AUTHORING SURFACE — how terse it actually lands (all compiler-free)
# ===========================================================================
#
#   let vol = signal(0.3);
#
#   Label(text = time)                       # bare signal        -> reactive
#   Label(text = vol * 100)                  # operator overload  -> reactive
#   Icon(hidden = battery > 0.8)             # comparison         -> reactive
#   Label(text = fmt("{:.0%}", vol))         # formatting helper  -> reactive
#   Label(text = vol.map(lambda v: f"{v:.0%}"))   # explicit map  -> reactive
#   Label(class = when(muted, "on", "off"))  # ternary helper     -> reactive
#   Button(on_click = toggle)                # bare callable, event channel
#
# THE ONE RULE: never CALL a signal in prop position — pass it bare, or derive
# it with an operator / .map / helper. Calling (vol()) snapshots a dead value.
# `lambda` only appears for genuinely gnarly expressions, where you want to see it.
# ===========================================================================
