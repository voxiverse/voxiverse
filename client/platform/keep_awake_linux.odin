package platform

import "core:dynlib"
import "core:log"
import "core:reflect"
import "core:time"

// Keeping the screen awake on Linux: the freedesktop screensaver Inhibit
// call over D-Bus (GNOME, KDE, Xfce, hypridle and others honour it),
// through libdbus loaded at run time like libX11; and, for X's own
// blanking, XResetScreenSaver every half minute (native_poll).

@(private = "file")
DBus :: struct {
	__handle:                                  dynlib.Library,
	dbus_error_init:                           proc "c" (err: rawptr),
	dbus_error_is_set:                         proc "c" (err: rawptr) -> b32,
	dbus_error_free:                           proc "c" (err: rawptr),
	dbus_bus_get:                              proc "c" (kind: i32, err: rawptr) -> rawptr,
	dbus_message_new_method_call:              proc "c" (
		dest, path, iface, method: cstring,
	) -> rawptr,
	dbus_message_iter_init_append:             proc "c" (msg, iter: rawptr),
	dbus_message_iter_append_basic:            proc "c" (
		iter: rawptr,
		kind: i32,
		value: rawptr,
	) -> b32,
	dbus_message_iter_init:                    proc "c" (msg, iter: rawptr) -> b32,
	dbus_message_iter_get_arg_type:            proc "c" (iter: rawptr) -> i32,
	dbus_message_iter_get_basic:               proc "c" (iter: rawptr, value: rawptr),
	dbus_connection_send_with_reply_and_block: proc "c" (
		conn, msg: rawptr,
		timeout_ms: i32,
		err: rawptr,
	) -> rawptr,
	dbus_connection_send:                      proc "c" (conn, msg: rawptr, serial: ^u32) -> b32,
	dbus_connection_flush:                     proc "c" (conn: rawptr),
	dbus_message_unref:                        proc "c" (msg: rawptr),
	dbus_message_iter_open_container:          proc "c" (
		iter: rawptr,
		kind: i32,
		signature: cstring,
		sub: rawptr,
	) -> b32,
	dbus_message_iter_close_container:         proc "c" (iter, sub: rawptr) -> b32,
}

@(private = "file")
dbus: DBus
@(private = "file")
dbus_tried: bool
@(private = "file")
inhibit_cookie: u32 // 0: not inhibiting (the screensaver's way)
@(private = "file")
portal_request: [256]u8 // the portal's request handle (an object path; empty: none)

// Opaque libdbus structs, bigger than they are (DBusError, DBusMessageIter).
@(private = "file")
Opaque :: struct #align (16) {
	_: [32]rawptr,
}

@(private = "file")
DBUS_BUS_SESSION :: 0
@(private = "file")
TYPE_STRING :: 's'
@(private = "file")
TYPE_UINT32 :: 'u'
@(private = "file")
TYPE_OBJECT_PATH :: 'o'
@(private = "file")
TYPE_ARRAY :: 'a'

@(private = "file")
PORTAL :: cstring("org.freedesktop.portal.Desktop")
@(private = "file")
PORTAL_PATH :: cstring("/org/freedesktop/portal/desktop")
@(private = "file")
PORTAL_INHIBIT_IDLE :: 8

@(private = "file")
SCREENSAVER :: cstring("org.freedesktop.ScreenSaver")
@(private = "file")
SCREENSAVER_PATH :: cstring("/org/freedesktop/ScreenSaver")

// warned: a failure to hold the screensaver off is told once per run.
@(private = "file")
warned: bool

@(private = "file")
warn_once :: proc(text: string) {
	if warned {return}
	warned = true
	log.info(text)
}

@(private = "file")
dbus_ready :: proc() -> bool {
	if !dbus_tried {
		dbus_tried = true
		count, ok := dynlib.initialize_symbols(&dbus, "libdbus-1.so.3")
		if !ok || count != reflect.struct_field_count(DBus) - 1 {
			warn_once("platform libdbus not available: the screensaver is not held off")
			dbus.__handle = nil
		}
	}
	return dbus.__handle != nil
}

// screensaver_inhibit asks the session's screensaver to hold off (or lets
// it be). The Inhibit call waits for its answer (a cookie), at most a
// fraction of a second, once per change.
@(private)
screensaver_inhibit :: proc(on: bool) {
	if !dbus_ready() {return}
	err: Opaque
	dbus.dbus_error_init(&err)
	defer dbus.dbus_error_free(&err)
	conn := dbus.dbus_bus_get(DBUS_BUS_SESSION, &err)
	if conn == nil || dbus.dbus_error_is_set(&err) {
		warn_once("platform no D-Bus session: the screensaver is not held off")
		return
	}
	if on {
		if inhibit_cookie != 0 {return}
		msg := dbus.dbus_message_new_method_call(
			SCREENSAVER,
			SCREENSAVER_PATH,
			SCREENSAVER,
			"Inhibit",
		)
		if msg == nil {return}
		defer dbus.dbus_message_unref(msg)
		iter: Opaque
		dbus.dbus_message_iter_init_append(msg, &iter)
		app, reason := cstring("Voxiverse"), cstring("Playing")
		dbus.dbus_message_iter_append_basic(&iter, TYPE_STRING, &app)
		dbus.dbus_message_iter_append_basic(&iter, TYPE_STRING, &reason)
		reply := dbus.dbus_connection_send_with_reply_and_block(conn, msg, 500, &err)
		if reply == nil || dbus.dbus_error_is_set(&err) {
			dbus.dbus_error_free(&err)
			dbus.dbus_error_init(&err)
			portal_inhibit(conn, &err)
			return
		}
		defer dbus.dbus_message_unref(reply)
		out: Opaque
		if dbus.dbus_message_iter_init(reply, &out) &&
		   dbus.dbus_message_iter_get_arg_type(&out) == TYPE_UINT32 {
			dbus.dbus_message_iter_get_basic(&out, &inhibit_cookie)
		}
		log.debugf("platform keep awake on (screensaver inhibited, cookie=%d)", inhibit_cookie)
	} else {
		if portal_request[0] != 0 {
			path := cstring(&portal_request[0])
			msg := dbus.dbus_message_new_method_call(
				PORTAL,
				path,
				"org.freedesktop.portal.Request",
				"Close",
			)
			if msg != nil {
				dbus.dbus_connection_send(conn, msg, nil)
				dbus.dbus_connection_flush(conn)
				dbus.dbus_message_unref(msg)
			}
			log.debugf("platform keep awake off (portal request %s closed)", path)
			portal_request = {}
		}
		if inhibit_cookie == 0 {return}
		msg := dbus.dbus_message_new_method_call(
			SCREENSAVER,
			SCREENSAVER_PATH,
			SCREENSAVER,
			"UnInhibit",
		)
		if msg == nil {return}
		defer dbus.dbus_message_unref(msg)
		iter: Opaque
		dbus.dbus_message_iter_init_append(msg, &iter)
		dbus.dbus_message_iter_append_basic(&iter, TYPE_UINT32, &inhibit_cookie)
		dbus.dbus_connection_send(conn, msg, nil)
		dbus.dbus_connection_flush(conn)
		log.debugf("platform keep awake off (cookie=%d released)", inhibit_cookie)
		inhibit_cookie = 0
	}
}

// portal_inhibit: the desktop portal's Inhibit (Wayland desktops), when
// there is no screensaver service: Inhibit("", idle, {}) answers with a
// request handle; closing it ends the inhibition.
@(private = "file")
portal_inhibit :: proc(conn: rawptr, err: ^Opaque) {
	msg := dbus.dbus_message_new_method_call(
		PORTAL,
		PORTAL_PATH,
		"org.freedesktop.portal.Inhibit",
		"Inhibit",
	)
	if msg == nil {return}
	defer dbus.dbus_message_unref(msg)
	iter, options: Opaque
	dbus.dbus_message_iter_init_append(msg, &iter)
	window := cstring("")
	flags := u32(PORTAL_INHIBIT_IDLE)
	dbus.dbus_message_iter_append_basic(&iter, TYPE_STRING, &window)
	dbus.dbus_message_iter_append_basic(&iter, TYPE_UINT32, &flags)
	dbus.dbus_message_iter_open_container(&iter, TYPE_ARRAY, "{sv}", &options)
	dbus.dbus_message_iter_close_container(&iter, &options)
	reply := dbus.dbus_connection_send_with_reply_and_block(conn, msg, 500, err)
	if reply == nil || dbus.dbus_error_is_set(err) {
		warn_once("platform neither the screensaver nor the portal answered Inhibit: not held off")
		return
	}
	defer dbus.dbus_message_unref(reply)
	out: Opaque
	path: cstring
	if dbus.dbus_message_iter_init(reply, &out) &&
	   dbus.dbus_message_iter_get_arg_type(&out) == TYPE_OBJECT_PATH {
		dbus.dbus_message_iter_get_basic(&out, &path)
	}
	if path == nil {return}
	n := min(len(path), len(portal_request) - 1)
	copy(portal_request[:n], (cast([^]u8)path)[:n])
	log.debugf("platform keep awake on (portal request %s)", path)
}

// KEEP_AWAKE_RESET: how often X's own screensaver timer is reset.
@(private)
KEEP_AWAKE_RESET :: 30 * time.Second
