# runtime_graph.jac — session/topology node and edge archetypes (PLAN §1, §7).
# ---------------------------------------------------------------------------
# OSP graph for desktop runtime state: sessions, outputs, surfaces, reactive
# nodes, and policy. Process-local closures live in SessionStore, not on nodes.
#
import from jacket.osp { ViewNode }
#
# PLAN §1 fixes landed here:
#  - shared RuntimeBase gives every runtime node a session identity (session_id)
#  - the overloaded Contains edge is split into correctly typed relationships
#       session -> output / policy / mode / source / binding
#       output  -> surface
#       surface -> view (Renders)
#       owner   -> reactive computation (Owns)
#  - runtime IDs are MONOTONIC (never reset) so cross-session keys cannot collide
#  - CollectSession walker reaches the whole runtime subgraph for disposal


# ---------------------------------------------------------------------------
# Runtime base — shared session identity for every graph-persistent runtime node.
# ---------------------------------------------------------------------------
node RuntimeBase {
    has session_id: str = "";
}

glob _rid_seq: int = 0;

def next_runtime_id(prefix: str) -> str {
    _rid_seq += 1;                          # monotonic: never reset (PLAN §1)
    return prefix + "-" + str(_rid_seq);
}


# ---------------------------------------------------------------------------
# Session / topology families
# ---------------------------------------------------------------------------
node DesktopSession(RuntimeBase) {
    has runtime_id: str = "";
    has label: str = "";
}

node OutputNode(RuntimeBase) {
    has runtime_id: str = "";
    has connector: str = "";
    has role: str = "unknown";
}

node SurfaceNode(RuntimeBase) {
    has runtime_id: str = "";
    has kind: str = "";
    has connector: str = "";
}

node RegionNode(RuntimeBase) {
    has runtime_id: str = "";
    has name: str = "";
}

# ---------------------------------------------------------------------------
# Reactive families — values live on nodes; closures live in SessionStore.
# ---------------------------------------------------------------------------
node ReactiveNode(RuntimeBase) {
    has runtime_id: str = "";
}

node SourceNode(ReactiveNode) {
    has value: object = None;
}

node DerivedNode(ReactiveNode) {
    has cached: object = None;
    has state: int = 0;          # CLEAN=0 CHECK=1 DIRTY=2
}

node BindingNode(ReactiveNode) {
    has enabled: bool = True;
    has runs: int = 0;
}

# RouteNode — reactive GATE between a route policy and bindings (PLAN §6).
# Mirrors its source's value only while active. Suppression removes the
# source->RouteNode Feeds edge; bindings read this node (never the source), so
# a suppressed route CANNOT be bypassed by dynamic-dependency tracking.
node RouteNode(ReactiveNode) {
    has runtime_id: str = "";
    has route_name: str = "";
    has cached: object = None;
    has state: int = 0;          # CLEAN/CHECK/DIRTY (mirrors DerivedNode)
    has active: bool = True;
    # NOTE: the source handle is process-local and lives in SessionStore
    # (route_sources), never on the node — a node ref here poisons the graph
    # serializer (PLAN §1: process-local state stays off nodes).
}

# ---------------------------------------------------------------------------
# Policy families
# ---------------------------------------------------------------------------
node BasePolicy(RuntimeBase) {
    has runtime_id: str = "";
    has name: str = "";
}

node ModeNode(RuntimeBase) {
    has runtime_id: str = "";
    has name: str = "";
}

node RoutePolicy(RuntimeBase) {
    has runtime_id: str = "";
    has route_name: str = "";
}

node SuppressionPolicy(RuntimeBase) {
    has runtime_id: str = "";
    has route_name: str = "";
    has owner_mode: str = "";
}

node OverridePolicy(RuntimeBase) {
    has runtime_id: str = "";
    has route_name: str = "";
    has surface_kind: str = "";
    has owner_mode: str = "";
}


# ---------------------------------------------------------------------------
# Typed edges (PLAN §1 / §4.2). The overloaded Contains relationship is gone:
# each runtime relationship now has its own typed edge.
# ---------------------------------------------------------------------------
edge SessionOutput:  DesktopSession --> OutputNode {}
edge SessionPolicy:  DesktopSession --> BasePolicy {}
edge SessionMode:    DesktopSession --> ModeNode {}
edge SessionSource:  DesktopSession --> SourceNode {}
edge SessionBinding: DesktopSession --> BindingNode {}
edge OutputSurface:  OutputNode --> SurfaceNode {}
edge SurfaceRegion:  SurfaceNode --> RegionNode {}
edge Owns:  ReactiveNode --> ReactiveNode {}
edge Feeds: ReactiveNode --> ReactiveNode {}
edge Requests:  BasePolicy --> RoutePolicy {}
edge Suppresses: ModeNode --> RoutePolicy {}
edge Overrides: ModeNode --> OverridePolicy {}
edge Activates:  RoutePolicy --> RouteNode {}
edge Renders: SurfaceNode --> ViewNode {}


# ---------------------------------------------------------------------------
# Reachability helpers (typed-edge reads)
# ---------------------------------------------------------------------------
def session_outputs(session: DesktopSession) -> list[OutputNode] {
    return [session ->:SessionOutput:->];
}

def session_policies(session: DesktopSession) -> list[BasePolicy] {
    return [session ->:SessionPolicy:->];
}

def session_modes(session: DesktopSession) -> list[ModeNode] {
    return [session ->:SessionMode:->];
}

def session_sources(session: DesktopSession) -> list[SourceNode] {
    return [session ->:SessionSource:->];
}

def session_bindings(session: DesktopSession) -> list[BindingNode] {
    return [session ->:SessionBinding:->];
}

def output_surfaces(out: OutputNode) -> list[SurfaceNode] {
    return [out ->:OutputSurface:->];
}

# Route-policy reachability (PLAN §6). Route truth is graph reachability:
# BasePolicy -Requests-> RoutePolicy -Activates-> RouteNode -Feeds-> BindingNode.
def session_route_policies(session: DesktopSession) -> list[RoutePolicy] {
    out: list = [];
    for bp in session_policies(session) {
        for rp in [bp ->:Requests:->][?:RoutePolicy] { out.append(rp); }
    }
    return out;
}

def route_policy_for(session: DesktopSession, route_name: str) -> RoutePolicy | None {
    for rp in session_route_policies(session) {
        if rp.route_name == route_name { return rp; }
    }
    return None;
}

def route_node_for_policy(rp: RoutePolicy) -> RouteNode | None {
    ns = [rp ->:Activates:->];
    if len(ns) > 0 { return ns[0]; }
    return None;
}


# ---------------------------------------------------------------------------
# CollectSession — reach every runtime node under a session for disposal.
# ViewNode subtrees are torn down first by the caller (projection), so this
# walker only has to gather the graph-persistent runtime nodes.
# ---------------------------------------------------------------------------
walker CollectSession {
    has nodes: list = [];

    can session with DesktopSession entry {
        self.nodes.append(here);
        visit [here ->:SessionOutput:->];
        visit [here ->:SessionPolicy:->];
        visit [here ->:SessionMode:->];
        visit [here ->:SessionSource:->];
        visit [here ->:SessionBinding:->];
    }
    can output with OutputNode entry {
        self.nodes.append(here);
        visit [here ->:OutputSurface:->];
    }
    can surface with SurfaceNode | RegionNode entry {
        self.nodes.append(here);
    }
    can mode with ModeNode entry {
        self.nodes.append(here);
        visit [here ->:Suppresses:->];
    }
    can base with BasePolicy entry {
        self.nodes.append(here);
        visit [here ->:Requests:->];            # reach RoutePolicy subgraph
    }
    can routepolicy with RoutePolicy entry {
        self.nodes.append(here);
        visit [here ->:Activates:->];           # reach the RouteNode gate
    }
    can modesup with SuppressionPolicy | OverridePolicy entry {
        self.nodes.append(here);
    }
    can reactive with SourceNode | DerivedNode | BindingNode | RouteNode entry {
        self.nodes.append(here);
    }
}


# ---------------------------------------------------------------------------
# Active-session identity — threaded onto every created runtime node so a
# session's subgraph is identifiable for disposal/inspection (PLAN §1).
# ---------------------------------------------------------------------------
glob _active_session_rid: str = "";

def active_session_rid() -> str { return _active_session_rid; }

def set_active_session_rid(rid: str) { _active_session_rid = rid; }


# ---------------------------------------------------------------------------
# Process-local closure registry — never persisted as durable policy. Scoped
# to the live session: dispose_session tears down every node whose closure
# lives here, and reset_session_store gives a clean slate for a new session.
# ---------------------------------------------------------------------------
obj SessionStore {
    has derived_fns: dict = {};
    has binding_fns: dict = {};
    has route_sources: dict = {};   # route runtime_id -> source node (process-local)
    has visit_counts: dict = {};
    has adapter_ops: list = [];
}

glob _store: any = None;

def session_store() -> SessionStore {
    if _store is None { _store = SessionStore(); }
    return _store;
}

def reset_session_store() {
    _store = SessionStore();   # IDs stay monotonic: do NOT reset _rid_seq (PLAN §1)
}

def trace_visit(kind: str) {
    s = session_store();
    c = s.visit_counts.get(kind, 0);
    s.visit_counts[kind] = c + 1;
}

def trace_adapter(op: str) {
    session_store().adapter_ops.append(op);
}
