# transition.jac — LIBRARY: popup enter/exit transitions + delayed hide.
# ---------------------------------------------------------------------------
# The exit-animation state machine popups share (launcher window, panels).
# Problem it solves: binding `hidden = visible.map(not)` hides the window the
# instant `visible` flips False — an exit tween would never be seen. Instead
# the transition owns a `shown` Signal:
#
#     open  -> shown True immediately, snap to hidden pose, tween in
#     close -> tween out, then shown False (via the tween on_done hook)
#
# Re-opening mid-exit cancels the pending hide (AnimatedSignal.to/set drops
# the old tween's on_done) and replays the enter. Bind:
#     tr = popup_transition(l.visible);
#     Window(hidden=tr.shown.map(_not), child=Box(opacity=tr.fade,
#                                                 margin_top=tr.slide, ...))
#
# Headless-testable: drive advance_animations(ms) and read tr.shown/fade/slide.
import from src.reactive { signal, Signal, effect, Reactive }
import from src.animation { animated, AnimatedSignal, ease }


# One transition instance per popup. The single effect keeps the open/close
# state machine consistent: it re-runs only when `visible` changes.
obj PopupTransition {
    has slide: AnimatedSignal;       # margin pose: offset (hidden) -> 0 (open)
    has fade: AnimatedSignal;        # opacity pose: 0 (hidden) -> 1 (open)
    has shown: Signal;               # window-mapped flag (False only after exit)
    has visible: any = None;         # watched open/close source
    has offset: float = 24.0;
    has enter_ms: float = 280.0;
    has enter_fade_ms: float = 200.0;
    has exit_ms: float = 220.0;
    has exit_fade_ms: float = 160.0;
    has opened: bool = False;        # gate: no exit tween before first open
}

def _sync_popup(tr: any, open_now: bool) {
    if open_now {
        tr.opened = True;
        tr.shown.set(True);                       # map the window now
        tr.slide.set(tr.offset);                  # hidden pose, cancel any exit
        tr.fade.set(0.0);
        tr.slide.to(0.0, ms=tr.enter_ms, ease_fn=ease.out);
        tr.fade.to(1.0, ms=tr.enter_fade_ms, ease_fn=ease.out);
    } elif tr.opened {
        # Exit: fade/slide out, keep the window mapped, hide on completion.
        # The slide tween is the longer one, so its on_done gates the hide.
        tr.fade.to(0.0, ms=tr.exit_fade_ms, ease_fn=ease.in_);
        tr.slide.to(tr.offset, ms=tr.exit_ms, ease_fn=ease.in_,
                    on_done=lambda { tr.shown.set(False); });
    }
}

def popup_transition(visible: Reactive,
                     offset: float = 24.0,
                     enter_ms: float = 280.0,
                     exit_ms: float = 220.0,
                     enter_fade_ms: float = 200.0,
                     exit_fade_ms: float = 160.0) -> PopupTransition {
    tr = PopupTransition(
        slide=animated(offset),
        fade=animated(0.0),
        shown=signal(False),
        visible=visible,
        offset=offset,
        enter_ms=enter_ms,
        exit_ms=exit_ms,
        enter_fade_ms=enter_fade_ms,
        exit_fade_ms=exit_fade_ms,
    );
    effect(lambda { _sync_popup(tr, bool(visible())); });
    return tr;
}
