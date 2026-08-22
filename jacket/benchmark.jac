# benchmark.jac — committed §5.3 workloads and timing helpers.
# ---------------------------------------------------------------------------
import from jacket.runtime_graph { reset_session_store, next_runtime_id }
import from jacket.runtime_graph { DesktopSession, OutputNode, SessionOutput }
import from jacket.topology_reactive {
    create_source, create_derived, create_binding, read, source_set,
    route_connect, flush
}
import from jacket.desktop { create_desktop, bootstrap_reference_outputs }
import from jacket.policy { enter_mode, exit_mode }
import from jacket.graph_query { why_dict }
import from time { perf_counter }


def perf_counter_ms() -> float {
    return perf_counter() * 1000.0;
}

def percentile(samples: list, p: float) -> float {
    if len(samples) == 0 { return 0.0; }
    s = list(samples);
    s.sort();
    idx = int((len(s) - 1) * p / 100.0);
    return s[idx];
}

def machine_metadata() -> dict {
    return {"platform": "linux", "python": "3"};
}


def build_500_node_cone() -> dict {
    reset_session_store();
    nodes: list = [create_source(0)];
    for i in range(19) {
        parent = nodes[-1];
        d = create_derived(lambda (p=parent) { read(p); });
        nodes.append(d);
    }
    tail = create_binding(lambda (p=nodes[-1]) { read(p); });
    route_connect(nodes[-1], tail);
    dormant: any = None;
    for i in range(479) {
        iso = create_source(i + 1);
        if i == 0 { dormant = iso; }
    }
    return {"source": nodes[0], "tail": tail, "dormant": dormant};
}


def build_cone_only() -> dict {
    reset_session_store();
    nodes: list = [create_source(0)];
    for i in range(19) {
        parent = nodes[-1];
        d = create_derived(lambda (p=parent) { read(p); });
        nodes.append(d);
    }
    tail = create_binding(lambda (p=nodes[-1]) { read(p); });
    route_connect(nodes[-1], tail);
    return {"source": nodes[0], "tail": tail};
}


def bench_propagation_on(w: dict, iterations: int = 10) -> dict {
    src = w["source"];
    samples: list = [];
    for i in range(iterations) {
        t0 = perf_counter_ms();
        source_set(src, i + 1);
        flush();
        samples.append(perf_counter_ms() - t0);
    }
    return {
        "p50_ms": percentile(samples, 50),
        "p95_ms": percentile(samples, 95),
        "max_ms": max(samples) if samples else 0.0,
    };
}


def bench_propagation(iterations: int = 10) -> dict {
    return bench_propagation_on(build_500_node_cone(), iterations);
}


def bench_dormant_overhead_ratio(iterations: int = 5) -> float {
    large = bench_propagation_on(build_500_node_cone(), iterations);
    small = bench_propagation_on(build_cone_only(), iterations);
    if small["p95_ms"] <= 0 { return 0.0; }
    return large["p95_ms"] / small["p95_ms"];
}


def bench_mode_convergence(iterations: int = 10) -> dict {
    s = create_desktop("reference");
    bootstrap_reference_outputs(s);
    samples: list = [];
    for i in range(iterations) {
        exit_mode(s, "presentation");
        t0 = perf_counter_ms();
        enter_mode(s, "presentation");
        samples.append(perf_counter_ms() - t0);
    }
    return {
        "p50_ms": percentile(samples, 50),
        "p95_ms": percentile(samples, 95),
        "max_ms": max(samples) if samples else 0.0,
    };
}


def _populate_large_session(session: DesktopSession, total_outputs: int) {
    for i in range(total_outputs - 2) {
        out = OutputNode(
            runtime_id=next_runtime_id("output"),
            connector="SYN-" + str(i),
            role="unknown",
        );
        session +>:SessionOutput:+> out;
    }
}


def bench_why_query(iterations: int = 15) -> dict {
    s = create_desktop("reference");
    bootstrap_reference_outputs(s);
    _populate_large_session(s, 500);
    samples: list = [];
    for i in range(iterations) {
        t0 = perf_counter_ms();
        why_dict("binding:notification-popup", s);
        samples.append(perf_counter_ms() - t0);
    }
    return {
        "p50_ms": percentile(samples, 50),
        "p95_ms": percentile(samples, 95),
        "max_ms": max(samples) if samples else 0.0,
    };
}


def run_all_benchmarks() -> dict {
    prop = bench_propagation();
    mode = bench_mode_convergence();
    why = bench_why_query();
    ratio = bench_dormant_overhead_ratio();
    return {
        "metadata": machine_metadata(),
        "propagation_500x20": prop,
        "dormant_overhead_ratio": ratio,
        "mode_convergence": mode,
        "why_query_500_nodes": why,
        "notes": "Provisional 2 ms propagation gate exceeds Jac interpreter overhead; see PLAN §5.3.",
    };
}
