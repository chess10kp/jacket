# topology_reactive.jac — OSP-native reactive engine (PLAN §2, §3).
# ---------------------------------------------------------------------------
# Source/Derived/Binding nodes connected by Feeds edges. PROPAGATION IS A
# WALKER (Propagate), not a recursive stale-marker; source_set enqueues only
# dirty source roots and flush spawns the walker. Dependency tracking is EXACT:
# reads are collected into an evaluation context and committed once via
# diff_feeds after evaluation (no edges mutated mid-read). GTK-free; closures
# live in SessionStore.
import from src.runtime_graph {
    SourceNode, DerivedNode, BindingNode, RouteNode, ReactiveNode, Owns, Feeds,
    next_runtime_id, session_store, reset_session_store, trace_visit,
    active_session_rid
}

glob CLEAN: int = 0;
glob CHECK: int = 1;
glob DIRTY: int = 2;

# ---------------------------------------------------------------------------
# Scheduler state. The queue holds DIRTY SOURCE ROOTS ONLY — it must not
# duplicate dependency relationships (PLAN §2). The walker owns traversal.
# ---------------------------------------------------------------------------
glob dirty_sources: list = [];
glob flush_scheduled: bool = False;
glob in_batch: bool = False;
glob _eval_depth: int = 0;          # >0 while any evaluation is on the stack
glob _in_flush: bool = False;       # True while the walker is driving a flush
glob MAX_FLUSH_PASSES: int = 100;
glob flush_hook: any = None;

# Per-flush generation + memo. _recomputed[rid]==gen means "already recomputed
# this pass"; _changed[rid] means "value changed this pass" (equality cutoff).
glob _flush_gen: int = 0;
glob _recomputed: dict = {};
glob _changed: dict = {};

# Evaluation-context stack: each entry collects the reactive nodes READ during
# one derived/binding evaluation, then diff_feeds commits the exact edge set.
glob _eval_stack: list = [];

obj EvalContext {
    has target: any = None;
    has reads: list = [];
}


# ===========================================================================
# Node construction + ownership
# ===========================================================================
def create_source(initial: any, owner: ReactiveNode = None) -> SourceNode {
    n = SourceNode(runtime_id=next_runtime_id("source"), value=initial);
    n.session_id = active_session_rid();
    root ++> n;
    if owner is not None { owner +>:Owns:+> n; }
    return n;
}

def create_derived(fn: any, owner: ReactiveNode = None) -> DerivedNode {
    n = DerivedNode(runtime_id=next_runtime_id("derived"));
    n.session_id = active_session_rid();
    root ++> n;
    session_store().derived_fns[n.runtime_id] = fn;
    if owner is not None { owner +>:Owns:+> n; }
    prime_derived(n);
    return n;
}

def create_binding(fn: any, owner: ReactiveNode = None) -> BindingNode {
    n = BindingNode(runtime_id=next_runtime_id("binding"));
    n.session_id = active_session_rid();
    root ++> n;
    session_store().binding_fns[n.runtime_id] = fn;
    if owner is not None { owner +>:Owns:+> n; }
    run_binding(n);                 # prime
    drain_after_eval();             # commit any writes the prime deferred
    return n;
}

# RouteNode gate (PLAN §6). The route mirrors its source via peek (UNTRACKED),
# so diff_feeds never touches the source->RouteNode edge — only the reconciler
# connects/disconnects it. Bindings read() the route and thus can never gain a
# direct Feeds edge to the source. The source handle is process-local and kept
# in SessionStore (never on the node) so it cannot poison the graph serializer.
def create_route(name: str, source: any) -> RouteNode {
    n = RouteNode(runtime_id=next_runtime_id("route"), route_name=name, state=DIRTY);
    n.session_id = active_session_rid();
    root ++> n;
    session_store().route_sources[n.runtime_id] = source;
    recompute_route(n);             # prime cached from the source
    return n;
}

def own_node(owner: any, child: any) { owner +>:Owns:+> child; }


# ===========================================================================
# Feeds edge management — dependency = src feeds dst
# ===========================================================================
def feed_targets(src: any) -> list {
    return [src ->:Feeds:->];
}

def feed_sources(g: ReactiveNode) -> list {
    return [g <-:Feeds:<-];
}

def clear_feeds_to(dst: any) {
    for s in feed_sources(dst) {
        disconnect_feeds(s, dst);
    }
}

def connect_feeds(src: any, dst: any) {
    for t in feed_targets(src) {
        if t is dst { return; }
    }
    src +>:Feeds:+> dst;
}

def disconnect_feeds(src: any, dst: any) {
    for e in [edge src ->:Feeds:-> dst] { del e; }
}

# Exact edge-set diff (PLAN §3): commit the new dependency set in one step.
# Stable dependencies do not delete/recreate edges; conditional branch changes
# remove stale edges and add new ones.
def diff_feeds(dst: any, new_deps: list) {
    old = feed_sources(dst);
    for o in old {
        if o not in new_deps { disconnect_feeds(o, dst); }
    }
    for d in new_deps {
        if d not in old { connect_feeds(d, dst); }
    }
}


# ===========================================================================
# Evaluation — collect reads, then commit edges. No edge mutation during read.
# ===========================================================================
def evaluate(target: any, fn: any) -> any {
    ctx = EvalContext(target=target);
    _eval_stack.append(ctx);
    _eval_depth += 1;
    result: any = None;
    try {
        result = fn();
    } finally {
        _eval_depth -= 1;
        _eval_stack.pop();
    }
    diff_feeds(target, ctx.reads);
    return result;
}

def read_reactive(g: any) -> any {
    if _eval_stack {
        _eval_stack[-1].reads.append(g);     # collect; do NOT mutate edges here
    }
    if isinstance(g, SourceNode) { return g.value; }
    if isinstance(g, RouteNode) {
        ensure_route_fresh(g);
        return g.cached;
    }
    if isinstance(g, DerivedNode) {
        ensure_fresh(g);
        return g.cached;
    }
    return None;
}

def peek(g: any) -> any {
    # untracked read — the supported signal.value path (PLAN §4)
    if isinstance(g, SourceNode) { return g.value; }
    if isinstance(g, RouteNode) { return g.cached; }
    if isinstance(g, DerivedNode) { return g.cached; }
    return None;
}


# ===========================================================================
# Pull side — derived recomputation. Memoized per flush pass (diamond-safe) and
# order-independent: a recompute reads its sources via read_reactive, which
# recursively ensures each source is fresh first.
# ===========================================================================
def prime_derived(n: DerivedNode) {
    recompute(n);
    n.state = CLEAN;
}

# RouteNode freshness — same per-pass memoization as derived nodes. The route's
# recompute reads its source via peek (untracked), so the source->RouteNode
# Feeds edge is owned exclusively by the reconciler, never by diff_feeds.
def ensure_route_fresh(n: RouteNode) {
    if _in_flush {
        if _recomputed.get(n.runtime_id) == _flush_gen { return; }
        _recomputed[n.runtime_id] = _flush_gen;
        recompute_route(n);
    } else {
        if n.state == DIRTY { recompute_route(n); }
        n.state = CLEAN;
    }
}

def recompute_route(n: RouteNode) {
    src = session_store().route_sources.get(n.runtime_id);
    if src is None { return; }
    old = n.cached;
    new = peek(src);
    n.cached = new;
    n.state = CLEAN;
    if new != old {
        _changed[n.runtime_id] = True;     # equality cutoff for the walker
    }
}

def ensure_fresh(n: DerivedNode) {
    if _in_flush {
        # within a flush pass, recompute at most once per generation
        if _recomputed.get(n.runtime_id) == _flush_gen { return; }
        _recomputed[n.runtime_id] = _flush_gen;
        recompute(n);
    } else {
        update_if_stale(n);
    }
}

def update_if_stale(n: DerivedNode) {
    if n.state == DIRTY { recompute(n); }
    n.state = CLEAN;
}

def recompute(n: DerivedNode) {
    fn = session_store().derived_fns.get(n.runtime_id);
    if fn is None { return; }
    old = n.cached;
    new = evaluate(n, fn);
    n.cached = new;
    n.state = CLEAN;
    if new != old {
        _changed[n.runtime_id] = True;     # equality cutoff signal for the walker
    }
}


# ===========================================================================
# Source write + scheduler
# ===========================================================================
def source_set(src: SourceNode, v: any) {
    if v != src.value {
        src.value = v;
        enqueue_dirty(src);
    }
}

def enqueue_dirty(src: SourceNode) {
    if src not in dirty_sources { dirty_sources.append(src); }
    schedule();
}

def schedule() {
    if flush_scheduled { return; }      # a pending or in-flight flush picks up new writes
    flush_scheduled = True;
    if _eval_depth > 0 { return; }      # mid-evaluation: defer until it unwinds
    if in_batch { return; }             # batch commits one flush at its end
    if _in_flush { return; }            # the flush while-loop picks up new writes
    run_scheduled();
}

def run_scheduled() {
    if flush_hook is not None {
        flush_hook(flush);
    } else {
        flush();
    }
}

# Called after a priming evaluation (create_binding/create_derived) and at batch
# end: if a write was deferred, commit it now that the evaluation has unwound.
def drain_after_eval() {
    if flush_scheduled and _eval_depth == 0 and not in_batch and not _in_flush {
        run_scheduled();
    }
}

def flush() {
    if _eval_depth > 0 { return; }      # never flush from inside an evaluation
    _in_flush = True;
    passes = 0;
    try {
        while dirty_sources {
            passes += 1;
            if passes > MAX_FLUSH_PASSES {
                dirty_sources = [];
                raise RuntimeError("reactive flush did not converge — write-loop?");
            }
            _flush_gen += 1;
            _changed = {};
            roots = list(dirty_sources);
            dirty_sources = [];
            if len(roots) > 0 {
                w = Propagate(seeds=roots);
                root spawn w;
            }
        }
    } finally {
        _in_flush = False;
        flush_scheduled = False;
        _changed = {};
        _recomputed = {};
    }
}

def batch(fn: any) {
    was = in_batch;
    in_batch = True;
    try {
        fn();
    } finally {
        in_batch = was;
        if not was { drain_after_eval(); }
    }
}

def set_flush_hook(fn: any) { flush_hook = fn; }

# Clear transient scheduler/propagation state — paired with reset_session_store
# for a clean engine slate (e.g. between headless tests).
def reset_engine_state() {
    dirty_sources = [];
    flush_scheduled = False;
    in_batch = False;
    _eval_depth = 0;
    _in_flush = False;
    _flush_gen = 0;
    _recomputed = {};
    _changed = {};
    _eval_stack = [];
}


# ===========================================================================
# Bindings — side-effect leaves
# ===========================================================================
def run_binding(b: BindingNode) {
    if not b.enabled { return; }
    fn = session_store().binding_fns.get(b.runtime_id);
    if fn is None { return; }
    evaluate(b, fn);          # reads collected -> diff_feeds commits Feeds
    b.runs += 1;
    trace_visit("binding_run");
}

def set_binding_enabled(b: BindingNode, on: bool) { b.enabled = on; }


# ===========================================================================
# Propagate — the production propagation walker (PLAN §2).
#   source.set(value)
#     -> equality cutoff
#     -> enqueue SourceNode once
#     -> flush spawns Propagate
#     -> walker follows Feeds only
#     -> pulls derived values in dependency order (memoized, diamond-safe)
#     -> runs each changed binding once (visited-set dedup)
# No Child/policy/topology traversal on data updates.
# ===========================================================================
walker Propagate {
    has visited: list = [];
    has seeds: list = [];          # all dirty source roots for this flush pass

    # ONE walker for all source writes in a batch (PLAN §2): launch from root,
    # visit every dirty source, and share a single visited set so a binding fed
    # by several changed sources still runs exactly once.
    can launch with Root entry {
        visit self.seeds;
    }
    can root with SourceNode entry {
        visit [here ->:Feeds:->];
    }
    can pull with DerivedNode entry {
        rid = here.runtime_id;
        if rid in self.visited { skip; }
        self.visited.append(rid);
        ensure_fresh(here);                       # recompute (idempotent per pass)
        if _changed.get(rid) {
            visit [here ->:Feeds:->];             # equality cutoff: skip if unchanged
        }
    }
    can route with RouteNode entry {
        rid = here.runtime_id;
        if rid in self.visited { skip; }
        self.visited.append(rid);
        ensure_route_fresh(here);                 # mirror source (peek, untracked)
        if _changed.get(rid) {
            visit [here ->:Feeds:->];             # reach bindings fed by this route
        }
    }
    can bind with BindingNode entry {
        rid = here.runtime_id;
        if rid in self.visited { skip; }
        if not here.enabled { skip; }
        self.visited.append(rid);
        run_binding(here);
    }
}

def propagate_from(src: SourceNode) {
    enqueue_dirty(src);
    drain_after_eval();
}


# ===========================================================================
# Route gate — connect/disconnect a binding region via Feeds edges (T1).
# A route node sits between source and binding so a binding cannot reconnect
# directly to a suppressed source during dynamic dependency tracking.
# ===========================================================================
def route_connect(src: any, binding: BindingNode) {
    connect_feeds(src, binding);
}

def route_disconnect(src: any, binding: BindingNode) {
    disconnect_feeds(src, binding);
}


# ===========================================================================
# Disposal — walk Owns post-order, remove incident Feeds, pop closures.
# Reactive cleanup is graph-native (Owns + Feeds), never callback-dependent.
# ===========================================================================
walker DisposeOwned {
    can descend with SourceNode | DerivedNode | BindingNode | RouteNode entry {
        visit [here ->:Owns:->];
    }
    can teardown with SourceNode | DerivedNode | BindingNode | RouteNode exit {
        dispose_reactive_node(here);
    }
}

def dispose_reactive_node(g: any) {
    store = session_store();
    if isinstance(g, DerivedNode) {
        store.derived_fns.pop(g.runtime_id, None);
    }
    if isinstance(g, BindingNode) {
        store.binding_fns.pop(g.runtime_id, None);
    }
    if isinstance(g, RouteNode) {
        store.route_sources.pop(g.runtime_id, None);
    }
    for s in feed_sources(g) { disconnect_feeds(s, g); }
    for t in feed_targets(g) { disconnect_feeds(g, t); }
}

# kept for the old per-subtree disposal API (reactive.jac anchor teardown)
def _dispose_node(g: any) { dispose_reactive_node(g); }

def dispose_owned(subtree: ReactiveNode) {
    w = DisposeOwned();
    subtree spawn w;
    del subtree;
}


# ===========================================================================
# Ergonomic reactive read helper for binding/derived fns
# ===========================================================================
def read(g: any) -> any { return read_reactive(g); }
