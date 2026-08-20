# animation_tests.jac — headless tests for the GTK-free tween scheduler.
import from src.animation {
    animated, follow, enter_tween, ease, advance_animations,
    active_tween_count, reset_animation_state,
}
import from src.reactive {
    signal, computed, effect, create_scope, enter_scope, exit_scope, flush,
}
import from src.mock_adapter { install_mock, delta_ops, count_kind }
import from src.builders { Label, Box }


test "animated starts at initial value" {
    reset_animation_state();
    a = animated(5);
    assert a() == 5;
    assert a.peek() == 5;
    assert not a.is_running();
}

test "to completes at target after duration" {
    reset_animation_state();
    a = animated(0);
    a.to(100, ms=100, ease_fn=ease.linear);
    advance_animations(100);
    flush();
    assert a() == 100;
    assert not a.is_running();
}

test "mid-tween interpolates linearly" {
    reset_animation_state();
    a = animated(0);
    a.to(100, ms=100, ease_fn=ease.linear);
    advance_animations(50);
    flush();
    v = a();
    assert abs(v - 50) < 1;
}

test "retarget mid-flight" {
    reset_animation_state();
    a = animated(0);
    a.to(100, ms=100, ease_fn=ease.linear);
    advance_animations(50);
    flush();
    assert abs(a() - 50) < 1;
    a.to(0, ms=50, ease_fn=ease.linear);
    advance_animations(50);
    flush();
    assert a() == 0;
    assert not a.is_running();
}

test "set snaps and cancels tween" {
    reset_animation_state();
    a = animated(0);
    a.to(100, ms=100);
    advance_animations(25);
    a.set(42);
    flush();
    assert a() == 42;
    assert not a.is_running();
    advance_animations(100);
    flush();
    assert a() == 42;
}

test "follow chases reactive target" {
    reset_animation_state();
    target = signal(0);
    anim = follow(target, ms=100, ease_fn=ease.linear);
    flush();
    target.set(100);
    flush();
    advance_animations(100);
    flush();
    assert anim() == 100;
    assert not anim.is_running();
}

test "scope disposal stops tween" {
    reset_animation_state();
    scope = create_scope();
    prev = enter_scope(scope);
    a = animated(0);
    a.to(100, ms=1000);
    exit_scope(prev);
    assert active_tween_count() == 1;
    scope.dispose();
    assert active_tween_count() == 0;
    assert not a.is_running();
    advance_animations(1000);
    flush();
    assert a() == 0;
}

test "enter_tween animates from to to" {
    reset_animation_state();
    a = enter_tween(0, 1, ms=100, ease_fn=ease.linear);
    assert a() == 0;
    advance_animations(100);
    flush();
    assert a() == 1;
    assert not a.is_running();
}

test "integration Label opacity reactive prop patches" {
    reset_animation_state();
    m = install_mock();
    opacity = animated(0);
    opacity.to(1, ms=100, ease_fn=ease.linear);
    Label(opacity=opacity);
    flush();
    n0 = len(m.ops);
    advance_animations(50);
    flush();
    advance_animations(50);
    flush();
    delta = delta_ops(m.ops, n0);
    assert count_kind(delta, "set_prop") >= 1;
    assert opacity() == 1;
}
