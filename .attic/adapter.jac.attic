# adapter.jac  —  DESIGN SKETCH (illustrative pseudo-Jac)
# ---------------------------------------------------------------------------
# THE WALLED-OFF SEAM. This is the one file where PyGObject's clunkiness is
# ALLOWED to live: boxing, enum coercion, construct-only handling, the
# one-parent unparent/destroy discipline, signal-handler lifecycle.
#
# Everything above it (reactive core, scheduler, builders, For) talks to GTK
# ONLY through this contract:
#     construct / set_prop / insert / remove / move / connect / disconnect
#     + is_construct_only
# Keep it that way — if PyGObject ugliness leaks upward, the abstraction failed.
#
# This is genuine LEAF work: no cleverness, just a correct, defensive mapping
# from our tag/prop vocabulary to real GTK4 calls. Written LAST because the
# engine can be developed and tested against a mock adapter first.
#
# Real imports (illustrative Jac spelling):
#     import from gi.repository { Gtk, Gdk, GObject, GLib, Gtk4LayerShell }
# ===========================================================================


# ---------------------------------------------------------------------------
# Tag -> GTK class map. Our vocabulary ("Box","Label") -> real constructors.
# ---------------------------------------------------------------------------
glob WIDGET_TYPES: dict = {
    "Box":    Gtk.Box,
    "Label":  Gtk.Label,
    "Button": Gtk.Button,
    "Icon":   Gtk.Image,
    "Window": Gtk.Window,      # top-level; layer-shell-wrapped (see below)
    # ... extend as widgets are needed
};

# Construct-only props: MUST be passed at construction, can't be set after.
# Changing one at runtime = REMOUNT the widget (builders/For handle that path).
# Keyed by tag; the builder calls is_construct_only() to split these out.
glob CONSTRUCT_ONLY: dict = {
    "Box":    {"orientation"},
    "Window": {"type"},
    # most props are settable; this set stays small
};

def is_construct_only(tag: str, prop: str) -> bool {
    return prop in (CONSTRUCT_ONLY.get(tag) or {});
}


# ---------------------------------------------------------------------------
# construct — build the real widget. Construct-only props go in here.
# ---------------------------------------------------------------------------
def construct(tag: str, construct_props: dict) -> any {
    cls = WIDGET_TYPES.get(tag);
    if cls == None { raise ValueError(f"unknown widget tag: {tag}"); }

    # coerce enum-shaped construct props (orientation="H" -> Gtk.Orientation)
    kwargs = {k: coerce(tag, k, v) for k, v in construct_props.items()};
    w = cls(**kwargs);

    if tag == "Window" { init_layer_shell(w); }   # gtk4-layer-shell wiring
    return w;
}


# ---------------------------------------------------------------------------
# set_prop — the hot path (every reactive leaf patch lands here). Must be
# fast and defensive. This is where the ugly prop-name -> GTK-call mapping and
# all the marshalling live. Special cases first, generic GObject setter last.
# ---------------------------------------------------------------------------
def set_prop(w: any, name: str, value: any) {
    if w == None { return; }                       # defensive: node mid-teardown

    if name == "class" {
        # GTK4 CSS classes: reconcile the whole class string. Cheap + correct.
        set_css_classes(w, value);
    } elif name == "text" or name == "label" {
        w.set_label(str(value)) if hasattr(w, "set_label") else w.set_text(str(value));
    } elif name == "hidden" {
        w.set_visible(not bool(value));
    } elif name == "icon" {
        w.set_from_icon_name(str(value));
    } elif name == "tooltip" {
        w.set_tooltip_text(str(value));
    } else {
        # GENERIC path: GObject property. This is the marshalling swamp —
        # set_property boxes into GValue; wrong types segfault instead of
        # raising, so coerce first.
        w.set_property(name.replace("_", "-"), coerce_value(value));
    }
}

def set_css_classes(w: any, value: any) {
    # value may be "a b c" (string) or a list; GTK4 has set_css_classes(list)
    classes = value.split() if isinstance(value, str) else list(value);
    w.set_css_classes(classes);
}


# ---------------------------------------------------------------------------
# Tree ops — insert / remove / move. The one-parent invariant lives here.
# GTK4 forbids implicit reparenting; every add has an explicit remove, and
# unmount MUST unparent+destroy or the widget (and its subtree) leaks.
# ---------------------------------------------------------------------------
def insert(parent: any, child: any, pos: int) {
    # Gtk.Box has no insert-at-index; append then reorder to position.
    parent.append(child);
    if pos < child_count(parent) - 1 {
        prev = nth_child(parent, pos - 1);         # None -> becomes first
        parent.reorder_child_after(child, prev);
    }
}

def remove(parent: any, child: any) {
    parent.remove(child);      # unparent (one-parent rule)
    # GTK4 widgets are refcounted; dropping the last ref finalizes. remove()
    # drops the parent's ref. If we hold no other ref (we don't — the ViewNode
    # is being disposed), it finalizes. Explicit run_dispose() if we ever pin.
}

def move(parent: any, child: any, after_widget: any) {
    # after_widget == None -> move to head. Minimizing these calls is why the
    # two-ended diff exists (each is a real GTK relayout).
    parent.reorder_child_after(child, after_widget);
}


# ---------------------------------------------------------------------------
# Events — connect returns an id we stash so the owner's cleanup can disconnect.
# GTK signals are stringly-typed; on_click -> "clicked", on_change -> "changed".
# ---------------------------------------------------------------------------
glob SIGNAL_MAP: dict = {
    "on_click":  "clicked",
    "on_change": "changed",
    "on_toggle": "toggled",
    "on_hover":  "enter",
    # ... GTK signal names are per-widget; extend as needed
};

def connect(w: any, gtk_signal: str, handler: any) -> int {
    # wrap so the GTK-supplied first arg (the widget) is swallowed unless the
    # author's handler wants it — keeps authoring handlers argument-free.
    return w.connect(gtk_signal, lambda *a: handler());
}

def disconnect(w: any, handler_id: int) {
    if w != None and handler_id { w.disconnect(handler_id); }
}


# ---------------------------------------------------------------------------
# Coercion — the boxing/enum swamp, contained. Turn our friendly vocabulary
# ("H", "V", python ints/strs) into what GObject's GValue marshalling expects.
# ---------------------------------------------------------------------------
glob ENUMS: dict = {
    ("Box", "orientation"): {"H": Gtk.Orientation.HORIZONTAL,
                             "V": Gtk.Orientation.VERTICAL},
};

def coerce(tag: str, prop: str, v: any) -> any {
    table = ENUMS.get((tag, prop));
    return (table.get(v) or v) if table else v;
}

def coerce_value(v: any) -> any {
    # last-resort generic coercion for the set_property path; extend as the
    # segfault-instead-of-exception cases are discovered in practice.
    return v;
}


# ---------------------------------------------------------------------------
# Layer shell + main loop — the shell-specific top-level wiring.
# ---------------------------------------------------------------------------
def init_layer_shell(window: any) {
    Gtk4LayerShell.init_for_window(window);
    Gtk4LayerShell.set_layer(window, Gtk4LayerShell.Layer.TOP);
    # anchors/margins/exclusive-zone set later via set_prop on the Window node
}

def run_app(build_root: any) {
    # build_root: a zero-arg fn that constructs the @component tree once.
    app = Gtk.Application(application_id="org.jac.shell");
    def on_activate(a: any) {
        root = build_root();          # runs the build pass -> live widgets
        root.widget.present();
    }
    app.connect("activate", on_activate);
    app.run(None);                    # GLib main loop; our flush() rides idle_add
}


# ---------------------------------------------------------------------------
# small helpers referenced above (child_count / nth_child) — GTK4 child
# iteration is via get_first_child / get_next_sibling, not an index API.
# ---------------------------------------------------------------------------
def child_count(w: any) -> int {
    n = 0; c = w.get_first_child();
    while c != None { n += 1; c = c.get_next_sibling(); }
    return n;
}
def nth_child(w: any, i: int) -> any {
    if i < 0 { return None; }
    c = w.get_first_child();
    while i > 0 and c != None { c = c.get_next_sibling(); i -= 1; }
    return c;
}


# ===========================================================================
# WHY THIS IS THE UGLIEST FILE, ON PURPOSE:
#   - set_property boxes into GValue; wrong type = segfault, not exception
#   - GTK4 child access is a linked-list walk, no index API (child_count/nth)
#   - signals are stringly-typed and per-widget (SIGNAL_MAP)
#   - construct-only vs settable is a real distinction the engine must respect
#   - one-parent rule: every add pairs with an explicit remove or it leaks
# All of it stops HERE. Nothing above imports `gi`. That is the whole contract.
# ===========================================================================
