# Reconciler hot-path profile — verdicts on PLAN §8 deferred perf items

**Date:** 2026-08-08 · **Branch:** shell-phases-4-5 · **Scope:** measurement only (no
`jacket/` or `tests/` changes). Drives the real reconciler headless through the mock
adapter, exactly like `tests/builders_tests.jac`.

This pass exists to answer one question with numbers, not vibes: are any of the
three explicitly-deferred perf items in `plans/PLAN.md` §8 actually warranted yet?
Each is gated on "only if profiling shows…". Short answer: **none of the three are
warranted.** Details below.

---

## Methodology

- **Engine under test:** `jacket/reactive.jac` (signal/effect/scheduler) +
  `jacket/builders.jac` `reconcile_list` keyed diff (`create_row` / `remove_row` /
  `move_row`), driven through `jacket/mock_adapter.jac` which records every
  construct/insert/remove/move/set_prop into `m.ops`. Fully headless — the diff
  hot path needs no GTK/display.
- **Harness:** `jac run` scripts with a `with entry {}` main (kept in scratchpad,
  not in the repo). Wall-clock via `from time import perf_counter`. Each shape is
  built fresh, timed as the single `src.set(newlist)` call that triggers one
  reconcile, with **2 warm-up iterations discarded** and the **median of 8**
  reported (the first `set()` in a process pays a one-time Jac native-lowering /
  JIT cost of tens of ms that is not representative of steady state).
- **Two signals captured per reconcile:** (a) wall-clock ms, and (b) the
  **move-op count** emitted to the adapter. The move-count is the load-bearing
  number for the LIS question — it is adapter-independent and is exactly what LIS
  would shrink.
- **Sizes:** 100 and 1000 items. Realistic shell `For` lists are far smaller (see
  "What the shell actually does" below); 1000 is a deliberate stress point.

Caveat on wall-clock: the mock adapter's `move()` / `remove()` do a Python
`list.remove()` (O(N) scan) + `list.insert()`, so an O(N)-move reconcile is
O(N²) *in the mock*. Real GTK reorder cost differs. Treat the **move-count** as
the portable signal and wall-clock as order-of-magnitude only.

---

## Results — `For` keyed diff by mutation shape

Median reconcile time and op-counts for a single mutation:

| Shape           |    N | median ms | insert | remove | **move** |
|-----------------|-----:|----------:|-------:|-------:|---------:|
| append          |  100 |     0.080 |      1 |      0 |    **0** |
| prepend         |  100 |     0.086 |      1 |      0 |    **1** |
| middle_insert   |  100 |     0.096 |      1 |      0 |    **1** |
| single_remove   |  100 |     0.317 |      0 |      1 |    **0** |
| reverse (full)  |  100 |     0.293 |      0 |      0 |   **99** |
| random_shuffle  |  100 |     0.239 |      0 |      0 |   **96** |
| adjacent_swap 5%|  100 |     0.058 |      0 |      0 |    **5** |
| append          | 1000 |     0.513 |      1 |      0 |    **0** |
| prepend         | 1000 |     0.506 |      1 |      0 |    **1** |
| middle_insert   | 1000 |     0.520 |      1 |      0 |    **1** |
| single_remove   | 1000 |     1.610 |      0 |      1 |    **0** |
| reverse (full)  | 1000 |   100.359 |      0 |      0 |  **999** |
| random_shuffle  | 1000 |    89.687 |      0 |      0 |  **994** |
| adjacent_swap 5%| 1000 |     1.810 |      0 |      0 |   **50** |

Reading of the two-ended diff (`reconcile_list`, builders.jac:147):

- **Shell-shaped edits land in 0–1 moves regardless of N.** append=0,
  single_remove=0, prepend=1, middle_insert=1 — flat at both N=100 and N=1000.
  This is the property the diff was built for, and it holds.
- **Full reverse and random shuffle emit ~O(N) moves** (99/96 at N=100,
  999/994 at N=1000). This *is* the "shuffle thrash" §8 asks about — an optimal
  LIS diff would cut reverse to ~1 move and a random shuffle to ~N−LIS(π)
  (expected ≈ N − √N) moves. So the thrash is real **as a property of the
  algorithm**. The question is whether the shell ever triggers it (it doesn't —
  see below).
- Modest reorders scale proportionally (5% adjacent swaps → 5% moves), i.e. the
  diff pays exactly for the disorder present, not more.

---

## Results — launcher scenario (gate for virtualization)

Launcher caps output at `MAX_RESULTS=30` (`examples/reference/launcher_ui.jac`) and ranks via
the pure O(n) `filter_apps`. Simulated a full type-then-backspace cycle
`f→fi→fir→fire→…→""` (9 keystrokes) over synthetic app catalogs, warm-up
discarded, median of 5 cycles:

| apps | keystroke median ms | peak keystroke ms | moves / 9-keystroke cycle | pure `filter_apps` (all-match) ms |
|-----:|--------------------:|------------------:|--------------------------:|----------------------------------:|
|  200 |               0.884 |             34.32 |                        10 |                             0.156 |
|  400 |               0.658 |             16.07 |                        20 |                             0.340 |
|  800 |               1.735 |             17.27 |                         0 |                             0.860 |

- **Pure ranking is sub-millisecond even at 800 `.desktop` entries** (0.86 ms).
  `filter_apps` is not a spike source.
- **Reconcile emits ~0 moves.** Narrowing a ranked list is membership churn
  (insert/remove of rows entering/leaving the top-30 window), not reordering, so
  the keyed diff barely moves anything. LIS would change nothing here.
- Steady-state keystroke cost is **~1 ms**. The occasional ~16–34 ms peak is a
  single keystroke that swaps up to 30 whole row subtrees at once (30 inserts +
  30 `Dispose` walkers building/tearing Label subtrees) — a one-shot per
  keystroke, dominated by widget construction, **not** by the diff and **not**
  reducible by virtualization (the list is already windowed to 30).

---

## What the shell actually does (grounds the verdicts)

Every `For` in `jacket/`:

| Site | List | Realistic N | Mutation shape |
|------|------|------------:|----------------|
| `launcher_ui.jac:55` | ranked results | ≤ 30 (hard cap) | insert/remove churn, ~0 moves (measured) |
| `components.jac:226` | WM workspaces | ~10 | append/remove, index-ordered — no shuffle |
| `components.jac:324` | tray items | a few | append/remove |
| `notif_ui.jac:39` | notifications | dozens at most | prepend/remove (newest first) — no shuffle |

None of these ever fully-reverse or randomly-shuffle a large list. The largest
`For` in the shell is the launcher at N≤30, where even a hypothetical full
reverse is ~30 moves in well under 1 ms.

---

## Allocation / GC note (gate for `__slots__`)

Read of the hot path: a pure move or content-update reconcile allocates **nothing
per row** — `move_row` only calls the adapter; content updates push through the
existing per-row `Signal` via the equality-cutoff `set()`. Allocation happens
only on **membership change** (`create_row` mints one `Signal` + one `ViewNode`
per newly-appearing key). This is the fine-grained design paying off exactly as
§7 predicts: steady ticks (clock, volume, a moved row) allocate zero. No
GC/alloc-pressure signal appeared in any measurement — timings are flat and
membership-proportional, not lumpy. Per-node set overhead (`subscribers`, `deps`)
is a fixed RSS cost (§7 already bounds the reconciler at ~1–2% of RSS), not a
hot-path cost.

---

## Verdicts

### 1. LIS minimum-move refinement for `For` — **NOT WARRANTED (gate not met)**

Gate: "add only if profiling shows shuffle thrash." The thrash exists as an
algorithmic property (full reverse of N=1000 = **999 moves**, random shuffle =
**994 moves**), but **no shell `For` ever produces it**: every real list is
append/prepend/remove-shaped (0–1 moves, confirmed flat to N=1000), the launcher
reorders ~0, and the largest list is 30 items. The triggering condition — a large
list undergoing arbitrary reorder — does not occur. **Keep LIS deferred.** Revisit
only if a future feature introduces a large (N≥100), user-reorderable/sortable
`For` (e.g. a drag-to-reorder list or a big sortable table); the move-count is the
number to watch, and this harness reproduces it in one line.

### 2. List virtualization (windowed `For`) — **NOT WARRANTED (gate not met)**

Gate: "only if a huge launcher list spikes." The launcher is already windowed by
`MAX_RESULTS=30`. Pure ranking is <1 ms at 800 apps; reconcile is ~1 ms
steady-state with ~0 moves. The only non-trivial cost (~16–34 ms one-shot peak) is
constructing up to 30 row subtrees on a keystroke that swaps the whole visible
set — virtualization can't reduce an already-30-item window. Nothing spikes.
**Keep virtualization deferred.**

### 3. `__slots__` / subscriber-slot tuning — **NOT WARRANTED (gate not met)**

Gate: micro-opt, post-profile only if alloc/GC pressure shows. It doesn't. The
hot path allocates nothing on moves/content updates (fine-grained working as
designed); allocation is strictly membership-proportional. No GC pressure or
alloc lumpiness in any timing. This stays a pure RSS micro-optimization with no
measured hot-path payoff. **Keep deferred.**

---

## Reproduce

Harness scripts live in the session scratchpad (not the repo). Run from
`shell/`:

```
jac run <scratchpad>/bench2.jac    # For-diff table (median) + launcher first-pass
jac run <scratchpad>/bench3.jac    # launcher warm-up + median cycle
```

Note: `jac run` here intermittently trips a flaky native-lowering parse error in
`osp.jac` (`E0013: 'root' is a keyword`) unrelated to this work — it is
non-deterministic; simply re-run until it compiles (2–4 tries). `jac test` is
unaffected (15/15 pass).
