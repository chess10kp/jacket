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
import from src.glib { run_cmd }


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
def filter_apps(apps: list, query: str) -> list {
    scored: list = [];
    for a in apps {
        sc = score(a["name"], query);
        if sc > 0 { scored.append((sc, a["name"], a)); }
    }
    scored.sort(key=lambda (t: tuple) { (-t[0], t[1]); });
    return [t[2] for t in scored];
}


# ---------------------------------------------------------------------------
# The scan + launch (OS side, not unit-tested here).
# ---------------------------------------------------------------------------
::py::
import os


def _desktop_dirs():
    dirs = []
    data_home = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    dirs.append(os.path.join(data_home, "applications"))
    data_dirs = os.environ.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share"
    for d in data_dirs.split(":"):
        if d:
            dirs.append(os.path.join(d, "applications"))
    return dirs


def scan_files():
    """Return [(desktop_filename, text)] across XDG dirs (first-seen wins). The
    filename is globally unique, so it's the stable For key (Exec can collide)."""
    seen = set()
    out = []
    for d in _desktop_dirs():
        if not os.path.isdir(d):
            continue
        try:
            names = sorted(os.listdir(d))
        except Exception:
            continue
        for name in names:
            if not name.endswith(".desktop") or name in seen:
                continue
            seen.add(name)
            try:
                with open(os.path.join(d, name), "r", encoding="utf-8") as f:
                    out.append((name, f.read()))
            except Exception:
                pass
    return out
::py::


obj Launcher {
    has apps: Signal = signal([]);
    has query: Signal = signal("");
    has visible: Signal = signal(False);

    def postinit() {
        self._scan();
    }

    def show() { self.query.set(""); self.visible.set(True); }
    def hide() { self.visible.set(False); }
    def toggle() { self.visible.set(not self.visible.peek()); }

    def _scan() {
        entries: list = [];
        for (fname, text) in scan_files() {
            e = parse_desktop(text);
            if e is not None {
                e["key"] = fname;              # unique For key (see scan_files)
                entries.append(e);
            }
        }
        self.apps.set(entries);
    }

    def launch(exec_: str) {
        # Detach from the shell: sh -c so the app outlives us.
        run_cmd(["sh", "-c", exec_ + " &"]);
    }
}

glob _launcher: any = None;

def get_launcher() -> Launcher {
    if _launcher is None { _launcher = Launcher(); }
    return _launcher;
}
