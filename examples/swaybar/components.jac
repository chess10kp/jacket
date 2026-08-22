# swaybar example — widgets built on the jacket library.
# ---------------------------------------------------------------------------
# One widget per module of ~/.config/sway/bar. Battery + clock use LIBRARY
# sources (jacket.battery, jacket.bluetooth, jacket.sources); countdown / mem / stocks use
# the local sources in examples/swaybar/sources.jac. Gruvbox colours live in
# style.jac.
import from time { strftime, localtime }
import from jacket.builders { component, Box, Label, Window }
import from jacket.sources { ticker }
import from jacket.battery { get_battery, battery_icon }
import from jacket.bluetooth { get_bluetooth }
import from examples.swaybar.sources {
    countdown, get_mem, get_stocks, format_stocks
}


# Countdown — elapsed timer off /tmp/timer_start; hidden when not set.
@component
def CountdownWidget() -> any {
    cd = countdown();
    txt = cd.map(lambda (s: str) { ("" if s == "" else "T- " + s); });
    return Label(class="countdown", text=txt, hidden=cd.map(lambda (s: str) { s == ""; }));
}


# Stocks — "L:price C:price W:price BE:price NOW:price"; hidden until any data.
@component
def StocksWidget() -> any {
    s = get_stocks();
    txt = s.prices.map(format_stocks);
    return Label(class="stocks", text=txt, hidden=txt.map(lambda (t: str) { t == ""; }));
}


# Mem — used memory, human form.
@component
def MemWidget() -> any {
    m = get_mem();
    return Label(class="mem", text=m.used.map(lambda (u: str) { "MEM " + u; }));
}


# Bluetooth — first connected device; hidden when nothing is connected.
@component
def BluetoothWidget() -> any {
    b = get_bluetooth();
    dev = b.primary_device;
    return Label(class="bt",
        text=dev.map(lambda (n: str) { ("" if n == "" else "BT " + n); }),
        hidden=dev.map(lambda (n: str) { n == ""; }));
}


# Clock — HHMM, matching the script's `date +'%H%M'`.
@component
def ClockWidget() -> any {
    t = ticker(1000);
    return Label(class="clock", text=t.map(lambda (tv: any) { strftime("%H%M", localtime(tv)); }));
}


# Battery — meter + percent. Faithful to the script's colours: red at/below 20%,
# yellow otherwise; charging shows the '+' marker in the library's meter.
# Hidden entirely when no battery is present.
def _batt_text(d: dict) -> str {
    return battery_icon(d["percent"], d["charging"]) + " " + str(d["percent"]) + "%";
}

def _batt_class(d: dict) -> str {
    if ((not d["present"]) or (d["percent"] <= 20)) { return "battery low"; }
    return "battery";
}

@component
def BatteryWidget() -> any {
    b = get_battery();
    return Label(class=b.battery.map(_batt_class),
        text=b.battery.map(_batt_text),
        hidden=b.battery.map(lambda (d: dict) { not d["present"]; }));
}


# Bar — bottom-anchored, full width. Order mirrors the shell script's
# get_status(): countdown, stocks, mem, bluetooth ... clock, battery.
@component
def Bar() -> any {
    return Window(class="bar", anchor="bottom", height=34,
        child=Box(orientation="H", class="bar-inner", children=[
            CountdownWidget(),
            StocksWidget(),
            MemWidget(),
            BluetoothWidget(),
            Box(orientation="H", class="spacer", hexpand=True),
            ClockWidget(),
            BatteryWidget(),
        ]));
}
