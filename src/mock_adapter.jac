# mock_adapter.jac — a recording adapter for headless reconciler tests (Phase 2).
# ---------------------------------------------------------------------------
# Implements the SAME contract as the real GTK adapter (adapter.jac, Phase 3):
#   construct / is_construct_only / set_prop / insert / remove / move / connect / disconnect
# but records every op into `ops` and models children as ordered lists, so the
# For keyed-diff can be asserted by OP STREAM (append/prepend/insert/remove/
# reverse each in 0-1 moves) with zero GTK dependency.
import from src.adapter_api { set_adapter }


# a readable widget handle for the op log
obj MHandle {
    has tag: str;
    has id: int;
    has text: str = "";   # last "text"/"label" set, for asserting row order
}

glob _mhid: int = 0;


obj MockAdapter {
    has ops: list = [];                 # full op log: [kind, ...]
    has kids: dict = {};                # parent_id -> list[child MHandle] (ordered)

    def construct(tag: str, cprops: dict) -> any {
        h = MHandle(tag=tag, id=_mhid);
        _mhid += 1;
        self.ops.append(["construct", tag, h.id]);
        self.kids[h.id] = [];
        return h;
    }

    def is_construct_only(tag: str, prop: str) -> bool { return False; }

    def set_prop(h: any, name: str, value: any) {
        if name == "text" or name == "label" { h.text = str(value); }
        self.ops.append(["set_prop", h.id, name]);
    }

    def insert(parent: any, child: any, pos: int) {
        lst = self.kids[parent.id];
        lst.insert(pos, child);
        self.ops.append(["insert", child.id, pos]);
    }

    # unparent from wherever it currently lives (one-parent rule).
    def remove(child: any) {
        for (pid, lst) in self.kids.items() {
            if child in lst { lst.remove(child); }
        }
        self.ops.append(["remove", child.id]);
    }

    def move(parent: any, child: any, pos: int) {
        lst = self.kids[parent.id];
        if child in lst { lst.remove(child); }
        lst.insert(pos, child);
        self.ops.append(["move", child.id, pos]);
    }

    def child_at(parent: any, i: int) -> any {
        lst: list[any] = self.kids[parent.id];
        if i < len(lst) { return lst[i]; }
        return None;
    }

    def connect(h: any, signal: str, handler: any) -> int {
        self.ops.append(["connect", h.id, signal]);
        return len(self.ops);
    }

    def disconnect(h: any, hid: int) {
        self.ops.append(["disconnect", h.id, hid]);
    }

    def grab_focus(h: any) -> bool {
        self.ops.append(["grab_focus", h.id]);
        return True;
    }

    def attach_hover_popover(anchor: any, content: any, position: str,
                             show_delay_ms: int, hide_delay_ms: int) -> any {
        return None;    # headless: no popovers to attach
    }

    def attach_click_popover(anchor: any, content: any, position: str) -> any {
        return None;
    }

    # the ordered child tags under a parent handle — for asserting final layout
    def child_tags(parent: any) -> list {
        lst: list[any] = self.kids[parent.id];
        return [c.tag for c in lst];
    }

    # ordered row "text" values under a parent — for asserting For row order
    def child_texts(parent: any) -> list {
        lst: list[any] = self.kids[parent.id];
        return [c.text for c in lst];
    }

    # op kinds in order, ignoring ids/values (for compact diff assertions)
    def op_kinds() -> list {
        return [op[0] for op in self.ops];
    }
}


def install_mock() -> MockAdapter {
    m = MockAdapter();
    set_adapter(m);
    return m;
}

def count_kind(ops: list, kind: str) -> int {
    n = 0;
    for op in ops { if op[0] == kind { n += 1; } }
    return n;
}

def delta_ops(ops: list, start: int) -> list {
    return ops[start:];
}
