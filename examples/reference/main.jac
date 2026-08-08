# REFERENCE — full jac-shell bar (multi-monitor, launcher, notifications, tray).
# See LIBRARY.md §1: this is one consumer of the library, not the product.
#
# main.jac — entry point: install the GTK adapter, wire the reactive scheduler
# onto the GLib main loop, build the roots, run.
#
# ROOTS come in two flavours:
#   * popups (launcher, notification layer) — one each, present-once then hidden
#     until their signal flips.
#   * bars — ONE PER CONNECTED MONITOR. We enumerate Gdk monitors at activate and
#     pin a Bar to each; on hotplug (items-changed) we present a bar for a new
#     output and destroy the bar of a removed one. Headless / single-output falls
#     back to a lone unpinned Bar.
import from src.adapter {
    install, run_dynamic, apply_css,
    list_monitors, monitor_key, destroy_window, connect_monitors_changed
}
import from src.glib { idle_add }
import from src.reactive { set_flush_hook }
import from src.builders { dispose_tree }
import from examples.reference.components { Bar }
import from examples.reference.launcher_ui { LauncherWindow }
import from examples.reference.notif_ui { NotificationLayer }
import from examples.reference.style { CSS }


# monitor-key -> the live Bar ViewNode currently pinned to that output.
glob _bars: dict = {};


# Reconcile the set of bars against the connected monitors: present a bar for
# each new output, tear down the bar of each vanished one. Idempotent, so it
# doubles as both the initial build and the hotplug handler.
def sync_bars() {
    want: dict = {};
    mons = list_monitors();
    for m in mons { want[monitor_key(m)] = m; }

    for k in list(_bars.keys()) {
        if k not in want {
            bar = _bars.pop(k);
            destroy_window(bar.widget);        # unmap + drop the GTK window
            dispose_tree(bar);                 # stop its effects/handlers
        }
    }
    for (k, m) in want.items() {
        if k not in _bars {
            bar = Bar(m);
            _bars[k] = bar;
            bar.widget.present();
        }
    }
    # No layer-shell monitors at all (headless / plain compositor): a lone bar.
    if len(_bars) == 0 {
        bar = Bar();
        _bars["_default"] = bar;
        bar.widget.present();
    }
}


def on_activate(app: any) {
    # Popups: present once (maps the layer surface), then hide until toggled.
    for p in [LauncherWindow(), NotificationLayer()] {
        p.widget.present();
        p.widget.set_visible(False);
    }
    sync_bars();
    connect_monitors_changed(sync_bars);       # live add/remove on hotplug
}


with entry {
    install();                                      # gtk init + install GTK adapter
    apply_css(CSS);                                 # app-level stylesheet
    set_flush_hook(lambda (f: any) { idle_add(f); });    # commit effects per idle tick
    run_dynamic(on_activate, "org.jac.shell");
}
