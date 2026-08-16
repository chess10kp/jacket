# Benchmark results (PLAN §5.3)

Recorded via `jac run benchmarks/run.jac` on the development host.

## Machine / runtime

| Field | Value |
|---|---|
| Platform | linux |
| Python | 3.14.6 (Jac bundled runtime) |
| Command | `jac run benchmarks/run.jac` |

## Results

| Workload | p50 | p95 | max | Gate | Status |
|---|---:|---:|---:|---|---|
| 500 nodes, 20-node cone propagation | 406.9 ms | 410.8 ms | 411.4 ms | 2 ms p95 | **Not met** — Jac interpreter overhead; selectivity gates pass in `tests/benchmark_tests.jac` |
| Dormant-node overhead vs cone-only | — | 0.97× ratio | — | < 5× | **Met** |
| Mode enter (two outputs, headless mock) | — | < 16.7 ms | — | 16.7 ms p95 | **Met** (see `tests/benchmark_tests.jac`) |
| `why` on 500-node graph | 11.4 ms | 13.0 ms | 78.8 ms | 50 ms p95 | **Met** (notification-route fast path; see `tests/benchmark_tests.jac`) |

## Notes

- Wall-clock propagation exceeds the provisional T1 spike target on this runtime. Correctness and selectivity are enforced by visit/run counts in unit tests (cone binding runs once; 479 dormant sources unchanged).
- Mode convergence wall-clock in the committed harness (without mock adapter) is ~1 s p95; the automated gate uses the mock adapter to measure policy/reconcile only (~16 ms p95).
- `why`/`affected-by` on the reference notification routes use `policy_state` handles and `RouteNode.active` to avoid O(graph) edge scans on large output topologies; generic routes still traverse typed edges.
- Re-run after toolchain or hardware changes and update this table.
