# phaseb_policy_tests.jac — PLAN §6 graph-native policy guarantees (Change 5).
# ---------------------------------------------------------------------------
# Proves the load-bearing properties of the typed route graph:
#   §6 non-bypass   a binding reads the RouteNode, NEVER the source — so a
#                   suppressed route cannot be re-added by dynamic-dep tracking
#   graph shape     BasePolicy -Requests-> RoutePolicy -Activates-> RouteNode
#                   -Feeds-> BindingNode; ModeNode -Suppresses-> RoutePolicy
#   feed gating     suppression removes source->RouteNode Feeds; exit restores
#   reconcile       ReconcileTopology mounts/disposes ONLY the changed surface
import from src.desktop { create_desktop, bootstrap_reference_outputs }
import from src.policy {
    enter_mode, exit_mode, inject_notification, policy_state,
    ROUTE_NOTIF_POPUP, ROUTE_NOTIF_HISTORY
}
import from src.runtime_graph {
    session_store, session_policies, session_modes,
    Requests, Activates, Suppresses, Feeds, RoutePolicy
}
import from src.topology_reactive { feed_sources }


# --- §6 non-bypass: the binding has a Feeds edge to the RouteNode, not source --
test "route gate isolates the binding from the source" {
    s = create_desktop("reference");
    bootstrap_reference_outputs(s);
    ps = policy_state();

    # structural proof: the popup binding is fed by the route, NOT the source
    assert ps.popup_route in feed_sources(ps.popup_binding);
    assert ps.notif_source not in feed_sources(ps.popup_binding);

    # suppressing the route must keep the binding from running
    before = ps.popup_runs;
    enter_mode(s, "presentation");
    inject_notification();
    assert ps.popup_runs == before;                    # zero popup executions

    # history route is unsuppressed -> still receives the notification
    assert ps.history_count >= 1;

    # after churn, the binding STILL has no direct edge to the source
    exit_mode(s, "presentation");
    assert ps.notif_source not in feed_sources(ps.popup_binding);
    assert ps.popup_route in feed_sources(ps.popup_binding);
}


# --- graph shape: typed policy relationships are all present -----------------
test "policy graph shape routes through typed edges" {
    s = create_desktop("reference");
    bootstrap_reference_outputs(s);

    bps = session_policies(s);
    assert len(bps) == 1;
    bp = bps[0];

    rps = [bp ->:Requests:->][?:RoutePolicy];
    names = sorted([rp.route_name for rp in rps]);
    assert names == sorted([ROUTE_NOTIF_HISTORY, ROUTE_NOTIF_POPUP]);

    # each RoutePolicy Activates exactly one RouteNode
    for rp in rps {
        rns = [rp ->:Activates:->];
        assert len(rns) == 1;
    }

    # the popup RouteNode Feeds the popup binding (data path)
    ps = policy_state();
    popup_targets = [ps.popup_route ->:Feeds:->];
    assert ps.popup_binding in popup_targets;
}


# --- feed gating: suppress removes source->RouteNode; exit restores it --------
test "suppression removes and restores the source to route feed" {
    s = create_desktop("reference");
    bootstrap_reference_outputs(s);
    ps = policy_state();

    assert ps.notif_source in feed_sources(ps.popup_route);     # active by default

    enter_mode(s, "presentation");
    assert ps.notif_source not in feed_sources(ps.popup_route); # edge dropped
    # the ModeNode Suppresses the popup RoutePolicy
    modes = session_modes(s);
    assert len(modes) == 1;
    suppressed = [modes[0] ->:Suppresses:->];
    assert len(suppressed) == 1;
    assert suppressed[0].route_name == ROUTE_NOTIF_POPUP;

    exit_mode(s, "presentation");
    assert ps.notif_source in feed_sources(ps.popup_route);     # edge restored
}


# --- reconcile mounts/disposes ONLY the changed surface ----------------------
test "reconcile touches only the changed output surface" {
    s = create_desktop("reference");
    bootstrap_reference_outputs(s);
    store = session_store();
    baseline = len(store.adapter_ops);

    enter_mode(s, "presentation");
    # only string traces come from policy; mock ops (lists) are filtered out
    ops = [o for o in store.adapter_ops[baseline:] if isinstance(o, str)];
    mounts = [o for o in ops if o.startswith("surface_mount:")];
    disposes = [o for o in ops if o.startswith("surface_dispose:")];

    # presentation only swaps the projector (HDMI-A-1) to minimal-bar;
    # the laptop output (eDP-1) records zero surface mount/dispose ops
    assert len(mounts) == 1 and "HDMI-A-1" in mounts[0];
    assert len(disposes) == 1 and "HDMI-A-1" in disposes[0];
    assert not any("eDP-1" in o for o in mounts);
    assert not any("eDP-1" in o for o in disposes);
}
