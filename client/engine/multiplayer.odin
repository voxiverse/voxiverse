package engine

import "core:log"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "client:ui"
import "common:netcode"

Multiplayer_Mode :: enum u8 {
	List,
	Direct, // Direct Connection: an address and a password
	Add, // Add Server: an address to keep in the list
	Name, // first time: the name to play under
}

Multiplayer_Screen :: struct {
	discovery:  netcode.Discovery,
	searching:  bool, // discovery is open
	opened:     time.Tick, // when it opened (a saved server is being asked a moment, not silent)
	mode:       Multiplayer_Mode,
	list:       ui.Scroll_List, // the row selected (the saved servers, then the LAN's) and the first in view
	last_row:   int, // the row clicked last ...
	last_click: time.Tick, // ... and when (a second click on it within DOUBLE_CLICK joins)
	saved:      [dynamic]Saved_Server, // the player's servers, in the order added (servers.txt)
	saved_read: bool, // read from the disk (once a run)
	address:    [dynamic]u8,
	password:   [dynamic]u8,
	name:       [dynamic]u8,
}

// Saved_Server: a server the player keeps in the list (Add Server), by the address typed.
Saved_Server :: struct {
	address:  string, // host or host:port, as typed (allocated)
	endpoint: net.Endpoint, // where it is (port DEFAULT_PORT when none was typed); {} when the host was not found
}

// saved_servers_path: servers.txt beside the settings file (VX_SETTINGS moves both).
saved_servers_path :: proc() -> (string, bool) {
	path, ok := settings_path()
	if !ok {return "", false}
	context.allocator = context.temp_allocator
	return filepath.join({filepath.dir(path), "servers.txt"}) or_else "", true
}

// saved_server_add keeps address (trimmed; once) at the end of the list, looked up now
// (a host name is resolved once, here); false if it is empty or there already.
saved_server_add :: proc(m: ^Multiplayer_Screen, typed: string) -> bool {
	address := strings.trim_space(typed)
	if address == "" {return false}
	for s in m.saved {if s.address == address {return false}}
	server := Saved_Server {
		address = strings.clone(address),
	}
	if ep, err := net.resolve_ip4(address); err == nil {
		server.endpoint = ep
		if server.endpoint.port == 0 {server.endpoint.port = netcode.DEFAULT_PORT}
	}
	append(&m.saved, server)
	return true
}

// saved_server_remove drops the saved server at i.
saved_server_remove :: proc(m: ^Multiplayer_Screen, i: int) {
	if i < 0 || i >= len(m.saved) {return}
	delete(m.saved[i].address)
	ordered_remove(&m.saved, i)
}

// saved_servers_destroy forgets every saved server (not on the disk) and frees the list.
saved_servers_destroy :: proc(m: ^Multiplayer_Screen) {
	for s in m.saved {delete(s.address)}
	delete(m.saved)
	m.saved = nil
}

// saved_servers_text: the servers file's text, one address a line (temp allocator).
saved_servers_text :: proc(m: ^Multiplayer_Screen) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "# Voxiverse: the servers Multiplayer lists, one address a line\n")
	for s in m.saved {
		strings.write_string(&b, s.address)
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// saved_servers_parse adds the servers of a servers file's text (blank lines and #
// comments skipped).
saved_servers_parse :: proc(m: ^Multiplayer_Screen, text: string) {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		address := strings.trim_space(line)
		if address == "" || strings.has_prefix(address, "#") {continue}
		saved_server_add(m, address)
	}
}

// saved_servers_load reads the player's servers, once a run; none for a run that keeps
// nothing (a script's, a benchmark's, a check's: the player's own are not theirs).
saved_servers_load :: proc(app: ^App) {
	m := &app.multiplayer
	if m.saved_read {return}
	m.saved_read = true
	if app.scripted || app.benchmark || app.checking {return}
	path, ok := saved_servers_path()
	if !ok {return}
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		if err != .Not_Exist {log.warnf("servers cannot read path=%s error=%v", path, err)}
		return
	}
	saved_servers_parse(m, string(data))
}

// saved_servers_save writes the player's servers (not for a run that keeps nothing).
saved_servers_save :: proc(app: ^App) {
	if app.scripted || app.benchmark || app.checking {return}
	path, ok := saved_servers_path()
	if !ok {return}
	{
		context.allocator = context.temp_allocator
		os.make_directory_all(filepath.dir(path))
	}
	if err := os.write_entire_file(path, saved_servers_text(&app.multiplayer)); err != nil {
		log.warnf("servers cannot write path=%s error=%v", path, err)
	}
}
