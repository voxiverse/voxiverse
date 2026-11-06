package steam_server

import sc "common:steam"

// The fake game server: it accepts the tickets the fake client makes (common/steam) and
// nothing else, keeps its sessions, and fails as scripted.

Fake_Script :: struct {
	fail_init: bool, // init fails
	expire:    bool, // every ticket is answered Expired_Ticket
}

Fake :: struct {
	script:    Fake_Script,
	callbacks: int, // run_callbacks calls
	sessions:  [MAX_SESSIONS]sc.Steam_ID,
	count:     int, // live sessions
}

// sessions: how many auth sessions are open (the fake's, for tests).
sessions :: proc(s: ^Server) -> int {return s.fake.count}

@(private)
fake_begin_auth :: proc(f: ^Fake, id: sc.Steam_ID, ticket: []u8) -> Auth_Result {
	who, ok := sc.fake_ticket_check(ticket)
	if !ok || who != id {return .Invalid_Ticket}
	if f.script.expire {return .Expired_Ticket}
	for i in 0 ..< f.count {
		if f.sessions[i] == id {return .Duplicate_Request}
	}
	if f.count == len(f.sessions) {return .Unavailable}
	f.sessions[f.count] = id
	f.count += 1
	return .Ok
}

@(private)
fake_end_auth :: proc(f: ^Fake, id: sc.Steam_ID) {
	for i in 0 ..< f.count {
		if f.sessions[i] == id {
			f.count -= 1
			f.sessions[i] = f.sessions[f.count]
			return
		}
	}
}
