# swaybar example — sources that mirror ~/.config/sway/bar (the i3bar script
# referenced by ~/.config/scroll/config's `bar { status_command ... }`).
# ---------------------------------------------------------------------------
# Modules cloned from that script, left -> right:
#   countdown  /tmp/timer_start elapsed timer (HH:MM:SS)
#   stocks     LITE CORZ CRWV BE NOW (Yahoo Finance, 10-min cache in /tmp)
#   mem        used memory (human), from /proc/meminfo
#   bluetooth  first connected device name (jacket.bluetooth)
# Battery + clock come from the LIBRARY (jacket.battery, jacket.sources) — this file
# only adds what the library doesn't ship. Everything here is CONSUMER code:
# nothing is added to jacket/. (See LIBRARY.md §1: examples are consumers.)
#
# Network (stocks) runs on a worker thread and marshals back via the GLib idle
# shim (jacket.glib.idle_add) so the GTK main loop never blocks on a fetch. The
# /tmp cache format matches the shell script byte-for-byte, so the two can
# share caches.
import from jacket.reactive { signal, Signal }
import from jacket.glib { timeout_add, idle_add }
import from jacket.sources { ticker }


# ===========================================================================
# ::py:: seam — file reads and the threaded stock fetcher.
# (Mirrors the walled-off style of battery.jac / audio.jac: system access
# lives in ::py::, plain callables exposed to Jac. Network stays off the main
# loop via a daemon thread + the jacket.glib idle shim.)
# ===========================================================================
::py::
import os, threading, time, json
from urllib import request as _urllib_request

_STOCK_CACHE_DIR = "/tmp"


def read_text(path):
    try:
        with open(path, "r") as f:
            return f.read()
    except Exception:
        return ""


def _cache_path(ticker):
    return os.path.join(_STOCK_CACHE_DIR, (ticker or "").lower() + "_stock_price.tmp")


def _read_cache(ticker):
    try:
        parts = open(_cache_path(ticker), "r").read().strip().split()
        if len(parts) >= 2:
            return parts[1]                      # "<ts> <price>"
    except Exception:
        return None
    return None


def read_stock_caches(tickers):
    """{ticker: price} for every ticker that has a cache file. Cheap; main-loop safe."""
    out = {}
    for t in tickers:
        c = _read_cache(t)
        if c is not None:
            out[t] = c
    return out


def _write_cache(ticker, ts, price):
    try:
        open(_cache_path(ticker), "w").write(str(ts) + " " + str(price) + "\n")
    except Exception:
        pass


def _fetch_one(ticker):
    url = "https://query1.finance.yahoo.com/v8/finance/chart/" + ticker
    req = _urllib_request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with _urllib_request.urlopen(req, timeout=8) as r:
        data = json.loads(r.read().decode("utf-8", "ignore"))
    price = data["chart"]["result"][0]["meta"].get("regularMarketPrice")
    return None if price is None else str(price)


def spawn_stock_fetch(tickers, on_done):
    """Fetch every ticker off-thread, refresh caches, then call on_done(dict)
    ON the GLib main loop. Safe to call from Jac. (idle_add is jacket.glib's shim,
    imported at the Jac level — same pattern as tray.jac's py_make_texture.)"""
    def work():
        out = {}
        now = int(time.time())
        for t in tickers:
            try:
                price = _fetch_one(t)
            except Exception:
                price = None
            if price is not None:
                _write_cache(t, now, price)
                out[t] = price
        for t in tickers:                        # backfill from cache if fetch failed
            if t not in out:
                c = _read_cache(t)
                if c is not None:
                    out[t] = c
        try:
            idle_add(lambda: (on_done(out), False)[1])
        except Exception:
            pass
    threading.Thread(target=work, daemon=True).start()
::py::


# ===========================================================================
# Pure Jac logic (kept here, not in jacket/, but written so it COULD be tested).
# ===========================================================================
# countdown: parse the timer-start file, format elapsed as HH:MM:SS.
def _pad2(n: int) -> str {
    return (("0" + str(n)) if n < 10 else str(n));
}

def fmt_elapsed(sec: any) -> str {
    s = int(sec);
    if s < 0 { s = 0; }
    return _pad2(s // 3600) + ":" + _pad2((s % 3600) // 60) + ":" + _pad2(s % 60);
}

def _countdown_text(tv: any) -> str {
    raw = read_text("/tmp/timer_start").strip();
    if raw == "" { return ""; }
    start = 0;
    try { start = int(raw); } except ValueError { return ""; }
    if start <= 0 { return ""; }
    return fmt_elapsed(int(tv) - start);
}

# mem: parse /proc/meminfo (KiB), report used = total - available, human form.
def parse_meminfo(text: any) -> dict {
    total = 0;
    avail = 0;
    for line in str(text).splitlines() {
        if line.startswith("MemTotal:") {
            total = int(line.split()[1]);
        } elif line.startswith("MemAvailable:") {
            avail = int(line.split()[1]);
        }
    }
    return {"total": total, "avail": avail};
}

def format_mem(used_kb: int) -> str {
    if used_kb >= 1048576 {                       # >= 1 GiB -> G with one decimal
        g = used_kb // 1048576;
        t = (used_kb * 10 // 1048576) % 10;
        return str(g) + "." + str(t) + "G";
    }
    return str(used_kb // 1024) + "M";            # else MiB
}

# stocks: short labels + ordering exactly as the shell script emits them.
glob STOCK_ORDER: list = ["LITE", "CORZ", "CRWV", "BE", "NOW"];
glob STOCK_LABELS: dict = {"LITE": "L", "CORZ": "C", "CRWV": "W", "BE": "BE", "NOW": "NOW"};

def format_stocks(d: dict) -> str {
    out = "";
    for t in STOCK_ORDER {
        if t in d {
            seg: str = str(STOCK_LABELS[t]) + ":" + str(d[t]);
            out = ((out + "  " + seg) if out != "" else seg);
        }
    }
    return out;
}


# ===========================================================================
# Sources (singletons). Each owns a Signal and refreshes on a GLib timeout.
# ===========================================================================
# countdown is a DERIVATION off the shared 1s ticker — re-reads the file every
# tick so a freshly-written /tmp/timer_start is picked up immediately.
glob _cd: any = None;

def countdown() -> Signal {
    if _cd is None { _cd = ticker(1000).map(_countdown_text); }
    return _cd;
}


obj Mem {
    has used: Signal = signal("");

    def postinit() {
        self._refresh();
        timeout_add(2000, lambda { self._refresh(); return True; });
    }

    def _refresh() {
        d = parse_meminfo(read_text("/proc/meminfo"));
        self.used.set(format_mem(int(d["total"]) - int(d["avail"])));
    }
}

glob _mem: any = None;

def get_mem() -> Mem {
    if _mem is None { _mem = Mem(); }
    return _mem;
}


obj Stocks {
    has prices: Signal = signal({});

    def postinit() {
        self.prices.set(read_stock_caches(STOCK_ORDER));        # show cached instantly
        timeout_add(60000, lambda {                             # re-read caches every minute
            self.prices.set(read_stock_caches(STOCK_ORDER));
            return True;
        });
        timeout_add(600000, lambda {                            # refetch every 10 min
            spawn_stock_fetch(STOCK_ORDER, lambda (d: dict) { self.prices.set(d); });
            return True;
        });
        spawn_stock_fetch(STOCK_ORDER, lambda (d: dict) { self.prices.set(d); });   # initial
    }
}

glob _stocks: any = None;

def get_stocks() -> Stocks {
    if _stocks is None { _stocks = Stocks(); }
    return _stocks;
}
