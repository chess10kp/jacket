# swaybar example — entry point (IPC-enabled).
# Run with no args to start the bar (server). Any args are an AGS-style request
# forwarded to the running instance (or answered cold if none is running):
#     jac run examples/swaybar/main.jac             # start the bar
#     jac run examples/swaybar/main.jac status      # one-line snapshot
#     jac run examples/swaybar/main.jac stocks      # just the stocks block
#     jac run examples/swaybar/main.jac toggle      # show/hide
#     jac run examples/swaybar/main.jac quit
import from jacket.adapter { install, apply_css, run_with_ipc }
import from jacket.reactive { set_flush_hook }
import from jacket.glib { idle_add }
import from jacket.ipc { ipc }
import from examples.swaybar.components { Bar }
import from examples.swaybar.style { CSS }
import from examples.swaybar.ipc { register_components }


def on_activate(app: any) {
    apply_css(CSS);
    bar = Bar();
    bar.widget.present();
    h = ipc();
    h.set_bar(bar);
    h.set_app(app);
}

with entry {
    install();
    set_flush_hook(lambda (f: any) { idle_add(f); });
    register_components();
    run_with_ipc(
        on_activate,
        lambda (argv: list) { return ipc().handle(argv); },
        "org.jac.swaybar",
    );
}
