# REFERENCE — launcher popup window (LIBRARY.md §1).
#
# launcher_ui.jac — the launcher popup window (PLAN Phase 5).
# ---------------------------------------------------------------------------
# An overlay layer-shell window: a search Entry over a live-filtered app list.
# The results are a `computed` off (apps, query) run through the pure
# filter_apps ranker; the `For` keys on exec so typing reshuffles rows in place.
# Visibility is driven by the launcher's `visible` Signal (toggled from the bar).
import from src.reactive { computed, effect }
import from src.builders { component, Box, Button, Entry, Window, For }
import from src.launcher { get_launcher, filter_apps }
import from src.adapter { grab_focus }
import from src.glib { idle_add }

# How many results to show — the launcher list isn't virtualized (PLAN §8).
glob MAX_RESULTS: int = 30;


# Launch the top-ranked result (Enter in the search box).
def launch_first(l: any) {
    res = filter_apps(l.apps.peek(), l.query.peek(), MAX_RESULTS);
    if len(res) > 0 {
        l.launch(res[0]["exec"]);
        l.hide();
    }
}

# A result row. The click action is a named helper: a MULTI-statement lambda
# body ({ launch; hide; }) trips the Jac codegen scoping bug, so the lambda holds
# a single call.
def _launch_and_hide(ex: str) {
    l = get_launcher();
    l.launch(ex);
    l.hide();
}

def launch_row(app: dict) -> any {
    ex = app["exec"];
    return Button(class="launcher-item", label=app["name"],
        on_click=lambda { _launch_and_hide(ex); });
}


# Small helpers keep each lambda in its own simple expression — packing many
# lambdas into one nested call trips the Jac codegen scoping bug.
def _on_search(e: any) { get_launcher().query.set(e.get_text()); }
def _on_enter() { launch_first(get_launcher()); }
def _not_visible(v: bool) -> bool { return not v; }
def _row_key(a: dict) -> any { return a["key"]; }

def _focus_entry(entry_node: any) {
    w = entry_node.widget;
    if w is not None {
        idle_add(lambda { grab_focus(w); return False; });
    }
}

@component
def LauncherWindow() -> any {
    l = get_launcher();
    # Recompute the ranked, capped result list whenever apps or query change.
    results = computed(lambda { filter_apps(l.apps(), l.query(), MAX_RESULTS); });
    entry = Entry(class="launcher-entry", placeholder="Search apps…",
        on_change=_on_search, on_activate=_on_enter);
    # Grab keyboard + focus the search box whenever the popup opens.
    effect(lambda {
        if l.visible() { _focus_entry(entry); }
    });
    rows = Box(orientation="V", class="launcher-list", children=[
        For(results, key=_row_key, row=launch_row),
    ]);
    box = Box(orientation="V", class="launcher-box", children=[entry, rows]);
    return Window(class="launcher", layer="overlay", keyboard=l.visible,
        hidden=l.visible.map(_not_visible), child=box);
}
