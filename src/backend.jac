# Renderer selection shim — W6 "flip the default renderer".
#
# Picks the windowing backend once, then re-exports the app-level surface the
# shell configs import (install / run_with_ipc / css / monitors / restart).
# Selection order:
#   JACKET_RENDERER=gtk          -> GTK adapter (legacy path)
#   JACKET_RENDERER=wl           -> Wayland adapter (hard pick)
#   JACKET_RENDERER=auto/unset   -> wl when WAYLAND_DISPLAY is usable, else GTK
# All pywayland/GLib/Gtk tokens stay inside the two backend modules; this file
# only delegates through plain callables (adapter-seam rule).
::py::
import importlib
import os

_state = {"mod": None}

_BACKENDS = {
    "gtk": "src.adapter",
    "wl": "src.wl_adapter",
}


def _wayland_usable():
    if not os.environ.get("WAYLAND_DISPLAY"):
        return False
    try:
        importlib.import_module("pywayland")
        return True
    except Exception:
        return False


def resolve_backend():
    """Return the chosen backend module, memoized."""
    if _state["mod"] is not None:
        return _state["mod"]
    choice = (os.environ.get("JACKET_RENDERER") or "auto").strip().lower()
    name = _BACKENDS.get(choice)
    if name is None:  # auto
        name = "src.wl_adapter" if _wayland_usable() else "src.adapter"
    mod = importlib.import_module(name)
    _state["mod"] = mod
    return mod


def reset_backend_cache():
    """Test hook: forget the memoized backend so env changes re-resolve."""
    _state["mod"] = None


def backend_name_bk():
    return resolve_backend().__name__


def install_bk():
    getattr(resolve_backend(), "install")()


def run_with_ipc_bk(on_activate, on_request, app_id):
    mod = resolve_backend()
    if hasattr(mod, "run_with_ipc"):
        return mod.run_with_ipc(on_activate, on_request, app_id)
    return mod.run_dynamic(on_activate, app_id)


def apply_css_bk(text):
    getattr(resolve_backend(), "apply_css")(text)


def apply_css_file_bk(path):
    getattr(resolve_backend(), "apply_css_file")(path)


def request_restart_bk():
    getattr(resolve_backend(), "request_restart")()


def list_monitors_bk():
    return list(getattr(resolve_backend(), "list_monitors")())


def monitor_key_bk(m):
    return getattr(resolve_backend(), "monitor_key")(m)


def connect_monitors_changed_bk(cb):
    return getattr(resolve_backend(), "connect_monitors_changed")(cb)
::py::

# Jac-level API (names mirror src.adapter so shell configs can swap imports).
def backend_name() -> str { return str(backend_name_bk()); }

def install() { install_bk(); }

def run_with_ipc(on_activate: any, on_request: any, app_id: str) -> any {
    return run_with_ipc_bk(on_activate, on_request, app_id);
}

def apply_css(text: str) { apply_css_bk(text); }

def apply_css_file(path: str) { apply_css_file_bk(path); }

def request_restart() { request_restart_bk(); }

def list_monitors() -> list { return list(list_monitors_bk()); }

def monitor_key(m: any) -> str { return str(monitor_key_bk(m)); }

def connect_monitors_changed(cb: any) -> any {
    return connect_monitors_changed_bk(cb);
}
