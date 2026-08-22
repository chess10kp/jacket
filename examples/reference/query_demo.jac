# REFERENCE — walker payoff demo (LIBRARY.md §3.3, §1).
#
# query_demo.jac — the §8a payoff, shown from the AUTHOR's chair.
# ---------------------------------------------------------------------------
# A component builds its subtree ONCE and hands back the root ViewNode. Because
# that root is a real, walkable OSP graph (ViewNode + typed Child edges), the
# author can spawn cross-cutting walkers over their OWN UI — query-by-class and
# flash-all-X restyle — with the same idiom the framework uses internally. No
# re-render, no parallel tree, no reaching into GTK.
import from jacket.builders { component, Box, Label, Button }
import from jacket.osp { ViewNode, query_by_class, flash_class, unflash_class }


# A tiny toolbar. Note the shared `action` class across the two buttons — that
# is the cross-cutting handle the walkers will grab.
@component
def Toolbar() -> any {
    return Box(class="toolbar", orientation="H", children=[
        Button(class="btn action", label="Save"),
        Button(class="btn action", label="Open"),
        Label(class="hint", text="ready"),
    ]);
}


# demo() plays the author role: it HOLDS the returned ViewNode and spawns
# walkers over it. Returns the held root so a caller (or a REPL) can keep poking.
def demo() -> ViewNode {
    ui = Toolbar();                       # <- a live ViewNode graph I OWN

    # QUERY my own tree: every node tagged `.action`.
    actions = query_by_class(ui, "action");   # -> the two Buttons

    # FLASH-ALL-X: paint `flash` onto every `.action` in one traversal.
    flash_class(ui, "action", "flash");
    # ... later, clear it just as cheaply:
    unflash_class(ui, "action", "flash");

    return ui;
}
