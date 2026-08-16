#!/usr/bin/env sh
# Launch the shell.
#
# gtk4-layer-shell is loaded globally from src/adapter.jac (ctypes.CDLL before
# `import gi`), so it is in place before GTK opens the Wayland display. No
# LD_PRELOAD is required. If anchoring ever regresses, the old preload shim is
# in git history — but please treat that as a bug in the early-load path, not
# the supported fix.
#
# Usage:
#   ./run.sh                              # start the reference bar (server)
#   ./run.sh status --json                # IPC to the running instance
#   ./run.sh mode enter presentation
#   ./run.sh examples/minimal/main.jac    # alternate entrypoint
DEFAULT="$(dirname "$0")/examples/reference/main.jac"
ENTRY="$DEFAULT"
case "$1" in
    *.jac|*.py)
        ENTRY="$1"
        shift
        ;;
esac
exec jac run "$ENTRY" "$@"
