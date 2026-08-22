# REFERENCE — desktop widget flyouts: control center, calendar, media popup.
# ---------------------------------------------------------------------------
# Three click-popovers anchored to bar buttons (the Anchored(mode="click")
# edge realizes via adapter().attach_click_popover — see mount.jac):
#
#   ControlCenter  — brightness slider + power-profile row + network status
#   CalendarFlyout — month grid rendered as one mono label under the clock
#   MediaPopup     — now-playing + prev/play-pause/next transport controls
#
# Every panel degrades to inert content when its source is unavailable
# (brightness hidden, power row flat, network "offline", media empty).
import from jacket.builders { component, Box, Label, Button, Slider }
import from jacket.reactive { signal, effect }
import from jacket.adapter_api { adapter }
import from jacket.power_profiles { get_power_profiles }
import from jacket.brightness { get_brightness }
import from jacket.network { get_network }
import from jacket.mpris { get_mpris, format_status }

# Mirror of power_profiles._PROFILE_ORDER (kept local: no private imports).
glob PP_ORDER: list = ["balanced", "performance", "power-saver"];


# --- named helpers (repo rule: named defs over nested statement lambdas)
def _profile_label(p: str) -> str {
    return {"power-saver": "eco", "balanced": "bal", "performance": "perf"}[p];
}

def _profile_class(active: str, mine: str) -> str {
    return "pp-btn active" if mine == active else "pp-btn";
}

def _set_profile(p: str) {
    get_power_profiles().set_profile(p);
}

def _bright_visible(avail: bool) -> bool { return avail; }

def _hidden(b: bool) -> bool { return b; }

def _media_title(p: dict) -> str {
    if p["title"] == "" { return "Nothing playing"; }
    return p["title"];
}


@component
def BrightnessRow() -> any {
    b = get_brightness();
    return Box(orientation="H", class="cc-row cc-brightness",
        hidden=b.available.map(_bright_visible), children=[
        Label(class="cc-icon", text="☀"),
        Slider(class="cc-slider", min=0, max=100, step=1,
            value=b.percent,
            on_value_change=lambda (w: any) { get_brightness().set_percent(int(w.get_value())); }),
    ]);
}


def _pp_row() -> list {
    pp = get_power_profiles();
    btns: list = [];
    for p in PP_ORDER {
        btns.append(Button(
            class=pp.profile.map(lambda (a: str, q: str = p) { _profile_class(a, q); }),
            label=_profile_label(p),
            tooltip=p,
            on_click=lambda (q: str = p) { _set_profile(q); },
        ));
    }
    return btns;
}


@component
def PowerRow() -> any {
    pp = get_power_profiles();
    return Box(orientation="H", class="cc-row cc-power",
        hidden=pp.available.map(_hidden), children=_pp_row());
}


# The network source exposes one Signal per fact; derive the status line in a
# single effect so every read is a tracked dependency.
@component
def NetworkRow() -> any {
    n = get_network();
    line = signal("");
    effect(lambda {
        txt = "";
        if n.available() and n.connected() and n.ssid() != "" {
            t = "wifi" if n.connection_type() == "wifi" else "eth";
            txt = "Network  " + n.ssid() + "  (" + t + " " + str(n.signal_strength()) + "%)";
        } elif n.connected() { txt = "Network  connected"; }
        else { txt = "Network  disconnected"; }
        line.set(txt);
    });
    return Label(class="cc-row cc-network", text=line);
}


@component
def ControlCenterPanel() -> any {
    return Box(orientation="V", class="control-center", children=[
        Label(class="cc-title", text="Control Center"),
        BrightnessRow(),
        PowerRow(),
        NetworkRow(),
    ]);
}


# Popover attachment is done via adapter().attach_click_popover (the same seam
# realize_anchored_edges uses behind the Anchored edge) because the strict
# checker rejects any fn call as an edge's right operand — only direct builder
# calls or locally-bound nodes pass. This keeps @component disposal semantics.
def _click_popover(btn: any, panel: any) {
    cleanup = adapter().attach_click_popover(btn.widget, panel.widget, "bottom");
    if cleanup is not None { btn.on_cleanup(cleanup); }
}

@component
def ControlCenterButton() -> ViewNode {
    btn = Button(class="control-center-toggle", label="⚙");
    _click_popover(btn, ControlCenterPanel());
    return btn;
}


@component
def MediaTransport() -> any {
    m = get_mpris();
    return Box(orientation="V", class="media-popup", children=[
        Label(class="media-popup-title", text=m.player.map(_media_title)),
        Label(class="media-popup-artist", text=m.player.map(lambda (p: dict) { p["artist"]; }),
            hidden=m.player.map(lambda (p: dict) { p["artist"] == ""; })),
        Box(orientation="H", class="media-popup-controls", children=[
            Button(class="media-prev", label="⏮", on_click=lambda { m.previous(); }),
            Button(class="media-playpause",
                label=m.player.map(lambda (p: dict) { "⏸" if p["playing"] else "▶"; }),
                on_click=lambda { m.play_pause(); }),
            Button(class="media-next", label="⏭", on_click=lambda { m.next(); }),
        ]),
    ]);
}


@component
def MediaPopupButton() -> ViewNode {
    m = get_mpris();
    btn = Button(
        class="media",
        hidden=m.player.map(lambda (p: dict) { not p["has_player"]; }),
        label=m.player.map(format_status),
        on_click=lambda { m.play_pause(); },
    );
    _click_popover(btn, MediaTransport());
    return btn;
}
