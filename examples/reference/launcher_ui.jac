# REFERENCE — launcher popup window (LIBRARY.md §1).
#
# launcher_ui.jac — the launcher popup window (PLAN Phase 5).
# ---------------------------------------------------------------------------
# An overlay layer-shell window: a search Entry over a live-filtered app list.
# Results are ranked via filter_apps; the list is a fixed pool of MAX_RESULTS
# row slots keyed by index. Keystrokes only patch label/hidden on existing rows
# (no For insert/remove churn). Visibility is driven by the launcher's `visible`
# Signal (toggled from the bar).
import from src.reactive { computed, effect, signal }
import from src.transition { popup_transition }
import from src.builders { component, Box, Button, Entry, Window, For, row_item }
import from src.launcher { get_launcher, filter_apps }
import from src.adapter_api { adapter }
import from src.glib { idle_add }

# 8 rows keeps the popup well under output height. 30 rows measured 1284px
# natural height on a 1200px output — the layer surface then stretches
# edge-to-edge (compositor clamps oversized surfaces).
glob MAX_RESULTS: int = 8;

# Measured bar height (px), published by main.jac after the bars map. The
# launcher is an overlay-layer surface with exclusive_zone = -1, so the
# compositor will NOT seat it below the top-layer bar's reserved space
# ("would like to be moved" is advisory and cross-layer behavior differs) —
# we seat it ourselves: anchored TOP, layer margin = bar height. Flush by
# construction, and it tracks CSS/font changes because it is measured, not
# hard-coded.
glob bar_px: any = signal(34);

def set_bar_px(px: int) {
    if px is not None and int(px) > 0 { bar_px.set(int(px)); }
}


# Launch the top-ranked result (Enter in the search box).
def launch_first(l: any) {
    res = filter_apps(l.apps.peek(), l.query.peek(), MAX_RESULTS);
    if len(res) > 0 {
        l.launch(res[0]["key"], res[0]["exec"]);
        l.hide();
    }
}

def _launch_and_hide(key: str, exec_: str) {
    l = get_launcher();
    l.launch(key, exec_);
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
    return str(a["name"]);
}

def _row_hidden(slot: dict) -> bool {
    return slot.get("app") is None;
}

def _launch_row_click() {
    a = row_item().peek().get("app");
    if a is not None { _launch_and_hide(a["key"], a["exec"]); }
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
def _on_stop_search() { get_launcher().hide(); }
def _not_visible(v: bool) -> bool { return not v; }

def _focus_entry(entry_node: any) {
    w = entry_node.widget;
    if w is not None {
        # Reset the text the user typed last time (show() resets the query
        # Signal; this clears the entry itself — set_text fires
        # on_change -> query.set("") again, a harmless no-op).
        adapter().set_prop(w, "text", "");
        idle_add(lambda { adapter().grab_focus(w); return False; });
    }
}

@component
def LauncherWindow() -> any {
    l = get_launcher();
    # Enter: snap to the hidden pose — offset is NEGATIVE, so the box starts
    # tucked UP behind the bar (clipped at the surface top edge, which sits
    # flush on the bar's bottom edge) — then slides DOWN out of the bar and
    # fades in. Exit: reverse the tween, i.e. retract back UP into the bar,
    # THEN unmap (shown flips False in the slide tween's on_done) — re-opening
    # mid-exit cancels the pending hide. See src/transition.jac. Durations are
    # slower than the library defaults (280/220) so the travel reads.
    tr = popup_transition(l.visible, offset=-40.0,
        enter_ms=520.0, enter_fade_ms=400.0,
        exit_ms=440.0, exit_fade_ms=340.0);
    slots = computed(lambda {
        _make_slots(l.apps(), l.query(), MAX_RESULTS);
    });
    entry = Entry(class="launcher-entry", placeholder="Search apps…",
        on_change=_on_search, on_activate=_on_enter,
        on_stop_search=_on_stop_search);
    effect(lambda {
        if l.visible() { _focus_entry(entry); }
    });
    rows = Box(orientation="V", class="launcher-list", children=[
        For(slots, key=_slot_key, row=launch_row),
    ]);
    box = Box(orientation="V", class="launcher-box",
        opacity=tr.fade,
        margin_top=tr.slide,
        children=[entry, rows]);
    return Window(class="launcher", layer="overlay", corner="top-center",
        keyboard=l.visible, margin_top=bar_px,
        hidden=tr.shown.map(_not_visible), child=box);
}
