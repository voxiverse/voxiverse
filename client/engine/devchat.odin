package engine

import "core:log"
import "core:net"
import "core:path/filepath"
import "core:strings"

import "common:base"
import "server:collector"

// Developer chat (docs/telemetry.md, "Developer chat"): the game's side runs
// while the `devchat` setting names a collector, on a thread of its own
// (collector.Chat), and keeps the conversation in devchat.jsonl beside the
// settings. With the setting empty no connection is ever made.

DEVCHAT_FILE :: "devchat.jsonl"
DEVCHAT_PORT :: 27316 // the collector's (DEFAULT_COLLECTOR)

Devchat :: struct {
	chat:    collector.Chat,
	running: bool,
	address: string, // the address it was last started for (also when that failed)
}

// devchat_endpoint: the collector at `address` ("host" or "host:port"); not ok
// for "" (off) or an address that does not resolve.
devchat_endpoint :: proc(address: string) -> (ep: net.Endpoint, ok: bool) {
	if address == "" {return}
	err: net.Network_Error
	if ep, err = net.resolve_ip4(address); err != nil {return {}, false}
	if ep.port == 0 {ep.port = DEVCHAT_PORT}
	return ep, true
}

// devchat_file: the conversation's file, beside the settings.
devchat_file :: proc() -> (string, bool) {
	path, ok := settings_path()
	if !ok {return "", false}
	context.allocator = context.temp_allocator
	return filepath.join({filepath.dir(path), DEVCHAT_FILE}) or_else "", true
}

// devchat_sync starts, restarts or stops the chat to follow the setting (each
// frame; it does nothing unless the setting changed). A benchmark or a check
// never chats.
devchat_sync :: proc(app: ^App) {
	want := base.var_text(&app.settings.devchat)
	if app.benchmark || app.checking {want = ""}
	if want == app.devchat.address {return}
	devchat_stop(app)
	app.devchat.address = strings.clone(want)
	if want == "" {return}
	ep, ok := devchat_endpoint(want)
	if !ok {
		log.warnf("devchat cannot find the collector address=%s", want)
		return
	}
	file, has_file := devchat_file()
	if !has_file {return}
	collector.chat_start(&app.devchat.chat, file, ep, app.account)
	app.devchat.running = true
}

// devchat_stop ends the chat's thread (what waits stays in the file).
devchat_stop :: proc(app: ^App) {
	if app.devchat.running {collector.chat_stop(&app.devchat.chat)}
	app.devchat.running = false
	delete(app.devchat.address)
	app.devchat.address = ""
}
