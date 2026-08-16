# components_tests.jac — the pure per-row helpers the widgets bind through .map.
# They exist as named defs (not inline lambdas) to dodge a Jac nested-lambda
# codegen bug (see components.jac), so they're plain functions we can call
# directly. _ws_class carries a real branch (active -> CSS class); the _tray_*
# accessors are the field projections each tray row's reactive props read off
# its per-row Signal. Locking them keeps a rename/typo in the item dict shape
# from silently blanking a workspace's active state or a tray row. The tray
# contract post-OSP-rewrite is {id, title, tooltip, key} — no icon-name or
# pixmap texture; rows render a first-letter glyph (or the fallback glyph).
#
# Importing examples.reference.components pulls the source get_*() singletons' *modules* (gi
# import only, no bus/socket/display at import time), so these run headless.
import from examples.reference.components { _ws_class, _tray_label, _tray_tip, _tray_key }


test "_ws_class flips the active CSS class off the item's active flag" {
    assert _ws_class({"active": True, "name": "1"}) == "ws active";
    assert _ws_class({"active": False, "name": "2"}) == "ws";
}

test "_tray_* project the row dict fields the reactive props bind" {
    it = {"id": ":1.42/StatusNotifierItem", "title": "Firefox", "tooltip": "Firefox", "key": ":1.42/StatusNotifierItem"};
    assert _tray_label(it) == "F";
    assert _tray_tip(it) == "Firefox";
    assert _tray_key(it) == ":1.42/StatusNotifierItem";
}

test "_tray_label falls back to a glyph when title and id are empty" {
    assert _tray_label({"id": "", "title": None, "tooltip": "", "key": "k"}) == "󰇮";
}
