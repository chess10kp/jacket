# main.jac — package-root entry for `jac build --as binary`.
#
# The sealed executable runs this module. Jac executes `with entry` blocks of
# imported modules as well as the root's, so merely importing
# examples/reference.main RUNS its authoritative entry (verified: a duplicate
# entry here made the sealed binary call run_with_ipc twice — the second
# GApplication command-line forward crashed GLib with
# g_application_impl_command_line: assertion 'object_id != 0', because
# /org/gtk/Application/CommandLine was already registered on this process's
# shared session-bus connection).
#
# So: no `with entry` here. The imports below trigger the reference entry;
# keep the item list non-empty (Jac requires at least one imported item).
# If examples/reference/main.jac's entry changes, nothing here needs to
# change — e2e tests cover the packaged path via dist/jacket.
import from jacket.adapter { apply_css, run_with_ipc }
import from jacket.glib { idle_add }
import from jacket.reactive { set_flush_hook }
import from examples.reference.main { install, on_activate, ipc }
import from examples.reference.style { CSS }
