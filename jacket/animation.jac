# animation.jac — GTK-free tween scheduler for Jacket reactive UI.
# ---------------------------------------------------------------------------
# Headless tests drive time via advance_animations(); production uses a GLib
# timeout (16 ms) only while active_tweens is non-empty.
# ===========================================================================

import from jacket.reactive {
    signal, Signal, effect, Reactive, on_scope_cleanup
}
import from time { perf_counter }
import from jacket.glib { timeout_add, source_remove, guard_call }


# ===========================================================================
# Easing — cubic in/out/in_out plus linear.
# ===========================================================================
def ease_linear(t: float) -> float {
    if t <= 0.0 { return 0.0; }
    if t >= 1.0 { return 1.0; }
    return t;
}

def ease_in(t: float) -> float {
    if t <= 0.0 { return 0.0; }
    if t >= 1.0 { return 1.0; }
    return t * t * t;
}

def ease_out(t: float) -> float {
    if t <= 0.0 { return 0.0; }
    if t >= 1.0 { return 1.0; }
    u = 1.0 - t;
    return 1.0 - u * u * u;
}

def ease_in_out(t: float) -> float {
    if t <= 0.0 { return 0.0; }
    if t >= 1.0 { return 1.0; }
    if t < 0.5 {
        return 4.0 * t * t * t;
    }
    u = -2.0 * t + 2.0;
    return 1.0 - u * u * u / 2.0;
}

obj ease {
    static def linear(t: float) -> float { return ease_linear(t); }
    static def in_(t: float) -> float { return ease_in(t); }
    static def out(t: float) -> float { return ease_out(t); }
    static def in_out(t: float) -> float { return ease_in_out(t); }
}


# ===========================================================================
# Interpolation helper
# ===========================================================================
def _lerp(from_val: any, to_val: any, t: float) -> any {
    if isinstance(from_val, int) and isinstance(to_val, int) {
        return int(round(from_val + (to_val - from_val) * t));
    }
    fv = float(from_val);
    tv = float(to_val);
    return fv + (tv - fv) * t;
}


# ===========================================================================
# Scheduler globals
# ===========================================================================
glob active_tweens: list = [];
glob _clock_offset: float = 0.0;
glob _timer_sid: int | None = None;


def _now() -> float {
    return perf_counter() + _clock_offset;
}

def _ensure_timer() {
    if _timer_sid is None {
        _timer_sid = timeout_add(16, _on_frame);
    }
}

def _stop_timer_if_idle() {
    if len(active_tweens) == 0 and _timer_sid is not None {
        source_remove(_timer_sid);
        _timer_sid = None;
    }
}

def _tick_once() { tick(_now()); }

def _on_frame() -> bool {
    # Guarded: an exception escaping a PyGObject callback destroys the GLib
    # source silently (dead timers = frozen UI). On error, fail SAFE: reset
    # the scheduler (drop all tweens, clear the stale source id) — animations
    # stop but the shell keeps running with correct final values.
    if not guard_call(_tick_once, "tween tick") {
        reset_animation_state();
    }
    return len(active_tweens) > 0;
}

def register_tween(tween_state: dict) {
    active_tweens.append(tween_state);
    _ensure_timer();
}

def unregister_tween(tween_state: dict) {
    i = 0;
    while i < len(active_tweens) {
        if active_tweens[i] is tween_state {
            active_tweens.pop(i);
        } else {
            i += 1;
        }
    }
    _stop_timer_if_idle();
}

def tick(now: float) {
    done: list = [];
    cbs: list = [];
    for tw in active_tweens {
        start_ms = tw["start"] as float;
        dur_ms = tw["ms"] as float;
        elapsed_ms = (now - start_ms) * 1000.0;
        raw_t = elapsed_ms / dur_ms;
        if raw_t >= 1.0 {
            tw["anim"].display.set(tw["to"]);
            tw["anim"]._tween = None;
            done.append(tw);
            if tw["on_done"] is not None { cbs.append(tw["on_done"]); }
        } else {
            eased = tw["ease"](raw_t);
            tw["anim"].display.set(_lerp(tw["from"], tw["to"], eased as float));
        }
    }
    for tw in done {
        unregister_tween(tw);
    }
    # Completion callbacks run AFTER unregistration, outside the iteration:
    # a callback may set()/to() (cancelling tweens) or start chained tweens.
    for cb in cbs {
        cb();
    }
}

def advance_animations(ms: float) {
    _clock_offset += ms / 1000.0;
    tick(_now());
}

def active_tween_count() -> int {
    return len(active_tweens);
}

def reset_animation_state() {
    active_tweens = [];
    _clock_offset = 0.0;
    if _timer_sid is not None {
        source_remove(_timer_sid);
        _timer_sid = None;
    }
}


# ===========================================================================
# AnimatedSignal — display signal authors bind to; tweens update display.
# ===========================================================================
obj AnimatedSignal {
    has display: Signal;
    has _tween: any = None;

    def __call__() -> any { return self.display(); }
    def peek() -> any { return self.display.peek(); }

    def set(v: any) {
        self._cancel_tween();
        self.display.set(v);
    }

    # on_done fires when the tween reaches `target` (or immediately when the
    # value is already there). Cancelling — set(), a retargeting to(), scope
    # disposal — DROPS the callback: the tween never completed, so the exit
    # it was gating (e.g. a delayed window hide) should not run.
    def to(target: any, ms: float = 200.0, ease_fn: any = ease_out,
           on_done: any = None) {
        self._cancel_tween();
        from_val = self.display.peek();
        if from_val == target {
            self.display.set(target);
            if on_done is not None { on_done(); }
            return;
        }
        tw = {
            "anim": self,
            "from": from_val,
            "to": target,
            "ms": ms,
            "ease": ease_fn,
            "start": _now(),
            "on_done": on_done,
        };
        self._tween = tw;
        register_tween(tw);
        tick(_now());
    }

    def is_running() -> bool {
        return self._tween is not None;
    }

    def _cancel_tween() {
        if self._tween is not None {
            unregister_tween(self._tween);
            self._tween = None;
        }
    }
}


def _register_animated_cleanup(anim: AnimatedSignal) {
    on_scope_cleanup(lambda (a: AnimatedSignal = anim) { a._cancel_tween(); });
}


# ===========================================================================
# Factory helpers
# ===========================================================================
def animated(initial: any) -> AnimatedSignal {
    anim = AnimatedSignal(display=signal(initial));
    _register_animated_cleanup(anim);
    return anim;
}

def follow(target: Reactive, ms: float = 200.0, ease_fn: any = ease_out) -> AnimatedSignal {
    anim = animated(target.peek());
    effect(lambda {
        v = target();
        if v != anim.peek() {
            anim.to(v, ms, ease_fn);
        }
    });
    return anim;
}

def enter_tween(from_val: any, to_val: any, ms: float = 200.0, ease_fn: any = ease_out) -> AnimatedSignal {
    anim = animated(from_val);
    anim.to(to_val, ms, ease_fn);
    return anim;
}
