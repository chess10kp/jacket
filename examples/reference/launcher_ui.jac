# REFERENCE — launcher popup window (LIBRARY.md §1).
#
# launcher_ui.jac — the launcher popup window (PLAN Phase 5).
# ---------------------------------------------------------------------------
# An overlay layer-shell window: a search Entry over a live-filtered app list.
# Results are ranked via filter_apps; the list is a fixed pool of MAX_RESULTS
# row slots keyed by index. Keystrokes only patch label/hidden on existing rows
# (no For insert/remove churn). Visibility is driven by the launcher's `visible`
# Signal (toggled from the bar).
import from src.reactive { computed, effect }
import from src.builders { component, Box, Button, Entry, Window, For, row_item }
import from src.launcher { get_launcher, filter_apps }
import from src.adapter { grab_focus }
import from src.glib { idle_add }

glob MAX_RESULTS: int = 30;


# Launch the top-ranked result (Enter in the search box).
def launch_first(l: any) {
    res = filter_apps(l.apps.peek(), l.query.peek(), MAX_RESULTS);
    if len(res) > 0 {
        l.launch(res[0]["exec"]);
        l.hide();
    }
}

def _launch_and_hide(ex: str) {
    l = get_launcher();
    l.launch(ex);
    l.hide();
}

# Fixed slot pool: stable For keys (0..MAX_RESULTS-1), mutable app payload.
def _make_slots(apps: list, query: str, limit: int) -> list {
    ranked = filter_apps(apps, query, limit);
    out: list = [];
    for i in range(limit) {
        app = None;
        if i < len(ranked) { app = ranked[i]; }
        out.append({"slot": i, "app": app});
    }
    return out;
}

def _slot_key(slot: dict) -> any { return slot["slot"]; }

def _row_label(slot: dict) -> str {
    a = slot.get("app");
    if a is None { return ""; }
    return a["name"];
}

def _row_hidden(slot: dict) -> bool {
    return slot.get("app") is None;
}

def _launch_row_click() {
    a = row_item().peek().get("app");
    if a is not None { _launch_and_hide(a["exec"]); }
}

def launch_row(_slot: dict) -> any {
    cur = row_item();
    return Button(class="launcher-item",
        label=cur.map(_row_label),
        hidden=cur.map(_row_hidden),
        on_click=lambda { _launch_row_click(); });
}

def _on_search(e: any) { get_launcher().query.set(e.get_text()); }
def _on_enter() { launch_first(get_launcher()); }
def _not_visible(v: bool) -> bool { return not v; }

def _focus_entry(entry_node: any) {
    w = entry_node.widget;
    if w is not None {
        idle_add(lambda { grab_focus(w); return False; });
    }
}

@component
def LauncherWindow() -> any {
    l = get_launcher();
    slots = computed(lambda {
        _make_slots(l.apps(), l.query(), MAX_RESULTS);
    });
    entry = Entry(class="launcher-entry", placeholder="Search apps…",
        on_change=_on_search, on_activate=_on_enter);
    effect(lambda {
        if l.visible() { _focus_entry(entry); }
    });
    rows = Box(orientation="V", class="launcher-list", children=[
        For(slots, key=_slot_key, row=launch_row),
    ]);
    box = Box(orientation="V", class="launcher-box", children=[entry, rows]);
    return Window(class="launcher", layer="overlay", keyboard=l.visible,
        hidden=l.visible.map(_not_visible), child=box);
}
