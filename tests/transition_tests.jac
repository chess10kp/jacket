# transition_tests.jac — headless tests for popup enter/exit transitions.
# popup_transition is the shared exit-animation state machine: `shown` must
# stay True while the exit tween plays, flip False only when it completes,
# and a mid-exit reopen must cancel the pending hide.
import from jacket.transition { popup_transition }
import from jacket.animation { advance_animations, active_tween_count, reset_animation_state }
import from jacket.reactive { signal, flush }


test "open maps the window and tweens the enter pose" {
    reset_animation_state();
    visible = signal(False);
    tr = popup_transition(visible);
    flush();
    assert tr.shown() == False;                 # never opened: stays hidden
    assert tr.fade() == 0.0;
    assert tr.slide() == 24.0;

    visible.set(True);
    flush();
    assert tr.shown() == True;                  # map immediately
    assert tr.fade.peek() < 1.0;                # tween underway
    advance_animations(280);
    flush();
    assert tr.fade() == 1.0;
    assert tr.slide() == 0.0;
    assert tr.shown() == True;
}

test "close keeps the window mapped until the exit tween completes" {
    reset_animation_state();
    visible = signal(False);
    tr = popup_transition(visible);
    flush();
    visible.set(True);
    flush();
    advance_animations(280);
    flush();

    visible.set(False);
    flush();
    assert tr.shown() == True;                  # still mapped mid-exit
    assert tr.fade.peek() > 0.0;
    advance_animations(220);                     # past both exit tweens
    flush();
    assert tr.fade() == 0.0;                    # tweened out, not snapped
    assert tr.slide() == 24.0;
    assert tr.shown() == False;                 # hidden only after completion
}

test "reopen mid-exit cancels the pending hide" {
    reset_animation_state();
    visible = signal(False);
    tr = popup_transition(visible);
    flush();
    visible.set(True);
    flush();
    advance_animations(280);
    flush();

    visible.set(False);                         # start exit
    flush();
    advance_animations(100);                    # halfway out
    flush();
    visible.set(True);                          # reopen before it finishes
    flush();
    assert tr.shown() == True;
    advance_animations(300);
    flush();
    assert tr.fade() == 1.0;                    # entered again
    assert tr.slide() == 0.0;
    assert tr.shown() == True;                  # the exit's hide never fired
}

test "custom offset and durations flow through" {
    reset_animation_state();
    visible = signal(False);
    tr = popup_transition(visible, offset=40.0, enter_ms=100, exit_ms=120,
                          enter_fade_ms=80, exit_fade_ms=90);
    flush();
    visible.set(True);
    flush();
    advance_animations(100);
    flush();
    assert tr.slide() == 0.0;
    visible.set(False);
    flush();
    advance_animations(120);
    flush();
    assert tr.slide() == 40.0;
    assert tr.fade() == 0.0;
    assert tr.shown() == False;
}
