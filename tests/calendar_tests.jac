# calendar_tests.jac — pure month-grid math (src/calendar.jac), fully headless.
import from src.calendar { days_in_month, month_grid, month_text }

glob NAMES: list = ["January", "February", "March", "April", "May", "June",
                    "July", "August", "September", "October", "November",
                    "December"];


test "days_in_month: regular, leap, and year rollover" {
    assert days_in_month(2026, 1) == 31;
    assert days_in_month(2026, 4) == 30;
    assert days_in_month(2026, 2) == 28;      # 2026 is not a leap year
    assert days_in_month(2024, 2) == 29;      # leap year
    assert days_in_month(2026, 12) == 31;     # Dec must not roll wrong
}


test "month_grid: always 42 cells, real days in order, zero padding" {
    g = month_grid(2026, 2);                  # Feb 2026: 28 days
    total = 0;
    days: list = [];
    ri = 0;
    while ri < len(g) {
        week = g[ri];
        assert len(week) == 7;
        ci = 0;
        while ci < 7 {
            c = week[ci];
            if c != 0 { days.append(c); }
            total += 1;
            ci += 1;
        }
        ri += 1;
    }
    assert total == 42;
    assert len(days) == 28;
    # days appear once each, in ascending order
    i = 0;
    while i < len(days) {
        assert days[i] == i + 1;
        i += 1;
    }
}


test "month_grid: first week aligns with Monday-first weekday" {
    # Jan 1 2026 falls on a Thursday (Mon=0 index 3) -> 3 leading zeros
    g = month_grid(2026, 1);
    assert g[0] == [0, 0, 0, 1, 2, 3, 4];
    assert g[1] == [5, 6, 7, 8, 9, 10, 11];
}


test "month_text: header, weekday rule, and today marker" {
    txt = month_text(2026, 2, 2026, 2, 9, NAMES);
    lines: list = txt.split("\n");
    assert lines[0] == "February 2026";
    assert lines[1] == "Mo Tu We Th Fr Sa Su";
    # today (the 9th) is bracketed somewhere in the text
    assert "[ 9]" in txt;
    # no other day is bracketed
    assert "] [" not in txt.replace("[ 9]", "");
    # exactly one bracketed day
    n = 0;
    for ch in txt {
        if ch == "[" { n += 1; }
    }
    assert n == 1;
}


test "month_text: today outside the month marks nothing" {
    txt = month_text(2026, 2, 2026, 3, 9, NAMES);
    assert "[" not in txt and "]" not in txt;
}
