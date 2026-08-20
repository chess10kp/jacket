# REFERENCE — notification popup layer (LIBRARY.md §1).
#
# notif_ui.jac — notification popups (PLAN Phase 5).
# ---------------------------------------------------------------------------
# A top-right overlay column of bubbles: a `For` over the daemon's active list,
# keyed on notification id. Because a Notify with replaces_id updates a bubble
# IN PLACE (same id, new text), each bubble's content reads its per-row Signal
# via row_item() — the row_fn snapshot would go stale (see builders.jac For).
# The window hides itself when the list is empty.
import from src.builders { component, Box, Label, Button, Window, For, Show, row_item }
import from src.animation { animated, ease }
import from src.notifications { get_notifications }
import from src.policy { popup_route_active }

# Named accessors keep the .map calls lambda-free (and dodge the nested-lambda
# codegen bug); the close closure stays a single-statement lambda.
def _app(n: dict) -> str { return n["app_name"]; }
def _summary(n: dict) -> str { return n["summary"]; }
def _body(n: dict) -> str { return n["body"]; }
def _urgency_class(n: dict) -> str { return "notif urgency-" + str(n["urgency"]); }
def _empty(ns: list) -> bool { return len(ns) == 0; }
def _key(n: dict) -> any { return n["id"]; }
def _close(nid: int) { get_notifications().begin_close(nid); }

# Enter on mount (slide down + fade in); exit when the daemon flags the row
# closing; re-enter if a re-Notify replaces a closing row mid-tween. The
# effect samples the per-row item each run — cur() in notif_row.
def _sync_notif_row(item: any, fade: any, slide: any) {
    if item is None { return; }
    if item["closing"] {
        fade.to(0.0, ms=150, ease_fn=ease.in_);
        slide.to(24.0, ms=200, ease_fn=ease.in_);
    } elif fade.peek() < 1.0 {
        fade.to(1.0, ms=200, ease_fn=ease.out);
        slide.to(0.0, ms=280, ease_fn=ease.out);
    }
}

def notif_row(n: dict) -> any {
    cur = row_item();
    nid = n["id"];
    fade = animated(1.0);                   # instant: no fade-in (latency)
    slide = animated(24.0);
    slide.to(0.0, ms=200, ease_fn=ease.out);
    effect(lambda { _sync_notif_row(cur(), fade, slide); });
    head = Box(orientation="H", class="notif-head", children=[
        Label(class="notif-app", text=cur.map(_app)),
        Button(class="notif-close", label="✕", on_click=lambda { _close(nid); }),
    ]);
    return Box(
        orientation="V",
        class=cur.map(_urgency_class),
        opacity=fade,
        margin_top=slide,
        children=[
            head,
            Label(class="notif-summary", text=cur.map(_summary)),
            Label(class="notif-body", text=cur.map(_body)),
        ],
    );
}

def _notif_popup_window() -> any {
    d = get_notifications();
    rows = Box(orientation="V", class="notif-list", children=[
        For(d.notifications, key=_key, row=notif_row),
    ]);
    w = Window(class="notif-layer", layer="overlay", corner="top-right",
        hidden=d.notifications.map(_empty), child=rows);
    if w.widget is not None and hasattr(w.widget, "present") {
        w.widget.present();
    }
    return w;
}

@component
def NotificationLayer() -> any {
    return Box(class="notif-route-gate", children=[
        Show(popup_route_active(), then=_notif_popup_window),
    ]);
}
