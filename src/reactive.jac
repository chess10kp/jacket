# reactive.jac — LIBRARY: fine-grained reactive engine (core + scheduler, merged)
# ---------------------------------------------------------------------------
# Implements PLAN.md Phase 1: the Solid-style reactive primitive + the
# tri-state glitch-free scheduler. GTK-free; the whole engine is testable
# headless. Companions (osp.jac, adapter.jac, builders.jac) build on this.
#
# The plan split this into reactive_core.jac + scheduler.jac; merged here
# because they SHARE module globals (current_computation, scheduler queues).
#
# DESIGN (PLAN §2, §3):
#   Reactive layer (Signal/Derived/Effect + dep graph) = plain obj, NOT OSP.
#   The per-tick path is O(1); a signal tick must not traverse a graph.
#   Structural layer (the widget tree) = OSP, in osp.jac.
#
# Scheduler (PLAN scheduler.jac) = three ideas:
#   1. tri-state staleness (CLEAN/CHECK/DIRTY) — never recompute blind
#   2. write = mark only; read = pull = topological recompute walk
#   3. effects are the roots that drive pull, drained once per tick
# ===========================================================================

# tri-state. `state` lives on every Reactive (CLEAN default).
#   CLEAN : cache trustworthy, sources unchanged since last compute
#   CHECK : a transitive source MIGHT have changed — verify before trusting
#   DIRTY : a DIRECT source definitely changed — must recompute
# The CHECK tier kills the diamond: a node fed by two paths is marked once,
# verified once, recomputed at most once.
# Comparison helpers. Jac's type checker forbids `any > any` (E1110) even
# though arithmetic on `any` is allowed. Shell comparisons are dynamic (int /
# float / str at runtime), so route the four ordering comparisons through Python
# where Python's own dispatch handles them. (Arithmetic overloads are fine as-is.)
::py::
def _cmp_gt(a, b): return a > b
def _cmp_lt(a, b): return a < b
def _cmp_ge(a, b): return a >= b
def _cmp_le(a, b): return a <= b
::py::

glob CLEAN: int = 0;
glob CHECK: int = 1;
glob DIRTY: int = 2;

# Global tracking — the entire "magic" of fine-grained reactivity.
#   current_computation : stack of running computations (Derived/Effect), so
#                         signal reads know who to subscribe.
#   current_scope       : disposal scope new effects attach to. A Scope
#                         (headless) or a ViewNode (real tree, osp.jac) — both
#                         provide on_cleanup(fn).
glob current_computation: list[any] = [];
glob current_scope: any = None;

# Scheduler state.
#   flush_hook : if set (GTK app), schedule_flush defers a flush via it
#                (GLib.idle_add). If None (headless), flush runs synchronously.
#   in_batch   : while True, schedule_flush defers to the batch's end, so
#                multiple writes commit in one pass even headlessly.
glob effect_queue: list[any] = [];
glob flush_scheduled: bool = False;
glob MAX_FLUSH_PASSES: int = 100;
glob flush_hook: any = None;
glob in_batch: bool = False;
glob mark_depth: int = 0;   # >0 while mark_stale/mark_check are propagating


# ===========================================================================
# Reactive — common base for Signal and Derived. CALLABLE: `x()` reads the
# value AND subscribes the current computation. Operators + .map live here so
# both writable signals and derived values get the sugar.
#
# NOTE: __eq__ is deliberately NOT overloaded — it would make Reactive
# instances unhashable and break the subscriber/deps sets. For reactive
# equality use .map (e.g. `a.map(lambda (x) { x == 3; })`).
# ===========================================================================
obj Reactive {
    has subscribers: set[any] = set();   # computations depending on this node
    has state: int = 0;                  # CLEAN/CHECK/DIRTY

    # read + track. update_if_stale first (pull = glitch-free), then subscribe.
    def __call__() -> any {
        update_if_stale(self);
        if current_computation {
            comp: any = current_computation[-1];
            self.subscribers.add(comp);
            comp.deps.add(self);
        }
        return self._peek();
    }

    def _peek() -> any { return None; }     # override: raw value, no tracking

    # combinator: the escape hatch for anything operators can't express.
    # vol.map(lambda (v) { f"{v:.0%}"; }) -> a Derived that re-runs fn reactively.
    def map(fn: any) -> any { return computed(lambda { fn(self()); }); }

    # operator overloads: simple derivations stay reactive, no lambda.
    # `vol * 100` -> Derived reading vol. Chainable (Derived is Reactive).
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

# unwrap: let operators mix signals with plain values or other signals.
# Reading a Reactive inside a computed lambda subscribes correctly.
def _v(o: any) -> any {
    if isinstance(o, Reactive) { return o(); }
    return o;
}


# ===========================================================================
# Signal — the writable leaf.  count = signal(0)
#   read: count()   write: count.set(3)   update: count.update(lambda (n) { n+1; })
# ===========================================================================
obj Signal(Reactive) {
    has value: any = None;

    def _peek() -> any { return self.value; }

    def set(v: any) {
        if v != self.value {              # equality cutoff (PLAN open-item #2)
            self.value = v;
            mark_stale(self);             # mark only — never compute here
        }
    }
    def update(fn: any) { self.set(fn(self.value)); }
}

def signal(initial: any) -> Signal {
    return Signal(value=initial);
}


# ===========================================================================
# Derived — read-only reactive computed from other reactives. Produced by
# operators, .map, computed(). Recomputes lazily (pull) when deps go stale.
# ===========================================================================
obj Derived(Reactive) {
    has fn: any = None;
    has cached: any = None;
    has deps: set[any] = set();          # reactives THIS node reads (cleared/run)

    def _peek() -> any { return self.cached; }
}

def computed(fn: any) -> Derived {
    d = Derived(fn=fn);
    recompute(d);                        # prime: establish value + deps
    d.state = CLEAN;
    return d;
}


# ===========================================================================
# Effect — a computation run for its SIDE EFFECT (a reactive prop binding).
# The bridge to the widget tree:
#   effect(lambda { adapter.set_prop(node, "label", text()); })
# Auto-tracks deps; re-runs when any read changes; owner-scoped for cleanup.
# Not a Reactive (no value, nobody reads it) — but it tracks deps like one.
# ===========================================================================
obj Effect {
    has fn: any = None;
    has deps: set[any] = set();
    has queued: bool = False;

    def run() {
        # clear old dep links so a fresh run re-subscribes to current deps only
        for d in self.deps { d.subscribers.discard(self); }
        self.deps = set();
        current_computation.append(self);
        try { self.fn(); }
        finally { current_computation.pop(); }
    }
}

def effect(fn: any) -> Effect {
    e = Effect(fn=fn);
    if current_scope {
        # dispose = stop tracking this effect when the scope tears down.
        current_scope.on_cleanup(lambda { dispose_effect(e); });
    }
    e.run();                             # prime: establish deps
    return e;
}

def dispose_effect(e: Effect) {
    for d in e.deps { d.subscribers.discard(e); }
    e.deps = set();
}


# ===========================================================================
# PUSH SIDE — a write marks, it does not compute. Called from Signal.set().
# `n` is typed `any` because it crosses the Effect/Derived union dynamically.
# Direct subscribers are DIRTY (a real source changed under them); everything
# deeper is CHECK (maybe stale — decided later at pull time by value compare).
# Effects reached are queued to drive the pull.
# ===========================================================================
def mark_stale(n: any) {
    top = (mark_depth == 0);
    mark_depth += 1;
    try {
        for sub in list(n.subscribers) {
            if isinstance(sub, Effect) {
                enqueue_effect(sub);
            } else {
                s: any = sub;
                if s.state == CLEAN {
                    s.state = DIRTY;         # directly downstream of a changed node
                    mark_check(s);           # push softer CHECK further down
                }
                # if already DIRTY/CHECK, its cone was already marked — stop (O(nodes)).
            }
        }
    } finally {
        mark_depth -= 1;
        # only the outermost mark_stale (the .set() that started it all) flushes.
        # Effects enqueued by nested mark_check are all queued by now.
        if top and effect_queue {
            schedule_flush();
        }
    }
}

# Propagate CHECK down from an already-DIRTY node. Stop at any non-CLEAN node:
# it (and its cone) is already accounted for. THIS makes diamonds O(nodes).
def mark_check(n: any) {
    for sub in list(n.subscribers) {
        if isinstance(sub, Effect) {
            enqueue_effect(sub);
        } else {
            s: any = sub;
            if s.state == CLEAN {
                s.state = CHECK;
                mark_check(s);
            }
        }
    }
}


# ===========================================================================
# PULL SIDE — reading a stale node brings it current, in dep order, once.
# Called by Reactive.__call__ before returning _peek(), and by flush when it
# runs an effect. This is the entire glitch-free guarantee.
# ===========================================================================

# Ensure `n` holds a current value. After this, n.state == CLEAN.
def update_if_stale(n: any) {
    if n.state == CHECK {
        # We don't yet know if we actually changed. Bring each source current;
        # if a source's value moved it upgrades US to DIRTY (see recompute), and
        # we break to recompute below. Else we settle to CLEAN for free.
        for src in list(n.deps) {
            update_if_stale(src);
            if n.state == DIRTY { break; }
        }
    }
    if n.state == DIRTY {
        recompute(n);
    }
    n.state = CLEAN;
}

# Recompute a Derived, tracking fresh deps, and decide whether our OUTPUT
# changed. If it did, any CHECK subscriber is genuinely DIRTY now (its input
# really moved). If not, they stay CHECK and settle to CLEAN. This value
# compare is the glitch cutoff.
def recompute(n: any) {
    for d in n.deps { d.subscribers.discard(n); }
    n.deps = set();
    current_computation.append(n);
    try {
        new = n.fn();
    } finally {
        current_computation.pop();
    }
    if new != n.cached {
        n.cached = new;
        for sub in list(n.subscribers) {
            if not isinstance(sub, Effect) {
                s: any = sub;
                if s.state == CHECK { s.state = DIRTY; }
            }
        }
    }
    n.state = CLEAN;
}


# ===========================================================================
# THE FLUSH — batched onto the host loop (GLib.idle_add in GTK; synchronous
# when headless). One tick = one commit pass.
# ===========================================================================
def enqueue_effect(e: Effect) {
    # Append only — NEVER schedule_flush here. enqueue happens during
    # mark_stale/mark_check; flushing mid-mark would process a half-marked
    # graph (the remaining subscribers would re-dirty already-settled nodes).
    # mark_stale schedules exactly once, at its top-level return.
    if not e.queued {
        e.queued = True;
        effect_queue.append(e);
    }
}

# set the deferral hook. GTK app: set_flush_hook(lambda (f) { GLib.idle_add(f); }).
# Default (None) = synchronous headless flush.
def set_flush_hook(fn: any) { flush_hook = fn; }

def schedule_flush() {
    if flush_scheduled { return; }
    if in_batch {                       # defer until batch() ends
        flush_scheduled = True;
        return;
    }
    if flush_hook is not None {         # deferred (GTK / host loop)
        flush_scheduled = True;
        flush_hook(flush);
        return;
    }
    # headless synchronous. Set the guard FIRST so an effect that writes a
    # signal mid-flush does NOT recurse into flush() — its enqueue just feeds
    # the current while-loop (capped by MAX_FLUSH_PASSES), not the call stack.
    flush_scheduled = True;
    flush();
}

def flush() {
    passes = 0;
    # Effects may write signals, which enqueue MORE effects onto this queue
    # (re-entrancy). Keep draining until quiescent; cap to catch write-loops.
    while effect_queue {
        passes += 1;
        if passes > MAX_FLUSH_PASSES {
            flush_scheduled = False;
            effect_queue = [];
            raise RuntimeError("reactive flush did not converge — write-loop?");
        }
        batch = effect_queue;
        effect_queue = [];
        for e in batch {
            e.queued = False;
            e.run();                    # each read pulls deps via update_if_stale
        }
    }
    flush_scheduled = False;
}

# Group multiple writes into one commit pass (useful headless and on GTK).
def batch(fn: any) {
    was = in_batch;
    in_batch = True;
    try { fn(); }
    finally {
        in_batch = was;
        if not was { flush(); }
    }
}


# ===========================================================================
# Scope — the disposal unit (GENERIC / headless). Every effect runs inside a
# scope; cleanups registered during its run tear down (children first) on
# dispose. In the real widget tree the scope is a ViewNode (osp.jac), which
# provides the SAME on_cleanup protocol and is torn down post-order by the
# Dispose walker. So there is ONE tree, not a parallel owner tree.
# ===========================================================================
obj Scope {
    has children: list[any] = [];
    has cleanups: list[any] = [];

    def on_cleanup(fn: any) { self.cleanups.append(fn); }

    def dispose() {
        for c in self.children { c.dispose(); }     # children first (leaves up)
        for fn in reversed(self.cleanups) { fn(); }
        self.children = [];
        self.cleanups = [];
    }
}

def create_scope() -> Scope { return Scope(); }

# Run fn under `scope` as current_scope, nesting it under the previous scope.
# NOTE: prefer enter_scope/exit_scope when fn itself creates lambdas — Jac's
# nested-lambda codegen can misplace an inner lambda's generated name.
def with_scope(scope: any, fn: any) -> any {
    prev = enter_scope(scope);
    try { return fn(); }
    finally { exit_scope(prev); }
}

# Push `scope` as current_scope (nesting it under the previous one). Returns the
# previous scope so the caller can restore it via exit_scope. Use this pair
# around any block that creates effects/closures, to avoid nested lambdas.
def enter_scope(scope: any) -> any {
    prev = current_scope;
    if prev is not None and hasattr(prev, "children") {
        prev.children.append(scope);
    }
    current_scope = scope;
    return prev;
}

def exit_scope(prev: any) { current_scope = prev; }


# ===========================================================================
# Ergonomic helpers — cover what operator overloading can't (ternary, format).
# Ordinary library code, no compiler involvement (PLAN §1 sugar decision).
# ===========================================================================

# reactive ternary:  when(muted, "on", "off")
def when(cond: any, a: any, b: any) -> any {
    return computed(lambda { _v(a) if _v(cond) else _v(b); });
}

# reactive format. Supports both fmt("{:.0%}", vol) and fmt(".0%", vol).
def fmt(spec: str, src: any) -> any {
    return src.map(lambda (v: any) { spec.format(v) if "{" in spec else format(v, spec); });
}
