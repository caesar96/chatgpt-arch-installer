#!/usr/bin/env python3
"""Export Electron menu trees through the stable GLib DBusMenu server API."""

import json
import sys
import threading

try:
    import gi

    gi.require_version("Dbusmenu", "0.4")
    from gi.repository import Dbusmenu, Gio, GLib
except Exception as error:  # pragma: no cover - depends on the host
    print(json.dumps({"event": "error", "message": f"GLib DBusMenu unavailable: {error}"}), flush=True)
    raise SystemExit(2)


REGISTRAR_SERVICE = "com.canonical.AppMenu.Registrar"
REGISTRAR_PATH = "/com/canonical/AppMenu/Registrar"
REGISTRAR_INTERFACE = "com.canonical.AppMenu.Registrar"


def emit(message):
    print(json.dumps(message, separators=(",", ":")), flush=True)


class Bridge:
    def __init__(self):
        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self.registrar = Gio.DBusProxy.new_sync(
            self.bus,
            Gio.DBusProxyFlags.NONE,
            None,
            REGISTRAR_SERVICE,
            REGISTRAR_PATH,
            REGISTRAR_INTERFACE,
            None,
        )
        self.servers = {}
        self.roots = {}
        self.items = {}
        self.loop = GLib.MainLoop()

    @staticmethod
    def path_for(window_id):
        return f"/com/openai/codex/globalmenu/{int(window_id):X}"

    @staticmethod
    def set_properties(item, node):
        if node.get("type") == "separator":
            item.property_set("type", "separator")
        else:
            item.property_set("label", str(node.get("label", "")))
            item.property_set_bool("enabled", bool(node.get("enabled", True)))
            item.property_set_bool("visible", bool(node.get("visible", True)))
            if node.get("children"):
                item.property_set("children-display", "submenu")
            if node.get("type") == "checkbox":
                item.property_set("toggle-type", "checkmark")
                item.property_set_int("toggle-state", 1 if node.get("checked") else 0)
            elif node.get("type") == "radio":
                item.property_set("toggle-type", "radio")
                item.property_set_int("toggle-state", 1 if node.get("checked") else 0)

        accelerator = node.get("accelerator") or []
        if accelerator:
            shortcut = GLib.Variant("aas", [[str(part) for part in accelerator]])
            item.property_set_variant("shortcut", shortcut)

    def build_item(self, node, window_id, item_map):
        item_id = int(node["id"])
        item = Dbusmenu.Menuitem.new_with_id(item_id)
        self.set_properties(item, node)
        item_map[item_id] = item
        item.connect("item-activated", self.item_activated, int(window_id), item_id)
        for child in node.get("children") or []:
            item.child_append(self.build_item(child, window_id, item_map))
        return item

    def item_activated(self, _item, timestamp, window_id, item_id):
        emit({
            "event": "activate",
            "window_id": int(window_id),
            "item_id": int(item_id),
            "timestamp": int(timestamp),
        })

    def register_window(self, window_id, menu):
        window_id = int(window_id)
        server = self.servers.get(window_id)
        if server is None:
            path = self.path_for(window_id)
            server = Dbusmenu.Server.new(path)
            self.servers[window_id] = server
            self.registrar.call_sync(
                "RegisterWindow",
                GLib.Variant("(uo)", (window_id, path)),
                Gio.DBusCallFlags.NONE,
                -1,
                None,
            )

        root = Dbusmenu.Menuitem.new_with_id(0)
        root.set_root(True)
        item_map = {0: root}
        for node in menu:
            root.child_append(self.build_item(node, window_id, item_map))
        server.set_root(root)
        self.roots[window_id] = root
        self.items[window_id] = item_map

    def unregister_window(self, window_id):
        window_id = int(window_id)
        if window_id not in self.servers:
            return
        try:
            self.registrar.call_sync(
                "UnregisterWindow",
                GLib.Variant("(u)", (window_id,)),
                Gio.DBusCallFlags.NONE,
                -1,
                None,
            )
        finally:
            self.items.pop(window_id, None)
            self.roots.pop(window_id, None)
            self.servers.pop(window_id, None)

    def set_menu(self, message):
        wanted = {int(window_id) for window_id in message.get("windows", [])}
        for window_id in list(self.servers):
            if window_id not in wanted:
                self.unregister_window(window_id)
        menu = message.get("menu") or []
        for window_id in wanted:
            self.register_window(window_id, menu)

    def handle(self, message):
        try:
            message_type = message.get("type")
            if message_type == "set-menu":
                self.set_menu(message)
            elif message_type == "remove-window":
                self.unregister_window(message["window_id"])
            elif message_type == "shutdown":
                self.close()
        except Exception as error:  # pragma: no cover - target-session dependent
            emit({"event": "error", "message": str(error)})
        return False

    def close(self):
        for window_id in list(self.servers):
            try:
                self.unregister_window(window_id)
            except Exception:
                pass
        self.loop.quit()


def read_commands(bridge):
    for line in sys.stdin:
        try:
            message = json.loads(line)
            GLib.idle_add(bridge.handle, message)
        except Exception as error:
            emit({"event": "error", "message": f"invalid command: {error}"})
    GLib.idle_add(bridge.close)


try:
    bridge = Bridge()
except Exception as error:  # pragma: no cover - target-session dependent
    emit({"event": "error", "message": str(error)})
    raise SystemExit(3)

threading.Thread(target=read_commands, args=(bridge,), daemon=True).start()
emit({"event": "ready"})
bridge.loop.run()
