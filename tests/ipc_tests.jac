# ipc_tests.jac — headless tests for src/ipc.jac handler logic.
import from src.ipc { IPC }


test "handle status_line with no args" {
    h = IPC();
    h.register("a", lambda { "1"; });
    h.register("b", lambda { "two"; });
    assert h.handle([]) == "a=1  b=two";
}

test "handle status command" {
    h = IPC();
    h.register("x", lambda { "val"; });
    assert h.handle(["status"]) == "x=val";
}

test "handle list returns registered names" {
    h = IPC();
    h.register("clock", lambda { ""; });
    h.register("mem", lambda { ""; });
    out = h.handle(["list"]);
    assert "clock" in out;
    assert "mem" in out;
}

test "handle named getter" {
    h = IPC();
    h.register("stocks", lambda { "L:1 C:2"; });
    assert h.handle(["stocks"]) == "L:1 C:2";
}

test "handle unknown command" {
    h = IPC();
    assert h.handle(["bogus"]) == "unknown command: bogus";
}

test "handle getter failure returns empty value" {
    h = IPC();
    h.register("bad", lambda { raise ValueError("fail"); });
    assert h.handle(["bad"]) == "";
}

test "status_line shows name= for empty getter" {
    h = IPC();
    h.register("empty", lambda { ""; });
    assert h.handle(["status"]) == "empty=";
}
