# sources.jac — plain imperative Jac that watches the system and feeds Signals.
# (PLAN Phase 4, partial — clock + a manual source for the demo.)
# ---------------------------------------------------------------------------
# Sources are DUMB and imperative. They know nothing about OSP, reconciliation,
# or GTK. Their job: watch a thing, and .set() a Signal ON the main loop. The
# reactive engine does the rest. (Full Hyprland/audio/battery sources come in
# Phase 4; this file ships the clock ticker used by the Phase-3 demo.)
import from time { time, localtime, strftime }
import from src.reactive { signal, Signal, flush }
import from src.glib { timeout_add }


glob _ticker_cache: dict = {};


# Whole-second wall-clock reads for 1s+ tickers (avoids float drift + redundant dirty).
def _ticker_value(interval_ms: int) -> any {
    if interval_ms >= 1000 and interval_ms % 1000 == 0 { return int(time()); }
    return time();
}

# Ms until the next integer second — phase-lock 1s tickers to the wall clock.
def _ms_until_next_second() -> int {
    t = time();
    sec = int(t);
    ms = int((t - sec) * 1000.0);
    rem = 1000 - ms;
    if rem < 1 { rem = 1; }
    if rem > 1000 { rem = 1000; }
    return rem;
}

def _fire_ticker(s: Signal, interval_ms: int) {
    s.set(_ticker_value(interval_ms));
    # Propagate immediately: idle-deferred flush can coalesce back-to-back ticks and
    # skip displayed seconds when the loop catches up after a stall.
    flush();
}

def _schedule_repeating_ticker(s: Signal, interval_ms: int) {
    timeout_add(interval_ms, lambda {
        _fire_ticker(s, interval_ms);
        return True;
    });
}

def _start_ticker(s: Signal, interval_ms: int) {
    if interval_ms >= 1000 and interval_ms % 1000 == 0 {
        timeout_add(_ms_until_next_second(), lambda {
            _fire_ticker(s, interval_ms);
            _schedule_repeating_ticker(s, interval_ms);
            return False;
        });
    } else {
        _schedule_repeating_ticker(s, interval_ms);
    }
}


# ticker(ms) -> a Signal of epoch seconds, updated every `ms` by a GLib timeout
# (which already runs ON the main loop, so .set() is safe — no marshalling).
# One shared Signal per interval_ms (clocks/countdowns don't each spawn a timer).
def ticker(interval_ms: int) -> Signal {
    cached = _ticker_cache.get(interval_ms);
    if cached is not None { return cached; }
    s = signal(_ticker_value(interval_ms));
    _start_ticker(s, interval_ms);
    _ticker_cache[interval_ms] = s;
    return s;
}
