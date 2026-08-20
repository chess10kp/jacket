# authoring.jac — LIBRARY: OSP-native UI authoring surface.
# ---------------------------------------------------------------------------
# Init widget nodes, chain typed edges, mount once at the composition root.
#
#   win = Window(class="bar", anchor="top");
#   inner = Box(class="bar-inner", orientation="H");
#   win +>:Child(order=0):+> inner;
#   inner +>:Child(order=0):+> LauncherButton();
#   vol = VolumeButton();
#   vol +>:Anchored(mode="hover", position="bottom"):+> VolumePanel();
#   inner +>:Child(order=1):+> vol;
#   return win;                    # @component calls mount_tree(win)
#
# Widget inits (Box, Label, …), For, Show, @component: src/builders.jac
# GTK projection + popovers: src/mount.jac (mount_tree)
# Graph walkers (query, dispose): src/osp.jac
import from src.builders {
    component, Box, Label, Button, Icon, Entry, Slider, Window,
    For, Show, row_item, dispose_tree,
}
import from src.animation {
    animated, follow, enter_tween, ease, advance_animations,
}
import from src.transition { popup_transition }
import from src.mount { mount_tree }
import from src.osp { ViewNode, Child, Anchored, Dispose, register_edge_realizer }
