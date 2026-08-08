# components.jac  —  DESIGN SKETCH (real Jac lambdas, OSP-consistent)
# ---------------------------------------------------------------------------
# What real components look like in this style. Progressively richer, showing
# the whole authoring surface: local state, derivation, events, lists (For),
# conditionals (Show), lifecycle, composition.
#
# CORRECTED: closures are `lambda x:` (no Rust `|x|`). Structural primitives
# (For/Show) and disposal are OSP under the hood (osp_runtime.jac / builders.jac).
#
# Operator overloads + .map/when/fmt keep MOST props lambda-free; explicit
# `lambda` appears mainly in events and multi-branch computed().
# ===========================================================================


# ---------------------------------------------------------------------------
# 1. SIMPLEST — a clock. Pure derivation off a source, no local state.
# ---------------------------------------------------------------------------
@component
def Clock() -> ViewNode {
    let time = ticker(1000);                              # Signal (sources.jac)
    return Label(
        class = "clock",
        text  = time.map(lambda t: strftime("%a %H:%M", t)),
    );
}


# ---------------------------------------------------------------------------
# 2. LOCAL STATE + EVENTS — a counter. Body runs ONCE; `n` lives for the
# component's lifetime. No re-render, no hooks-rules.
# ---------------------------------------------------------------------------
@component
def Counter() -> ViewNode {
    let n = signal(0);
    return Box(orientation="H", class="counter", children=[
        Button(child=Label(text="−"), on_click = lambda: n.update(lambda v: v - 1)),
        Label(text = n.map(str)),
        Button(child=Label(text="+"), on_click = lambda: n.update(lambda v: v + 1)),
    ]);
}


# ---------------------------------------------------------------------------
# 3. DERIVATION + CONDITIONAL + Show — a volume widget.
# computed() for multi-branch; when() reactive class; fmt() reactive text; an
# event that reads a signal; Show() to conditionally mount a slider.
# ---------------------------------------------------------------------------
@component
def Volume() -> ViewNode {
    let vol   = audio.volume;                            # Signal[float] 0..1
    let muted = audio.muted;
    let open  = signal(False);                           # local UI state

    let icon = computed(lambda:
        "audio-muted" if muted() else
        "audio-high"  if vol() > 0.66 else
        "audio-low"   if vol() > 0.0  else
        "audio-off");

    return Box(class = when(muted, "vol muted", "vol"), orientation="H", children=[
        Button(
            child     = Icon(icon = icon),
            on_click  = lambda: open.update(lambda o: not o),
            # |e| -> lambda dy: event payload (R2). Reading vol() in an EVENT
            # is correct (a snapshot), unlike in a prop.
            on_scroll = lambda dy: audio.set_volume(clamp(vol() + (-dy * 0.05), 0.0, 1.0)),
        ),
        Label(text = fmt("{:.0%}", vol)),
        Show(open, then = lambda: Slider(
            value     = vol,
            on_change = lambda v: audio.set_volume(v),
        )),
    ]);
}


# ---------------------------------------------------------------------------
# 4. A LIST — workspaces. The canonical `For`. Each row's OWN effects patch its
# class/label; the diff only adds/removes/moves by key.
# ---------------------------------------------------------------------------
@component
def Workspaces() -> ViewNode {
    return Box(class="workspaces", children=[
        For(hypr.workspaces,
            key = lambda w: w["id"],
            row = lambda w: Button(
                class    = when(w["active"], "ws active", "ws"),
                child    = Label(text = str(w["idx"])),
                on_click = lambda: hypr.focus(w["id"]),
            )),
    ]);
}


# ---------------------------------------------------------------------------
# 5. LIST + EMPTY STATE + LIFECYCLE — notifications.
# Show() with an else_ branch; on_cleanup for a per-row resource (dismiss timer);
# reactive list length.
# ---------------------------------------------------------------------------
@component
def Notifications() -> ViewNode {
    let items = notifd.list;                             # Signal[list] (Gio source)
    let count = items.map(len);

    return Box(class="notifs", children=[
        Show(count > 0,
            then  = lambda: Box(children=[
                For(items, key = lambda n: n["id"], row = lambda n: Notification(n)),
            ]),
            else_ = lambda: Label(class="notifs-empty", text="No notifications"),
        ),
    ]);
}

@component
def Notification(n: dict) -> ViewNode {
    # per-row resource with cleanup: auto-dismiss after 5s. on_cleanup attaches
    # to currentScope (this row's root ViewNode) — runs when the row unmounts.
    let timer = GLib.timeout_add(5000, lambda: (notifd.dismiss(n["id"]), False)[1]);
    on_cleanup(lambda: GLib.source_remove(timer));

    return Box(class="notif", orientation="V", children=[
        Label(class="notif-title", text = n["summary"]),
        Label(class="notif-body",  text = n["body"]),
        Button(child=Label(text="✕"), on_click = lambda: notifd.dismiss(n["id"])),
    ]);
}


# ---------------------------------------------------------------------------
# 6. COMPOSITION — the Bar. Components are functions; compose by calling.
# ---------------------------------------------------------------------------
@component
def Bar(monitor: int) -> ViewNode {
    return Window(class="bar", monitor=monitor, anchor="top", height=32,
        child = Box(orientation="H", class="bar-inner", children=[
            Box(class="left",   children=[ Workspaces() ]),
            Box(class="center", children=[ Clock() ]),
            Box(class="right",  children=[
                Volume(),
                Battery(),
                Notifications(),
            ]),
        ]),
    );
}


# ---------------------------------------------------------------------------
# 7. DERIVED COMPOSITION + a genuine side-effect. effect() (not a prop) runs on
# any dep change, attaches to currentScope, auto-cleaned on unmount.
# ---------------------------------------------------------------------------
@component
def Battery() -> ViewNode {
    let pct = battery.percent;                           # 0..1
    let chg = battery.charging;

    let level = computed(lambda:
        "full" if pct() > 0.8 else
        "ok"   if pct() > 0.3 else
        "low");

    effect(lambda: notify_low_battery() if (pct() < 0.1 and not chg()) else None);

    return Box(class = fmt("battery {}", level), orientation="H", children=[
        Icon(icon = when(chg, "battery-charging", level.map(lambda l: f"battery-{l}"))),
        Label(text = fmt("{:.0%}", pct)),
    ]);
}


# ===========================================================================
# on_cleanup — free function; registers a teardown on currentScope (the
# ViewNode being built). Same protocol effect()/on_* use. (reactive_core.jac)
# ===========================================================================
def on_cleanup(fn: any) {
    if currentScope { currentScope.on_cleanup(fn); }
}


# ===========================================================================
# WHAT THIS EXERCISE PROVED
#   - Components are ordinary functions; state lives wherever declared; they
#     never re-run, so there are zero rules about placement.
#   - `lambda` appears almost only in EVENTS and multi-branch computed(); props
#     stay terse via bare signals / operators / .map / when / fmt.
#   - The 4 structural primitives are the whole vocabulary: builders, For, Show,
#     event handlers — all backed by the OSP node/edge/walker runtime.
#   - Two refinements found by DOING it (both folded in): Show (R1), event
#     arity (R2). Small, clean — the core held up.
# ===========================================================================
