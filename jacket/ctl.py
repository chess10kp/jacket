"""jacket-ctl — send a command to the running jacket bar.

Fast Unix-socket path with a GApplication fallback so the desktop shell
can also route requests. Console entry point (see
[entrypoints.scripts] in jac.toml).
"""
from __future__ import annotations

import os
import socket
import sys


def _sock_path() -> str:
    return os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "jacket.sock")


def _unlink_stale(path: str) -> None:
    try:
        os.unlink(path)
    except OSError:
        pass


def _via_socket(argv: list[str]) -> str | None:
    path = _sock_path()
    if not os.path.exists(path):
        return None
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(2.0)
            s.connect(path)
            s.sendall((" ".join(argv) + "\n").encode())
            return s.recv(65536).decode().strip()
    except (ConnectionRefusedError, ConnectionError, TimeoutError):
        # Socket file left behind after the bar exited or crashed.
        _unlink_stale(path)
        return None
    except OSError:
        _unlink_stale(path)
        return None


def _via_gio(argv: list[str]) -> int:
    from gi.repository import Gio

    app = Gio.Application.new(
        "org.jac.shell",
        Gio.ApplicationFlags.HANDLES_COMMAND_LINE,
    )

    def command_line(_app, cmd):
        if cmd.get_is_remote():
            return 0
        print(
            "jacket bar is not running (start with: jacket run)",
            file=sys.stderr,
        )
        return 1

    app.connect("command-line", command_line)
    return app.run(["jacket-ctl", *argv])


def main(argv: list[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv[1:]
    if not argv:
        print("usage: jacket-ctl <command> [args...]", file=sys.stderr)
        return 2
    resp = _via_socket(argv)
    if resp is not None:
        print(resp)
        return 1 if resp.startswith("error") else 0
    return _via_gio(argv)


if __name__ == "__main__":
    sys.exit(main())
