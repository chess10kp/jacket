# seam_gate_tests.jac — the W0 "seam gate" (WAYLAND_BACKEND.md §3 + §5 W0).
# ---------------------------------------------------------------------------
# Enforces the backend-selection rule as an executable audit: PyGObject/gi
# usage may live ONLY behind the adapter seam. Anything above the seam reaches
# Gtk/GLib through the plain callables of jacket/adapter_api.jac, so a second
# backend (WlAdapter) can be swapped in without touching code above the wall.
#
# Policy (encoded below in the ::py:: scanner):
#   1. HARD_FORBIDDEN tokens ("import gi", gi.repository, require_version, Gtk,
#      Gdk, GdkPixbuf, Gtk4LayerShell, GObject) are permitted ONLY in
#      jacket/adapter.jac. One refinement: a `from gi.repository import ...`
#      line that binds ONLY the sanctioned GLib/Gio transport slice (§1
#      non-goals) is not a GTK leak — DBus sources import through it.
#   2./3. GLib/Gio are permitted in adapter.jac + glib.jac (the loop shim) and
#      the DBus source modules, which survive GTK removal (§1 non-goals).
#
# Comment stripping removes `#`/`//` line comments AND triple-quoted
# docstrings before matching: the gate targets executable usage, not prose
# (e.g. glib.jac's docstring mentioning Gtk.Application).
#
# A TEMPORARY allowlist recorded today's known debt while it was unpaid; every
# entry carried a "# W0-DEBT" marker and was deleted once its refactor landed
# (test 3 now guards that the ledger stays empty instead of silently growing).
#
# All filesystem walking / regex / list handling lives inside this ::py::
# block and crosses upward ONLY as flat lists of strings — attribute access on
# arbitrary Python objects breaks the Jac compiler (the known gi
# OverridesProxyModule issue), so Jac just sees `len(x) == 0`.
::py::
import re as _re
from pathlib import Path as _Path

_ROOT = _Path(__file__).resolve().parent.parent
_SCAN_DIRS = ("jacket", "examples")

_HARD_FORBIDDEN = ("import gi", "gi.repository", "require_version",
                   "Gtk", "Gdk", "GdkPixbuf", "Gtk4LayerShell", "GObject")
_GLIB_TOKENS = ("GLib",)
_GIO_TOKENS = ("Gio",)

_SEAM = "jacket/adapter.jac"
_SEAMS = ("jacket/adapter.jac", "jacket/wl_adapter.jac")   # both backend seams (§3)
_LOOP_SHIM = "jacket/glib.jac"
_SOURCE_MODULES = frozenset({
    "adapter.jac", "glib.jac", "battery.jac", "bluetooth.jac",
    "brightness.jac", "dev_watch.jac", "hyprland.jac", "ipc.jac",
    "launcher.jac", "mpris.jac", "network.jac", "notifications.jac",
    "power_profiles.jac", "sway.jac", "tray.jac",
})

# The W0-DEBT ledger is paid down: every originally recorded entry landed behind
# the adapter seam (tray textures -> py_make_texture, the tray popover menu ->
# build_menu_model/attach_popover, swaybar stocks -> jacket.glib.idle_add).
#
# One NEW remainder rode in mid-refactor from the concurrent W1/W2 track:
# jacket/wl_adapter.jac binds the narrow Pango/PangoCairo gi slice directly
# (WAYLAND_BACKEND.md §4 text choice). It carries a "# W0-DEBT" marker until
# wl_adapter owns its own walled seam / the sanctioned slice grows.
_W0_DEBT = {
    "jacket/wl_adapter.jac": ["gi.repository", "GLib"],
}

_PATTERNS = {tok: _re.compile(r"\b" + _re.escape(tok).replace("\\ ", "\\s+")
                              + r"\b") for tok in
             set(_HARD_FORBIDDEN) | set(_GLIB_TOKENS) | set(_GIO_TOKENS)}


_DOCSTRING_RE = _re.compile(r'("""[\s\S]*?"""|\'\'\'[\s\S]*?\'\'\')')


def _strip_comments(text):
    """Drop triple-quoted docstrings, then `#` and `//` line comments (only
    when the marker is outside a quoted string), so prose mentions of gi
    tokens don't trip the gate."""
    text = _DOCSTRING_RE.sub('""', text)
    out_lines = []
    for line in text.splitlines():
        kept = []
        in_s = in_d = False
        i, n = 0, len(line)
        while i < n:
            c = line[i]
            if (in_s or in_d) and c == "\\" and i + 1 < n:
                kept.append(line[i:i + 2])
                i += 2
                continue
            if c == "'" and not in_d:
                in_s = not in_s
            elif c == '"' and not in_s:
                in_d = not in_d
            elif not in_s and not in_d:
                if c == "#":
                    break
                if c == "/" and i + 1 < n and line[i + 1] == "/":
                    break
            kept.append(c)
            i += 1
        out_lines.append("".join(kept))
    return "\n".join(out_lines)


_GI_IMPORT_RE = _re.compile(
    r"^\s*from\s+gi\.repository\s+import\s+(?P<names>[\w.,\s]+)$")
_SANCTIONED_SLICE = frozenset({"GLib", "Gio"})


def _sanctioned_gi_import(line):
    """True for `from gi.repository import ...` lines binding ONLY the
    GLib/Gio transport slice (the §1 non-goal that survives GTK removal)."""
    m = _GI_IMPORT_RE.match(line)
    if m is None:
        return False
    names = [n.strip().split(" as ")[0].strip()
             for n in m.group("names").split(",")]
    return all(n in _SANCTIONED_SLICE for n in names)


def _token_allowed(rel, token, cls):
    if rel in _W0_DEBT and token in _W0_DEBT[rel]:
        return True
    if cls == "hard":
        return rel in _SEAMS
    # GLib/Gio: the backend seams, the loop shim, and the DBus source
    # modules under jacket/.
    if rel in _SEAMS or rel == _LOOP_SHIM:
        return True
    if rel.startswith("jacket/") and rel.rsplit("/", 1)[1] in _SOURCE_MODULES:
        return True
    return False


def scanned_files():
    files = []
    for d in _SCAN_DIRS:
        base = _ROOT / d
        for f in sorted(base.rglob("*.jac")):
            files.append(f.relative_to(_ROOT).as_posix())
    return sorted(files)


def seam_violations():
    """Flat 'path:lineno TOKEN context' strings for ALL gate rules."""
    out = []
    for rel in scanned_files():
        text = _strip_comments((_ROOT / rel).read_text(encoding="utf-8"))
        for lineno, line in enumerate(text.splitlines(), start=1):
            for cls, toks in (("hard", _HARD_FORBIDDEN),
                              ("GLib", _GLIB_TOKENS), ("Gio", _GIO_TOKENS)):
                for tok in toks:
                    if _token_allowed(rel, tok, cls):
                        continue
                    if not _PATTERNS[tok].search(line):
                        continue
                    # A pure GLib/Gio gi import line is the sanctioned
                    # transport slice, not a GTK leak (rule 1 refinement).
                    if tok == "gi.repository" and _sanctioned_gi_import(line):
                        continue
                    out.append(f"{rel}:{lineno} {tok} {line.strip()[:80]}")
    return out


def hard_seam_violations():
    return [v for v in seam_violations()
            if v.split(" ", 2)[1] in _HARD_FORBIDDEN]


def glib_gio_seam_violations():
    return [v for v in seam_violations()
            if v.split(" ", 2)[1] in _GLIB_TOKENS + _GIO_TOKENS]


def debt_allowlist_keys():
    return sorted(_W0_DEBT.keys())
::py::


test "no GTK tokens outside the adapter seam" {
    offenders: list = hard_seam_violations();
    if len(offenders) > 0 {
        print("seam gate offenders:", offenders);
    }
    assert len(offenders) == 0,
        "gi leaked above the adapter seam (only jacket/adapter.jac may carry "
        + "gi/Gtk/Gdk tokens): " + str(offenders);
}

test "GLib/Gio confined to source modules and the loop shim" {
    offenders: list = glib_gio_seam_violations();
    if len(offenders) > 0 {
        print("GLib/Gio offenders:", offenders);
    }
    assert len(offenders) == 0,
        "GLib/Gio used outside adapter.jac/glib.jac/the DBus sources: "
        + str(offenders);
}

test "the original W0 debts are paid off" {
    # Inverted per the ledger's contract: every originally recorded W0-DEBT
    # entry has been paid by pushing its gi use behind the adapter seam, so
    # none of them may reappear. The only tolerated remainder is the concurrent
    # WlAdapter Pango slice (see ledger note); any OTHER new entry must come
    # with a "# W0-DEBT" marker and a plan to delete it again.
    keys: list = debt_allowlist_keys();
    assert "jacket/tray.jac" not in keys, "tray.jac texture debt resurfaced";
    assert "examples/reference/components.jac" not in keys,
        "components.jac popover debt resurfaced";
    assert "examples/swaybar/sources.jac" not in keys,
        "swaybar sources.jac loop-shim debt resurfaced";
    if len(keys) > 1 or (len(keys) == 1 and keys[0] != "jacket/wl_adapter.jac") {
        print("unexpected W0-DEBT entries:", keys);
    }
    assert keys == ["jacket/wl_adapter.jac"],
        "unexpected W0-DEBT entries (expected only the wl_adapter Pango "
        + "slice): " + str(keys);
}

test "scan actually sees files" {
    files: list = scanned_files();
    if len(files) < 30 {
        print("scanner only saw:", files);
    }
    assert len(files) >= 30, "scanner glob is broken — gate would be vacuous";
    assert "jacket/adapter.jac" in files, "seam file not scanned";
    assert "jacket/builders.jac" in files, "builders.jac not scanned";
}
