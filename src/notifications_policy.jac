# notifications_policy.jac — bridge NotificationDaemon → policy notif_source (T2 step 4).
# ---------------------------------------------------------------------------
# GTK/DBus path only: imported by the reference shell, not headless policy tests.
import from src.reactive { effect }
import from src.notifications { get_notifications }
import from src.topology_reactive { source_set }


def wire_notification_source(src: any) {
    d = get_notifications();
    effect(lambda {
        source_set(src, len(d.notifications()));
    });
}

def inject_notification_event() {
    d = get_notifications();
    d._notify("test", 0, "summary", "body", {}, 0);
}
