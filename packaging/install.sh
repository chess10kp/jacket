#!/usr/bin/env bash
# install.sh — set up jac-shell to run on a real session.
#
# Two things stand between a fresh checkout and a running shell:
#   1. Jac ships its own bundled Python that can't see the system PyGObject
#      (`gi`). We drop a `system_site.pth` into every Jac runtime site-packages
#      pointing at the system's, so `import gi` resolves.
#   2. gtk4-layer-shell must be LD_PRELOADed before GTK opens the display
#      (run.sh already handles this) — we just install a systemd user unit that
#      launches run.sh at graphical-session start.
#
# Idempotent: safe to re-run after a Jac upgrade (which mints a new runtime dir).
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"          # …/shell
RUN_SH="$HERE/run.sh"

# --- 1. Expose the system `gi` to Jac's bundled Python ----------------------
SYS_SITE="$(python3 -c 'import gi, os; print(os.path.dirname(os.path.dirname(gi.__file__)))')"
echo "system gi site-packages: $SYS_SITE"

shopt -s nullglob
JAC_SITES=(
  "$HOME/.cache/jac/rt/"*/python/lib/python*/site-packages
)
if [ ${#JAC_SITES[@]} -eq 0 ]; then
  # Prime the runtime by touching jac once, then look again.
  jac --version >/dev/null 2>&1 || true
  JAC_SITES=("$HOME/.cache/jac/rt/"*/python/lib/python*/site-packages)
fi

if [ ${#JAC_SITES[@]} -eq 0 ]; then
  echo "!! no Jac runtime site-packages found under ~/.cache/jac/rt — run 'jac run $HERE/examples/reference/main.jac' once, then re-run this script." >&2
else
  for site in "${JAC_SITES[@]}"; do
    [[ "$site" == *.tmp.* ]] && continue
    echo "$SYS_SITE" > "$site/system_site.pth"
    echo "  wrote $site/system_site.pth"
  done
fi

# --- 2. Verify layer-shell is preloadable -----------------------------------
if ! ls /usr/lib*/libgtk4-layer-shell.so >/dev/null 2>&1; then
  echo "!! libgtk4-layer-shell.so not found — install gtk4-layer-shell for anchored bars." >&2
fi

# --- 3. Install the systemd user unit ---------------------------------------
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
mkdir -p "$UNIT_DIR"
# Rewrite ExecStart to this checkout's real run.sh (handles non-default paths).
sed "s|^ExecStart=.*|ExecStart=$RUN_SH|" \
  "$HERE/packaging/jac-shell.service" > "$UNIT_DIR/jac-shell.service"
echo "installed $UNIT_DIR/jac-shell.service (ExecStart=$RUN_SH)"

systemctl --user daemon-reload 2>/dev/null || true

cat <<EOF

Done. To start the shell now and on every login:

    systemctl --user enable --now jac-shell.service

Follow its logs with:

    journalctl --user -u jac-shell -f

(If your compositor doesn't hand off to the systemd user session, skip the unit
and launch $RUN_SH from your compositor's autostart instead.)
EOF
