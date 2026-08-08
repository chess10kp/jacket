# wm.jac — pick the workspace source for the running compositor.
# ---------------------------------------------------------------------------
# Both sources expose the same duck-typed interface (a `workspaces` Signal + a
# `focus(id)` method), so the bar never learns which WM it's on. Prefer sway/i3
# when $SWAYSOCK is present, else Hyprland.
import from src.hyprland { get_hyprland }
import from src.sway { get_sway }

::py::
import os
def _has_sway():
    return bool(os.environ.get("SWAYSOCK") or os.environ.get("I3SOCK"))
::py::

def get_wm() -> any {
    if _has_sway() { return get_sway(); }
    return get_hyprland();
}
