# REFERENCE — full jacket bar (multi-monitor, launcher, notifications, tray).
# See LIBRARY.md §1: this is one consumer of the library, not the product.
#
# main.jac — graph-native session drives output/surface policy; GTK bars are
# projections mounted during convergence (PLAN E6 / H5).
#
# IPC (AGS-style): start the bar with no args; forward commands to the running
# instance (or answer cold and exit when no server is up):
#     ./run.sh                              # start the bar
#     ./run.sh status --json                # graph session snapshot
#     ./run.sh mode enter presentation      # enter presentation mode
#     ./run.sh mode exit do-not-disturb     # exit DND mode
#     ./run.sh why binding:notification-popup --json
#     ./run.sh quit
import from src.adapter {
    install, run_with_ipc, apply_css,
    list_monitors, monitor_key, connect_monitors_changed
}
import from src.glib { idle_add }
import from src.reactive { set_flush_hook }
import from src.desktop {
    create_desktop, get_desktop, converge
}
import from src.outputs { apply_output_attach, apply_output_detach, classify_role }
import from src.graph_query { status_dict }
import from src.policy { policy_state }
import from src.notifications_policy { wire_notification_source }
import from src.projection {
    register_surface_builder, present_surface_views
}
import from src.ipc { ipc }
import from examples.reference.components { Bar, MinimalBar }
import from examples.reference.launcher_ui { LauncherWindow }
import from examples.reference.notif_ui { NotificationLayer }
import from examples.reference.style { CSS }


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
        # Headless / pre-display fallback: one unpinned bar.
        st = status_dict(session);
        if len(st.get("outputs", [])) == 0 {
            apply_output_attach(session, "_default", "unknown");
            converge(session);
            present_surface_views(session);
        }
    }
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
}


with entry {
    install();
    apply_css(CSS);
    set_flush_hook(lambda (f: any) { idle_add(f); });
    run_with_ipc(
        on_activate,
        lambda (argv: list) { return ipc().handle(argv); },
        "org.jac.shell",
    );
}
