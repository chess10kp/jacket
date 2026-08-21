# wl_adapter.jac — raw Wayland client backend (WAYLAND_BACKEND.md §3/W1-W3).
# ---------------------------------------------------------------------------
# zwlr_layer_shell_v1 + wl_shm + pycairo, NO Gtk/Gdk/gtk4-layer-shell in the
# process. Implements the SAME adapter contract as adapter.jac / mock_adapter.jac:
#   construct / is_construct_only / set_prop / insert / remove / move /
#   child_at / connect / disconnect
# Selection at startup: install() here vs adapter.jac's install() — the same
# swap point the mock adapter uses (§3). Everything pywayland/pycairo/GLib
# lives inside this ::py:: block; plain callables + the WlAdapter obj cross
# upward (Phase-0 discipline: no foreign proxy attribute access above the seam).
#
# Rendering pipeline: the widget tree maintained through the contract is laid
# out (flexbox-lite) and painted onto a cairo image surface mapped into a
# wl_shm pool (ARGB8888, double-buffered), committed on configure/damage.
# Text is PangoCairo (narrow gi slice — pangocairo only, never Gtk/Gdk).
# Events ride the wl display fd through a GLib io watch, so sources, the
# scheduler's idle-flush hook, and IPC keep working unchanged (§4).
#
# Quirk log (§7): pywayland segfaults in interpreter teardown after
# disconnect(); we flush and let process exit tear down instead.
#
# W4 input: wl_seat pointer + keyboard ride the same fd pump. Pointer
# enter/leave/motion/button/axis are hit-tested against the LAID-OUT tree and
# dispatch the author-facing signals (on_click on release-inside, hover :hover
# style overrides, scroll/drag -> Slider value-changed). Keyboard goes through
# python-xkbcommon (compositor keymap fd -> State), routing keys into the
# focused Entry (printables + BackSpace fire on_change; Return fires
# on_activate; Esc fires on_stop_search). Headless tests inject synthetic
# events through the wl_inject_* callables — no display needed.
#
# Still open: popovers (W5).
import from src.adapter_api { set_adapter }


::py::
import os
import mmap
import re as _re
import tempfile as _tempfile

# Bridge system + user site-packages (gi/PangoCairo live in system dirs;
# pywayland/pycairo in the user dir). Same discipline as adapter.jac: needed
# because jac's bundled runtime has an isolated sys.path.
import sys as _sys
import glob as _glob
import site as _site
for _sp in sorted(_glob.glob("/usr/lib*/python%d.%d/*-packages" % _sys.version_info[:2])):
    if _sp not in _sys.path:
        _site.addsitedir(_sp)
for _sp in sorted(_glob.glob(
        os.path.expanduser("~/.local/lib/python%d.%d/site-packages" % _sys.version_info[:2]))):
    if _sp not in _sys.path:
        _site.addsitedir(_sp)

import cairo as _cairo
import gi as _gi
_gi.require_version("Pango", "1.0")
_gi.require_version("PangoCairo", "1.0")
from gi.repository import GLib as _GLib, Pango as _Pango, PangoCairo as _PangoCairo
from pywayland.client import Display as _WlDisplay
from pywayland.protocol.wayland import WlCompositor as _WlCompositor, WlShm as _WlShm, \
    WlOutput as _WlOutput, WlSeat as _WlSeat, WlPointer as _WlPointer, \
    WlKeyboard as _WlKeyboard
from pywayland.protocol.wlr_layer_shell_unstable_v1 import (
    ZwlrLayerShellV1 as _ZwlrLayerShellV1,
    ZwlrLayerSurfaceV1 as _ZwlrLayerSurfaceV1,
)
try:
    from xkbcommon import xkb as _xkb
except ImportError:          # headless test machines: injection still works
    _xkb = None


# ===========================================================================
# Connection — one Wayland display, integrated with the GLib loop.
# ===========================================================================
class WlConn:
    display = None
    compositor = None
    shm = None
    layer_shell = None
    outputs = {}            # wl_output proxy -> name str (assigned on done/global)
    watch_sid = None
    seat = None
    pointer = None
    keyboard = None

_conn = WlConn()


def _on_global(registry, name, iface, version):
    if iface == "wl_compositor":
        _conn.compositor = registry.bind(name, _WlCompositor, min(version, 5))
    elif iface == "wl_shm":
        _conn.shm = registry.bind(name, _WlShm, 1)
    elif iface == "zwlr_layer_shell_v1":
        _conn.layer_shell = registry.bind(name, _ZwlrLayerShellV1, min(version, 4))
    elif iface == "wl_seat":
        _conn.seat = registry.bind(name, _WlSeat, min(version, 5))
        _bind_seat()
    elif iface == "wl_output":
        out = registry.bind(name, _WlOutput, min(version, 3))
        _conn.outputs[out] = "output-%d" % len(_conn.outputs)


def _pump(fd=None, cond=None):
    """Read + dispatch pending wayland events + flush; runs on the GLib main
    thread. dispatch(block=False) only drains the queue — the socket read has
    to happen explicitly (wl_display_prepare/read_events)."""
    d = _conn.display
    if d is None:
        return False
    try:
        d.read()
    except Exception:
        pass
    try:
        d.dispatch(block=False)
    except Exception:
        pass
    try:
        d.flush()
    except Exception:
        pass
    return True


def connect_wayland():
    if _conn.display is not None:
        return
    d = _WlDisplay()
    d.connect()
    reg = d.get_registry()
    reg.dispatcher["global"] = _on_global
    d.roundtrip()
    if _conn.compositor is None or _conn.layer_shell is None:
        d.disconnect()
        raise RuntimeError(
            "compositor lacks zwlr_layer_shell_v1 — WlAdapter needs a "
            "layer-shell compositor (Hyprland/sway/wlroots-based)")
    _conn.display = d
    _conn.watch_sid = _GLib.io_add_watch(d.get_fd(), _GLib.IO_IN, _pump)


# ===========================================================================
# Input engine (W4). The dispatch CORE below (hit_test + wl_inject_*) is pure:
# it takes a laid-out widget root and surface-local coordinates, so headless
# tests drive the exact code path the live wl_pointer/wl_keyboard handlers do.
#
# Signal semantics mirror the GTK adapter (adapter.jac R2):
#   on_click        fired on button RELEASE inside the pressed widget (Button)
#   on_value_change Slider drag/scroll — continuous, handler reads get_value()
#   on_change       Entry text edits (printable keys + BackSpace)
#   on_activate     Entry Return/KP_Enter
#   on_stop_search  Entry Escape
# Handlers are arity-wrapped in wl_connect: a 0-arg lambda works everywhere; a
# `lambda (w)` receives the widget handle.
# ===========================================================================
_ptr = {"surf": None, "x": 0.0, "y": 0.0, "hover": None, "press": None}
_kbstate = {"ctx": None, "keymap": None, "state": None, "surface": None}
_surf_by_wl = {}            # wl_surface proxy -> BarSurface


def _bind_seat():
    if _conn.seat is None or _conn.pointer is not None:
        return
    p = _conn.pointer = _conn.seat.get_pointer()
    p.dispatcher["enter"] = _on_ptr_enter
    p.dispatcher["leave"] = _on_ptr_leave
    p.dispatcher["motion"] = _on_ptr_motion
    p.dispatcher["button"] = _on_ptr_button
    p.dispatcher["axis"] = _on_ptr_axis
    k = _conn.keyboard = _conn.seat.get_keyboard()
    k.dispatcher["keymap"] = _on_kb_keymap
    k.dispatcher["enter"] = _on_kb_enter
    k.dispatcher["leave"] = _on_kb_leave
    k.dispatcher["key"] = _on_kb_key
    k.dispatcher["modifiers"] = _on_kb_mods


def _surf_for_wl(surface_proxy):
    s = _surf_by_wl.get(surface_proxy)
    if s is not None:
        return s
    # pywayland normally reuses proxies, but match by wire id as a fallback.
    wid = getattr(surface_proxy, "id", None)
    for bar, wl in [(b, b.wl_surface) for b in _surf_by_wl.values()]:
        if getattr(wl, "id", None) == wid and wid is not None:
            return bar
    return None


def _on_ptr_enter(pointer, serial, surface, sx, sy):
    surf = _surf_for_wl(surface)
    _ptr["surf"] = surf
    _ptr["x"], _ptr["y"] = float(sx), float(sy)
    if surf is not None:
        wl_inject_motion(surf.win, _ptr["x"], _ptr["y"])


def _on_ptr_leave(pointer, serial, surface):
    surf = _ptr["surf"]
    _ptr["surf"] = None
    _ptr["press"] = None
    if surf is not None:
        wl_inject_motion(surf.win, -1.0, -1.0)     # outside every rect -> unhover


def _on_ptr_motion(pointer, time, sx, sy):
    surf = _ptr["surf"]
    _ptr["x"], _ptr["y"] = float(sx), float(sy)
    if surf is not None:
        wl_inject_motion(surf.win, _ptr["x"], _ptr["y"])


def _on_ptr_button(pointer, serial, time, button, state):
    surf = _ptr["surf"]
    if surf is None:
        return
    wl_inject_button(surf.win, _ptr["x"], _ptr["y"], int(button), state == 1)


def _on_ptr_axis(pointer, time, axis, value):
    # axis: 0 = vertical_scroll; value in wl_axis units (10 px per wheel step).
    surf = _ptr["surf"]
    if surf is None or axis != 0:
        return
    steps = -int(value / 10.0) if value else 0
    if steps:
        wl_inject_scroll(surf.win, _ptr["x"], _ptr["y"], steps)


def _on_kb_keymap(kb, fmt, fd, size):
    if _xkb is None or fmt != 1:
        return
    try:
        data = os.read(fd, size)
    finally:
        os.close(fd)
    ctx = _kbstate["ctx"] = _xkb.Context()
    km = ctx.keymap_new_from_buffer(data, format=1)
    _kbstate["keymap"] = km
    _kbstate["state"] = km.state_new()


def _on_kb_enter(kb, serial, surface, keys):
    _kbstate["surface"] = _surf_for_wl(surface)


def _on_kb_leave(kb, serial, surface):
    _kbstate["surface"] = None


def _on_kb_mods(kb, serial, dep, lat, lock, group):
    st = _kbstate["state"]
    if st is not None:
        st.update_mask(dep, lat, lock, group)


def _on_kb_key(kb, serial, msec, key, state):
    st = _kbstate["state"]
    surf = _kbstate["surface"]
    if st is None or surf is None or state != 1:
        return
    entry = getattr(surf.win, "focused", None)
    if not isinstance(entry, WlWidget):
        return
    kc = key + 8                       # evdev -> xkb keycode offset
    try:
        st.update_key(kc, _xkb.XKB_KEY_DOWN)
        sym_name = _xkb.keysym_get_name(st.key_get_one_sym(kc))
        text = st.key_get_string(kc) or ""
    except Exception:
        return
    _dispatch_key(entry, sym_name, text)


# --- dispatch core (shared by live events and headless injection) ----------

def hit_test(node, x, y):
    """Deepest visible laid-out node whose rect contains (x, y); None if no hit."""
    best = [None]

    def walk(n):
        if not n.visible():
            return
        nx, ny, nw, nh = n.rect
        if nw > 0 and nh > 0 and nx <= x < nx + nw and ny <= y < ny + nh:
            best[0] = n                 # children overwrite -> deepest wins
        for c in n.children:
            walk(c)

    walk(node)
    return best[0]


def _fire(w, signal, *args):
    for hid, fn in list(w.handlers.get(signal, [])):
        fn(*args)


def _window_of(w):
    root = w
    while root.parent is not None:
        root = root.parent
    return root if isinstance(root, WlWindow) else None


def _repaint_window(win):
    if win is None:
        return
    for s in win.surfaces:
        if s.canvas is not None:
            mark_dirty(s)


def _set_hover(widget):
    cur = _ptr["hover"]
    if cur is widget:
        return False
    if cur is not None:
        cur.hovered = False
        cur.resolve_style()      # drop :hover overrides (also covers headless)
    _ptr["hover"] = widget
    if widget is not None:
        widget.hovered = True
        widget.resolve_style()   # apply :hover overrides without waiting for paint
    return True


def _slider_bounds(slider):
    lo = float(slider.cprops.get("min") or 0)
    hi = float(slider.cprops.get("max") or 1)
    step = abs(float(slider.cprops.get("step") or 0.01)) or 0.01
    return lo, hi, step


def _slider_set(slider, val):
    lo, hi, step = _slider_bounds(slider)
    v = max(lo, min(hi, val))
    v = lo + round((v - lo) / step) * step
    if v == float(slider.props.get("value") or lo):
        return
    slider.props["value"] = v
    _fire(slider, "on_value_change")
    _repaint_window(_window_of(slider))


_KEY_SIGS = {
    "Escape": "on_stop_search",
    "Return": "on_activate",
    "KP_Enter": "on_activate",
}


def _dispatch_key(entry, sym_name, text):
    """Route one key press into a focused Entry. True if consumed."""
    sig = _KEY_SIGS.get(sym_name)
    if sig is not None:
        _fire(entry, sig)
        _repaint_window(_window_of(entry))
        return True
    if sym_name == "BackSpace":
        t = str(entry.props.get("text") or "")
        entry.props["text"] = t[:-1]
        _fire(entry, "on_change")
        _repaint_window(_window_of(entry))
        return True
    if text and not sym_name.startswith(("Control_", "Shift_", "Alt_", "Super_")):
        entry.props["text"] = str(entry.props.get("text") or "") + text
        _fire(entry, "on_change")
        _repaint_window(_window_of(entry))
        return True
    return False


# --- headless injection API -------------------------------------------------

def wl_inject_motion(root, x, y):
    """Move the synthetic pointer to surface-local (x, y): updates hover state
    (:hover styles) and drags a pressed Slider."""
    hit = hit_test(root, x, y)
    changed = _set_hover(hit)
    drag = _ptr["press"]
    if drag is not None and drag.tag == "Slider" and hit is not None:
        sx, _, sw, _ = drag.rect
        frac = 0.5 if sw <= 0 else max(0.0, min(1.0, (x - sx) / float(sw)))
        lo, hi, _ = _slider_bounds(drag)
        _slider_set(drag, lo + frac * (hi - lo))
        changed = False            # _slider_set already repainted
    if changed:
        _repaint_window(root if isinstance(root, WlWindow) else _window_of(root))


def wl_inject_button(root, x, y, button, pressed):
    """Synthetic button event at surface-local (x, y). button 0x110 = left.
    Release inside the pressed widget fires its on_click (GTK semantics)."""
    hit = hit_test(root, x, y)
    win = root if isinstance(root, WlWindow) else _window_of(root)
    if pressed:
        if win is not None:
            win.focused = hit if (hit is not None and hit.tag == "Entry") else None
        _ptr["press"] = hit
        _set_hover(hit)
        _repaint_window(win)
    else:
        target = _ptr["press"]
        _ptr["press"] = None
        if target is not None and target is hit and button == 0x110:
            _fire(target, "on_click")


def wl_inject_scroll(root, x, y, dy):
    """Synthetic scroll: dy > 0 scrolls down (= value decrease on a Slider)."""
    hit = hit_test(root, x, y)
    if hit is not None and hit.tag == "Slider":
        lo, hi, step = _slider_bounds(hit)
        _slider_set(hit, float(hit.props.get("value") or lo) - dy * step)


def wl_inject_key(root, name_or_char, pressed=True):
    """Headless keyboard: route one key into the focused Entry of this tree.
    name_or_char is an xkb keysym name ('Escape', 'Return', 'BackSpace') or a
    literal character ('a', '5', ' '). No-op when nothing is focused."""
    win = root if isinstance(root, WlWindow) else _window_of(root)
    entry = getattr(win, "focused", None) if win is not None else None
    if not pressed or not isinstance(entry, WlWidget):
        return False
    if len(name_or_char) == 1:
        return _dispatch_key(entry, name_or_char, name_or_char)
    return _dispatch_key(entry, name_or_char, "")


def wl_grab_focus(w):
    """Focus a focusable widget (Entries only today). Returns success."""
    if w is None or w.tag != "Entry":
        return False
    win = _window_of(w)
    if win is None:
        return False
    win.focused = w
    return True


# ===========================================================================
# CSS-subset parser (W3): selector { prop: value; } — later rule wins,
# :hover variants recorded separately for W4. No cascade beyond class lists.
# ===========================================================================
def parse_css(text):
    rules = []
    text = _re.sub(r"/\*.*?\*/", "", text, flags=_re.S)
    for m in _re.finditer(r"([^{}]+)\{([^{}]*)\}", text):
        props = {}
        hover = False
        sel = m.group(1).strip()
        if sel.endswith(":hover"):
            sel = sel[:-6].strip()
            hover = True
        for decl in m.group(2).split(";"):
            if ":" not in decl:
                continue
            k, v = decl.split(":", 1)
            k = k.strip().replace("-", "_")
            v = v.strip()
            if k == "padding":
                parts = v.split()
                vals = [_px(p) for p in (parts * 4)[:4]]
                if len(parts) == 1:
                    vals = [vals[0]] * 4
                elif len(parts) == 2:
                    vals = [vals[0], vals[1], vals[0], vals[1]]
                props["pad_t"], props["pad_r"], props["pad_b"], props["pad_l"] = vals
                continue
            props[k] = v
        rules.append((sel, hover, props))
    return rules


def _px(v):
    try:
        return int(float(str(v).rstrip("px")))
    except Exception:
        return 0


def _color(v):
    """'#rgb' / '#rrggbb' / '#rrggbbaa' -> (r,g,b,a) floats; None if unparsed."""
    if not isinstance(v, str) or not v.startswith("#"):
        return None
    h = v[1:]
    if len(h) == 3:
        h = "".join(c * 2 for c in h)
    if len(h) == 6:
        h += "ff"
    if len(h) != 8:
        return None
    try:
        n = int(h, 16)
    except ValueError:
        return None
    return ((n >> 24 & 255) / 255.0, (n >> 16 & 255) / 255.0,
            (n >> 8 & 255) / 255.0, (n & 255) / 255.0)


_glob_styles = {"rules": []}


# ===========================================================================
# Widget model — the handles that cross up into Jac.
# ===========================================================================
class WlWidget:
    _next_id = 1

    def __init__(self, tag, cprops=None):
        self.tag = tag
        self.cprops = dict(cprops or {})
        self.props = dict(self.cprops)
        cls = self.cprops.get("class")
        self.classes = cls if isinstance(cls, str) else " ".join(cls or [])
        self.parent = None
        self.children = []
        self.handlers = {}          # signal name -> list[(hid, fn)]
        self.hovered = False
        self.style = {}
        self.rect = (0, 0, 0, 0)    # last laid-out (x, y, w, h)
        self.hid = 0

    # -- tree ops ------------------------------------------------------------
    def insert_child(self, child, pos):
        child.parent = self
        pos = max(0, min(pos, len(self.children)))
        self.children.insert(pos, child)

    def remove_child(self, child):
        if child in self.children:
            self.children.remove(child)
        child.parent = None

    def child_at(self, i):
        if 0 <= i < len(self.children):
            return self.children[i]
        return None

    def visible(self):
        return not bool(self.props.get("hidden"))

    # -- API surface mirroring what authors call on live widgets -------------
    def present(self):
        if isinstance(self, WlWindow):
            self.map_surfaces()

    def get_text(self):
        return str(self.props.get("text") or "")

    def get_value(self):
        try:
            return float(self.props.get("value") or 0)
        except (TypeError, ValueError):
            return 0.0

    def set_visible(self, v):
        self.props["hidden"] = not v
        _dirty_parent_surfaces(self)

    def destroy(self):
        if isinstance(self, WlWindow):
            self.unmap_surfaces()

    # -- styling -------------------------------------------------------------
    def resolve_style(self):
        st = {}
        low = self.tag.lower()
        for sel, hover, props in _glob_styles["rules"]:
            if hover and not self.hovered:
                continue
            if sel.startswith("."):
                cls = sel[1:]
                if cls not in (self.classes or "").split():
                    continue
            elif sel != low:
                continue
            st.update(props)
        self.style = st


class WlWindow(WlWidget):
    def __init__(self, cprops=None):
        super().__init__("Window", cprops)
        self.surfaces = []          # list[BarSurface]
        self.presented = False
        self.focused = None         # focused WlWidget (Entries only today)

    def _autofocus(self):
        kb = str(self.props.get("keyboard") or "none")
        if kb in ("none", "") or self.focused is not None:
            return
        stack = [self]
        while stack:
            n = stack.pop(0)
            if n.tag == "Entry":
                self.focused = n
                return
            stack.extend(n.children)

    def map_surfaces(self):
        self.presented = True
        want = str(self.props.get("monitor") or "")
        for out in list(_conn.outputs):
            name = _conn.outputs[out]
            if want and name != want:
                continue
            if any(s.output is out for s in self.surfaces):
                continue
            self.surfaces.append(BarSurface(self, out))
        # blocking roundtrip is safe here: surfaces are only mapped before the
        # loop spins (or from handlers already on the main thread).
        _conn.display.roundtrip()
        self._autofocus()

    def unmap_surfaces(self):
        for s in self.surfaces:
            s.destroy()
        self.surfaces = []

    def sync_monitor(self, want):
        keep = []
        for s in self.surfaces:
            if want and s.output_name() != want:
                s.destroy()
            else:
                keep.append(s)
        self.surfaces = keep
        if self.presented:
            self.map_surfaces()


_dirty = set()
_dirty_scheduled = [False]


def mark_dirty(surface):
    _dirty.add(surface)
    if not _dirty_scheduled[0]:
        _dirty_scheduled[0] = True
        _GLib.idle_add(_redirty)


def _redirty():
    _dirty_scheduled[0] = False
    for s in list(_dirty):
        _dirty.discard(s)
        try:
            s.draw()
        except Exception:
            import traceback
            traceback.print_exc()
    return False


# ===========================================================================
# Surfaces + shm buffers (double-buffered ARGB8888 pools).
# ===========================================================================
class ShmCanvas:
    """A double-buffered wl_shm pool behind two cairo image surfaces."""

    def __init__(self, shm, w, h):
        self.shm = shm
        self.resize(w, h)

    def resize(self, w, h):
        self.w, self.h = w, h
        self.stride = _cairo.Format.stride_for_width(_cairo.FORMAT_ARGB32, w)
        frame = self.stride * h
        self.size = frame * 2
        f = _tempfile.NamedTemporaryFile(prefix="jacket-wl-", delete=False)
        f.truncate(self.size)
        f.close()
        self.path = f.name
        self.fd = os.open(self.path, os.O_RDWR)
        os.unlink(self.path)
        self.pool = self.shm.create_pool(self.fd, self.size)
        fmt = _WlShm.format.argb8888
        self.buffers = [
            self.pool.create_buffer(0, w, h, self.stride, fmt),
            self.pool.create_buffer(frame, w, h, self.stride, fmt),
        ]
        self.mm = mmap.mmap(self.fd, self.size)
        self.surfaces = [
            _cairo.ImageSurface.create_for_data(
                memoryview(self.mm)[off:off + frame],
                _cairo.FORMAT_ARGB32, w, h, self.stride)
            for off in (0, frame)
        ]
        self.idx = 0

    def next_surface(self):
        self.idx ^= 1
        return self.surfaces[self.idx], self.buffers[self.idx]

    def destroy(self):
        try:
            self.mm.close()
        except Exception:
            pass
        for b in self.buffers:
            try:
                b.destroy()
            except Exception:
                pass
        try:
            self.pool.destroy()
        except Exception:
            pass
        try:
            os.close(self.fd)
        except Exception:
            pass


_ANCHORS = {"top": 1, "bottom": 2, "left": 4, "right": 8}
_LAYERS = {"background": 0, "bottom": 1, "top": 2, "overlay": 3}
_KB = {"none": 0, "exclusive": 1, "on_demand": 2}


class BarSurface:
    """One layer surface: Window x output."""

    def __init__(self, win, output):
        self.win = win
        self.output = output
        self.canvas = None
        self.pending_cfg = None
        self.mapped = False
        edge = str(win.props.get("anchor") or "top")
        a = _ZwlrLayerSurfaceV1.anchor
        # Bars span the output: pin left+right + one vertical edge, reserving
        # space via the exclusive zone (the auto_exclusive_zone_enable analogue).
        bits = a.left | a.right | (a.bottom if "bottom" in edge.split("-") else a.top)
        horiz = True

        self.wl_surface = _conn.compositor.create_surface()
        _surf_by_wl[self.wl_surface] = self
        ls = self.lsurf = _conn.layer_shell.get_layer_surface(
            self.wl_surface, output,
            _LAYERS.get(str(win.props.get("layer") or "top"), 2),
            "jacket-bar")
        ls.set_anchor(bits)
        kb = _KB.get(str(win.props.get("keyboard") or "none"), 0)
        if kb:
            ls.set_keyboard_interactivity(kb)
        excl = win.props.get("exclusive")
        if excl is None:
            excl = horiz              # horizontal bars reserve space, like GTK auto zone
        if excl:
            self.exclusive = int(win.props.get("height") or 32)
        else:
            self.exclusive = 0
        ls.set_exclusive_zone(self.exclusive if excl else 0)
        self.desired_h = int(win.props.get("height") or 32)
        ls.set_size(0 if horiz else 10, self.desired_h)
        ls.dispatcher["configure"] = self._on_configure
        self.wl_surface.commit()

    def output_name(self):
        return _conn.outputs.get(self.output, "")

    def _on_configure(self, lsurf, serial, w, h):
        self.pending_cfg = (serial, int(w), int(h) or self.desired_h)
        # ack + draw right away: we're on the main thread inside _pump().
        self._apply_configure()

    def _apply_configure(self):
        cfg = self.pending_cfg
        if cfg is None:
            return
        self.pending_cfg = None
        serial, w, h = cfg
        self.lsurf.ack_configure(serial)
        if self.canvas is None or self.canvas.w != w or self.canvas.h != h:
            old = self.canvas
            self.canvas = ShmCanvas(_conn.shm, max(w, 1), max(h, 1))
            if old is not None:
                old.destroy()
        self.mapped = True
        self.draw()

    def draw(self):
        if self.canvas is None or not self.mapped:
            return
        surf, buf = self.canvas.next_surface()
        cr = _cairo.Context(surf)
        cr.save()
        cr.set_source_rgba(0, 0, 0, 0)
        cr.set_operator(_cairo.Operator.SOURCE)
        cr.paint()
        cr.restore()
        try:
            paint_tree(cr, self.win, self.canvas.w, self.canvas.h)
        except Exception:
            import traceback
            traceback.print_exc()
        surf.flush()
        self.wl_surface.attach(buf, 0, 0)
        self.wl_surface.damage(0, 0, self.canvas.w, self.canvas.h)
        self.wl_surface.commit()
        try:
            _conn.display.flush()
        except Exception:
            pass

    def destroy(self):
        try:
            self.lsurf.destroy()
        except Exception:
            pass
        try:
            self.wl_surface.destroy()
        except Exception:
            pass
        if _ptr["surf"] is self:
            _ptr["surf"] = None
        if _kbstate["surface"] is self:
            _kbstate["surface"] = None
        _surf_by_wl.pop(self.wl_surface, None)
        if self.canvas is not None:
            self.canvas.destroy()
            self.canvas = None
        _dirty.discard(self)


# ===========================================================================
# Flexbox-lite layout + paint over the widget tree.
# ===========================================================================
_measure_ctx = [None]


def _measurer():
    if _measure_ctx[0] is None:
        tmp = _cairo.ImageSurface(_cairo.FORMAT_ARGB32, 1, 1)
        cr = _cairo.Context(tmp)
        _measure_ctx[0] = _PangoCairo.create_layout(cr)
    return _measure_ctx[0]


def _font_desc(st):
    d = _Pango.FontDescription()
    fam = st.get("font_family")
    if fam:
        d.set_family(fam.split(",")[0].strip().strip("'\""))
    size = _px(st.get("font_size", ""))
    if size:
        d.set_absolute_size(size * _Pango.SCALE)
    w = st.get("font_weight")
    if w:
        try:
            d.set_weight(int(w))
        except ValueError:
            pass
    return d


def _text_size(node):
    lay = _measurer()
    lay.set_font_description(_font_desc(node.style))
    lay.set_text(str(node.props.get("text") or node.props.get("label") or ""), -1)
    return lay.get_pixel_size()


def _pad(st, key, default=0):
    return int(st.get(key) or default)


def natural_size(node):
    """Content-box natural (w, h) of a node's own paint, excluding margins."""
    if not node.visible():
        return (0, 0)
    node.resolve_style()
    st = node.style
    pt, pr, pb, pl = (_pad(st, "pad_t"), _pad(st, "pad_r"),
                      _pad(st, "pad_b"), _pad(st, "pad_l"))
    if node.tag == "Label":
        tw, th = _text_size(node)
        w, h = tw + pl + pr, th + pt + pb
    elif node.tag in ("Entry",):
        w, h = 200 + pl + pr, 28 + pt + pb
    elif node.tag in ("Slider",):
        w, h = 140 + pl + pr, 20 + pt + pb
    elif node.tag == "Icon":
        w, h = 16 + pl + pr, 16 + pt + pb
    else:
        # containers: stack children per orientation
        vert = str(node.cprops.get("orientation") or "H").upper().startswith("V")
        kw = kh = 0
        for c in node.children:
            cw, ch = natural_size_full(c)
            if vert:
                kh += ch
                kw = max(kw, cw)
            else:
                kw += cw
                kh = max(kh, ch)
        w, h = kw + pl + pr, kh + pt + pb
    mw = _pad(node.style, "min_width")
    mh = _pad(node.style, "min_height")
    pw = int(node.props.get("width") or 0)
    ph = int(node.props.get("height") or 0)
    return (max(w, mw, pw), max(h, mh, ph))


def natural_size_full(node):
    """Natural size including the node's margins."""
    st = node.style
    w, h = natural_size(node)
    return (w + _pad(st, "margin_l") + _pad(st, "margin_r"),
            h + _pad(st, "margin_t") + _pad(st, "margin_b"))


def layout_tree(node, x, y, w, h):
    """Assign rects depth-first. Box model: margins sit OUTSIDE the allocation
    the parent hands out; padding sits INSIDE the node's own rect."""
    node.resolve_style()
    if not node.visible():
        _zero_rects(node)
        return
    node.rect = (x, y, w, h)
    if not node.children:
        return
    st = node.style
    pt, pr, pb, pl = (_pad(st, "pad_t"), _pad(st, "pad_r"),
                      _pad(st, "pad_b"), _pad(st, "pad_l"))
    cx, cy = x + pl, y + pt
    cw, ch = w - pl - pr, h - pt - pb
    if cw <= 0 or ch <= 0:
        for c in node.children:
            c.rect = (x, y, 0, 0)
        return
    kids = [c for c in node.children if c.visible()]
    if not kids:
        return
    vert = str(node.cprops.get("orientation") or "H").upper().startswith("V")

    # Windows fill their children across the whole surface (the GTK Window ->
    # set_child behaviour): every visible child gets the full content area.
    if node.tag == "Window":
        for c in kids:
            layout_tree(c, cx, cy, cw, ch)
        return

    nats = [natural_size_full(c) for c in kids]
    expanders = [i for i, c in enumerate(kids)
                 if c.props.get("expand") or c.style.get("expand")]
    fixed = 0
    for i, (nw, nh) in enumerate(nats):
        if i not in expanders:
            fixed += nw if not vert else nh
    free = (cw if not vert else ch) - fixed
    share = max(0, free // len(expanders)) if expanders else 0

    cur = cy if vert else cx
    for i, c in enumerate(kids):
        cst = c.style
        mt, mr, mb, ml = (_pad(cst, "margin_t"), _pad(cst, "margin_r"),
                          _pad(cst, "margin_b"), _pad(cst, "margin_l"))
        nw, nh = nats[i][0] - ml - mr, nats[i][1] - mt - mb
        if vert:
            aw = cw - ml - mr
            ah = share if i in expanders else max(nh, 0)
            ax, ay = cx + ml, cur + mt
            cur += ah + mt + mb
        else:
            aw = share if i in expanders else max(nw, 0)
            ah = ch - mt - mb
            ax, ay = cur + ml, cy + mt
            cur += aw + ml + mr
        layout_tree(c, ax, ay, max(int(aw), 0), max(int(ah), 0))


def _rounded_rect(cr, x, y, w, h, r):
    r = max(0, min(r, w / 2.0, h / 2.0))
    if r <= 0:
        cr.rectangle(x, y, w, h)
        return
    cr.new_sub_path()
    cr.arc(x + w - r, y + r, r, -_PI / 2, 0)
    cr.arc(x + w - r, y + h - r, r, 0, _PI / 2)
    cr.arc(x + r, y + h - r, r, _PI / 2, _PI)
    cr.arc(x + r, y + r, r, _PI, 3 * _PI / 2)
    cr.close_path()


_PI = 3.141592653589793


def paint_tree(cr, node, w, h):
    layout_tree(node, 0, 0, w, h)
    _paint(cr, node)


def _paint(cr, node):
    if not node.visible():
        return
    st = node.style
    x, y, w, h = node.rect
    if w <= 0 or h <= 0:
        return
    bg = _color(st.get("background"))
    radius = _px(st.get("border_radius", ""))
    if bg is not None:
        cr.save()
        cr.set_source_rgba(*bg)
        _rounded_rect(cr, x, y, w, h, radius)
        cr.fill()
        cr.restore()
    bw = _px(st.get("border_width", "") or st.get("border", ""))
    bc = _color(st.get("border_color"))
    if bw > 0 and bc is not None:
        cr.save()
        cr.set_source_rgba(*bc)
        cr.set_line_width(bw)
        _rounded_rect(cr, x + bw / 2.0, y + bw / 2.0, w - bw, h - bw, radius)
        cr.stroke()
        cr.restore()

    if node.tag == "Label":
        col = _color(st.get("color")) or (1, 1, 1, 1)
        lay = _PangoCairo.create_layout(cr)
        lay.set_font_description(_font_desc(st))
        lay.set_text(str(node.props.get("text") or node.props.get("label") or ""), -1)
        tw, th = lay.get_pixel_size()
        lx = x + _pad(st, "pad_l")
        ly = y + max(0, (h - th) // 2)
        cr.save()
        cr.set_source_rgba(*col)
        cr.move_to(lx, ly)
        _PangoCairo.show_layout(cr, lay)
        cr.restore()
    elif node.tag == "Entry":
        col = _color(st.get("color")) or (1, 1, 1, 1)
        txt = str(node.props.get("text") or "")
        if not txt:
            txt = str(node.props.get("placeholder") or "")
            col = (col[0], col[1], col[2], 0.5 * col[3])
        if txt:
            lay = _PangoCairo.create_layout(cr)
            lay.set_font_description(_font_desc(st))
            lay.set_text(txt, -1)
            cr.save()
            cr.set_source_rgba(*col)
            cr.move_to(x + _pad(st, "pad_l") + 2, y + max(0, (h - lay.get_pixel_size()[1]) // 2))
            _PangoCairo.show_layout(cr, lay)
            cr.restore()
    elif node.tag == "Slider":
        val = float(node.props.get("value") or 0)
        lo = float(node.cprops.get("min") or 0)
        hi = float(node.cprops.get("max") or 1)
        frac = 0.5
        if hi > lo:
            frac = max(0.0, min(1.0, (val - lo) / (hi - lo)))
        cr.save()
        cr.set_source_rgba(1, 1, 1, 0.18)
        _rounded_rect(cr, x, y + h / 2 - 3, w, 6, 3)
        cr.fill()
        cr.set_source_rgba(0.55, 0.57, 1.0, 0.9)
        _rounded_rect(cr, x, y + h / 2 - 3, max(6.0, w * frac), 6, 3)
        cr.fill()
        cr.restore()
    elif node.tag == "Icon":
        col = _color(st.get("color")) or (1, 1, 1, 0.7)
        cr.save()
        cr.set_source_rgba(*col)
        _rounded_rect(cr, x + 2, y + 2, w - 4, h - 4, 3)
        cr.set_line_width(1.5)
        cr.stroke()
        cr.restore()

    for c in node.children:
        _paint(cr, c)


# ===========================================================================
# Contract implementation — the plain callables Jac talks to.
# ===========================================================================
_CONSTRUCT_ONLY = {
    "Box": {"orientation"},
    "Window": {"type"},
    "Slider": {"orientation", "min", "max", "step"},
}

_TAGS = {"Box", "Label", "Button", "Icon", "Entry", "Slider", "Window"}

_SAME = ("text", "label")


def wl_construct(tag, cprops):
    if tag not in _TAGS:
        raise ValueError("unknown widget tag: " + tag)
    if tag == "Window":
        w = WlWindow(cprops)
    else:
        w = WlWidget(tag, cprops)
    return w


def wl_is_construct_only(tag, prop):
    return prop in _CONSTRUCT_ONLY.get(tag, ())


def wl_set_prop(w, name, value):
    if w is None:
        return
    w.props[name] = value
    if name == "class":
        w.classes = value if isinstance(value, str) else " ".join(value)
    if isinstance(w, WlWindow):
        if name in ("anchor", "layer", "keyboard", "height", "exclusive"):
            for s in list(w.surfaces):
                s.destroy()
            w.surfaces = []
            if w.presented:
                w.map_surfaces()
        elif name == "monitor":
            w.sync_monitor(str(value or ""))
        return
    for s in _win_surfaces_of(w):
        mark_dirty(s)


def _win_surfaces_of(w):
    root = w
    while root.parent is not None:
        root = root.parent
    if isinstance(root, WlWindow):
        return [s for s in root.surfaces if s.canvas is not None]
    return []


def _dirty_parent_surfaces(w):
    for s in _win_surfaces_of(w):
        mark_dirty(s)


def _zero_rects(node):
    node.rect = (0, 0, 0, 0)
    for c in node.children:
        _zero_rects(c)


def wl_insert(parent, child, pos):
    parent.insert_child(child, pos)
    for s in _win_surfaces_of(parent):
        mark_dirty(s)


def wl_remove(child):
    p = child.parent
    if p is not None:
        p.remove_child(child)
        for s in _win_surfaces_of(p):
            mark_dirty(s)


def wl_move(parent, child, pos):
    if child in parent.children:
        parent.children.remove(child)
    parent.insert_child(child, pos)
    for s in _win_surfaces_of(parent):
        mark_dirty(s)


def wl_child_at(parent, i):
    return parent.child_at(i)


def wl_connect(w, signal, handler):
    # R2 event arity (mirrors adapter.jac): a 0-arg author lambda ignores the
    # payload; `lambda (w)` gets the widget; extra payload args pass through.
    def cb(*a):
        try:
            return handler()
        except TypeError:
            try:
                return handler(*a)
            except TypeError:
                return handler(w)
    w.hid += 1
    w.handlers.setdefault(signal, []).append((w.hid, cb))
    return w.hid


def wl_disconnect(w, hid):
    for sig, lst in list(w.handlers.items()):
        w.handlers[sig] = [(i, f) for (i, f) in lst if i != hid]


def wl_apply_css(text):
    _glob_styles["rules"] = parse_css(text)


def wl_present(w):
    if w is not None:
        w.present()


def wl_quit():
    if _conn.display is not None:
        try:
            _conn.display.flush()
        except Exception:
            pass
    loop = _loop.get("loop")
    if loop is not None:
        loop.quit()


_loop = {"loop": None}


def wl_run(on_activate, non_unique=False):
    connect_wayland()
    on_activate(None)
    loop = _GLib.MainLoop()
    _loop["loop"] = loop
    try:
        loop.run()
    except KeyboardInterrupt:
        pass
    finally:
        _loop["loop"] = None
        _pump()


def install_wl_backend():
    connect_wayland()
    set_adapter(WlAdapter())


# --- headless render probes (tests/wl_adapter_tests.jac) --------------------
def offscreen_surface(w, h):
    return _cairo.ImageSurface(_cairo.FORMAT_ARGB32, w, h)


def offscreen_context(surf):
    return _cairo.Context(surf)
::py::


# ===========================================================================
# The adapter obj satisfying the contract (mirrors GtkAdapter/MockAdapter).
# ===========================================================================
obj WlAdapter {
    def construct(tag: str, cprops: dict) -> any { return wl_construct(tag, cprops); }
    def is_construct_only(tag: str, prop: str) -> bool { return bool(wl_is_construct_only(tag, prop)); }
    def set_prop(w: any, name: str, value: any) { wl_set_prop(w, name, value); }
    def insert(parent: any, child: any, pos: int) { wl_insert(parent, child, pos); }
    def remove(child: any) { wl_remove(child); }
    def move(parent: any, child: any, pos: int) { wl_move(parent, child, pos); }
    def child_at(parent: any, i: int) -> any { return wl_child_at(parent, i); }
    def connect(w: any, signal: str, handler: any) -> any { return wl_connect(w, signal, handler); }
    def disconnect(w: any, hid: int) { wl_disconnect(w, hid); }
    def grab_focus(w: any) -> bool { return bool(wl_grab_focus(w)); }
    def attach_hover_popover(anchor: any, content: any, position: str,
                             show_delay_ms: int, hide_delay_ms: int) -> any {
        return None;    # W4/W5: layer-surface popups
    }
    def attach_click_popover(anchor: any, content: any, position: str) -> any {
        return None;
    }
}


# --- install + run (the swap point; see §3) ---------------------------------
def install() {
    install_wl_backend();
}

def apply_css(text: str) { wl_apply_css(text); }

def run(build_roots: any, app_id: str) -> any {
    def activate(a: any) {
        roots = build_roots();
        for top in roots {
            wl_present(top.widget);
        }
    }
    return wl_run(activate);
}

def run_dynamic(on_activate: any, app_id: str, non_unique: bool = False) -> any {
    return wl_run(on_activate, non_unique);
}

def quit() { wl_quit(); }
