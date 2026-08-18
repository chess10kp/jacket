# sources_tests.jac — headless tests for the PURE source logic (PLAN §5).
# Sources own sockets/DBus/subprocesses (untestable here), but their PARSERS
# are pure text->data functions and carry all the real logic. We test those.
import from src.hyprland { parse_workspaces, parse_active }
import from src.sway { parse_sway_workspaces }
import from src.battery { parse_battery, battery_icon }
import from src.power_profiles {
    normalize_profile, parse_profile_properties, parse_powerprofilesctl_output,
    next_profile
}
import from src.audio { parse_volume }
import from src.brightness { parse_brightnessctl_info, parse_brightnessctl_get }
import from src.pipewire {
    parse_vol_from_desc, parse_device_line, parse_wpctl_status,
    merge_device_volume, resolve_wpctl_id
}
import from src.launcher { parse_desktop, filter_apps, score, strip_field_codes }
import from src.notifications { make_notification, apply_notify, dismiss, resolve_timeout, hint_urgency }
import from src.mpris { parse_metadata, is_playing, format_status }
import from src.tray { resolve_item, split_item_key, should_show, pick_icon_name, _pixmap_to_texture, parse_menu_layout, clean_label }
import from src.network { parse_nmcli_general_status, parse_nmcli_wifi_list, parse_nmcli_active_connection }
import from src.bluetooth {
    parse_bluetoothctl_devices, parse_bluetoothctl_show_powered,
    parse_bluetoothctl_paired, primary_device_from_connected
}


# --- Hyprland ---------------------------------------------------------------
test "parse_workspaces keeps rendered fields, sorted by id" {
    j = "[{\"id\": 2, \"name\": \"two\", \"monitor\": \"DP-1\", \"focused\": true, \"windows\": 3},"
        + "{\"id\": 1, \"name\": \"one\", \"monitor\": \"DP-1\", \"focused\": false, \"windows\": 0}]";
    ws = parse_workspaces(j);
    assert len(ws) == 2;
    assert ws[0]["id"] == 1;               # sorted
    assert ws[1]["id"] == 2;
    assert ws[1]["active"] == True;        # `focused` -> active
    assert ws[0]["windows"] == 0;
}

test "parse_workspaces tolerates garbage / empty" {
    assert parse_workspaces("not json") == [];
    assert parse_workspaces("[]") == [];
}

test "parse_active reads the id" {
    assert parse_active("{\"id\": 5, \"name\": \"five\"}") == 5;
    assert parse_active("garbage") == 0;
}


# --- Sway/i3 workspaces (same shape as Hyprland's) --------------------------
test "parse_sway_workspaces maps num/output/focused, sorted" {
    j = "[{\"id\": 7, \"num\": 2, \"name\": \"2\", \"output\": \"eDP-1\", \"focused\": true},"
        + "{\"id\": 6, \"num\": 1, \"name\": \"1\", \"output\": \"eDP-1\", \"focused\": false}]";
    ws = parse_sway_workspaces(j);
    assert len(ws) == 2;
    assert ws[0]["id"] == 1;               # sorted by num
    assert ws[0]["key"] == 6;              # container id -> stable For key
    assert ws[1]["active"] == True;        # focused -> active
    assert ws[0]["monitor"] == "eDP-1";    # output -> monitor
    assert parse_sway_workspaces("junk") == [];
}


# --- Bluetooth --------------------------------------------------------------
test "parse_bluetoothctl_devices reads Connected lines" {
    txt = "Device 88:0E:85:39:E6:9C soundcore Life Q20\n"
        + "Device AA:BB:CC:DD:EE:FF\n"
        + "garbage line\n";
    devs = parse_bluetoothctl_devices(txt);
    assert len(devs) == 2;
    assert devs[0]["address"] == "88:0E:85:39:E6:9C";
    assert devs[0]["name"] == "soundcore Life Q20";
    assert devs[0]["alias"] == "soundcore Life Q20";
    assert devs[1]["name"] == "";
}

test "parse_bluetoothctl_show_powered reads yes/no" {
    assert parse_bluetoothctl_show_powered("Powered: yes\n") == True;
    assert parse_bluetoothctl_show_powered("Powered: no\n") == False;
    assert parse_bluetoothctl_show_powered("no Powered here\n") == False;
}

test "parse_bluetoothctl_paired mirrors devices parser" {
    txt = "Device C4:EF:3D:91:96:24 Galaxy S24 FE\n";
    paired = parse_bluetoothctl_paired(txt);
    assert len(paired) == 1;
    assert paired[0]["name"] == "Galaxy S24 FE";
}

test "primary_device_from_connected picks first name or alias" {
    assert primary_device_from_connected([]) == "";
    devs = [
        {"name": "Headphones", "address": "AA:BB", "alias": "HP"},
        {"name": "Phone", "address": "CC:DD", "alias": "Phone"},
    ];
    assert primary_device_from_connected(devs) == "Headphones";
    no_name = [{"name": "", "address": "AA:BB", "alias": "Fallback"}];
    assert primary_device_from_connected(no_name) == "Fallback";
}


# --- Network (nmcli parsers) ------------------------------------------------
test "parse_nmcli_general_status reads wifi radio + connected state" {
    g = parse_nmcli_general_status("enabled:connected");
    assert g["available"] == True;
    assert g["wifi_enabled"] == True;
    assert g["connected"] == True;
    d = parse_nmcli_general_status("disabled:disconnected");
    assert d["wifi_enabled"] == False;
    assert d["connected"] == False;
    assert parse_nmcli_general_status("")["available"] == False;
}

test "parse_nmcli_wifi_list dedupes by ssid, keeps strongest, marks active" {
    txt = "no:Guest:40:WPA2\nyes:Home:72:WPA2\nno:Home:55:WPA2\nno::80:--\n";
    nets = parse_nmcli_wifi_list(txt);
    assert len(nets) == 2;
    assert nets[0]["ssid"] == "Home";
    assert nets[0]["strength"] == 72;
    assert nets[0]["secured"] == True;
    assert nets[0]["active"] == True;
    assert nets[1]["ssid"] == "Guest";
    assert nets[1]["active"] == False;
}

test "parse_nmcli_active_connection prefers wifi over bridge/loopback" {
    txt = "lo:loopback:lo:activated\n"
        + "docker0:bridge:docker0:activated\n"
        + "Office:802-11-wireless:wlan0:activated\n";
    a = parse_nmcli_active_connection(txt);
    assert a["connected"] == True;
    assert a["connection_type"] == "wifi";
    assert a["device"] == "wlan0";
    assert a["ssid"] == "Office";
    eth = parse_nmcli_active_connection("Work:802-3-ethernet:enp0s31f6:activated\n");
    assert eth["connection_type"] == "ethernet";
    assert eth["ssid"] == "";
    assert parse_nmcli_active_connection("")["connected"] == False;
}


# --- Battery ----------------------------------------------------------------
test "parse_battery normalizes percentage + charging state" {
    b = parse_battery(42.0, 2);            # UPower Percentage is 0-100; state 2 = Discharging
    assert b["percent"] == 42;
    assert b["charging"] == False;
    c = parse_battery(100.0, 1);           # state 1 = Charging
    assert c["percent"] == 100;
    assert c["charging"] == True;
}

test "battery_icon steps by charge + charging flag" {
    assert battery_icon(5, False) != battery_icon(95, False);
    assert battery_icon(50, True) != battery_icon(50, False);
}


# --- Power profiles ---------------------------------------------------------
test "normalize_profile maps canonical names and aliases" {
    assert normalize_profile("performance") == "performance";
    assert normalize_profile("balanced") == "balanced";
    assert normalize_profile("power-saver") == "power-saver";
    assert normalize_profile("power-save") == "power-saver";
    assert normalize_profile("POWER_SAVER") == "power-saver";
    assert normalize_profile("unknown") == "balanced";
}

test "parse_powerprofilesctl_output strips whitespace" {
    assert parse_powerprofilesctl_output("power-saver\n") == "power-saver";
    assert parse_powerprofilesctl_output(" balanced ") == "balanced";
}

test "parse_profile_properties extracts profile, has_performance, degradation" {
    props = {
        "ActiveProfile": "balanced",
        "Profiles": [
            {"Profile": "power-saver"},
            {"Profile": "balanced"},
            {"Profile": "performance"},
        ],
        "PerformanceDegraded": "thermal",
        "PerformanceInhibited": "",
    };
    r = parse_profile_properties(props);
    assert r["available"] == True;
    assert r["profile"] == "balanced";
    assert r["has_performance"] == True;
    assert r["degradation_reason"] == "thermal";
}

test "parse_profile_properties uses inhibited when degraded is empty" {
    props = {
        "ActiveProfile": "performance",
        "Profiles": [{"Profile": "performance"}],
        "PerformanceDegraded": "",
        "PerformanceInhibited": "low-battery",
    };
    r = parse_profile_properties(props);
    assert r["degradation_reason"] == "low-battery";
    assert r["has_performance"] == True;
}

test "parse_profile_properties without performance profile" {
    props = {
        "ActiveProfile": "balanced",
        "Profiles": [{"Profile": "balanced"}, {"Profile": "power-saver"}],
        "PerformanceDegraded": "",
        "PerformanceInhibited": "",
    };
    r = parse_profile_properties(props);
    assert r["has_performance"] == False;
    assert r["degradation_reason"] == "";
}

test "next_profile cycles balanced -> performance -> power-saver -> balanced" {
    assert next_profile("balanced") == "performance";
    assert next_profile("performance") == "power-saver";
    assert next_profile("power-saver") == "balanced";
    assert next_profile("garbage") == "performance";  # unknown normalizes to balanced
}


# --- Brightness -------------------------------------------------------------
test "parse_brightnessctl_info reads machine -m output" {
    m = "intel_backlight,backlight,340,85%,400";
    b = parse_brightnessctl_info(m);
    assert b["available"] == True;
    assert b["device"] == "intel_backlight";
    assert b["raw"] == 340;
    assert b["percent"] == 85;
    assert b["max"] == 400;
}

test "parse_brightnessctl_info reads -l backlight block" {
    txt = "Available devices:\n"
        + "Device 'intel_backlight' of class 'backlight':\n"
        + "\tCurrent brightness: 200 (50%)\n"
        + "\tMax brightness: 400\n"
        + "Device 'phy0-led' of class 'leds':\n"
        + "\tCurrent brightness: 1 (100%)\n"
        + "\tMax brightness: 1\n";
    b = parse_brightnessctl_info(txt);
    assert b["available"] == True;
    assert b["device"] == "intel_backlight";
    assert b["raw"] == 200;
    assert b["percent"] == 50;
    assert b["max"] == 400;
}

test "parse_brightnessctl_info skips non-backlight machine lines" {
    m = "phy0-led,leds,1,100%,1\nintel_backlight,backlight,80,20%,400";
    b = parse_brightnessctl_info(m);
    assert b["device"] == "intel_backlight";
    assert b["percent"] == 20;
}

test "parse_brightnessctl_info tolerates empty / garbage" {
    e = parse_brightnessctl_info("");
    assert e["available"] == False;
    assert parse_brightnessctl_info("no backlight here")["available"] == False;
}

test "parse_brightnessctl_get from get+max lines" {
    b = parse_brightnessctl_get("340\n400");
    assert b["available"] == True;
    assert b["raw"] == 340;
    assert b["max"] == 400;
    assert b["percent"] == 85;
}

test "parse_brightnessctl_get accepts raw/max slash form" {
    b = parse_brightnessctl_get("200/400");
    assert b["raw"] == 200;
    assert b["max"] == 400;
    assert b["percent"] == 50;
}

test "parse_brightnessctl_get rejects zero max" {
    assert parse_brightnessctl_get("100\n0")["available"] == False;
}


# --- Audio ------------------------------------------------------------------
test "parse_volume reads wpctl output" {
    v = parse_volume("Volume: 0.65");
    assert v["percent"] == 65;
    assert v["muted"] == False;
    m = parse_volume("Volume: 0.30 [MUTED]");
    assert m["percent"] == 30;
    assert m["muted"] == True;
}

test "parse_volume tolerates junk" {
    v = parse_volume("");
    assert v["percent"] == 0;
}


# --- Launcher ---------------------------------------------------------------
def sample_desktop() -> str {
    return "[Desktop Entry]\nName=Firefox\nExec=firefox %u\nIcon=firefox\n"
        + "Type=Application\nCategories=Network;\n";
}

test "parse_desktop extracts name/exec/icon, strips field codes" {
    e = parse_desktop(sample_desktop());
    assert e["name"] == "Firefox";
    assert e["exec"] == "firefox";          # %u stripped
    assert e["icon"] == "firefox";
}

test "parse_desktop skips NoDisplay/Hidden entries" {
    hidden = "[Desktop Entry]\nName=Secret\nExec=x\nNoDisplay=true\n";
    assert parse_desktop(hidden) is None;
}

test "filter_apps fuzzy-ranks by query" {
    apps = [
        {"name": "Firefox", "exec": "firefox"},
        {"name": "Files", "exec": "nautilus"},
        {"name": "Calculator", "exec": "gnome-calculator"},
    ];
    res = filter_apps(apps, "fi");
    assert len(res) == 2;                   # Firefox + Files match
    assert res[0]["name"] in ["Firefox", "Files"];
    # empty query returns all
    assert len(filter_apps(apps, "")) == 3;
}

test "score prefers prefix + contiguous matches" {
    assert score("Firefox", "fire") > score("Firefox", "fox");
    assert score("Firefox", "xyz") == 0;
}


# --- Notifications reducer ---------------------------------------------------
def notif(id: int, urgency: int) -> dict {
    return make_notification(id, "app", "sum", "body", urgency, -1);
}

test "apply_notify appends a new notification" {
    a = apply_notify([], notif(1, 1));
    assert len(a) == 1;
    assert a[0]["id"] == 1;
    b = apply_notify(a, notif(2, 1));
    assert len(b) == 2;
    assert a is not b;                     # new list (identity change for the For)
}

test "apply_notify replaces in place by id (replaces_id semantics)" {
    a = apply_notify([], notif(1, 1));
    updated = make_notification(1, "app", "NEW", "body", 1, -1);
    b = apply_notify(a, updated);
    assert len(b) == 1;                    # replaced, not appended
    assert b[0]["summary"] == "NEW";
}

test "dismiss removes by id" {
    a = apply_notify(apply_notify([], notif(1, 1)), notif(2, 1));
    b = dismiss(a, 1);
    assert len(b) == 1;
    assert b[0]["id"] == 2;
    assert dismiss(b, 99) == b;            # missing id is a no-op
}

test "resolve_timeout: critical is sticky, 0 never, -1 defaults" {
    assert resolve_timeout(-1, 2) == 0;    # critical urgency overrides
    assert resolve_timeout(0, 1) == 0;     # explicit never
    assert resolve_timeout(-1, 1) == 5000; # server default
    assert resolve_timeout(3000, 0) == 3000;
}

test "hint_urgency defaults to normal, reads the hint" {
    assert hint_urgency({}) == 1;
    assert hint_urgency({"urgency": 2}) == 2;
}


# --- MPRIS ------------------------------------------------------------------
test "parse_metadata pulls title + first artist" {
    m = parse_metadata({"xesam:title": "Song", "xesam:artist": ["Band", "Feat"]});
    assert m["title"] == "Song";
    assert m["artist"] == "Band";
    # tolerates a string artist and missing fields
    assert parse_metadata({"xesam:artist": "Solo"})["artist"] == "Solo";
    assert parse_metadata({})["title"] == "";
}

test "is_playing maps PlaybackStatus" {
    assert is_playing("Playing") == True;
    assert is_playing("Paused") == False;
    assert is_playing("Stopped") == False;
}

test "format_status renders artist — title, empty when idle" {
    playing = {"has_player": True, "playing": True, "title": "T", "artist": "A"};
    assert "A — T" in format_status(playing);
    # no player / no title -> empty
    assert format_status({"has_player": False}) == "";
    assert format_status({"has_player": True, "title": ""}) == "";
    # title only
    assert "Solo" in format_status({"has_player": True, "playing": False, "title": "Solo", "artist": ""});
}


# --- Tray (StatusNotifierItem) ----------------------------------------------
test "resolve_item: bus name vs object path (KDE vs Ayatana)" {
    # KDE style: a bus name -> item at the canonical /StatusNotifierItem path.
    assert resolve_item(":1.42", ":1.42") == ":1.42/StatusNotifierItem";
    # Ayatana/libappindicator style: an object path -> bus is the SENDER.
    assert resolve_item("/org/ayatana/NotificationItem/x", ":1.99")
        == ":1.99/org/ayatana/NotificationItem/x";
    # path with an empty sender falls back to the path itself as the bus part
    assert resolve_item("/StatusNotifierItem", "") == "/StatusNotifierItem";
}

test "split_item_key round-trips resolve_item" {
    k = resolve_item(":1.42", ":1.42");
    (bus, path) = split_item_key(k);
    assert bus == ":1.42";
    assert path == "/StatusNotifierItem";
    (b2, p2) = split_item_key(":1.99/org/ayatana/NotificationItem/x");
    assert b2 == ":1.99";
    assert p2 == "/org/ayatana/NotificationItem/x";
    # a bare path (no bus) keys off the first '/'
    (b3, p3) = split_item_key("/StatusNotifierItem");
    assert b3 == "";
    assert p3 == "/StatusNotifierItem";
}

test "pick_icon_name swaps in the attention icon only on NeedsAttention" {
    assert pick_icon_name("normal", "attn", "Active") == "normal";
    assert pick_icon_name("normal", "attn", "NeedsAttention") == "attn";
    # no attention icon supplied -> keep the normal one even when attending
    assert pick_icon_name("normal", "", "NeedsAttention") == "normal";
    assert should_show("Passive") == True;         # we draw Passive items too
}


# ===========================================================================
# EDGE CASES — strengthen coverage of the already-wired pure logic. These lock
# in branch behavior the happy-path tests above don't reach.
# ===========================================================================

# --- Battery: charging semantics across the full UPower State enum ----------
test "parse_battery treats Fully(4)/Pending(5) as charging, Empty(3) as not" {
    assert parse_battery(80.0, 4)["charging"] == True;    # Fully charged
    assert parse_battery(80.0, 5)["charging"] == True;    # Pending charge
    assert parse_battery(80.0, 3)["charging"] == False;   # Empty
    assert parse_battery(0.0, 2)["charging"] == False;    # Discharging
}

test "parse_battery rounds percentage to the nearest int" {
    assert parse_battery(42.4, 2)["percent"] == 42;
    assert parse_battery(42.6, 2)["percent"] == 43;
    assert parse_battery(99.9, 1)["percent"] == 100;
}

test "battery_icon gives a distinct meter per bucket; charging overrides" {
    # boundary values exercise each >= step (90/70/50/30/10)
    glyphs = [
        battery_icon(90, False), battery_icon(70, False),
        battery_icon(50, False), battery_icon(30, False),
        battery_icon(10, False), battery_icon(5, False),
    ];
    assert len(set(glyphs)) == 6;                          # 6 discharging buckets
    assert battery_icon(95, False) == battery_icon(90, False);   # same top bucket
    assert battery_icon(0, True) == battery_icon(100, True);     # one marker regardless of charge
}


# --- Audio: parse_volume label-skip, over-amplification, no numeric token ---
test "parse_volume skips the 'Volume:' label and reads the first float" {
    v = parse_volume("Volume: 1.00");
    assert v["percent"] == 100;
    assert v["muted"] == False;
}

test "parse_volume handles over-amplification and a muted zero" {
    assert parse_volume("Volume: 1.50")["percent"] == 150;
    m = parse_volume("Volume: 0.00 [MUTED]");
    assert m["percent"] == 0;
    assert m["muted"] == True;
}

test "parse_volume with no numeric token is zero, unmuted" {
    v = parse_volume("Volume: n/a");
    assert v["percent"] == 0;
    assert v["muted"] == False;
}


# --- PipeWire (wpctl status / get-volume parsers) ---------------------------
def sample_wpctl_status() -> str {
    return "Audio\n"
        + " ├─ Sinks:\n"
        + " │      59. HDMI Output [vol: 1.00]\n"
        + " │  *   93. soundcore Life Q20 [vol: 0.28]\n"
        + " ├─ Sources:\n"
        + " │      63. Microphone [vol: 1.00]\n"
        + " ├─ Filters:\n"
        + " │  *  102. bluez_input [Audio/Source]\n"
        + "Video\n";
}

test "parse_vol_from_desc reads vol bracket and muted marker" {
    v = parse_vol_from_desc("vol: 0.28");
    assert v["percent"] == 28;
    assert v["muted"] == False;
    m = parse_vol_from_desc("vol: 0.30 [MUTED]");
    assert m["percent"] == 30;
    assert m["muted"] == True;
    assert parse_vol_from_desc("Audio/Source")["percent"] == 0;
}

test "parse_device_line extracts id, name, default star, description" {
    d = parse_device_line(" │  *   93. soundcore Life Q20 [vol: 0.28]");
    assert d is not None;
    assert d["id"] == 93;
    assert d["name"] == "soundcore Life Q20";
    assert d["percent"] == 28;
    assert d["default"] == True;
    assert d["description"] == "vol: 0.28";
    plain = parse_device_line(" │      63. Microphone [vol: 1.00]");
    assert plain["default"] == False;
    assert plain["name"] == "Microphone";
}

test "parse_device_line rejects non-device lines" {
    assert parse_device_line(" ├─ Sinks:") is None;
    assert parse_device_line("") is None;
    assert parse_device_line("no id here") is None;
}

test "parse_wpctl_status collects sinks, sources, defaults" {
    p = parse_wpctl_status(sample_wpctl_status());
    assert p["ready"] == True;
    assert len(p["sinks"]) == 2;
    assert len(p["sources"]) == 2;           # Sources + Filters inputs
    assert p["default_sink"]["id"] == 93;
    assert p["default_sink"]["name"] == "soundcore Life Q20";
    assert p["default_sink"]["percent"] == 28;
    assert p["default_source"]["id"] == 102;
    assert p["default_source"]["name"] == "bluez_input";
}

test "parse_wpctl_status tolerates garbage / empty" {
    empty = parse_wpctl_status("");
    assert empty["ready"] == False;
    assert empty["default_sink"]["id"] == 0;
    assert empty["sinks"] == [];
    assert empty["sources"] == [];
}

test "merge_device_volume prefers get-volume mute + percent" {
    dev = {"id": 93, "name": "Headphones", "percent": 28, "muted": False, "description": "vol: 0.28"};
    merged = merge_device_volume(dev, "Volume: 0.30 [MUTED]");
    assert merged["percent"] == 30;
    assert merged["muted"] == True;
    assert merged["name"] == "Headphones";
}

test "resolve_wpctl_id maps default aliases and passes numeric ids" {
    assert resolve_wpctl_id("default", "sink") == "@DEFAULT_AUDIO_SINK@";
    assert resolve_wpctl_id("", "source") == "@DEFAULT_AUDIO_SOURCE@";
    assert resolve_wpctl_id("93", "sink") == "93";
    assert resolve_wpctl_id("@DEFAULT_AUDIO_SINK@", "sink") == "@DEFAULT_AUDIO_SINK@";
}


# --- Launcher: field-code stripping + fuzzy ranking edges -------------------
test "strip_field_codes drops every %-token, keeps args + flags" {
    assert strip_field_codes("firefox %u") == "firefox";
    assert strip_field_codes("app %F --flag %i %c") == "app --flag";
    assert strip_field_codes("code --new-window") == "code --new-window";
    assert strip_field_codes("%f") == "";
}

test "score matches a non-contiguous subsequence, rewards contiguity" {
    assert score("Firefox", "ff") > 0;                     # f..f subsequence
    assert score("Firefox", "ffx") > 0;
    assert score("abc", "cba") == 0;                       # out of order -> no match
    assert score("Terminal", "term") > score("Terminal", "trml");
}

test "filter_apps sorts by score desc, breaks equal scores by name" {
    apps = [
        {"name": "Slack", "exec": "slack"},
        {"name": "Settings", "exec": "settings"},
        {"name": "Screenshot", "exec": "grim"},
    ];
    res = filter_apps(apps, "s");                           # all share the prefix score
    names = [a["name"] for a in res];
    assert names == ["Screenshot", "Settings", "Slack"];   # alphabetical tie-break
}

test "parse_desktop ignores non-[Desktop Entry] sections" {
    txt = "[Desktop Entry]\nName=App\nExec=app\n"
        + "[Desktop Action new]\nName=NewWindow\nExec=app --new\n";
    e = parse_desktop(txt);
    assert e["name"] == "App";
    assert e["exec"] == "app";                             # the Action's Exec is ignored
}

test "parse_desktop returns None for a Link type or a missing Exec" {
    link = "[Desktop Entry]\nName=Site\nURL=x\nType=Link\n";
    assert parse_desktop(link) is None;
    noexec = "[Desktop Entry]\nName=NoRun\n";
    assert parse_desktop(noexec) is None;
}


# --- MPRIS: metadata + status formatting edges ------------------------------
test "parse_metadata handles an empty artist list and a missing title" {
    m = parse_metadata({"xesam:title": "T", "xesam:artist": []});
    assert m["artist"] == "";
    assert m["title"] == "T";
    assert parse_metadata({})["artist"] == "";
}

test "format_status picks a play/pause marker and drops an empty artist" {
    paused = format_status({"has_player": True, "playing": False, "title": "T", "artist": "A"});
    playing = format_status({"has_player": True, "playing": True, "title": "T", "artist": "A"});
    assert paused != playing;                              # marker differs by state
    assert "A — T" in paused;
    solo = format_status({"has_player": True, "playing": True, "title": "T", "artist": ""});
    assert "—" not in solo;                                # no dash without an artist
    assert "T" in solo;
}


# --- Tray: key round-trips for both SNI registration styles -----------------
test "split_item_key on a bus name with no path uses the canonical path" {
    (bus, path) = split_item_key(":1.5");
    assert bus == ":1.5";
    assert path == "/StatusNotifierItem";
}

test "resolve_item then split_item_key survives an Ayatana object path" {
    k = resolve_item("/org/ayatana/NotificationItem/app", ":1.7");
    (bus, path) = split_item_key(k);
    assert bus == ":1.7";
    assert path == "/org/ayatana/NotificationItem/app";
}


# --- Tray: raw IconPixmap decode (ARGB->RGBA, pick largest, reject garbage) --
# When an item ships no themed IconName we fall back to its raw pixmap array.
# The decode is pure byte work behind the seam; only the final Gdk.Texture needs
# GDK (imports headless). We assert the reject branches + that the largest frame
# wins (its width survives onto the texture).
test "_pixmap_to_texture rejects empty and degenerate pixmaps" {
    assert _pixmap_to_texture([]) is None;
    assert _pixmap_to_texture(None) is None;
    assert _pixmap_to_texture([[0, 0, bytes(0)]]) is None;        # zero dims
    assert _pixmap_to_texture([[2, 2, bytes(4)]]) is None;        # buffer too short for w*h*4
}

test "_pixmap_to_texture decodes a valid frame and picks the largest by area" {
    small = [1, 1, bytes([255, 10, 20, 30])];                     # 1x1
    big = [2, 2, bytes(2 * 2 * 4)];                               # 2x2, all zero
    t = _pixmap_to_texture([small]);
    assert t is not None;
    assert t.get_width() == 1;
    # given both, the 2x2 (larger area) is chosen -> texture is 2 wide
    chosen = _pixmap_to_texture([small, big]);
    assert chosen.get_width() == 2;
    assert chosen.get_height() == 2;
}


# --- Workspace parsers: field defaults + negative-num sorting ---------------
test "parse_workspaces defaults missing fields, key mirrors id" {
    ws = parse_workspaces("[{\"id\": 3}]");
    assert ws[0]["id"] == 3;
    assert ws[0]["key"] == 3;
    assert ws[0]["name"] == "";
    assert ws[0]["active"] == False;
    assert ws[0]["windows"] == 0;
}

# --- Tray: dbusmenu (com.canonical.dbusmenu) layout parsing -----------------
# GetLayout replies (revision, root) where each node is (id, a{sv}, av-children);
# unpacked that's a recursive (id, props, [children]) tuple. parse_menu_layout
# turns one node into the plain dict tree the popover is built from.
def sample_menu_root() -> any {
    # A representative root (id 0) with: a normal enabled entry (mnemonic label),
    # a separator, a submenu with one deep child, a hidden entry, and a checkmark.
    return (0, {}, [
        (1, {"label": "_File", "enabled": True, "visible": True}, []),
        (2, {"type": "separator"}, []),
        (3, {"label": "Sub", "children-display": "submenu"}, [
            (4, {"label": "Deep"}, []),
        ]),
        (5, {"label": "Hidden", "visible": False}, []),
        (6, {"label": "Check", "toggle-type": "checkmark", "toggle-state": 1}, []),
    ]);
}

test "parse_menu_layout builds a dict tree with ids, labels, nested children" {
    m = parse_menu_layout(sample_menu_root());
    assert m["id"] == 0;
    assert m["separator"] == False;
    kids = m["children"];
    assert len(kids) == 5;
    assert kids[0]["id"] == 1;
    assert kids[0]["label"] == "File";              # mnemonic '_' stripped
    assert kids[0]["enabled"] == True;
    assert kids[0]["visible"] == True;
    assert kids[0]["children"] == [];
}

test "parse_menu_layout marks separators and recurses into submenus" {
    kids = parse_menu_layout(sample_menu_root())["children"];
    assert kids[1]["separator"] == True;            # type == "separator"
    assert kids[1]["type"] == "separator";
    assert kids[2]["label"] == "Sub";
    assert len(kids[2]["children"]) == 1;
    assert kids[2]["children"][0]["id"] == 4;
    assert kids[2]["children"][0]["label"] == "Deep";
}

test "parse_menu_layout carries visible/enabled/toggle flags with spec defaults" {
    kids = parse_menu_layout(sample_menu_root())["children"];
    assert kids[3]["visible"] == False;             # explicit visible=false
    assert kids[4]["toggle_type"] == "checkmark";
    assert kids[4]["toggle_state"] == 1;
    # defaults: an entry with no props is enabled+visible, standard, untoggled
    d = parse_menu_layout((9, {}, []));
    assert d["enabled"] == True;
    assert d["visible"] == True;
    assert d["type"] == "standard";
    assert d["separator"] == False;
    assert d["toggle_state"] == -1;                 # -1 == no toggle state
    assert d["label"] == "";
}

test "clean_label strips single mnemonic underscores, keeps doubled literals" {
    assert clean_label("_File") == "File";
    assert clean_label("Save _As") == "Save As";
    assert clean_label("a__b") == "a_b";            # '__' -> literal '_'
    assert clean_label("plain") == "plain";
    assert clean_label("") == "";
}


test "parse_sway_workspaces sorts named(-1) first, keeps container id as key" {
    j = "[{\"id\": 40, \"num\": 2, \"name\": \"2\", \"output\": \"DP-1\", \"focused\": false},"
        + "{\"id\": 41, \"num\": -1, \"name\": \"scratch\", \"output\": \"DP-1\", \"focused\": true}]";
    ws = parse_sway_workspaces(j);
    assert ws[0]["id"] == -1;                              # -1 sorts before 2
    assert ws[0]["key"] == 41;                             # container id preserved
    assert ws[0]["active"] == True;
}
