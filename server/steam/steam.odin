package steam_server

import "core:dynlib"
import "core:log"

import sc "common:steam"

// The dedicated server's Steam (docs/platforms.md, "Steam"): the game server side of the
// flat C API, only what checking a joining player's auth ticket needs. Like the client's
// (client/steam) it is one interface with two implementations, the real library loaded at
// run time and a fake whose tickets are the ones the fake client makes. A Server that is
// not on says "no Steam" and the server runs as it does without it.

Kind :: enum {
	Off,
	Real,
	Fake,
}

// Auth_Result: how a ticket fared (Steam's EBeginAuthSessionResult, folded).
Auth_Result :: enum {
	Ok,
	Invalid_Ticket,
	Invalid_Version,
	Game_Mismatch,
	Expired_Ticket,
	Duplicate_Request, // the SteamID already has a session
	Unavailable, // no Steam, or it failed in a way the ticket does not explain
}

MAX_SESSIONS :: 256

Server :: struct {
	kind: Kind,
	real: Real,
	fake: Fake,
}

// open_real starts the real game server Steam from the library in `dir`; `enabled` false
// leaves it off without a word, a missing library or failed init leaves it off with one
// line in the log. `ip` (0: any), `game_port` and `query_port` are the server's.
open_real :: proc(
	s: ^Server,
	dir: string,
	enabled: bool,
	ip: u32,
	game_port, query_port: u16,
	version: cstring,
) {
	s^ = {}
	if !enabled {return}
	if real_open(&s.real, dir, ip, game_port, query_port, version) {s.kind = .Real}
}

// open_fake starts the fake with a script; false when the script says init fails.
open_fake :: proc(s: ^Server, script: Fake_Script) -> bool {
	s^ = {}
	if script.fail_init {return false}
	s.fake.script = script
	s.kind = .Fake
	return true
}

on :: proc(s: ^Server) -> bool {return s.kind != .Off}

shutdown :: proc(s: ^Server) {
	if s.kind == .Real {real_shutdown(&s.real)}
	s^ = {}
}

// run_callbacks: once a tick. It allocates nothing.
run_callbacks :: proc(s: ^Server) {
	switch s.kind {
	case .Off:
	case .Real:
		s.real.run_callbacks()
	case .Fake:
		s.fake.callbacks += 1
	}
}

// begin_auth checks `ticket`, which the player at `id` says is theirs. Ok opens a session
// that end_auth closes.
begin_auth :: proc(s: ^Server, id: sc.Steam_ID, ticket: []u8) -> Auth_Result {
	switch s.kind {
	case .Off:
	case .Real:
		if len(ticket) == 0 || len(ticket) > sc.MAX_TICKET {return .Invalid_Ticket}
		return auth_result(s.real.begin_auth(s.real.server, &ticket[0], i32(len(ticket)), u64(id)))
	case .Fake:
		return fake_begin_auth(&s.fake, id, ticket)
	}
	return .Unavailable
}

// end_auth closes the session begin_auth opened for id.
end_auth :: proc(s: ^Server, id: sc.Steam_ID) {
	switch s.kind {
	case .Off:
	case .Real:
		s.real.end_auth(s.real.server, u64(id))
	case .Fake:
		fake_end_auth(&s.fake, id)
	}
}

@(private)
auth_result :: proc(code: i32) -> Auth_Result {
	switch code {
	case 0:
		return .Ok
	case 1:
		return .Invalid_Ticket
	case 2:
		return .Duplicate_Request
	case 3:
		return .Invalid_Version
	case 4:
		return .Game_Mismatch
	case 5:
		return .Expired_Ticket
	}
	return .Unavailable
}

@(private)
unload :: proc(lib: dynlib.Library) {
	if lib != nil {dynlib.unload_library(lib)}
}

@(private)
log_off :: proc(why: string) {
	log.infof("steam server off: %s", why)
}
