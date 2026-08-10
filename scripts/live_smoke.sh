#!/usr/bin/env bash
# live_smoke.sh — §5.4 Wayland integration smoke (skips when no compositor/gi).
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ -z "${DISPLAY:-}" ]; then
  echo "SKIP live smoke: no WAYLAND_DISPLAY or DISPLAY"
  exit 0
fi
# Prior timed-out runs can leave jac holding org.jac.shell.smoke on the session bus.
pkill -f "jac run.*examples/smoke/main.jac" 2>/dev/null || true
sleep 0.5
# Preflight gi on the Jac bundled interpreter (system python3 may differ).
JAC_PY="$(ls -1 "$HOME/.cache/jac/rt/"*/python/bin/python3* 2>/dev/null | head -n1)"
if [ -z "$JAC_PY" ] || ! "$JAC_PY" -c "import gi" >/dev/null 2>&1; then
  echo "SKIP live smoke: gi (PyGObject) not available in Jac runtime (run packaging/install.sh)"
  exit 0
fi
out="$(timeout --kill-after=5s 120s "$HERE/run.sh" "$HERE/examples/smoke/main.jac" 2>&1)" || {
  echo "$out"
  exit 1
}
echo "$out"
echo "$out" | grep -q "SMOKE OK"
