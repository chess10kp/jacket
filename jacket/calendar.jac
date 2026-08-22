# calendar.jac — LIBRARY: pure month-grid math for the clock's calendar flyout.
# ---------------------------------------------------------------------------
# No state, no GTK: the UI (examples/reference) renders whatever these fns
# return, and the tests exercise them headless.
#
# Convention: weeks are Monday-first lists of 7 day numbers; padding days are
# 0. A month always renders 6 rows (42 cells) so the flyout never changes
# height month-to-month.
#
# NOTE: the datetime math lives in the ::py:: shim — Jac's checker cannot
# follow operators/attributes on untyped Python objects. monthrange() gives
# both facts we need in one call: (first-day weekday Mon=0, days in month).

::py::
import calendar as _calmod

def py_month_info(year: int, month: int) -> tuple:
    """(first-weekday Mon=0, days_in_month) for the given month."""
    return _calmod.monthrange(int(year), int(month))
::py::


def month_info(year: int, month: int) -> list {
    (lead, n) = py_month_info(year, month);
    return [int(lead), int(n)];
}


def days_in_month(year: int, month: int) -> int {
    return month_info(year, month)[1];
}


# The 42-cell grid: 6 rows x 7 cols, leading/trailing zeros pad partial weeks.
def month_grid(year: int, month: int) -> list {
    info = month_info(year, month);
    lead = info[0];
    n = info[1];
    cells: list = [];
    k = 0;
    while k < lead { cells.append(0); k += 1; }
    d = 1;
    while d <= n { cells.append(d); d += 1; }
    while len(cells) % 7 != 0 { cells.append(0); }
    while len(cells) < 42 { cells.append(0); }
    out: list = [];
    r = 0;
    while r < len(cells) { out.append(cells[r:r + 7]); r += 7; }
    return out;
}

# Rendered text for the flyout: header line, weekday header, then rows with
# today wrapped in brackets. Pure fn of "now" so tests can pin a date.
def month_text(year: int, month: int, today_y: int, today_m: int, today_d: int,
               names: list) -> str {
    lines: list = [];
    lines.append(str(names[month - 1]) + " " + str(year));
    lines.append("Mo Tu We Th Fr Sa Su");
    grid = month_grid(year, month);
    ri = 0;
    while ri < len(grid) {
        row: list = [];
        ci = 0;
        while ci < 7 {
            d = grid[ri][ci];
            if d == 0 { row.append("  "); }
            elif d == today_d and year == today_y and month == today_m {
                row.append("[" + str(d).rjust(2) + "]");
            } else { row.append(str(d).rjust(2)); }
            ci += 1;
        }
        lines.append(" ".join(row).rstrip());
        ri += 1;
    }
    return "\n".join(lines);
}
