# dev_watch_tests.jac — config resolution and dev-watch helpers.
# ---------------------------------------------------------------------------
import os;
import tempfile;
import from src.config { config_home, resolve_config, validate_config }
import from src.dev_watch { is_ignored_watch_path, WATCH_DEBOUNCE_MS }


test "resolve_config builds paths under XDG_CONFIG_HOME/jacket" {
    td = tempfile.mkdtemp();
    os.environ["XDG_CONFIG_HOME"] = td;
    cfg = resolve_config("mybar");
    assert cfg["name"] == "mybar";
    assert cfg["dir"].endswith(os.path.join("jacket", "mybar"));
    assert cfg["shell"].endswith(os.path.join("jacket", "mybar", "shell.jac"));
    assert cfg["theme_css"].endswith(os.path.join("jacket", "mybar", "theme.css"));
}


test "validate_config errors when shell.jac is missing" {
    td = tempfile.mkdtemp();
    os.environ["XDG_CONFIG_HOME"] = td;
    cfg = resolve_config("missing");
    err = validate_config(cfg);
    assert "config not found" in err;
    assert "jacket init" in err;
}


test "validate_config passes when shell.jac exists" {
    td = tempfile.mkdtemp();
    os.environ["XDG_CONFIG_HOME"] = td;
    cfg = resolve_config("ok");
    os.makedirs(cfg["dir"], exist_ok=True);
    with open(cfg["shell"], "w", encoding="utf-8") as f {
        f.write("# stub\n");
    }
    assert validate_config(cfg) == "";
}


test "is_ignored_watch_path skips temp and cache paths" {
    assert is_ignored_watch_path("");
    assert is_ignored_watch_path("/tmp/foo/__pycache__/x.jac");
    assert is_ignored_watch_path("/tmp/foo/bar.jacir");
    assert is_ignored_watch_path("/tmp/foo/bar.jac~");
    assert is_ignored_watch_path("/tmp/foo/.bar.jac.swp");
    assert not is_ignored_watch_path("/home/u/.config/jacket/default/components.jac");
}


test "WATCH_DEBOUNCE_MS is a positive debounce window" {
    assert WATCH_DEBOUNCE_MS >= 300;
}
