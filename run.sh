#!/usr/bin/env sh
# Dev wrapper — thin pass-through to the installed jacket commands.
#
# Requires a one-time editable install from the checkout:
#   jac install -e .
# (see docs/getting-started.md). After that, use the console commands
# directly; this wrapper only exists for habit and for running an
# explicit in-repo .jac entrypoint.
#
# gtk4-layer-shell is loaded globally from jacket/adapter.jac
# (ctypes.CDLL before `import gi`), so it is in place before GTK opens
# the Wayland display. No LD_PRELOAD is required.
#
# Usage:
#   ./run.sh                              # same as: jacket run
#   ./run.sh --watch                      # dev mode
#   ./run.sh examples/minimal/main.jac    # explicit .jac entrypoint

# Explicit .jac/.py entrypoint (library dev / examples).
case "$1" in
    *.jac|*.py)
        exec jac run "$@"
        ;;
esac

exec jacket "$@"
