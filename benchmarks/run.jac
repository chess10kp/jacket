# benchmarks/run.jac — record §5.3 benchmark results (jac run benchmarks/run.jac).
import from src.benchmark { run_all_benchmarks }
import json;


with entry {
    print(json.dumps(run_all_benchmarks(), indent=2, sort_keys=True));
}
