# benchmarks/launcher_filter.jac — filter_apps throughput (jac run benchmarks/launcher_filter.jac).
import from src.launcher { filter_apps }
import from time { perf_counter }


glob MAX_RESULTS: int = 30;
glob QUERIES: list = ["f", "fi", "fir", "fire", "fir", "fi", "f", ""];


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


def make_apps(n: int) -> list {
    names = [
        "Firefox", "Files", "Calculator", "Terminal", "Settings",
        "Discord", "Spotify", "GIMP", "LibreOffice Writer", "VLC",
        "Thunderbird", "Obsidian", "Kitty", "Alacritty", "Neovim",
        "Steam", "Blender", "Inkscape", "GParted", "Htop",
    ];
    out: list = [];
    for i in range(n) {
        base = names[i % len(names)];
        name = base + " " + str(i);
        out.append({
            "name": name,
            "exec": "app-" + str(i),
            "icon": "icon",
            "key": "app-" + str(i) + ".desktop",
            "lname": name.lower(),
        });
    }
    return out;
}


def bench_one(apps: list, query: str, limit: int, iterations: int) -> dict {
    for _ in range(3) {
        filter_apps(apps, query, limit);
    }
    samples: list = [];
    for _ in range(iterations) {
        t0 = perf_counter_ms();
        filter_apps(apps, query, limit);
        samples.append(perf_counter_ms() - t0);
    }
    return {
        "p50_ms": percentile(samples, 50),
        "p95_ms": percentile(samples, 95),
        "max_ms": max(samples),
    };
}


def bench_cycle(apps: list, limit: int, cycles: int) -> dict {
    for _ in range(2) {
        for q in QUERIES { filter_apps(apps, q, limit); }
    }
    cycle_samples: list = [];
    for _ in range(cycles) {
        t0 = perf_counter_ms();
        for q in QUERIES { filter_apps(apps, q, limit); }
        cycle_samples.append(perf_counter_ms() - t0);
    }
    per_keystroke: list = [];
    for _ in range(cycles) {
        for q in QUERIES {
            t0 = perf_counter_ms();
            filter_apps(apps, q, limit);
            per_keystroke.append(perf_counter_ms() - t0);
        }
    }
    return {
        "cycle_p50_ms": percentile(cycle_samples, 50),
        "cycle_max_ms": max(cycle_samples),
        "keystroke_p50_ms": percentile(per_keystroke, 50),
        "keystroke_max_ms": max(per_keystroke),
    };
}


def bench_size(n: int) -> dict {
    apps = make_apps(n);
    queries = ["", "f", "fire"];
    single: dict = {};
    for q in queries {
        single[q if q != "" else "<empty>"] = bench_one(apps, q, MAX_RESULTS, 50);
    }
    return {
        "n": n,
        "single_query": single,
        "keystroke_cycle": bench_cycle(apps, MAX_RESULTS, 5),
    };
}


with entry {
    sizes = [50, 200, 400, 800];
    results: list = [];
    for n in sizes {
        print("bench n=" + str(n) + " ...");
        results.append(bench_size(n));
    }
    print("");
    print("=== filter_apps (Jac, limit=" + str(MAX_RESULTS) + ") ===");
    for r in results {
        cyc = r["keystroke_cycle"];
        print("");
        print("n=" + str(r["n"]));
        print("  keystroke p50  " + str(round(cyc["keystroke_p50_ms"], 3)) + "ms");
        print("  keystroke max  " + str(round(cyc["keystroke_max_ms"], 3)) + "ms");
        print("  cycle p50      " + str(round(cyc["cycle_p50_ms"], 3)) + "ms");
        sq = r["single_query"];
        for (q, row) in sq.items() {
            print("  query " + q + " p50  " + str(round(row["p50_ms"], 3)) + "ms");
        }
    }
}
