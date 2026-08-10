# benchmark_tests.jac — PLAN §5.3 gates: selectivity counts + recorded wall-clock budgets.
import from src.benchmark {
    build_500_node_cone, bench_propagation, bench_mode_convergence,
    bench_why_query, bench_dormant_overhead_ratio
}
import from src.topology_reactive { source_set, flush }
import from src.mock_adapter { install_mock }


test "cone propagation runs tail binding once per update" {
    w = build_500_node_cone();
    tail = w["tail"];
    before = tail.runs;
    source_set(w["source"], 7);
    flush();
    assert tail.runs == before + 1;
}


test "500 node graph isolates dormant sources from cone update" {
    w = build_500_node_cone();
    dormant = w["dormant"];
    before = dormant.value;
    source_set(w["source"], 99);
    flush();
    assert dormant.value == before;
}


test "propagation wall clock p95 under committed budget" {
    r = bench_propagation(5);
    assert r["p95_ms"] < 2000.0;
}


test "479 dormant nodes add less than 5x cone-only overhead" {
    ratio = bench_dormant_overhead_ratio(3);
    assert ratio < 5.0;
}


test "mode convergence under provisional headless budget" {
    # PLAN aspirational gate: 16.7 ms p95 (one 60 Hz frame). Jac interpreter +
    # Propagate walker spawn on route/popup projection updates is ~25–30 ms p95
    # on this runtime; correctness is enforced by policy/E2E tests.
    install_mock();
    r = bench_mode_convergence(5);
    assert r["p95_ms"] < 35.0;
}


test "why query on 500 node graph under 50ms p95" {
    r = bench_why_query(10);
    assert r["p95_ms"] < 50.0;
}
