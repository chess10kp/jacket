# wl_adapter_tests.jac — headless probes for the raw-Wayland backend
# (WAYLAND_BACKEND.md W1/W2). No display connection: we exercise the CSS-subset
# parser, the adapter contract against the WlWidget tree, the flexbox-lite
# layout pass, and an OFFSCREEN cairo render — the same code paths the live
# surface runs, minus the wl_shm commit.
import from src.adapter_api { set_adapter, adapter }
import from src.wl_adapter {
    WlAdapter, wl_construct, wl_is_construct_only,
    parse_css, _color, paint_tree, offscreen_surface, offscreen_context,
    wl_apply_css, wl_inject_button, wl_inject_motion, wl_inject_scroll,
    wl_inject_key, wl_grab_focus, hit_test,
}


glob _BG: tuple = (30.0/255.0, 30.0/255.0, 46.0/255.0, 1.0);

::py::
def _pixel_at(data, stride, x, y):
    off = y * stride + x * 4
    return (data[off + 2], data[off + 1], data[off])


def _pixel_near(data, stride, x, y, want, tol=1):
    px = _pixel_at(data, stride, x, y)
    return all(abs(a - b) <= tol for a, b in zip(px, want))


def _row_varies(data, stride, y, x0, x1):
    return any(_pixel_at(data, stride, x, y) != _pixel_at(data, stride, x + 1, y)
               for x in range(x0, x1))
::py::


test "construct-only table mirrors the GTK adapter" {
    assert wl_is_construct_only("Box", "orientation") == True;
    assert wl_is_construct_only("Slider", "step") == True;
    assert wl_is_construct_only("Window", "anchor") == False;
    assert wl_is_construct_only("Label", "text") == False;
}

test "unknown tag raises like the GTK adapter" {
    threw = False;
    try {
        wl_construct("Gauge", {});
    } except Exception { threw = True; }
    assert threw;
}

test "css subset parses colors, shorthand padding, later-rule-wins" {
    rules = parse_css("""
        /* comment { fake } */
        window { background: #1e1e2e; }
        .clock { color: #e6e6e6; padding: 4px 12px; font-family: monospace;
                 font-size: 15px; min-width: 40px; border-radius: 6px; }
        .clock:hover { color: #ffffff; }
    """);
    assert len(rules) == 3;
    win_sel = rules[0][0];
    win_hover: bool = rules[0][1];
    win_props = rules[0][2];
    clock_sel = rules[1][0];
    clk = rules[1][2];
    hov_hover: bool = rules[2][1];
    hov_props = rules[2][2];
    assert win_sel == "window" and win_hover == False;
    assert clock_sel == ".clock";
    assert hov_hover == True;
    assert _color(win_props["background"]) == (30/255, 30/255, 46/255, 1.0);
    assert _color(clk["color"]) == (230/255, 230/255, 230/255, 1.0);
    # shorthand '4px 12px' -> top/bottom 4, left/right 12
    assert clk["pad_t"] == 4 and clk["pad_r"] == 12;
    assert clk["pad_b"] == 4 and clk["pad_l"] == 12;
    assert clk["font_family"] == "monospace";
    assert clk["font_size"] == "15px";
    assert clk["min_width"] == "40px";
    assert clk["border_radius"] == "6px";
    assert hov_props["color"] == "#ffffff";
}

test "contract builds a tree; insert/move/child_at hold order" {
    set_adapter(WlAdapter());
    a = adapter();
    bar = a.construct("Box", {"orientation": "H"});
    k1 = a.construct("Label", {});
    k2 = a.construct("Label", {});
    k3 = a.construct("Button", {});
    a.insert(bar, k3, 0);
    a.insert(bar, k1, 1);
    a.insert(bar, k2, 2);
    assert a.child_at(bar, 0) is k3;
    assert a.child_at(bar, 1) is k1;
    assert a.child_at(bar, 2) is k2;
    assert a.child_at(bar, 3) is None;
    a.move(bar, k3, 2);                      # tail
    assert a.child_at(bar, 2) is k3;
    a.remove(k1);
    assert a.child_at(bar, 0) is k2 and a.child_at(bar, 1) is k3;
}

test "set_prop records text/class/hidden on the handle" {
    set_adapter(WlAdapter());
    a = adapter();
    lbl = a.construct("Label", {});
    a.set_prop(lbl, "text", "88:88");
    a.set_prop(lbl, "class", "clock");
    a.set_prop(lbl, "hidden", False);
    assert lbl.props["text"] == "88:88";
    assert lbl.classes == "clock";
    assert lbl.visible();

    hid = a.connect(lbl, "on_click", lambda {});
    assert hid > 0;
    assert lbl.handlers["on_click"][0][0] == hid;
    a.disconnect(lbl, hid);
    assert lbl.handlers["on_click"] == [];
}

test "layout pass assigns sane rects to a bar subtree" {
    set_adapter(WlAdapter());
    a = adapter();
    bar = a.construct("Window", {"height": 32});
    box = a.construct("Box", {"orientation": "H"});
    clock = a.construct("Label", {"class": "clock", "text": "hello"});
    spacer = a.construct("Box", {"orientation": "H", "expand": True});
    right = a.construct("Label", {"text": "[x]"});
    a.insert(box, clock, 0);
    a.insert(box, spacer, 1);
    a.insert(box, right, 2);
    a.insert(bar, box, 0);

    surf = offscreen_surface(400, 32);
    cr = offscreen_context(surf);
    paint_tree(cr, bar, 400, 32);

    rw = bar.rect[2];
    rh = bar.rect[3];
    assert rw == 400 and rh == 32;
    bw = box.rect[2];
    bh = box.rect[3];
    assert bw == 400 and bh == 32;
    cw: int = clock.rect[2];
    chh: int = clock.rect[3];
    assert cw > 0 and chh == 32;              # fills cross axis
    sw: int = spacer.rect[2];
    assert sw > cw;                           # expand child takes the free width
    pw_: int = right.rect[2];
    px_: int = right.rect[0];
    assert pw_ > 0 and px_ + pw_ <= 400;      # right label stays inside the bar
}

test "offscreen render paints window bg and label pixels" {
    # Same subset as examples/minimal: window bg + .clock text styling.
    wl_apply_css("window { background: #1e1e2e; }\n"
                 ".clock { color: #e6e6e6; font-family: monospace; font-size: 15px; }");
    set_adapter(WlAdapter());
    a = adapter();
    bar = a.construct("Window", {"height": 32});
    box = a.construct("Box", {"orientation": "H"});
    clock = a.construct("Label", {"class": "clock", "text": "hello"});
    a.insert(box, clock, 0);
    a.insert(bar, box, 0);

    surf = offscreen_surface(200, 32);
    cr = offscreen_context(surf);
    paint_tree(cr, bar, 200, 32);

    data = bytes(surf.get_data());
    stride = surf.get_stride();
    # window bg #1e1e2e -> (30, 30, 46)
    assert _pixel_near(data, stride, 150, 16, (30, 30, 46));
    # some pixel inside the label run differs from bare background (glyph AA)
    assert _row_varies(data, stride, 16, 10, 60);
}

# ===========================================================================
# W4 — input: synthetic pointer/keyboard events through the dispatch core.
# Same code path the live wl_pointer/wl_keyboard handlers run; no display.
# ===========================================================================

glob _W4_CSS: str = """
    window { background: #1e1e2e; }
    .btn { background: #333344; padding: 4px 8px; }
    .btn:hover { background: #555577; }
""";

def _w4_tree() -> any {
    set_adapter(WlAdapter());
    a = adapter();
    bar = a.construct("Window", {"height": 32});
    box = a.construct("Box", {"orientation": "H"});
    btn = a.construct("Button", {"class": "btn", "label": "hi"});
    spacer = a.construct("Box", {"orientation": "H", "expand": True});
    a.insert(box, btn, 0);
    a.insert(box, spacer, 1);
    a.insert(bar, box, 0);

    wl_apply_css(_W4_CSS);
    surf = offscreen_surface(200, 32);
    paint_tree(offscreen_context(surf), bar, 200, 32);
    return bar;
}

test "hit_test finds deepest visible node; misses outside rects" {
    bar = _w4_tree();
    hit = hit_test(bar, 10, 16);          # left edge where the button sits
    assert hit is not None and hit.tag == "Button";
    miss = hit_test(bar, -1, 16);
    assert miss is None;
}

test "click press+release inside fires on_click; release outside does not" {
    bar = _w4_tree();
    clicks: list = [];
    hid = adapter().connect(hit_test(bar, 10, 16), "on_click", lambda { clicks.append(1); });
    wl_inject_button(bar, 10, 16, 0x110, True);
    wl_inject_button(bar, 10, 16, 0x110, False);
    assert len(clicks) == 1;
    # drag off the widget before release: GTK semantics say no click
    wl_inject_button(bar, 10, 16, 0x110, True);
    wl_inject_button(bar, 150, 16, 0x110, False);
    assert len(clicks) == 1;
}

test "hover tracks motion and :hover style overrides resolve" {
    bar = _w4_tree();
    btn: any = hit_test(bar, 10, 16);
    assert btn.hovered == False;
    base_bg = btn.style.get("background");
    wl_inject_motion(bar, 10, 16);
    assert btn.hovered == True;
    hov_bg = btn.style.get("background");
    assert hov_bg == "#555577" and base_bg == "#333344";
    wl_inject_motion(bar, 150, 16);
    assert btn.hovered == False;
    assert btn.style.get("background") == "#333344";
}

test "entry text edits fire on_change; Return fires on_activate; Esc stop-search" {
    set_adapter(WlAdapter());
    a = adapter();
    bar = a.construct("Window", {"height": 48, "keyboard": "exclusive"});
    entry = a.construct("Entry", {"placeholder": "search"});
    a.insert(bar, entry, 0);

    changes: list = [];
    acts: list = [];
    stops: list = [];
    a.connect(entry, "on_change", lambda { changes.append(entry.get_text()); });
    a.connect(entry, "on_activate", lambda { acts.append(1); });
    a.connect(entry, "on_stop_search", lambda { stops.append(1); });

    assert wl_grab_focus(entry) == True;   # launcher's explicit focus path
    for ch in "abc" {
        wl_inject_key(bar, ch);
    }
    assert entry.get_text() == "abc";
    wl_inject_key(bar, "BackSpace");
    assert entry.get_text() == "ab";
    assert len(changes) == 4;               # a, b, c, backspace
    wl_inject_key(bar, "Return");
    wl_inject_key(bar, "Escape");
    assert len(acts) == 1 and len(stops) == 1;

    # click elsewhere unfocuses: keys go nowhere
    other = a.construct("Label", {});
    a.insert(bar, other, 1);
    paint_tree(offscreen_context(offscreen_surface(200, 48)), bar, 200, 48);
    wl_inject_button(bar, 190, 40, 0x110, True);
    assert bar.focused is None;
}

test "slider scroll steps value and fires on_value_change with get_value" {
    set_adapter(WlAdapter());
    a = adapter();
    bar = a.construct("Window", {"height": 32});
    row = a.construct("Box", {"orientation": "H"});
    slider = a.construct("Slider", {"min": 0, "max": 100, "step": 5});
    spacer = a.construct("Box", {"orientation": "H", "expand": True});
    a.insert(row, slider, 0);
    a.insert(row, spacer, 1);
    a.insert(bar, row, 0);

    vals: list = [];
    a.connect(slider, "on_value_change",
              lambda (w: any) { vals.append(w.get_value()); });

    paint_tree(offscreen_context(offscreen_surface(200, 32)), bar, 200, 32);
    sx = slider.rect[0];
    sy = slider.rect[1] + slider.rect[3] / 2;
    wl_inject_scroll(bar, sx + 5, sy, 2);       # scroll down x2
    # scrolling DOWN from min must not fire (value unchanged, equality cutoff)
    assert len(vals) == 0;
    wl_inject_scroll(bar, sx + 5, sy, -1);      # scroll up: +step
    assert len(vals) == 1 and vals[0] == 5.0;
    assert float(slider.props["value"]) == 5.0;

    # drag to the right half of the slider rect
    wl_inject_button(bar, sx + 5, sy, 0x110, True);
    mid = slider.rect[0] + slider.rect[2] / 2;
    wl_inject_motion(bar, mid, sy);
    wl_inject_button(bar, mid, sy, 0x110, False);
    got = vals[-1];
    assert got > 45 and got < 55;               # ~50%, snapped to step of 5
}
