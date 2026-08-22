# osp_local.jac — run the OSP graph session fully in-process (no SQL store).
# ---------------------------------------------------------------------------
# The jaclang runtime auto-attaches an embedded PostgreSQL store to every
# graph Session whose module has a project base path (Session.postinit ->
# PgStore over ~/.cache/jac/pg, spawned on demand). For a desktop shell that
# store is a liability, not a feature:
#
#   * every typed edge hop (`visit [here ->:Feeds:->]`) becomes a wire query
#     under serializable isolation; at shell write rates (~150/s: 1s clock
#     ticks + 16ms tween frames) PG exhausts max_pred_locks_per_transaction
#     and then EVERY query raises PgWireError (2026-08-20 frozen-bar incident);
#   * every commit serializes anchors, logging "Falling back to str()" per
#     lambda / GTK widget reachable from a node (~150/s warning flood);
#   * a wedged embedded PG blocks new `jac run` boots for minutes.
#
# With the store detached, the query planner walks the live in-process
# topology (query_planner: `mem.store is not None and oanch.persistent`
# gates the SQL path) and Session.commit just clears the dirty set. Graph
# state is process-local by design (PLAN §1) — nothing here wants durable
# storage.
::py::
def detach_sql_store() -> str:
    """Drop the session's SQL store. Idempotent; returns a status line."""
    try:
        from jaclang.jac0core.runtime import JacContext
        mem = getattr(JacContext.get_context(), "mem", None)
        if mem is None:
            return "osp-local: no session (skipped)"
        if getattr(mem, "store", None) is None:
            return "osp-local: already detached"
        mem.store = None
        return "osp-local: sql store detached — graph runs in-process"
    except Exception as e:
        return "osp-local: detach FAILED " + repr(e)
::py::

def run_graph_inprocess() {
    print(detach_sql_store());
}
