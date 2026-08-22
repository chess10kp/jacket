# REFERENCE — lockscreen layer (LIBRARY §1 pattern, one consumer of the
# library). Pairs with jacket/lockscreen.jac (daemon) — this file is only UI.
#
# A fullscreen overlay window bound to the lock daemon's state Signal:
#   - anchor="full" + keyboard=True: covers the output and grabs all input
#     while shown (layer-shell EXCLUSIVE keyboard mode)
#   - popup_transition drives the exit: on unlock success the layer fades,
#     THEN unmaps (shown gates the window's hidden prop)
#   - Entry password mode; Enter submits; typing clears a failure hint
import from jacket.builders { component, Box, Label, Window, Entry }
import from jacket.animation { animated, ease }
import from jacket.transition { popup_transition }
import from jacket.reactive { effect }
import from jacket.sources { ticker }
import from jacket.lockscreen { get_lockscreen }
import from time { strftime, localtime }


def _not(b: bool) -> bool { return not b; }

def _visible(s: str) -> bool { return s != "unlocked"; }

def _lock_class(s: str) -> str { return "lock state-" + s; }

# Named accessor keeps the .map lambda single-statement (repo codegen rule).
def _clock_text(tv: any) -> str {
    return strftime("%H:%M", localtime(tv));
}

def _date_text(tv: any) -> str {
    return strftime("%A, %d %B", localtime(tv));
}

def _hint(s: str) -> str {
    if s == "checking" { return "Verifying…"; }
    if s == "failed" { return "Wrong password"; }
    return "";
}

def _submit(d: any, e: any) {
    d.submit(e.get_text());
    e.set_text("");
}

# Event handlers are named fns (repo pattern): lambda params would need types.
def _on_lock_activate(e: any) { _submit(get_lockscreen(), e); }
def _on_lock_typed(e: any) { get_lockscreen().reset_prompt(); }

def _focus_when_shown(shown: bool, entry_widget: any) {
    if shown and entry_widget is not None { entry_widget.grab_focus(); }
}

@component
def LockLayer() -> any {
    d = get_lockscreen();
    # visible while anything other than "unlocked"; the transition owns the
    # exit tween and unmaps the window only after the fade completes.
    tr = popup_transition(d.state.map(_visible), offset=0.0);
    t = ticker(1000);
    entry = Entry(
        class="lock-entry", password=True,
        on_activate=_on_lock_activate,
        on_change=_on_lock_typed,
    );
    effect(lambda { _focus_when_shown(tr.shown(), entry.widget); });
    panel = Box(orientation="V", class="lock-panel", children=[
        Label(class="lock-clock", text=t.map(_clock_text)),
        Label(class="lock-date", text=t.map(_date_text)),
        Label(class="lock-hint", text=d.state.map(_hint)),
    ]);
    win = Window(
        class="lock-layer",
        layer="overlay",
        anchor="full",
        keyboard=True,
        hidden=tr.shown.map(_not),
        child=Box(
            orientation="V",
            class="lock-root",
            opacity=tr.fade,
            children=[panel, entry],
        ),
    );
    if win.widget is not None and hasattr(win.widget, "present") {
        win.widget.present();
        win.widget.set_visible(False);      # resting state: session open
    }
    return win;
}
