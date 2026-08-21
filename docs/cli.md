# jacket CLI reference

Two binaries ship with jacket: `jacket` (manage your shell) and `jacket-ctl`
(talk to a running shell).

## `jacket`

| Command | Purpose |
|---|---|
| `jacket init <name>` | Scaffold `~/.config/jacket/<name>/` from the template |
| `jacket run -c <name>` | Start the shell from that config |
| `jacket run -c <name> --watch` | Start in dev-watch mode |

Extra args after the command are passed through to the entry.

### Config layout

```
~/.config/jacket/<name>/
  shell.jac        # entry bootstrap
  components.jac   # your bar widgets
  launcher_ui.jac  # optional overlays (from template)
  notif_ui.jac
  theme.css        # GTK4 CSS
```

`JACKET_CONFIG_DIR` / `JACKET_CONFIG_NAME` override resolution (see
`src/config.jac`).

### Watch mode

| Change | Behavior |
|---|---|
| `theme.css` | hot-applies in-process (`apply_css_file`), no restart |
| any `.jac` file | debounced `jac check`; on success restarts, on syntax error keeps last good bar running and logs to stderr |

`jacket reload` forces the same restart manually.

## `jacket-ctl`

Sends commands to a running bar over a fast Unix socket
(`$XDG_RUNTIME_DIR/jacket.sock`), falling back to GApplication remote
activation.

| Command | Purpose |
|---|---|
| `jacket-ctl status` | Dump registered status getters |
| `jacket-ctl list` | List registered command names |
| `jacket-ctl <name>` | Invoke a getter you registered via `IPC.register(name, fn)` |
| `jacket-ctl toggle` | Toggle the bar |
| `jacket-ctl quit` | Quit the shell |

If no bar is running, `jacket-ctl` exits non-zero with a hint. Registering
your own commands is covered in [guide.md §10](guide.md#10-ipc-commands-srcipcjac).

## Packaging / install

`packaging/install.sh` bootstraps the Jac-runtime `system_site.pth` so the
sealed binary resolves system `gi`. A systemd user unit is provided at
`packaging/jacket.service`.
