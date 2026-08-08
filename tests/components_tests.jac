# components_tests.jac — the pure per-row helpers the widgets bind through .map.
# They exist as named defs (not inline lambdas) to dodge a Jac nested-lambda
# codegen bug (see components.jac), so they're plain functions we can call
# directly. _ws_class carries a real branch (active -> CSS class); the _tray_*
# accessors are the field projections each tray row's reactive props read off
# its per-row Signal. Locking them keeps a rename/typo in the item dict shape
# from silently blanking a workspace's active state or a tray icon.
#
# Importing examples.reference.components pulls the source get_*() singletons' *modules* (gi
# import only, no bus/socket/display at import time), so these run headless.
import from examples.reference.components { _ws_class, _tray_icon, _tray_texture, _tray_tip, _tray_key }


test "_ws_class flips the active CSS class off the item's active flag" {
    assert _ws_class({"active": True, "name": "1"}) == "ws active";
    assert _ws_class({"active": False, "name": "2"}) == "ws";
}

test "_tray_* project the row dict fields the reactive props bind" {
    it = {"icon": "firefox", "texture": None, "tooltip": "Firefox", "key": ":1.42/StatusNotifierItem"};
    assert _tray_icon(it) == "firefox";
    assert _tray_texture(it) is None;
    assert _tray_tip(it) == "Firefox";
    assert _tray_key(it) == ":1.42/StatusNotifierItem";
}

test "_tray_texture passes a live paintable through untouched" {
    # a texture is an opaque handle; the accessor must hand back identity, not a copy
    tex = ["opaque-paintable"];
    assert _tray_texture({"texture": tex}) is tex;
}
