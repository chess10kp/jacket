# lockscreen_tests.jac — headless tests for the session lock (jacket/lockscreen.jac).
# The pure state machine is checked directly; the daemon runs against an
# injected fake verifier (never PAM) with results pumped through the real
# GLib main loop via glib.run_for — the same path the live UI exercises.
import from jacket.lockscreen {
    check_lock, resolve_lock, clear_error, is_session_open,
    LockDaemon,
}
import from jacket.glib { run_for }


# Named verifier fns — never PAM in tests. (A fn RETURNING a lambda trips a
# Jac codegen bug: __jac_lambda_N is not defined at call time.)
def verify_ok(pw: str) -> bool { return True; }
def verify_bad(pw: str) -> bool { return False; }

# Pump the loop until the daemon reaches `want` (thread + idle round trip) or
# fail after ~2s. Returns True on success so asserts read plainly.
def wait_state(d: LockDaemon, want: str) -> bool {
    for _ in range(40) {
        if d.state.peek() == want { return True; }
        run_for(50);
    }
    return d.state.peek() == want;
}


# --- pure state machine ----------------------------------------------------
test "check_lock: locked and failed move to checking" {
    assert check_lock("locked") == "checking";
    assert check_lock("failed") == "checking";
}

test "check_lock: checking/unlocked are sticky" {
    assert check_lock("checking") == "checking";
    assert check_lock("unlocked") == "unlocked";
}

test "resolve_lock: verdict only lands on a pending check" {
    assert resolve_lock("checking", True) == "unlocked";
    assert resolve_lock("checking", False) == "failed";
    assert resolve_lock("locked", True) == "locked";      # stale result dropped
    assert resolve_lock("unlocked", False) == "unlocked";
}

test "clear_error: only failed resets to locked" {
    assert clear_error("failed") == "locked";
    assert clear_error("locked") == "locked";
    assert clear_error("unlocked") == "unlocked";
}

test "is_session_open: only unlocked counts" {
    assert is_session_open("unlocked");
    assert not is_session_open("locked");
    assert not is_session_open("checking");
    assert not is_session_open("failed");
}


# --- daemon (fake verifier, real GLib pump) ---------------------------------
test "daemon: starts unlocked at rest" {
    d = LockDaemon(verify=verify_ok);
    assert d.state.peek() == "unlocked";
    assert d.session_open();
}

test "daemon: correct password unlocks through the async path" {
    d = LockDaemon(verify=verify_ok);
    d.lock();
    assert d.state.peek() == "locked";
    assert not d.session_open();
    d.submit("hunter2");
    assert wait_state(d, "unlocked");
}

test "daemon: wrong password lands on failed; typing clears it" {
    d = LockDaemon(verify=verify_bad);
    d.lock();
    d.submit("nope");
    assert wait_state(d, "failed");
    d.reset_prompt();
    assert d.state.peek() == "locked";
}

test "daemon: re-lock after unlock works" {
    d = LockDaemon(verify=verify_ok);
    d.submit("x");                          # ignored: already unlocked
    assert d.state.peek() == "unlocked";
    d.lock();
    assert d.state.peek() == "locked";
    d.submit("pw");
    assert wait_state(d, "unlocked");
    d.lock();
    assert d.state.peek() == "locked";
}

test "daemon: empty submit never checks and clears a failure" {
    d = LockDaemon(verify=verify_bad);
    d.lock();
    d.submit("bad");
    assert wait_state(d, "failed");
    d.submit("");
    assert d.state.peek() == "locked";      # back to clean prompt, no check ran
}

test "daemon: user defaults to the current user" {
    d = LockDaemon(verify=verify_ok);
    assert d.user != "";
}
