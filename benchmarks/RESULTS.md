# Benchmark results (PLAN §5.3)

Recorded via `jac run benchmarks/run.jac` on the development host.

## Machine / runtime

| Field | Value |
|---|---|
| Platform | linux |
| Python | 3.14.6 (Jac bundled runtime) |
| Command | `jac run benchmarks/run.jac` |
| Load caveat | 2026-08-26 re-run on a host with load average 16–19 from unrelated processes; absolute numbers are pessimistic and run-to-run noisy (see Notes) |

## Results

Latest full-workload run (`jac run benchmarks/run.jac`, loaded host):

| Workload | p50 | p95 | max | Gate | Status |
|---|---:|---:|---:|---|---|
| 500 nodes, 20-node cone propagation | 684.1 ms | 1033.4 ms | 1318.4 ms | 2 ms p95 | **Not met** — Jac interpreter overhead; selectivity gates pass in `tests/benchmark_tests.jac` |
| Dormant-node overhead vs cone-only | — | 1.02× ratio | — | < 5× | **Met** |
| Mode enter (two outputs, headless mock) | 41.5 ms | 46.2 ms | 63.5 ms | 35 ms p95 (`tests/benchmark_tests.jac`) | **Marginal** — passes on an idle host, fails under load (see Notes) |
| `why` on 500-node graph | 1.3 ms | 1.8 ms | 7548 ms (load-spike outlier) | 50 ms p95 | **Met** (notification-route fast path; see `tests/benchmark_tests.jac`) |

Earlier recording (idle host): propagation 406.9/410.8/411.4 ms (p50/p95/max); mode enter < 16.7 ms p95; `why` 11.4/13.0/78.8 ms.

## Notes

- Wall-clock propagation exceeds the provisional T1 spike target on this runtime. Correctness and selectivity are enforced by visit/run counts in unit tests (cone binding runs once; 479 dormant sources unchanged).
- **Mode-convergence unit gate is marginal.** The automated gate (`tests/benchmark_tests.jac`, mock adapter, 35 ms p95 budget) measures policy/reconcile only. Profiling shows an `enter_mode` transition issues ~20 typed-edge graph queries, each with ~1–1.5 ms *fixed* Jac-interpreter cost regardless of graph size (verified: query cost is flat from 0 to 4000 extra nodes). Median is ~28–31 ms on this host, so the 35 ms budget leaves <20% headroom and ordinary scheduler/load noise flips the gate. With `bench_mode_convergence(5)`, p95 of 5 samples is effectively the max, so a single multi-hundred-ms stall (common under load) fails the test. Run-to-run on a loaded day the failing gate moves between tests (mode-convergence some runs, the 2000 ms propagation gate others); on quieter periods all 6 pass.
- Query-count reductions landed in `src/policy.jac` (behavior-preserving, no API change): suppression state resolved in ONE pass over modes (`_suppressed_route_names`) instead of per-route rescans in `_sync_routes`/`route_is_active`, and mode names hoisted out of the per-output reconcile loop. Controlled A/B: `bench_mode_convergence` p50 median ~30.9 → ~27.8 ms (~10%). This does NOT reliably flip the 35 ms gate under load; the residual cost is fixed per-query interpreter overhead, not algorithmic work.
- Walker-spawn cost was ruled out as the mode-convergence bottleneck: with no dirty sources, `flush()` is a no-op here, and a 1-seed flush after building several 500-node cones measures ~0.01 ms. The O(total-graph-nodes) spawn concern remains valid for large flushes, which is why `reconcile_topology` stays a plain function loop.
- `why`/`affected-by` on the reference notification routes use `policy_state` handles and `RouteNode.active` to avoid O(graph) edge scans on large output topologies; generic routes still traverse typed edges.
- Re-run after toolchain or hardware changes and update this table. Record host load average alongside timings.

## Recommendation: mode-convergence gate (35 ms p95)

Options considered:

1. **Raise the budget** (e.g. 35 → 50–60 ms p95) and/or raise `bench_mode_convergence` iterations from 5 to 15+ so p95 stops being max-of-5. Pros: honest against measured medians (~28–31 ms), cheap, keeps a real regression tripwire. Cons: admits the "one 60 Hz frame" aspiration is unmet on this runtime.
2. **Mark xfail-tolerant** (`xfail`/strict=False or skip-under-load). Pros: no red CI from machine noise. Cons: loses the regression signal entirely; timing regressions would ship silently.
3. **Algorithmic fix to get back under 35 ms.** Not available repo-side: profiling attributes ~70% of the path to fixed per-typed-edge-query interpreter overhead (~1 ms × ~20 queries), already reduced by the safe query-count cuts above (~10%). The next cut would require caching session/mode/route lookups across mutations (stale-cache risk, behavior-changing) or runtime-level cheaper edge queries (outside this repo).

**Pick: option 1**, combined: raise the budget to ~50 ms p95 *and* bump iterations to ≥15 for a statistically meaningful p95. Rationale: the gate currently measures machine noise more than code; medians show real headroom against 50 ms even on a loaded host, while a genuine 2× regression (~60 ms+) would still fail loudly. Revisit if the Jac runtime ever makes typed-edge queries sub-millisecond, at which point the original 16.7 ms aspiration becomes plausible again.
