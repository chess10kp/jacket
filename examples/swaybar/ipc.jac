# swaybar example — IPC component registration.
# ---------------------------------------------------------------------------
# Transport + handler registry live in the library (adapter.run_with_ipc,
# src.ipc). This file registers the swaybar's named getters so scripts can
# query live widget data:
#     jac run examples/swaybar/main.jac status          # -> "clock=.. mem=.. ..."
#     jac run examples/swaybar/main.jac stocks          # -> "L:.. C:.. W:.. ..."
import from src.battery { get_battery }
import from time { time, strftime, localtime }
import from src.ipc { ipc }
import from examples.swaybar.sources {
    countdown, get_mem, get_bluetooth, get_stocks, format_stocks
}


def _clock_text() -> str {
    return strftime("%H%M", localtime(int(time())));
}

def _battery_text() -> str {
    b = get_battery().battery();
    if not bool(b["present"]) { return ""; }
    pct = int(b["percent"]);
    return str(pct) + "%" + (" charging" if bool(b["charging"]) else "");
}

def register_components() {
    h = ipc();
    h.register("clock", _clock_text);
    h.register("countdown", lambda { str(countdown()()); });
    h.register("stocks", lambda { format_stocks(get_stocks().prices()); });
    h.register("mem", lambda { str(get_mem().used()); });
    h.register("battery", _battery_text);
    h.register("bluetooth", lambda { str(get_bluetooth().device()); });
}
