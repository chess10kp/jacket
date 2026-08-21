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
import sys
# gtk4-layer-shell must be mapped into the process BEFORE GTK touches Wayland,
# so its ELF constructor installs the wl_registry hooks in time. Loading it
# globally here (ahead of `import gi`) replaces the LD_PRELOAD workaround —
# see https://github.com/wmww/gtk4-layer-shell/blob/main/linking.md
import ctypes, ctypes.util
_l4ls = ctypes.CDLL(
    ctypes.util.find_library("gtk4-layer-shell") or "libgtk4-layer-shell.so",
    mode=ctypes.RTLD_GLOBAL,
)
# The sealed binary embeds an isolated Python; distros ship PyGObject (gi) in
# system site-packages. Bridge to them for the matching minor version (the
# C extension ABI must match the embedded interpreter). This replaces the
# packaging/install.sh system_site.pth patch, which cannot travel inside the
# executable.
import glob as _glob, site as _site
for _sp in sorted(
    _glob.glob("/usr/lib*/python%d.%d/*-packages" % sys.version_info[:2])
):
    if _sp not in sys.path:
        _site.addsitedir(_sp)
try:
    import gi
except ImportError:
    raise ImportError(
        "jacket needs system PyGObject: install python3-gobject (or gi for "
        "python %d.%d) — the embedded runtime found no usable 'gi' module"
        % sys.version_info[:2]
    )
gi.require_version("Gtk", "4.0")
gi.require_version("Gtk4LayerShell", "1.0")
gi.require_version("Gdk", "4.0")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import Gtk, GLib, Gdk, GdkPixbuf, Gtk4LayerShell, GObject, Gio

def gtk_init():
    Gtk.init()

# --- constructors (construct-only props resolved here, inside python) -------
def make_box(orient="H"):
    o = Gtk.Orientation.HORIZONTAL if orient == "H" else Gtk.Orientation.VERTICAL
    return Gtk.Box(orientation=o)
def make_label():   return Gtk.Label()
def make_button():  return Gtk.Button()
def make_image():   return Gtk.Image()
_gtk_app = None
def set_gtk_application(app):
    global _gtk_app
    _gtk_app = app
def make_window():
    if _gtk_app is not None:
        return Gtk.Window(application=_gtk_app)
    return Gtk.Window()
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

def _is_layer_window(w) -> bool:
    """True when w is a Gtk.Window that gtk4-layer-shell adopted (init_layer
    succeeded). Routes margin_* between layer margins and widget margins."""
    try:
        return bool(Gtk4LayerShell.is_layer_window(w));
    except Exception:
        return False;

def anchor_corner(w, corner):
    """Pin a popup to a screen corner or edge-center ("top-right",
    "top-center"), sized to its content. exclusive_zone = -1 (swaybar's
    overlay-mode trick): the compositor NEVER moves it for other surfaces'
    reserved space — layer compositors seat popups explicitly via layer
    margins instead of relying on a lower layer's exclusive zone.
    No-op off layer-shell."""
    vmap = {"top": EDGE_TOP, "bottom": EDGE_BOTTOM}
    hmap = {"left": EDGE_LEFT, "right": EDGE_RIGHT}
    try:
        parts = corner.split("-")
        v = vmap.get(parts[0], EDGE_TOP)
        Gtk4LayerShell.set_anchor(w, v, True)
        Gtk4LayerShell.set_margin(w, v, 44)          # clear the bar (default)
        if len(parts) > 1 and parts[1] in hmap:
            h = hmap[parts[1]]
            Gtk4LayerShell.set_anchor(w, h, True)
            Gtk4LayerShell.set_margin(w, h, 12)
        Gtk4LayerShell.set_exclusive_zone(w, -1)
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
    # EXCLUSIVE grabs the keyboard as soon as the surface is visible (launcher
    # popups). ON_DEMAND only routes keys after a widget inside has focus, which
    # is easy to miss on show. NONE = never (bars).
    try:
        mode = Gtk4LayerShell.KeyboardMode.EXCLUSIVE if on else Gtk4LayerShell.KeyboardMode.NONE
        Gtk4LayerShell.set_keyboard_mode(w, mode)
    except Exception:
        pass

def grab_focus(w):
    try:
        w.grab_focus()
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

def _wrap_activate(on_activate):
    """Apply any CSS queued before the display existed, then run the author hook."""
    def wrapped(a):
        set_gtk_application(a)
        flush_pending_css()
        on_activate(a)
    return wrapped

def run_app(app_id, on_activate, non_unique=False):
    flags = Gio.ApplicationFlags.NON_UNIQUE if non_unique else Gio.ApplicationFlags.DEFAULT_FLAGS
    app = Gtk.Application(application_id=app_id, flags=flags)
    app.connect("activate", lambda a: _wrap_activate(on_activate)(a))
    return app.run(sys.argv)

def run_ipc_app(app_id, on_activate, on_request):
    """GApplication IPC transport: HANDLES_COMMAND_LINE forwards argv to the
    primary instance; on_request(argv) returns a str printed to the client's
    stdout via print_literal. PyGObject exposes is_remote as get_is_remote()."""
    app = Gtk.Application(
        application_id=app_id,
        flags=Gio.ApplicationFlags.HANDLES_COMMAND_LINE,
    )

    def command_line(a, cmd):
        rest = list(cmd.get_arguments())[1:]          # drop argv[0] (entry file)
        is_remote = cmd.get_is_remote()
        if not is_remote and not rest:
            app.activate()                            # server mode: build the bar
        if rest:
            try:
                resp = on_request(rest)
            except Exception as e:
                resp = "error: " + str(e)
            if resp is not None:
                s = str(resp)
                cmd.print_literal(s if s.endswith("\n") else s + "\n")
            if not is_remote:
                # cold one-shot query (no server up yet): answer, then exit so
                # we don't leave a bar running from a mere status request.
                GLib.idle_add(lambda: (app.quit(), False)[1])
        return 0

    app.connect("activate", lambda a: _wrap_activate(on_activate)(a))
    app.connect("command-line", command_line)
    return app.run(sys.argv)

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
_pending_css = None

def _apply_css(text):
    prov = Gtk.CssProvider()
    try:
        prov.load_from_string(text)          # GTK >= 4.12
    except Exception:
        prov.load_from_data(text.encode(), -1)
    Gtk.StyleContext.add_provider_for_display(
        Gdk.Display.get_default(), prov,
        Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

def load_css(text):
    """Load app-level CSS. If Gdk has no default display yet, defer until activate."""
    global _pending_css
    if Gdk.Display.get_default() is None:
        _pending_css = text
        return
    _apply_css(text)

def flush_pending_css():
    global _pending_css
    if _pending_css is not None:
        _apply_css(_pending_css)
        _pending_css = None

def load_css_file(path):
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    load_css(text)
    return text

def py_apply_css_file(path):
    return load_css_file(path)

# --- raw-pixel paintables (tray IconPixmap fallback), walled here so no module
# above the seam touches Gdk/GdkPixbuf. Takes (w, h, RGBA bytes); returns a
# Gdk.Texture or None when Gdk is unavailable (headless / future wl backend).
def py_make_texture(w, h, rgba):
    if Gdk is None:
        return None
    try:
        pb = GdkPixbuf.Pixbuf.new_from_bytes(
            GLib.Bytes.new(bytes(rgba)), GdkPixbuf.Colorspace.RGB, True, 8,
            w, h, w * 4)
        return Gdk.Texture.new_for_pixbuf(pb)
    except Exception:
        return None

def py_request_restart():
    """Re-exec the current process (preserves argv/env for --watch dev mode)."""
    import os
    exe = sys.executable
    argv = list(sys.argv)
    GLib.idle_add(lambda: (os.execv(exe, [exe] + argv), False)[1])

# --- anchored popovers (Quickshell PopupWindow analogue) -------------------
# Gtk.Popover anchors to a bar widget; show/hide is driven by hover or click.
_POS = {
    "top": Gtk.PositionType.TOP,
    "bottom": Gtk.PositionType.BOTTOM,
    "left": Gtk.PositionType.LEFT,
    "right": Gtk.PositionType.RIGHT,
}

def _make_popover(anchor_widget, content_widget, position="bottom"):
    if anchor_widget is None or content_widget is None:
        return None
    if not hasattr(anchor_widget, "add_controller"):
        return None
    pop = Gtk.Popover.new()
    pop.set_child(content_widget)
    pop.set_parent(anchor_widget)
    pop.set_position(_POS.get(str(position), Gtk.PositionType.BOTTOM))
    pop.set_has_arrow(True)
    pop.set_autohide(True)
    return pop

def py_attach_hover_popover(anchor_widget, content_widget, position="bottom",
                         show_delay_ms=100, hide_delay_ms=200):
    """Hover-triggered popover (Quickshell PopupWindow + hover timer pattern).
    Returns a cleanup callable, or None when headless / non-GTK handles."""
    pop = _make_popover(anchor_widget, content_widget, position)
    if pop is None:
        return None

    show_sid = [None]
    hide_sid = [None]
    on_trigger = [False]
    on_content = [False]

    def _cancel():
        for sid in (show_sid[0], hide_sid[0]):
            if sid:
                try:
                    GLib.source_remove(sid)
                except Exception:
                    pass
        show_sid[0] = hide_sid[0] = None

    def _open():
        show_sid[0] = None
        if on_trigger[0] or on_content[0]:
            try:
                pop.popup()
            except Exception:
                pass
        return False

    def _close():
        hide_sid[0] = None
        if not on_trigger[0] and not on_content[0]:
            try:
                pop.popdown()
            except Exception:
                pass
        return False

    def _schedule_open():
        _cancel()
        show_sid[0] = GLib.timeout_add(max(0, int(show_delay_ms)), _open)

    def _schedule_close():
        _cancel()
        hide_sid[0] = GLib.timeout_add(max(0, int(hide_delay_ms)), _close)

    def _trigger_enter(*a):
        on_trigger[0] = True
        _schedule_open()

    def _trigger_leave(*a):
        on_trigger[0] = False
        _schedule_close()

    def _content_enter(*a):
        on_content[0] = True
        _cancel()

    def _content_leave(*a):
        on_content[0] = False
        _schedule_close()

    ctrl = Gtk.EventControllerMotion.new()
    ctrl.connect("enter", _trigger_enter)
    ctrl.connect("leave", _trigger_leave)
    anchor_widget.add_controller(ctrl)

    cctrl = Gtk.EventControllerMotion.new()
    cctrl.connect("enter", _content_enter)
    cctrl.connect("leave", _content_leave)
    content_widget.add_controller(cctrl)

    def cleanup():
        _cancel()
        try:
            pop.popdown()
            pop.unparent()
        except Exception:
            pass

    return cleanup

def py_attach_click_popover(anchor_widget, content_widget, position="bottom"):
    """Click-toggle popover. Returns cleanup callable or None."""
    pop = _make_popover(anchor_widget, content_widget, position)
    if pop is None:
        return None

    def _toggle(*a):
        try:
            if pop.get_visible():
                pop.popdown()
            else:
                pop.popup()
        except Exception:
            pass

    gesture = Gtk.GestureClick.new()
    gesture.connect("pressed", _toggle)
    anchor_widget.add_controller(gesture)

    def cleanup():
        try:
            pop.popdown()
            pop.unparent()
        except Exception:
            pass

    return cleanup

# --- tray dbusmenu popover (the reference bar's right-click item menu) ------
# Menu construction + attachment live here so nothing above the seam touches
# Gtk/Gio widget APIs. build_menu_model turns a parsed dbusmenu tree into a
# (Gio.Menu, action group) pair; attach_popover wraps it in a PopoverMenu;
# py_attach_tray_menu wires the BUTTON_SECONDARY GestureClick that drives both.
def _build_menu_model(node, group, key, fire_cb):
    """Parsed dbusmenu tree -> (Gio.Menu, actions installed on `group`). Visible
    non-separator leaves become MenuItems bound to a "traymenu.i<id>" action whose
    activate fires the dbusmenu Event; separators flush a section; children recurse
    into submenus. Disabled entries get a disabled action (greyed, unclickable)."""
    menu = Gio.Menu()
    section = Gio.Menu()
    for child in node.get("children", []):
        if not child.get("visible", True):
            continue
        if child.get("separator"):
            if section.get_n_items() > 0:
                menu.append_section(None, section)
                section = Gio.Menu()
            continue
        label = child.get("label") or ""
        if child.get("children"):
            submodel = _build_menu_model(child, group, key, fire_cb)
            section.append_submenu(label, submodel)
            continue
        act = "i%d" % int(child["id"])
        section.append_item(Gio.MenuItem.new(label, "traymenu." + act))
        action = Gio.SimpleAction.new(act, None)
        action.set_enabled(bool(child.get("enabled", True)))

        def _on_activate(a, p, _id=int(child["id"])):
            try:
                fire_cb(key, _id)
            except Exception:
                pass
        action.connect("activate", _on_activate)
        group.add_action(action)
    if section.get_n_items() > 0:
        menu.append_section(None, section)
    return menu


def build_menu_model(node, key, fire_cb):
    """Parsed dbusmenu tree -> (Gio.Menu, SimpleActionGroup), or None when gi is
    unavailable (headless / future wl backend) or the tree has no children."""
    if Gtk is None or node is None or not node.get("children"):
        return None
    group = Gio.SimpleActionGroup()
    return (_build_menu_model(node, group, key, fire_cb), group)


def attach_popover(anchor_widget, model, group):
    """Wrap `model` in a PopoverMenu parented to anchor_widget and pop it up.
    The group is installed as "traymenu" so the model's actions resolve; the
    popover unparents itself on close. No-op headless or with no model."""
    if anchor_widget is None or model is None:
        return
    try:
        pop = Gtk.PopoverMenu.new_from_model(model)
        pop.insert_action_group("traymenu", group)
        pop.set_parent(anchor_widget)
        pop.connect("closed", lambda p: p.unparent())
        pop.popup()
    except Exception:
        pass


def py_attach_tray_menu(widget, key, fetch_cb, fire_cb):
    """Wire a right-button GestureClick on `widget`; on press, fetch_cb(key)
    yields the parsed dbusmenu tree, which becomes a PopoverMenu anchored to
    the button. No-op headless or when the widget isn't a live GTK handle."""
    if widget is None or Gtk is None:
        return

    def _on_pressed(gesture, n_press, x, y):
        try:
            tree = fetch_cb(key)
        except Exception:
            tree = None
        if not tree or not tree.get("children"):
            return
        built = build_menu_model(tree, key, fire_cb)
        if built is None:
            return
        attach_popover(widget, built[0], built[1])

    gesture = Gtk.GestureClick.new()
    gesture.set_button(3)          # 3 = BUTTON_SECONDARY (right click)
    gesture.connect("pressed", _on_pressed)
    widget.add_controller(gesture)
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
    "on_stop_search": "stop-search",
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
    } elif name == "opacity" {
        if hasattr(w, "set_opacity") { w.set_opacity(float(value)); }
    } elif name == "margin_top" {
        # Layer-shell windows position their SURFACE via layer margins; every
        # other widget uses the GTK margin (space INSIDE its parent window).
        if _is_layer_window(w) { set_margin(w, EDGE_TOP, int(value)); }
        else { w.set_margin_top(int(value)); }
    } elif name == "margin_bottom" {
        if _is_layer_window(w) { set_margin(w, EDGE_BOTTOM, int(value)); }
        else { w.set_margin_bottom(int(value)); }
    } elif name == "margin_start" {
        if _is_layer_window(w) { set_margin(w, EDGE_LEFT, int(value)); }
        else { w.set_margin_start(int(value)); }
    } elif name == "margin_end" {
        if _is_layer_window(w) { set_margin(w, EDGE_RIGHT, int(value)); }
        else { w.set_margin_end(int(value)); }
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

# Load an app-level stylesheet (safe before or after Gtk.Application starts;
# deferred automatically when Gdk.Display.get_default() is still None).
def apply_css(text: str) { load_css(text); }

def apply_css_file(path: str) { py_apply_css_file(path); }

def make_texture(w: int, h: int, rgba: bytes) -> any {
    return py_make_texture(w, h, rgba);
}

def request_restart() { py_request_restart(); }

def attach_hover_popover(
    anchor: any,
    content: any,
    position: str = "bottom",
    show_delay_ms: int = 100,
    hide_delay_ms: int = 200,
) -> any {
    return py_attach_hover_popover(anchor, content, position, show_delay_ms, hide_delay_ms);
}

def attach_click_popover(anchor: any, content: any, position: str = "bottom") -> any {
    return py_attach_click_popover(anchor, content, position);
}

def attach_tray_menu(anchor: any, key: str, fetch_cb: any, fire_cb: any) -> any {
    return py_attach_tray_menu(anchor, key, fetch_cb, fire_cb);
}

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
def run_dynamic(on_activate: any, app_id: str, non_unique: bool = False) -> any {
    return run_app(app_id, on_activate, non_unique);
}

# run_with_ipc — AGS-style request/response over GApplication command-line
# forwarding. Second launch with args runs on_request(argv) on the primary and
# prints the return value to the client's stdout. See src/ipc.jac for the
# registry handler; examples/swaybar/ is a full worked example.
def run_with_ipc(on_activate: any, on_request: any, app_id: str) -> any {
    return run_ipc_app(app_id, on_activate, on_request);
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
    def attach_hover_popover(anchor: any, content: any, position: str,
                             show_delay_ms: int, hide_delay_ms: int) -> any {
        return py_attach_hover_popover(anchor, content, position, show_delay_ms, hide_delay_ms);
    }
    def attach_click_popover(anchor: any, content: any, position: str) -> any {
        return py_attach_click_popover(anchor, content, position);
    }
}
