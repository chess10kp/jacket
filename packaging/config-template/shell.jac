# User shell entry — ~/.config/jacket/<name>/shell.jac
# ---------------------------------------------------------------------------
# Start:  jacket run -c <name>
# Dev:    jacket run -c <name> --watch
#     theme.css edits hot-apply; .jac edits restart after jac check passes.
# ===========================================================================
# ::py:: — put the config dir on sys.path so local modules resolve.
::py::
import os, sys
_cfg = os.environ.get("JACKET_CONFIG_DIR")
if _cfg and _cfg not in sys.path:
    sys.path.insert(0, _cfg)
::py::
import os;
# Backend shim: picks wl (Wayland) or gtk (fallback) via JACKET_RENDERER,
# defaulting to auto — wl whenever a Wayland compositor is reachable.
import from jacket.backend {
    install, run_with_ipc, apply_css_file, request_restart,
    list_monitors, monitor_key, connect_monitors_changed
}
import from jacket.glib { idle_add }
import from jacket.osp_local { run_graph_inprocess }
import from jacket.reactive { set_flush_hook }
import from jacket.desktop {
    create_desktop, get_desktop, converge
}
import from jacket.outputs { apply_output_attach, apply_output_detach, classify_role }
import from jacket.graph_query { status_dict }
import from jacket.policy { policy_state }
import from jacket.notifications_policy { wire_notification_source }
import from jacket.projection {
    register_surface_builder, present_surface_views
}
import from jacket.ipc { ipc, start_ipc_socket }
import from jacket.config { resolve_config, validate_config }
import from jacket.dev_watch { watch_config }
import from components { Bar, MinimalBar }
import from launcher_ui { LauncherWindow }
import from notif_ui { NotificationLayer }


glob CONFIG: dict = {};
glob THEME_PATH: str = "";


def _init_paths() {
    name = os.environ.get("JACKET_CONFIG_NAME", "default");
    CONFIG = resolve_config(name);
    THEME_PATH = CONFIG["theme_css"];
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


def _register_bar_builders() {
    register_surface_builder("full-bar", lambda (c: str) { Bar(_mon_for(c)); });
    register_surface_builder("minimal-bar", lambda (c: str) { MinimalBar(_mon_for(c)); });
}


def _sync_session_outputs() {
    session = get_desktop();
    if session is None { return; }
    mons = _monitor_map();
    st: dict = status_dict(session);
    outputs: list = list(st.get("outputs", []));
    have: dict = {};
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
}


def sync_bars() {
    _register_bar_builders();
    _sync_session_outputs();
    session = get_desktop();
    converge(session);
    present_surface_views(session);
    if len(list_monitors()) == 0 {
        st = status_dict(session);
        if len(st.get("outputs", [])) == 0 {
            apply_output_attach(session, "_default", "unknown");
            converge(session);
            present_surface_views(session);
        }
    }
}


def _maybe_watch() {
    if os.environ.get("JACKET_WATCH") != "1" { return; }
    watch_config(
        CONFIG["dir"],
        CONFIG["shell"],
        THEME_PATH,
        lambda { apply_css_file(THEME_PATH); },
        lambda { request_restart(); },
    );
}


def on_activate(app: any) {
    create_desktop("reference");
    wire_notification_source(policy_state().notif_source);
    ipc().enable_graph(True);
    ipc().set_app(app);
    launcher = LauncherWindow();
    launcher.widget.present();
    launcher.widget.set_visible(False);
    NotificationLayer();
    sync_bars();
    connect_monitors_changed(sync_bars);
    start_ipc_socket(lambda (argv: list) { return ipc().handle(argv); });
    _maybe_watch();
}


with entry {
    _init_paths();
    run_graph_inprocess();           # detach the SQL store BEFORE any graph op
    err = validate_config(CONFIG);
    if err != "" {
        print(err);
        raise Exception(err);
    }
    install();
    apply_css_file(THEME_PATH);
    set_flush_hook(lambda (f: any) { idle_add(f); });
    run_with_ipc(
        on_activate,
        lambda (argv: list) { return ipc().handle(argv); },
        "org.jac.shell",
    );
}
