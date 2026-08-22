# REFERENCE — stylesheet for the full reference bar (LIBRARY.md §1).
#
# style.jac — the shell's default stylesheet (GTK4 CSS), as a Jac string const.
# Kept out of main so authors can tweak the look in one obvious place.
glob CSS: str = """
.bar {
    background: rgba(20, 22, 30, 0.92);
    color: #e6e6e6;
    font-family: 'Iosevka', monospace;
    font-size: 14px;
}
.bar-inner {
    min-height: 30px;
    padding: 2px 10px;
}
.clock { font-weight: bold; }
.battery, .volume, .clock, .media, .notifications, .bluetooth { padding: 2px 10px; }
.bluetooth { color: #8ab4f8; }
.media { background: transparent; border: none; box-shadow: none; color: #b8c0d0; }
.media:hover { background: rgba(255, 255, 255, 0.08); }
.notifications { color: #ffd27f; }
.launcher-toggle { background: transparent; border: none; box-shadow: none; padding: 2px 12px; color: #b8c0d0; font-size: 16px; }
.launcher-toggle:hover { background: rgba(255, 255, 255, 0.08); }
.mode-toggles { padding: 0 2px; }
.mode-toggle {
    background: transparent;
    border: none;
    box-shadow: none;
    padding: 2px 8px;
    color: #8a90a0;
    font-size: 15px;
}
.mode-toggle:hover { background: rgba(255, 255, 255, 0.08); color: #c8ccd4; }
.mode-toggle.active { color: #a8c8ff; background: rgba(120, 160, 255, 0.22); }

/* Launcher popup */
.launcher-box {
    background: rgba(24, 26, 34, 0.98);
    border: 1px solid rgba(120, 160, 255, 0.35);
    border-radius: 10px;
    padding: 12px;
    min-width: 480px;
}
.launcher-entry {
    font-size: 16px;
    padding: 8px 10px;
    margin-bottom: 8px;
    background: rgba(255, 255, 255, 0.06);
    color: #e6e6e6;
    border-radius: 6px;
}
.launcher-list { }
.launcher-item {
    background: transparent;
    border: none;
    box-shadow: none;
    color: #d6dae4;
    padding: 7px 10px;
    margin: 1px 0;
}
.launcher-item:hover { background: rgba(120, 160, 255, 0.22); }

/* Notification popups */
.notif-list { }
.notif {
    background: rgba(24, 26, 34, 0.98);
    border: 1px solid rgba(120, 160, 255, 0.30);
    border-radius: 10px;
    padding: 10px 12px;
    margin: 6px;
    min-width: 320px;
}
.notif.urgency-2 { border-color: rgba(255, 90, 90, 0.7); }
.notif-head { }
.notif-app { color: #8aa0c0; font-size: 12px; }
.notif-close { background: transparent; border: none; box-shadow: none; color: #8a8f99; padding: 0 4px; }
.notif-close:hover { color: #ffffff; }
.notif-summary { color: #ffffff; font-weight: bold; }
.notif-body { color: #c8ccd4; }
.volume { background: transparent; border: none; box-shadow: none; }
.volume:hover { background: rgba(255, 255, 255, 0.08); }
.volume-overlay {
    background: #2a2d38;
    border: 1px solid #3d4250;
    border-radius: 8px;
    padding: 10px 12px;
    min-width: 200px;
}
.volume-overlay-title { color: #e8eaed; padding-bottom: 6px; }
.volume-slider { min-height: 24px; }
/* System tray (StatusNotifierItem) */
.tray { padding: 0 4px; }
.tray-item {
    background: transparent;
    border: none;
    box-shadow: none;
    padding: 2px 4px;
    margin: 0 1px;
    min-width: 0;
}
.tray-item:hover { background: rgba(255, 255, 255, 0.08); }
.tray-label {
    min-width: 18px;
    text-align: center;
    font-size: 13px;
    color: #c8ccd4;
}
.workspaces button.ws {
    background: transparent;
    border: none;
    box-shadow: none;
    padding: 2px 10px;
    margin: 0 1px;
    color: #9aa0aa;
}
.workspaces button.ws.active {
    color: #ffffff;
    background: rgba(120, 160, 255, 0.25);
}
.workspaces button.ws:hover { background: rgba(255, 255, 255, 0.08); }

/* --- lockscreen -----------------------------------------------------------
   Fullscreen overlay: dimmed backdrop, centered clock panel, masked entry.
   The window itself is transparent; .lock-root paints the dim. */
.lock-root {
    background: rgba(10, 12, 16, 0.82);
}
.lock-layer {
    background: transparent;
}
.lock-panel {
    margin-top: 22vh;
    spacing: 8px;
    align-items: center;
}
.lock-clock {
    font-size: 84px;
    font-weight: 300;
    color: #f2f4f8;
}
.lock-date {
    font-size: 20px;
    font-weight: 400;
    color: #aab2c0;
}
.lock-hint {
    min-height: 24px;
    margin-top: 10px;
    font-size: 14px;
    color: #e0a0a0;
}
.state-checking .lock-hint { color: #9ab0d8; }
.lock-entry {
    margin-top: 18px;
    font-size: 18px;
    padding: 8px 14px;
    border-radius: 10px;
    background: rgba(255, 255, 255, 0.08);
    color: #f2f4f8;
}
.lock-entry:focus {
    background: rgba(255, 255, 255, 0.13);
}

""";
