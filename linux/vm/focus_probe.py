#!/usr/bin/env python3
import os
import time

os.environ["GDK_BACKEND"] = "wayland"
import gi  # noqa: E402

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk  # noqa: E402

log = open("/tmp/focus-probe.log", "a", buffering=1)
w = Gtk.Window(title="Meeting app (focus probe)")
entry = Gtk.Entry()
entry.set_text("typing here")
w.add(entry)
w.connect("notify::is-active", lambda win, _p: log.write("%.3f active=%s\n" % (time.time(), win.is_active())))
entry.connect("changed", lambda e: log.write("%.3f text=%s\n" % (time.time(), e.get_text())))
w.connect("destroy", Gtk.main_quit)
w.maximize()
w.show_all()
Gtk.main()
