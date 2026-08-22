# Minimal shell bootstrap — copy-paste starting point from LIBRARY.md §2.
# A single top bar with a static clock label; no sources, no multi-monitor logic.
import from jacket.adapter { install, run_dynamic, apply_css }
import from jacket.glib { idle_add }
import from jacket.reactive { set_flush_hook }
import from jacket.builders { component, Window, Box, Label }
import from jacket.osp { ViewNode }

glob MY_CSS: str = """
window { background: #1e1e2e; }
.clock { color: #e6e6e6; font-family: monospace; padding: 4px 12px; }
""";

@component
def MyBar() -> ViewNode {
    return Window(
        layer="top",
        anchor="top",
        height=32,
        child=Box(orientation="H", children=[
            Label(class="clock", text="hello"),
        ]),
    );
}

def on_activate(app: any) {
    bar = MyBar();
    bar.widget.present();
}

with entry {
    install();
    apply_css(MY_CSS);
    set_flush_hook(lambda (f: any) { idle_add(f); });
    run_dynamic(on_activate, "org.example.my-shell");
}
