# scheduler.jac  —  DESIGN SKETCH (illustrative pseudo-Jac)
# ---------------------------------------------------------------------------
# The flush loop that makes reactive_core.jac CORRECT.
# Replaces the eager `_notify` / `_recompute` placeholders with:
#   mark-stale (push)  ->  lazy pull (glitch-free, dep-ordered)  ->  batched flush
#
# Companion to reactive_core.jac. Read that first: it defines
# Reactive / Signal / Derived / Effect / Owner and the currentComputation stack.
# This file shows how a write PROPAGATES without diamonds, double-runs, or
# per-write commits — and how it batches onto GTK's main loop.
#
# THREE IDEAS, and that's the whole file:
#   1. tri-state staleness (CLEAN / CHECK / DIRTY) so we never recompute blind
#   2. write = mark only; read = pull = the topological recompute walk
#   3. effects are the roots that drive pull, drained once per GLib.idle tick
# ===========================================================================


# ---------------------------------------------------------------------------
# Node state. Lives on every Reactive (add `has state: int = CLEAN;` there).
#   CLEAN  : cache is trustworthy, sources unchanged since last compute.
#   CHECK  : a transitive source MIGHT have changed — verify before trusting.
#            (We do NOT know if our own value changed. Must pull sources first.)
#   DIRTY  : a DIRECT source definitely changed — must recompute.
# The CHECK tier is what kills the diamond: a node fed by two paths is marked
# once, verified once, recomputed at most once.
# ---------------------------------------------------------------------------
glob CLEAN: int = 0;
glob CHECK: int = 1;
glob DIRTY: int = 2;


# ---------------------------------------------------------------------------
# Global scheduler state.
# ---------------------------------------------------------------------------
glob effect_queue: list = [];     # effects whose deps went stale, pending run
glob flush_scheduled: bool = False;
glob MAX_FLUSH_PASSES: int = 100; # re-entrancy backstop (write-loop -> throw)


# ===========================================================================
# PUSH SIDE — a write marks, it does not compute.
# Called from Signal.set() instead of the old eager _notify().
# ===========================================================================

# Mark this node's whole downstream cone stale, cheaply, running nothing.
# Direct subscribers are DIRTY (a real source changed under them); everything
# deeper is CHECK (maybe stale — decided later at pull time by value compare).
# Effects reached along the way are queued to drive the pull.
def mark_stale(node: Reactive) {
    for sub in node.subscribers {
        if isinstance(sub, Effect) {
            # effects have no downstream value; just schedule them
            enqueue_effect(sub);
        } else {
            # a Derived
            if sub.state == CLEAN {
                # first time we reach it this tick: it's directly downstream of
                # a changed node -> DIRTY, and its OWN cone is now maybe-stale
                sub.state = DIRTY;
                mark_check(sub);       # push CHECK further down (not DIRTY)
            }
            # if already DIRTY/CHECK, its cone was already marked — stop, no
            # re-walk. THIS is what makes diamonds O(nodes), not O(paths).
        }
    }
}

# Propagate the softer CHECK mark down from an already-DIRTY node. We stop at
# any node that's already non-CLEAN: it (and its cone) is accounted for.
def mark_check(node: Reactive) {
    for sub in node.subscribers {
        if isinstance(sub, Effect) {
            enqueue_effect(sub);
        } elif sub.state == CLEAN {
            sub.state = CHECK;
            mark_check(sub);
        }
    }
}


# ===========================================================================
# PULL SIDE — reading a stale node brings it up to date, in dep order, once.
# This is called by Reactive.__call__ BEFORE returning _peek(), and by the
# flush loop when it runs an effect. It is the entire glitch-free guarantee.
# ===========================================================================

# Ensure `node` holds a current value. Returns nothing; after this, node.state
# == CLEAN and node.cached is correct.
def update_if_stale(node: Reactive) {
    if node.state == CHECK {
        # We don't yet know if we actually changed. Bring each source current;
        # if updating a source flips US to DIRTY (its value changed -> see
        # note in recompute), we'll recompute below. Otherwise we're just CLEAN.
        for src in node.deps {
            update_if_stale(src);          # recurse UP first = topological order
            if node.state == DIRTY { break; }   # a source changed value -> stop
        }
    }
    if node.state == DIRTY {
        recompute(node);
    }
    node.state = CLEAN;
}

# Recompute a Derived, tracking fresh deps, and — crucially — decide whether
# our OUTPUT changed. If it did, our own subscribers that are CHECK must be
# upgraded to DIRTY (their input really moved). If not, they stay CHECK and
# will settle to CLEAN for free. This value-compare is the glitch cutoff.
def recompute(node: Reactive) {
    for d in node.deps { d.subscribers.discard(node); }
    node.deps = {};
    currentComputation.append(node);
    try { new = node.fn(); }
    finally { currentComputation.pop(); }

    if new != node.cached {
        node.cached = new;
        # our value moved -> any CHECK subscriber is genuinely DIRTY now
        for sub in node.subscribers {
            if not isinstance(sub, Effect) and sub.state == CHECK {
                sub.state = DIRTY;
            }
        }
    }
    node.state = CLEAN;
}


# ===========================================================================
# THE FLUSH — batched onto GTK's main loop. One tick = one commit pass.
# ===========================================================================

def enqueue_effect(e: Effect) {
    if not e.queued {
        e.queued = True;               # add `has queued: bool = False;` to Effect
        effect_queue.append(e);
    }
    schedule_flush();
}

def schedule_flush() {
    if not flush_scheduled {
        globals()["flush_scheduled"] = True;
        # idle_add fires AFTER GTK finishes current event handling, so we
        # commit once per frame, never mid-event. Returns False = one-shot.
        GLib.idle_add(flush);
    }
}

def flush() -> bool {
    passes = 0;
    # Effects may write signals, which enqueue MORE effects onto this same
    # queue (re-entrancy). Keep draining until quiescent; cap to catch loops.
    while effect_queue {
        passes += 1;
        if passes > MAX_FLUSH_PASSES {
            raise RuntimeError("reactive flush did not converge — write-loop?");
        }
        batch = effect_queue;
        globals()["effect_queue"] = [];
        for e in batch {
            e.queued = False;
            # running the effect pulls its deps: each read hits __call__ ->
            # update_if_stale -> the lazy topological recompute above.
            e.run();
        }
    }
    globals()["flush_scheduled"] = False;
    return False;                      # GLib: do not reschedule
}


# ===========================================================================
# HOW THIS WIRES BACK INTO reactive_core.jac  (the deltas)
# ===========================================================================
#
#   Reactive:  + has state: int = CLEAN;
#              __call__ calls `update_if_stale(self)` before `return _peek()`
#              so a read never returns a stale cache.
#
#   Signal.set(v):  replace the eager loop with:
#              if v != self.value { self.value = v; mark_stale(self); }
#              (no compute here — mark only)
#
#   Derived:   drop its own _recompute; the scheduler's recompute() owns it.
#              computed() primes once with recompute(d); d.state = CLEAN.
#
#   Effect:    + has queued: bool = False;
#              effect() runs once eagerly to establish deps, exactly as before.
#              Thereafter it only re-runs via the flush queue.
#
# ---------------------------------------------------------------------------
# WORKED DIAMOND — why D runs exactly once.
#
#   A ──▶ B ──▶ D
#   └───▶ C ───┘
#
#   A.set(x):
#     mark_stale(A): B->DIRTY, C->DIRTY; from each, mark_check reaches D->CHECK
#                    (second path to D finds it already CHECK -> stops).
#     effect E (reads D) enqueued once.
#   flush -> E.run() reads D:
#     update_if_stale(D): D is CHECK -> pull sources:
#        update_if_stale(B): DIRTY -> recompute B; B's value moved ->
#                            D (CHECK) upgraded to DIRTY.
#        loop sees D==DIRTY -> break (C not yet pulled here...)
#     D is DIRTY -> recompute(D): reading B (CLEAN, cached) and C.
#        reading C hits __call__ -> update_if_stale(C): DIRTY -> recompute C.
#     D computed ONCE with BOTH fresh inputs. No glitch, no double-run.
#
#   (The break is safe: C is still stale, but D's recompute reads C, and that
#    read pulls C current on demand. Pull-on-read is the invariant that lets us
#    stop early without missing anyone.)
# ===========================================================================
