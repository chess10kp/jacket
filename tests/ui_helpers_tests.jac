# ui_helpers_tests.jac — the pure per-row helpers behind the popup windows'
# reactive props (notif_ui.jac, launcher_ui.jac). Like the tray/workspace
# helpers (components_tests.jac), they're named defs — not inline lambdas — to
# dodge the Jac nested-lambda codegen bug, so they call directly. Most are field
# projections a row's .map binds; the ones with real logic (_urgency_class's
# class string, _empty's list predicate, _not_visible's negation) are the ones
# a shape/typo change would silently break. Import pulls only the gi *module*
# (no daemon/socket/display at import), so these run headless.
import from examples.reference.notif_ui { _app, _summary, _body, _urgency_class, _empty, _key }
import from examples.reference.launcher_ui {
    _not_visible, _slot_key, _row_label, _row_hidden, _make_slots, _sync_launcher_slide
}
import from src.animation { animated, ease, advance_animations, reset_animation_state }
import from src.reactive { flush }


test "notif_ui projections read the notification dict fields" {
    n = {"id": 7, "app_name": "Discord", "summary": "ping", "body": "hi there", "urgency": 1};
    assert _app(n) == "Discord";
    assert _summary(n) == "ping";
    assert _body(n) == "hi there";
    assert _key(n) == 7;
}

test "_urgency_class builds the per-urgency CSS class" {
    assert _urgency_class({"urgency": 0}) == "notif urgency-0";   # low
    assert _urgency_class({"urgency": 1}) == "notif urgency-1";   # normal
    assert _urgency_class({"urgency": 2}) == "notif urgency-2";   # critical
}

test "_empty drives the notif-layer's hidden binding off list length" {
    assert _empty([]) == True;
    assert _empty([{"id": 1}]) == False;
    assert _empty([{"id": 1}, {"id": 2}]) == False;
}

test "launcher_ui: _not_visible inverts the visible flag" {
    assert _not_visible(True) == False;
    assert _not_visible(False) == True;
}

test "launcher_ui: slot pool helpers pad to limit with stable keys" {
    apps = [
        {"name": "Firefox", "exec": "firefox", "key": "firefox.desktop", "lname": "firefox"},
        {"name": "Files", "exec": "nautilus", "key": "files.desktop", "lname": "files"},
    ];
    slots = _make_slots(apps, "f", 3);
    assert len(slots) == 3;
    assert _slot_key(slots[0]) == 0;
    assert _slot_key(slots[2]) == 2;
    assert _row_label(slots[0]) != "";
    assert _row_hidden(slots[0]) == False;
    assert _row_hidden(slots[2]) == True;
}

test "launcher_ui: _sync_launcher_slide animates on open, snaps on close" {
    reset_animation_state();
    slide = animated(24.0);
    fade = animated(0.0);
    _sync_launcher_slide(True, slide, fade);
    advance_animations(300);
    flush();
    assert fade() == 1.0;
    assert slide() == 0.0;
    _sync_launcher_slide(False, slide, fade);
    assert fade() == 0.0;
    assert slide() == 24.0;
}
