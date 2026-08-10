# smoke/main.jac — §5.4 live Wayland integration smoke (self-checking, auto-quit).
# Run via scripts/live_smoke.sh when WAYLAND_DISPLAY is set.
import from src.adapter {
    install, run_dynamic, apply_css,
    list_monitors, monitor_key
}
import from src.glib { idle_add, timeout_add }
import from src.reactive { set_flush_hook }
import from src.topology_reactive { flush }
import from src.desktop {
    create_desktop, get_desktop, bootstrap_reference_outputs, converge
}
import from src.outputs {
    apply_output_attach, apply_output_detach, classify_role
}
import from src.graph_query { status_dict }
import from src.policy { enter_mode, exit_mode, policy_state, inject_notification }
import from src.notifications_policy { wire_notification_source }
import from src.projection {
    register_surface_builder, present_surface_views, reset_projection
}
import from examples.reference.components { Bar, MinimalBar }
import from examples.reference.notif_ui { NotificationLayer }
import from examples.reference.style { CSS }
import json;

::py::
import os

def force_exit(code=0):
    os._exit(code)
::py::


glob _smoke_done: bool = False;
glob _activated: bool = False;


def _watchdog(app: any) -> bool {
    if not _smoke_done {
        _fail("activation watchdog (checks never finished)");
        print("SMOKE FAILED: " + json.dumps(_failures));
        _quit_app(app);
    }
    return False;
}

def _watchdog_cb(app: any) -> bool {
    return _watchdog(app);
}

def _force_exit_cb() -> bool {
    code = 0 if len(_failures) == 0 else 1;
    force_exit(code);
    return False;
}

glob _failures: list = [];


def _fail(msg: str) {
    _failures.append(msg);
    print("SMOKE FAIL: " + msg);
}

def _quit_app(app: any) {
    idle_add(lambda { app.quit(); return False; });
    timeout_add(1000, _force_exit_cb);
}

def _surface_kinds(st: dict, connector: str) -> list {
    outputs: list = list(st.get("outputs", []));
    for o in outputs {
        if o["connector"] == connector {
            surfaces: list = list(o.get("surfaces", []));
            return [s["kind"] for s in surfaces];
        }
    }
    return [];
}

def _monitor_map() -> dict {
    want: dict = {};
    for m in list_monitors() {
        want[monitor_key(m)] = m;
    }
    return want;
}

def _mon_for(connector: str) -> any {
    return _monitor_map().get(connector);
}

# Mirror reference/main.jac: attach only real outputs for the live bar preview.
# bootstrap_reference_outputs() uses synthetic eDP-1 + HDMI-A-1 for policy checks
# and would stack two unpinned bars on a single monitor if presented.
def _sync_live_outputs() {
    session = get_desktop();
    if session is None { return; }
    mons = _monitor_map();
    st: dict = status_dict(session);
    have: dict = {};
    outputs: list = list(st.get("outputs", []));
    for o in outputs {
        have[o["connector"]] = o;
    }
    for k in list(have.keys()) {
        if k not in mons {
            apply_output_detach(session, k);
        }
    }
    for (k, m) in mons.items() {
        if k not in have {
            apply_output_attach(session, k, classify_role(k));
        }
    }
    if len(mons) == 0 {
        st = status_dict(session);
        if len(st.get("outputs", [])) == 0 {
            apply_output_attach(session, "_default", "unknown");
        }
    }
}

def _register_builders() {
    register_surface_builder("full-bar", lambda (c: str) { Bar(_mon_for(c)); });
    register_surface_builder("minimal-bar", lambda (c: str) { MinimalBar(_mon_for(c)); });
}

def _run_checks(app: any) -> bool {
    session = get_desktop();
    if session is None {
        _fail("no desktop session");
        _quit_app(app);
        return False;
    }
    # Policy/graph checks only — drop builders so bootstrap does not mount GTK bars.
    reset_projection();
    bootstrap_reference_outputs(session);
    st = status_dict(session);
    if len(st["outputs"]) < 1 {
        _fail("expected at least one output");
    }
    if st["routes"]["notification-popup"] is not True {
        _fail("popup route should start active");
    }
    enter_mode(session, "presentation");
    st = status_dict(session);
    if "presentation" not in st["modes"] {
        _fail("presentation mode did not activate");
    }
    if st["routes"]["notification-popup"] is not False {
        _fail("popup route should be suppressed in presentation");
    }
    before = policy_state().history_count;
    before_popup = policy_state().popup_runs;
    inject_notification();
    flush();
    if policy_state().history_count != before + 1 {
        _fail("history should increment once");
    }
    if policy_state().popup_runs != before_popup {
        _fail("popup binding should not run when suppressed");
    }
    apply_output_attach(session, "SMOKE-DP", "projector");
    st = status_dict(session);
    if _surface_kinds(st, "SMOKE-DP") != ["minimal-bar"] {
        _fail("projector output should get minimal bar in presentation");
    }
    apply_output_detach(session, "SMOKE-DP");
    st2 = status_dict(session);
    if _surface_kinds(st2, "SMOKE-DP") != [] {
        _fail("detached output should leave no surfaces");
    }
    exit_mode(session, "presentation");
    st3 = status_dict(session);
    if st3["routes"]["notification-popup"] is not True {
        _fail("popup route should restore after mode exit");
    }
    if len(_failures) == 0 {
        print("SMOKE OK");
    } else {
        print("SMOKE FAILED: " + json.dumps(_failures));
    }
    _smoke_done = True;
    _quit_app(app);
    return False;
}

def on_activate(app: any) {
    if _activated { return; }
    _activated = True;
    timeout_add(30000, lambda { return _watchdog_cb(app); });
    create_desktop("reference");
    wire_notification_source(policy_state().notif_source);
    _register_builders();
    _sync_live_outputs();
    NotificationLayer();
    converge(get_desktop());
    present_surface_views(get_desktop());
    _run_checks(app);
}

with entry {
    install();
    apply_css(CSS);
    set_flush_hook(lambda (f: any) { idle_add(f); });
    run_dynamic(on_activate, "org.jac.shell.smoke");
}
