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
# Widget inits (Box, Label, …), For, Show, @component: jacket/builders.jac
# GTK projection + popovers: jacket/mount.jac (mount_tree)
# Graph walkers (query, dispose): jacket/osp.jac
import from jacket.builders {
    component, Box, Label, Button, Icon, Entry, Slider, Window,
    For, Show, row_item, dispose_tree,
}
import from jacket.animation {
    animated, follow, enter_tween, ease, advance_animations,
}
import from jacket.transition { popup_transition }
import from jacket.mount { mount_tree }
import from jacket.osp { ViewNode, Child, Anchored, Dispose, register_edge_realizer }
