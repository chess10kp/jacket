# Release notes

## 0.1.0 — package namespace: `src/` is now `jacket/` (BREAKING)

jacket is now an installable wheel instead of a checkout you run scripts
from. Three visible changes:

### 1. The import namespace moved: `src.*` → `jacket.*`

Every consumer config, example, and template must rewrite its imports.
Mechanical fix:

```bash
grep -rlE 'from src[.]' ~/.config/jacket | xargs sed -i 's/from src\./from jacket./g'
```

Anything matching `from src.` or `import src` outside the repo's `.attic/`
is now rejected by CI.

### 2. `bin/jacket` and `bin/jacket-ctl` are gone — use console commands

The ROOT-coupled scripts are replaced by real entry points installed with
the wheel (`jacket`, `jacket-ctl`). They no longer depend on where a
checkout lives; configs resolve through the installed (or editable)
package. `JACKET_ROOT` is a removed contract and is ignored.

```bash
jac build --as wheel && jac install dist/jacket-*.whl
jacket init -c mybar && jacket run -c mybar
jacket status --json          # IPC, same wire protocol as before
```

### 3. Templates live in the package

`packaging/config-template/` moved to `jacket/config_template/` and ships
inside the wheel; `jacket init` scaffolds from the installed copy. If you
symlinked or copied the old path, re-scaffold once.

### Also in this cycle

- `run.sh` is a thin dev wrapper now (editable install + `.jac`
  passthrough); session plumbing stays in `packaging/install.sh`.
- `jac build --as wheel` passes the full type-check gate; the wheel was
  verified by installing it into a clean consumer project with the repo
  checkout removed.
