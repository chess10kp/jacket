# launcher.jac — app launcher source: scan .desktop files, fuzzy-filter, launch.
# ---------------------------------------------------------------------------
# (PLAN Phase 5.) Pure logic — .desktop parsing, fuzzy scoring, filtering — is
# fully unit-tested headless. Only the directory scan + Gio spawn touch the OS.
#
# Exposes:
#     apps  : Signal[list]   — all visible entries {name, exec, icon}
#     query : Signal[str]    — the current search text (bound to an Entry)
#     results: computed via filter_apps(apps, query) in the launcher component.
import from src.reactive { signal, Signal }
import from src.glib { spawn_detached }


# ---------------------------------------------------------------------------
# Pure: parse a single .desktop file's text into {name, exec, icon} or None.
# Skips NoDisplay/Hidden and non-Application entries. Only the [Desktop Entry]
# group is read (actions/other groups ignored).
# ---------------------------------------------------------------------------
def parse_desktop(text: any) -> dict | None {
    in_entry = False;
    fields: dict = {};
    for raw in str(text).splitlines() {
        line = raw.strip();
        if line == "" or line.startswith("#") { continue; }
        if line.startswith("[") {
            in_entry = line == "[Desktop Entry]";
            continue;
        }
        if not in_entry { continue; }
        if "=" not in line { continue; }
        (k, v) = line.split("=", 1);
        fields[k.strip()] = v.strip();
    }
    if fields.get("Type", "Application") != "Application" { return None; }
    if fields.get("NoDisplay", "false").lower() == "true" { return None; }
    if fields.get("Hidden", "false").lower() == "true" { return None; }
    name = fields.get("Name");
    exec_ = fields.get("Exec");
    if name is None or exec_ is None { return None; }
    return {
        "name": name,
        "exec": strip_field_codes(exec_),
        "icon": fields.get("Icon", ""),
    };
}

# .desktop Exec lines carry %-field codes (%u %U %f %F %i %c %k) — drop them.
def strip_field_codes(exec_: str) -> str {
    out: list = [];
    for tok in exec_.split() {
        if tok.startswith("%") { continue; }
        out.append(tok);
    }
    return " ".join(out);
}


# ---------------------------------------------------------------------------
# Pure: subsequence fuzzy score. 0 = no match. Rewards prefix + contiguous runs
# so "fire" outranks "fox" for "Firefox".
# ---------------------------------------------------------------------------
def score(name: any, query: str) -> int {
    n = name.lower();
    q = query.lower();
    if q == "" { return 1; }
    s = 0;
    qi = 0;
    prev = -2;
    for i in range(len(n)) {
        if qi < len(q) and n[i] == q[qi] {
            if i == prev + 1 { s += 3; } else { s += 1; }      # contiguous bonus
            if i == 0 and qi == 0 { s += 5; }                  # prefix bonus
            prev = i;
            qi += 1;
        }
    }
    if qi < len(q) { return 0; }                               # not all matched
    return s;
}

# Pure: rank apps by score, drop non-matches. Ties break by name for stability.
def filter_apps(apps: list, query: str, limit: int = 0) -> list {
    if len(apps) == 0 { return []; }
    q = query;
    if q == "" {
        ranked = sorted(apps, key=lambda (a: dict) { a.get("lname", a["name"].lower()); });
        if limit > 0 { return ranked[:limit]; }
        return ranked;
    }
    scored: list = [];
    for a in apps {
        lname = a.get("lname");
        if lname is None { lname = a["name"].lower(); }
        sc = score(lname, q);
        if sc > 0 {
            scored.append((sc, lname, a));
        }
    }
    scored.sort(key=lambda (t: tuple) { (-t[0], t[1]); });
    out: list = [];
    for t in scored {
        out.append(t[2]);
    }
    if limit > 0 { return out[:limit]; }
    return out;
}


# ---------------------------------------------------------------------------
# Scan + launch (OS side, not unit-tested here). Gio respects NoDisplay/Hidden
# and desktop-entry precedence; AppInfoMonitor rescans on install/uninstall.
# ---------------------------------------------------------------------------
::py::
from gi.repository import Gio


def scan_app_infos():
    """All launchable desktop apps via Gio. Returns [dict {key, name, exec, icon}]
    in stable order (sorted by display name)."""
    out = []
    for ai in Gio.app_info_get_all():
        try:
            if not isinstance(ai, Gio.DesktopAppInfo) or not ai.should_show():
                continue
            icon = ai.get_icon()
            iname = icon.to_string() if icon is not None else ""
            out.append({
                "key": ai.get_id(),
                "name": ai.get_display_name() or ai.get_name(),
                "exec": (ai.get_commandline() or ""),
                "icon": iname,
            })
        except Exception:
            continue
    out.sort(key=lambda e: e["name"].lower())
    return out


def watch_app_infos(cb):
    Gio.AppInfoMonitor.get().connect("changed", lambda *a: cb())


def launch_app_info(key):
    """Launch by desktop-id. Returns True/False on success/failure, None if missing."""
    for ai in Gio.app_info_get_all():
        if ai.get_id() == key:
            return bool(ai.launch(None, None))
    return None
::py::


obj Launcher {
    has apps: Signal = signal([]);
    has query: Signal = signal("");
    has visible: Signal = signal(False);

    def postinit() {
        self._scan();
        watch_app_infos(lambda { self._scan(); });
    }

    def show() { self.query.set(""); self.visible.set(True); }
    def hide() { self.visible.set(False); }
    def toggle() {
        if self.visible.peek() { self.hide(); }
        else { self.show(); }
    }

    def _scan() {
        entries: list = [];
        for raw in scan_app_infos() {
            e = {
                "key": raw["key"],
                "name": raw["name"],
                "exec": strip_field_codes(raw["exec"]),
                "icon": raw["icon"],
                "lname": raw["name"].lower(),
            };
            entries.append(e);
        }
        self.apps.set(entries);
    }

    def launch(key: str, exec_: str = "") {
        ok = launch_app_info(key);
        if ok is True { return; }
        if exec_ == "" { return; }
        # Gio missed or failed — spawn stripped command line as fallback.
        spawn_detached(["sh", "-c", exec_]);
    }
}

glob _launcher: any = None;

def get_launcher() -> Launcher {
    if _launcher is None { _launcher = Launcher(); }
    return _launcher;
}
