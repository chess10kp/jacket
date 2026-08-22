# busname.jac — generic DBus well-known-name ownership.
# ---------------------------------------------------------------------------
# One mechanism for "jacket serves interface X under well-known name Y":
#   1. connect to the session bus (quiet no-op when absent),
#   2. claim the name via Gio.bus_own_name,
#   3. register the introspection XML's interface at the given object path,
#   4. watch org.freedesktop.DBus.NameOwnerChanged — when the current holder
#      exits while we do NOT own the name, claim it again automatically.
#
# Step 4 is the crash-recovery story: while we own the name nothing fires;
# if a competing daemon held it at startup and later exits, we take over
# without a restart. Callers stay protocol-specific: they hand in their
# introspection XML plus a method dispatcher and get an owner back.
#
# The jacket.glib import is load-bearing: its bootstrap bridges jac's isolated
# sys.path to the interpreter site-packages, which is what makes the gi
# import below resolvable at all.
import from jacket.glib { timeout_add }
import from gi.repository { Gio }


obj BusNameOwner {
    has name: str;
    has path: str;
    has iface_xml: str;
    # Caller callbacks: method_call(c, sender, p, iface, method, params,
    # invocation); get_property(c, sender, p, iface, prop) -> Variant|None;
    # on_acquired(conn).
    has method_call: any;
    has get_property: any = None;
    has on_acquired: any = None;
    has on_lost: any = None;
    has conn: any = None;
    has iface: any = None;
    has registered_conn: any = None;
    has active: bool = True;             # release() disarms auto-reclaim
    has owned: bool = False;
    has owner_id: any = None;

    def postinit() {
        try {
            self.conn = Gio.bus_get_sync(Gio.BusType.SESSION, None);
        } except Exception {
            return;                                    # headless: stay quiet
        }
        try {
            info: any = Gio.DBusNodeInfo.new_for_xml(self.iface_xml);
            self.iface = info.interfaces[0];
        } except Exception {
            return;
        }
        self.conn.signal_subscribe(
            "org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged",
            "/org/freedesktop/DBus", self.name,
            Gio.DBusSignalFlags.NONE, self._on_name_owner_changed);
        self.claim();
    }

    # Claim the name now, unless we already hold it. Safe to call repeatedly:
    # NameOwnerChanged drives it after a competing holder exits.
    def claim() {
        if not self.active or self.owned or self.conn is None or self.iface is None { return; }
        if self.owner_id is not None {
            try {
                Gio.bus_unown_name(self.owner_id);
            } except Exception as e {
                _ = e;
            }
        }
        self.owner_id = Gio.bus_own_name(
            Gio.BusType.SESSION, self.name, Gio.BusNameOwnerFlags.NONE,
            self._on_bus_acquired, self._on_name_acquired, self._on_name_lost);
    }

    def _on_bus_acquired(c: any, n: str) {
        # bus_own_name attempts can repeat; the connection (and thus the
        # registered object) is usually the same one. Re-registering the same
        # path/interface raises, so guard instead of silently failing.
        if self.registered_conn is c { return; }
        try {
            c.register_object(self.path, self.iface, self.method_call,
                              self.get_property, None);
            self.registered_conn = c;
        } except Exception { }
    }

    def _on_name_acquired(c: any, n: str) {
        self.owned = True;
        if self.on_acquired is not None {
            try { self.on_acquired(c); } except Exception { }
        }
    }

    def _on_name_lost(c: any, n: str) {
        self.owned = False;
        if self.on_lost is not None {
            try { self.on_lost(c); } except Exception { }
        }
    }

    # Fires only for our watched name (arg0 filter). Empty new_owner means
    # the previous holder is gone — take the name if we don't have it.
    def _on_name_owner_changed(c: any, sender: str, p: str, iface: str,
                               signal: str, params: any) {
        try {
            res: list = params.unpack();
            noc_name = res[0];
            new_owner = res[2];
        } except Exception {
            return;
        }
        if noc_name == self.name and new_owner == "" and not self.owned {
            self.claim();
        }
    }

    # Give the name up for good (tests, shutdown). Disarms the
    # NameOwnerChanged watcher so freeing the name does not instantly
    # re-trigger a claim.
    def release() {
        self.active = False;
        if self.owner_id is not None {
            try { Gio.bus_unown_name(self.owner_id); } except Exception as e { _ = e; }
        }
        self.owner_id = None;
        self.owned = False;
    }
}


# Claim `name` for `iface_xml` served at `path`. Returns the owner handle, or
# None when there is no session bus (the handle stays a quiet no-op there).
def own_name(name: str, path: str, iface_xml: str, method_call: any,
             get_property: any = None, on_acquired: any = None,
             on_lost: any = None) -> BusNameOwner | None {
    try {
        Gio.bus_get_sync(Gio.BusType.SESSION, None);
    } except Exception {
        return None;
    }
    return BusNameOwner(name=name, path=path, iface_xml=iface_xml,
                        method_call=method_call, get_property=get_property,
                        on_acquired=on_acquired, on_lost=on_lost);
}
