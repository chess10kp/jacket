# REFERENCE — cookbook widgets built on the jacket library (LIBRARY.md §1).
#
# components.jac — the real bar widgets (PLAN Phase 4/5 milestone).
# ---------------------------------------------------------------------------
# Components in the fine-grained style: bodies run ONCE; state/derivations live
# where declared; no re-render. Each widget binds a source Signal to a leaf
# prop via .map — one effect, one patch per change (PLAN §3).
import from time { strftime, localtime }
import from jacket.reactive { signal }
import from jacket.osp { Child, Anchored }
import from jacket.builders { component, Box, Label, Button, Window, For, row_item, Slider }
import from jacket.sources { ticker }
import from jacket.wm { get_wm }
import from jacket.battery { get_battery, battery_icon }
import from jacket.bluetooth { get_bluetooth }
import from jacket.audio { get_audio }
import from jacket.mpris { get_mpris, format_status }
import from jacket.notifications { get_notifications }
import from jacket.launcher { get_launcher }
import from jacket.tray { get_tray }
import from jacket.desktop { get_desktop }
import from jacket.policy { active_modes, toggle_mode }
import from jacket.projection { present_surface_views }


# ===========================================================================
# ::py:: seam — the ONE GTK-direct spot in components: a right-click gesture +
# a Gtk.PopoverMenu built from the tray's parsed dbusmenu tree. The adapter's
# event map has no right-click channel and the builders expose no popover, so
# this talks to the live Gtk.Button widget directly (mirrors the walled-off
# gi style of adapter.jac / tray.jac). Only `attach_tray_menu` crosses to Jac.
# ===========================================================================
::py::
import gi
try:
    gi.require_version("Gtk", "4.0")
    from gi.repository import Gtk, Gio, GLib
except Exception:
    Gtk = None
    Gio = None
    GLib = None


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


def attach_tray_menu(widget, key, fetch_cb, fire_cb):
    """Wire a right-button GestureClick on `widget`; on press, fetch_cb(key) yields
    the parsed dbusmenu tree, which we turn into a PopoverMenu anchored to the
    button. No-op headless (gi import failed) or when the item ships no menu."""
    if widget is None or Gtk is None:
        return

    def _on_pressed(gesture, n_press, x, y):
        try:
            tree = fetch_cb(key)
        except Exception:
            tree = None
        if not tree or not tree.get("children"):
            return
        group = Gio.SimpleActionGroup()
        model = _build_menu_model(tree, group, key, fire_cb)
        pop = Gtk.PopoverMenu.new_from_model(model)
        pop.insert_action_group("traymenu", group)
        pop.set_parent(widget)
        pop.connect("closed", lambda p: p.unparent())
        pop.popup()

    gesture = Gtk.GestureClick.new()
    gesture.set_button(3)          # 3 = BUTTON_SECONDARY (right click)
    gesture.connect("pressed", _on_pressed)
    widget.add_controller(gesture)
::py::


# Clock — pure derivation off a source, no local state. Proves the leaf-patch
# path: every tick the source changes, the derived string recomputes, one
# set_label/second. (PLAN Phase-3 milestone.)
@component
def Clock() -> any {
    t = ticker(1000);
    return Label(
        class="clock",
        text=t.map(lambda (tv: any) { strftime("%a %d %b  %H:%M:%S", localtime(tv)); }),
    );
}


# Workspaces — the first real `For`, keyed on workspace id. The source is chosen
# per-compositor by wm.get_wm() (sway/i3 or Hyprland). Rows are reused across
# reconciles, so each button's live content (name, active class) reads its
# per-row Signal via row_item(); the `w` snapshot is used only for the stable id
# in the click closure. (On an unknown WM with no IPC this renders empty.)
#
# The row builder is a named def, NOT an inline lambda: nesting .map lambdas
# inside a row *lambda* trips a Jac codegen scoping bug (__jac_lambda not
# defined). A def hosts the same nested lambdas cleanly.
def _ws_class(c: dict) -> str { return "ws active" if c["active"] else "ws"; }

def ws_row(w: dict) -> any {
    cur = row_item();
    wid = w["id"];
    h = get_wm();
    return Button(
        class=cur.map(_ws_class),
        label=cur.map(lambda (c: dict) { c["name"]; }),
        on_click=lambda { h.focus(wid); },
    );
}

@component
def Workspaces() -> any {
    h = get_wm();
    return Box(orientation="H", class="workspaces", children=[
        For(h.workspaces, key=lambda (w: dict) { w["key"]; }, row=ws_row),
    ]);
}


# BluetoothWidget — first connected device name; hidden when nothing is connected.
def _bt_label(name: str) -> str {
    return ("" if name == "" else "BT  " + name);
}

@component
def BluetoothWidget() -> any {
    b = get_bluetooth();
    return Label(
        class="bluetooth",
        hidden=b.primary_device.map(lambda (n: str) { n == ""; }),
        text=b.primary_device.map(_bt_label),
    );
}


# BatteryWidget — icon + percent, hidden entirely when no battery is present.
@component
def BatteryWidget() -> any {
    b = get_battery();
    return Label(
        class="battery",
        hidden=b.battery.map(lambda (d: dict) { not d["present"]; }),
        text=b.battery.map(lambda (d: dict) {
            battery_icon(d["percent"], d["charging"]) + "  " + str(d["percent"]) + "%";
        }),
    );
}


# Volume — click to mute/unmute; hover panel wired on the bar root in Bar().
def _vol_label(d: dict) -> str {
    return ("MUTE  " if d["muted"] else "VOL  ") + str(d["percent"]) + "%";
}

@component
def VolumePanel() -> any {
    a = get_audio();
    return Box(orientation="V", class="volume-overlay", children=[
        Label(class="volume-overlay-title",
            text=a.volume.map(lambda (d: dict) { "Volume " + str(d["percent"]) + "%"; })),
        Slider(class="volume-slider", min=0, max=100, step=1,
            value=a.volume.map(lambda (d: dict) { d["percent"]; }),
            on_value_change=lambda (w: any) { get_audio().set_volume(int(w.get_value())); }),
    ]);
}

@component
def VolumeButton() -> any {
    a = get_audio();
    return Button(
        class="volume",
        label=a.volume.map(_vol_label),
        on_click=lambda { a.toggle_mute(); },
    );
}


# MediaWidget — MPRIS now-playing; click toggles play/pause. Hidden when no
# player is present (empty status string).
@component
def MediaWidget() -> any {
    m = get_mpris();
    return Button(
        class="media",
        hidden=m.player.map(lambda (p: dict) { not p["has_player"]; }),
        label=m.player.map(format_status),
        on_click=lambda { m.play_pause(); },
    );
}


# NotificationsWidget — a bell + active count; hidden when nothing is pending.
# (The daemon lives on the session bus; this reflects its active list.)
@component
def NotificationsWidget() -> any {
    d = get_notifications();
    return Label(
        class="notifications",
        hidden=d.notifications.map(lambda (ns: list) { len(ns) == 0; }),
        text=d.notifications.map(lambda (ns: list) { "NOTIF " + str(len(ns)); }),
    );
}


# TrayWidget — StatusNotifierItem system tray. A `For` over the watcher's live
# item list, keyed on the canonical bus+path. Items update IN PLACE (an app fires
# NewIcon/NewStatus on the same key), so each row reads its per-row Signal via
# row_item() and binds label/tooltip off it. GTK icon names/pixmaps are skipped
# here — they often fail to render in layer-shell bars; the item's title initial
# (or a plain '?') is more reliable. Left-click calls Activate.
def _tray_label(it: dict) -> str {
    t = str(it["title"] or it["id"] or "").strip();
    if t != "" { return t[0:1]; }
    return "?";
}
def _tray_tip(it: dict) -> str { return it["tooltip"]; }
def _tray_key(it: dict) -> any { return it["key"]; }
def _tray_activate(key: str) { get_tray().activate(key); }

# Right-click plumbing. These two named callables are the ONLY things that cross
# from the GTK popover (built in the seam below) back into the tray source: fetch
# the parsed dbusmenu tree, and fire an Event when an entry is chosen. Passing
# them as plain callables keeps the seam free of any jacket.tray import.
def _tray_fetch_menu(key: str) -> any { return get_tray().load_menu(key); }
def _tray_fire(key: str, item_id: int) { get_tray().fire(key, item_id); }

def tray_row(it: dict) -> any {
    cur = row_item();
    key = it["key"];
    lbl = Label(class="tray-label", text=cur.map(_tray_label));
    btn = Button(class="tray-item", child=lbl,
        tooltip=cur.map(_tray_tip),
        on_click=lambda { _tray_activate(key); });
    # Right-click: attach a GestureClick to the live GTK button; on press it
    # fetches the dbusmenu tree and pops up a PopoverMenu. Direct-to-widget wiring
    # (the adapter/builders expose no right-click channel or popover primitive).
    attach_tray_menu(btn.widget, key, _tray_fetch_menu, _tray_fire);
    return btn;
}

@component
def TrayWidget() -> any {
    t = get_tray();
    return Box(orientation="H", class="tray", children=[
        For(t.items, key=_tray_key, row=tray_row),
    ]);
}


# Bar — composition. left: workspaces; center: clock; right: volume + battery.
# Spacer Boxes with hexpand push the three groups apart.
# LauncherButton — the apps toggle; opens the launcher popup window.
@component
def LauncherButton() -> any {
    l = get_launcher();
    return Button(class="launcher-toggle", label="Apps",
        on_click=lambda { l.toggle(); });
}


def _toggle_presentation() {
    s = get_desktop();
    if s is None { return; }
    toggle_mode(s, "presentation");
    present_surface_views(s);
}

def _toggle_dnd() {
    s = get_desktop();
    if s is None { return; }
    toggle_mode(s, "do-not-disturb");
    present_surface_views(s);
}

def _pres_class(modes: list) -> str {
    return "mode-toggle active" if "presentation" in modes else "mode-toggle";
}

def _dnd_class(modes: list) -> str {
    return "mode-toggle active" if "do-not-disturb" in modes else "mode-toggle";
}

@component
def ModeButtons() -> any {
    modes = active_modes();
    return Box(orientation="H", class="mode-toggles", children=[
        Button(class=modes.map(_pres_class), label="Pres", tooltip="Presentation mode",
            on_click=lambda { _toggle_presentation(); }),
        Button(class=modes.map(_dnd_class), label="DND", tooltip="Do not disturb",
            on_click=lambda { _toggle_dnd(); }),
    ]);
}


# Bar takes the monitor it should pin to (None = let the compositor choose, the
# single-output / headless fallback). main.jac builds one per connected output.
@component
def MinimalBar(mon: any = None) -> any {
    win = Window(class="bar minimal", anchor="top", monitor=mon);
    inner = Box(orientation="H", class="bar-inner minimal");
    win +>:Child(order=0):+> inner;
    inner +>:Child(order=0):+> Clock();
    return win;
}


@component
def Bar(mon: any = None) -> any {
    win = Window(class="bar", anchor="top", monitor=mon);
    inner = Box(orientation="H", class="bar-inner");
    win +>:Child(order=0):+> inner;
    inner +>:Child(order=0):+> LauncherButton();
    inner +>:Child(order=1):+> Workspaces();
    inner +>:Child(order=2):+> MediaWidget();
    inner +>:Child(order=3):+> Box(orientation="H", class="spacer", hexpand=True);
    inner +>:Child(order=4):+> Clock();
    inner +>:Child(order=5):+> Box(orientation="H", class="spacer", hexpand=True);
    inner +>:Child(order=6):+> ModeButtons();
    inner +>:Child(order=7):+> TrayWidget();
    inner +>:Child(order=8):+> NotificationsWidget();
    vol = VolumeButton();
    vol +>:Anchored(mode="hover", position="bottom"):+> VolumePanel();
    inner +>:Child(order=9):+> vol;
    inner +>:Child(order=10):+> BluetoothWidget();
    inner +>:Child(order=11):+> BatteryWidget();
    return win;
}
