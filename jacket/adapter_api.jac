# adapter_api.jac — the swappable adapter handle.
# ---------------------------------------------------------------------------
# builders.jac and osp.jac reach GTK ONLY through `adapter()`. The impl is
# set once at startup (MockAdapter for headless tests, GtkAdapter for the real
# shell) via set_adapter. A holder OBJECT (not a reassigned glob) so the swap
# is visible across every module that imports the accessor (field mutation on
# a shared instance; cross-module glob reassignment would not propagate).

obj AdapterSlot {
    has impl: any = None;
}

glob _slot: any = AdapterSlot();

def set_adapter(a: any) { _slot.impl = a; }

# the single accessor everything above the seam calls through:
#   adapter().construct(...) / set_prop / insert / remove / move / connect ...
def adapter() -> any { return _slot.impl; }
