# config.jac — user shell config resolution (~/.config/jacket/<name>/).
# ---------------------------------------------------------------------------
import os;


glob DEFAULT_CONFIG_NAME: str = "default";


def config_home() -> str {
    base = os.environ.get("XDG_CONFIG_HOME");
    if base is None or base == "" {
        home = os.environ.get("HOME", "");
        if home == "" { return "/etc/jacket"; }
        return os.path.join(home, ".config", "jacket");
    }
    return os.path.join(base, "jacket");
}


def resolve_config(name: str = "") -> dict {
    n = name if name != "" else DEFAULT_CONFIG_NAME;
    dir = os.path.join(config_home(), n);
    shell = os.path.join(dir, "shell.jac");
    theme = os.path.join(dir, "theme.css");
    return {"name": n, "dir": dir, "shell": shell, "theme_css": theme};
}


def validate_config(cfg: dict) -> str {
    shell = str(cfg["shell"]);
    name = str(cfg["name"]);
    if not os.path.isfile(shell) {
        return (
            "config not found: " + shell
            + " (run: jacket init -c " + name + ")"
        );
    }
    return "";
}
