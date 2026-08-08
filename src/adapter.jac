# adapter.jac — LIBRARY: the walled-off PyGObject seam (Phase 3).
# ---------------------------------------------------------------------------
# The one place PyGObject clunkiness lives: the gi bootstrap, enum coercion,
# construct-only handling, the one-parent unparent/destroy discipline, signal
# lifecycle. Everything above (reactive core, scheduler, builders, For) talks
# to GTK ONLY through the adapter contract:
#     construct / is_construct_only / set_prop / insert / remove / move /
#     connect / disconnect / child_at
#
# PHASE-0 FINDING: Jac breaks on attribute access of gi's OverridesProxyModule
# (Gtk.init -> OverridesProxyModule error). So the gi bootstrap + ALL proxy
# attribute access (constructors, enums, GLib) lives in a ::py:: block; only
# plain callables cross into Jac. Widget INSTANCES are usable directly from
# Jac (set_label/append/reorder_child_after/get_first_child all work), so most
# of the contract is Jac calling widget instance methods.
#
# If PyGObject ugliness leaks upward past this file, the abstraction failed.
import from src.adapter_api { set_adapter }


# ===========================================================================
# ::py:: shim — gi bootstrap + constructors + enums + main-loop helpers.
# Names defined here are callable from Jac. gi.require_version MUST run before
# importing gi.repository, and import statements run before entry code, so the
# bootstrap belongs here at module top.
# ===========================================================================
::py::
import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Gtk4LayerShell", "1.0")
gi.require_version("Gdk", "4.0")
from gi.repository import Gtk, GLib, Gdk, Gtk4LayerShell, GObject

def gtk_init():
    Gtk.init()

# --- constructors (construct-only props resolved here, inside python) -------
def make_box(orient="H"):
    o = Gtk.Orientation.HORIZONTAL if orient == "H" else Gtk.Orientation.VERTICAL
    return Gtk.Box(orientation=o)
def make_label():   return Gtk.Label()
def make_button():  return Gtk.Button()
def make_image():   return Gtk.Image()
def make_window():  return Gtk.Window()
def make_entry():   return Gtk.SearchEntry()
def make_scale(orient, lo, hi, step):
    o = Gtk.Orientation.HORIZONTAL if orient == "H" else Gtk.Orientation.VERTICAL
    s = Gtk.Scale.new_with_range(o, lo, hi, step)
    s.set_draw_value(False)
    s.set_hexpand(True)
    return s

# --- layer shell (top-level window wiring) ---------------------------------
def init_layer(w):
    try:
        Gtk4LayerShell.init_for_window(w)
        Gtk4LayerShell.set_layer(w, Gtk4LayerShell.Layer.TOP)
    except Exception:
        pass   # non-layer-shell compositor: fall back to a plain window

EDGE_TOP    = Gtk4LayerShell.Edge.TOP
EDGE_BOTTOM = Gtk4LayerShell.Edge.BOTTOM
EDGE_LEFT   = Gtk4LayerShell.Edge.LEFT
EDGE_RIGHT  = Gtk4LayerShell.Edge.RIGHT
def set_anchor(w, edge, val):  Gtk4LayerShell.set_anchor(w, edge, val)
def set_margin(w, edge, val):  Gtk4LayerShell.set_margin(w, edge, val)

def anchor_corner(w, corner):
    """Pin a popup to a screen corner (e.g. "top-right") with a small margin,
    sized to its content. No exclusive zone. No-op off layer-shell."""
    vmap = {"top": EDGE_TOP, "bottom": EDGE_BOTTOM}
    hmap = {"left": EDGE_LEFT, "right": EDGE_RIGHT}
    try:
        parts = corner.split("-")
        v = vmap.get(parts[0], EDGE_TOP)
        h = hmap.get(parts[1], EDGE_RIGHT)
        Gtk4LayerShell.set_anchor(w, v, True)
        Gtk4LayerShell.set_anchor(w, h, True)
        Gtk4LayerShell.set_margin(w, v, 44)          # clear the bar
        Gtk4LayerShell.set_margin(w, h, 12)
    except Exception:
        pass

# --- monitors (multi-output: one bar per connected monitor) ----------------
def list_monitors():
    """Every connected Gdk.Monitor, or [] before the display is up / headless."""
    d = Gdk.Display.get_default()
    if d is None:
        return []
    try:
        model = d.get_monitors()
        return [model.get_item(i) for i in range(model.get_n_items())]
    except Exception:
        return []

def monitor_key(m):
    """A stable per-monitor key (the connector name, e.g. "DP-1")."""
    try:
        c = m.get_connector()
        if c:
            return c
    except Exception:
        pass
    return str(id(m))

def set_window_monitor(w, m):
    """Pin a layer-shell window to a specific monitor (must precede map)."""
    if m is None:
        return
    try:
        Gtk4LayerShell.set_monitor(w, m)
    except Exception:
        pass

def destroy_window(w):
    try:
        w.destroy()
    except Exception:
        pass

def connect_monitors_changed(cb):
    """Fire cb() on monitor hotplug (items-changed on the monitors model)."""
    d = Gdk.Display.get_default()
    if d is None:
        return
    try:
        d.get_monitors().connect("items-changed", lambda model, pos, rem, add: cb())
    except Exception:
        pass

def set_layer(w, layer):
    m = {
        "overlay": Gtk4LayerShell.Layer.OVERLAY,
        "top": Gtk4LayerShell.Layer.TOP,
        "bottom": Gtk4LayerShell.Layer.BOTTOM,
        "background": Gtk4LayerShell.Layer.BACKGROUND,
    }
    try:
        Gtk4LayerShell.set_layer(w, m.get(layer, Gtk4LayerShell.Layer.TOP))
    except Exception:
        pass

def set_keyboard(w, on):
    # ON_DEMAND lets the popup grab the keyboard while focused (launcher typing),
    # then hand it back. NONE = never (bars).
    try:
        mode = Gtk4LayerShell.KeyboardMode.ON_DEMAND if on else Gtk4LayerShell.KeyboardMode.NONE
        Gtk4LayerShell.set_keyboard_mode(w, mode)
    except Exception:
        pass

def anchor_bar(w, edge):
    """Anchor a top-level as a bar: pin to left+right and one of top/bottom,
    and reserve its height (auto exclusive zone) so tiled windows don't overlap.
    No-op off layer-shell compositors."""
    try:
        Gtk4LayerShell.set_anchor(w, EDGE_LEFT, True)
        Gtk4LayerShell.set_anchor(w, EDGE_RIGHT, True)
        Gtk4LayerShell.set_anchor(w, EDGE_BOTTOM if edge == "bottom" else EDGE_TOP, True)
        Gtk4LayerShell.auto_exclusive_zone_enable(w)
    except Exception:
        pass

# --- main loop -------------------------------------------------------------
def idle_add(fn):      return GLib.idle_add(fn)
def timeout_add(ms, fn): return GLib.timeout_add(ms, fn)
def source_remove(sid):  return GLib.source_remove(sid)

def run_app(app_id, on_activate):
    app = Gtk.Application(application_id=app_id)
    app.connect("activate", lambda a: on_activate(a))
    return app.run()

# --- events: connect wraps arity so a 0-arg author handler just works. -----
# R2 (event arity): a `lambda:` ignores the payload; a `lambda (w)` that wants
# the widget gets it (e.g. Slider on_change reads w.get_value()); a handler
# that wants the raw signal payload gets it first (scroll deltas, keyvals).
def connect(w, signal, handler):
    def cb(*a):
        try:
            return handler()
        except TypeError:
            try:
                return handler(*a)
            except TypeError:
                return handler(w)
    return w.connect(signal, cb)
def disconnect(w, hid):
    if w is not None and hid:
        try: w.disconnect(hid)
        except Exception: pass

# --- CSS classes -----------------------------------------------------------
def set_css_classes(w, value):
    classes = value.split() if isinstance(value, str) else list(value)
    w.set_css_classes(classes)

# --- CSS: one app-level provider, added to the default display -------------
def load_css(text):
    prov = Gtk.CssProvider()
    try:
        prov.load_from_string(text)          # GTK >= 4.12
    except Exception:
        prov.load_from_data(text.encode(), -1)
    Gtk.StyleContext.add_provider_for_display(
        Gdk.Display.get_default(), prov,
        Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
::py::


# ===========================================================================
# Tag -> constructor map. Our vocabulary ("Box","Label") -> real widgets.
# ===========================================================================
def construct(tag: str, cprops: dict) -> any {
    if tag == "Box" { return make_box(cprops.get("orientation") or "H"); }
    if tag == "Label" { return make_label(); }
    if tag == "Button" { return make_button(); }
    if tag == "Icon" { return make_image(); }
    if tag == "Entry" { return make_entry(); }
    if tag == "Slider" {
        return make_scale(
            cprops.get("orientation") or "H",
            cprops.get("min") or 0.0,
            cprops.get("max") or 1.0,
            cprops.get("step") or 0.01,
        );
    }
    if tag == "Window" {
        w = make_window();
        init_layer(w);
        return w;
    }
    raise ValueError("unknown widget tag: " + tag);
}

glob CONSTRUCT_ONLY: dict = {
    "Box": {"orientation"},
    "Window": {"type"},
    "Slider": {"orientation", "min", "max", "step"},
};

def is_construct_only(tag: str, prop: str) -> bool {
    table: any = CONSTRUCT_ONLY.get(tag);
    if table is None { return False; }
    s: set = table;
    return prop in s;
}


# ---------------------------------------------------------------------------
# set_prop — the hot path (every reactive leaf patch lands here). Special
# cases first, generic GObject setter last.
# ---------------------------------------------------------------------------
glob SIGNAL_MAP: dict = {
    "on_click": "clicked",
    "on_toggle": "toggled",
    "on_activate": "activate",
    "on_change": "search-changed",
    "on_value_change": "value-changed",
};

def set_prop(w: any, name: str, value: any) {
    if w is None { return; }                       # defensive: node mid-teardown
    if name == "class" {
        set_css_classes(w, value);
    } elif name == "text" or name == "label" {
        if hasattr(w, "set_label") { w.set_label(str(value)); }
        else { w.set_text(str(value)); }
    } elif name == "hidden" {
        w.set_visible(not bool(value));
    } elif name == "icon" {
        if value { w.set_from_icon_name(str(value)); }   # "" would clobber a paintable
    } elif name == "paintable" {
        if value is not None { w.set_from_paintable(value); }
    } elif name == "placeholder" {
        w.set_placeholder_text(str(value));
    } elif name == "value" {
        w.set_value(float(value));
    } elif name == "width" {
        w.set_size_request(int(value), -1);
    } elif name == "height" {
        w.set_size_request(-1, int(value));
    } elif name == "tooltip" {
        w.set_tooltip_text(str(value));
    } elif name == "anchor" {
        anchor_bar(w, str(value));
    } elif name == "corner" {
        anchor_corner(w, str(value));
    } elif name == "monitor" {
        set_window_monitor(w, value);
    } elif name == "layer" {
        set_layer(w, str(value));
    } elif name == "keyboard" {
        set_keyboard(w, bool(value));
    } elif name == "orientation" {
        # settable on Gtk.Box via property
        w.set_orientation(0 if value == "H" else 1);
    } else {
        w.set_property(name.replace("_", "-"), value);
    }
}


# ---------------------------------------------------------------------------
# Tree ops — the one-parent invariant lives here.
# ---------------------------------------------------------------------------
def insert(parent: any, child: any, pos: int) {
    # Gtk.Box etc. have append()+reorder_child_after; Gtk.Window/Bin use set_child.
    if hasattr(parent, "append") {
        parent.append(child);
        prev = child_at(parent, pos - 1);              # None -> reorder to head
        parent.reorder_child_after(child, prev);
    } else {
        parent.set_child(child);
    }
}

def remove(child: any) {
    # Mirror insert()'s dual path: multi-child containers (Box/Grid) have
    # remove(); single-child ones (Button/Window/Bin) unparent via set_child(None)
    # and have NO remove(). Calling the wrong one raises and would abort a Dispose
    # walk mid-subtree (leaving a nested row's outer widget parented). unparent()
    # is the last-resort primitive for anything else.
    p = child.get_parent();
    if p is None { return; }                       # one-parent rule
    if hasattr(p, "remove") { p.remove(child); }
    elif hasattr(p, "set_child") { p.set_child(None); }
    else { child.unparent(); }
}

def move(parent: any, child: any, pos: int) {
    prev = child_at(parent, pos - 1);              # None -> head
    parent.reorder_child_after(child, prev);
}

def connect_signal(w: any, gtk_signal: str, handler: any) -> any {
    sig = SIGNAL_MAP.get(gtk_signal);
    if sig is None { sig = gtk_signal; }
    return connect(w, sig, handler);
}

def disconnect_signal(w: any, hid: int) { disconnect(w, hid); }


# ---------------------------------------------------------------------------
# GTK4 child access is a linked-list walk, no index API.
# ---------------------------------------------------------------------------
def child_at(parent: any, i: int) -> any {
    if i < 0 { return None; }
    c = parent.get_first_child();
    while i > 0 and c is not None { c = c.get_next_sibling(); i -= 1; }
    return c;
}


# ===========================================================================
# Install + run. main.jac calls install() once, then run_app with the root
# builder. The reactive scheduler is flushed on GLib.idle (one commit/tick).
# ===========================================================================
def install() {
    gtk_init();
    set_adapter(GtkAdapter());
}

# Load an app-level stylesheet (call after install(), before building).
def apply_css(text: str) { load_css(text); }

def run(build_roots: any, app_id: str) -> any {
    # build_roots() returns a LIST of top-level ViewNodes (bar, launcher,
    # notification layer, ...). Each is presented; the GLib loop then runs.
    def on_activate(a: any) {
        roots = build_roots();       # runs the build pass -> live widgets
        # Present each (realizes the layer surface); popups after the first are
        # hidden until their `visible` signal flips — present() maps them once so
        # a later set_visible(True) re-shows without a rebuild.
        first = True;
        for top in roots {
            top.widget.present();
            if not first { top.widget.set_visible(False); }
            first = False;
        }
    }
    return run_app(app_id, on_activate);
}

# run_dynamic — like run(), but hands the raw Gtk.Application `activate` to the
# caller so it can manage roots itself (multi-monitor bars present/destroy on
# hotplug). main.jac uses this; the reactive scheduler is still on GLib.idle.
def run_dynamic(on_activate: any, app_id: str) -> any {
    return run_app(app_id, on_activate);
}


# the adapter obj satisfying the contract the builders expect.
obj GtkAdapter {
    def construct(tag: str, cprops: dict) -> any { return construct(tag, cprops); }
    def is_construct_only(tag: str, prop: str) -> bool { return is_construct_only(tag, prop); }
    def set_prop(w: any, name: str, value: any) { set_prop(w, name, value); }
    def insert(parent: any, child: any, pos: int) { insert(parent, child, pos); }
    def remove(child: any) { remove(child); }
    def move(parent: any, child: any, pos: int) { move(parent, child, pos); }
    def child_at(parent: any, i: int) -> any { return child_at(parent, i); }
    def connect(w: any, signal: str, handler: any) -> any { return connect_signal(w, signal, handler); }
    def disconnect(w: any, hid: int) { disconnect_signal(w, hid); }
}
