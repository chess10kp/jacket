# adapter_tests.jac — the ONE piece of adapter policy that is pure, not a GTK
# call: the construct-only classification (CONSTRUCT_ONLY + is_construct_only).
# builders route these props into the constructor's cprops instead of a post-
# construct set_prop; getting the table wrong silently drops props on GTK (a
# construct-only prop set after construction is ignored). The mock adapter
# hard-codes is_construct_only()->False (builders_tests.jac note, line ~214), so
# this behavior has no coverage there — it does here.
#
# Importing adapter.jac only pulls the gi *module* import (no Gtk.init / no
# display), so the pure classifier runs headless like any other seam parser.
import from src.adapter { is_construct_only }


test "construct-only props are recognized per tag" {
    # Box orientation, Window type, Slider geometry: all resolved at construction.
    assert is_construct_only("Box", "orientation") == True;
    assert is_construct_only("Window", "type") == True;
    assert is_construct_only("Slider", "orientation") == True;
    assert is_construct_only("Slider", "min") == True;
    assert is_construct_only("Slider", "max") == True;
    assert is_construct_only("Slider", "step") == True;
}

test "a known tag's non-construct props are patchable (False)" {
    # These are live, post-construct set_props — NOT in the table.
    assert is_construct_only("Box", "class") == False;
    assert is_construct_only("Slider", "value") == False;
    assert is_construct_only("Window", "anchor") == False;
}

test "a tag with no construct-only props returns False for everything" {
    # Label/Button/Icon/Entry have no table entry -> lookup is None -> False.
    assert is_construct_only("Label", "text") == False;
    assert is_construct_only("Button", "label") == False;
    assert is_construct_only("Entry", "placeholder") == False;
    # even a name that IS construct-only on another tag is False here:
    assert is_construct_only("Label", "orientation") == False;
}

test "an unknown tag never claims construct-only" {
    assert is_construct_only("Nope", "orientation") == False;
    assert is_construct_only("", "") == False;
}
