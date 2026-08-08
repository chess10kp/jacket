#!/usr/bin/env sh
# Launch the shell. gtk4-layer-shell MUST be preloaded so it hooks libwayland
# before GTK opens the display — otherwise the bar falls back to a plain,
# unanchored window. (See https://github.com/wmww/gtk4-layer-shell/blob/main/linking.md)
#
# Usage:
#   ./run.sh                              # full reference bar (default)
#   ./run.sh examples/minimal/main.jac    # minimal bootstrap from LIBRARY.md
LIB=$(ls /usr/lib*/libgtk4-layer-shell.so 2>/dev/null | head -n1)
ENTRY="${1:-$(dirname "$0")/examples/reference/main.jac}"
shift 2>/dev/null || true
exec env LD_PRELOAD="$LIB" jac run "$ENTRY" "$@"
