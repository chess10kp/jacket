# ui_helpers_tests.jac — the pure per-row helpers behind the popup windows'
# reactive props (notif_ui.jac, launcher_ui.jac). Like the tray/workspace
# helpers (components_tests.jac), they're named defs — not inline lambdas — to
# dodge the Jac nested-lambda codegen bug, so they call directly. Most are field
# projections a row's .map binds; the ones with real logic (_urgency_class's
# class string, _empty's list predicate, _not_visible's negation) are the ones
# a shape/typo change would silently break. Import pulls only the gi *module*
# (no daemon/socket/display at import), so these run headless.
import from examples.reference.notif_ui { _app, _summary, _body, _urgency_class, _empty, _key }
import from examples.reference.launcher_ui { _not_visible, _row_key }


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

test "launcher_ui: _not_visible inverts the visible flag; _row_key reads the key" {
    assert _not_visible(True) == False;
    assert _not_visible(False) == True;
    assert _row_key({"key": "firefox.desktop", "name": "Firefox"}) == "firefox.desktop";
}
