#!/usr/bin/env sh
# Launch the shell.
#
# gtk4-layer-shell is loaded globally from src/adapter.jac (ctypes.CDLL before
# `import gi`), so it is in place before GTK opens the Wayland display. No
# LD_PRELOAD is required.
#
# Usage:
#   ./run.sh                              # user config (auto-inits on first run)
#   ./run.sh --watch                      # dev mode (user config)
#   ./run.sh launcher toggle              # fast socket IPC
#   ./run.sh status --json
#   ./run.sh examples/minimal/main.jac    # alternate entrypoint
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE" || exit 1

JACKET="$HERE/bin/jacket"

# Fast path: Unix socket when the bar is already running.
if [ "$#" -gt 0 ] && [ -x "$HERE/bin/jacket-ctl" ]; then
    case "$1" in
        status|mode|why|affected-by|quit|reload|toggle|stocks)
            exec "$HERE/bin/jacket-ctl" "$@"
            ;;
    esac
fi

# Explicit .jac entrypoint (library dev / examples).
case "$1" in
    *.jac|*.py)
        exec jac run "$@"
        ;;
esac

# User config via jacket CLI when available.
if [ -x "$JACKET" ]; then
    WATCH=""
    if [ "$1" = "--watch" ]; then
        WATCH="--watch"
        shift
    fi
    # `./run.sh run` is a common mistake — don't forward "run" to IPC.
    if [ "$1" = "run" ]; then
        shift
    fi
    exec "$JACKET" run $WATCH "$@"
fi

# Fallback: reference bar from the repo.
exec jac run "$HERE/examples/reference/main.jac" "$@"
