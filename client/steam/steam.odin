package steam

import "core:dynlib"
import "core:log"

import sc "common:steam"

// The client's Steam (docs/platforms.md, "Steam"): one interface, `Client`, with two
// implementations behind it: the real Steamworks flat C API, loaded at run time from beside
// the executable (real.odin), and a fake for tests (fake.odin). A Client that is not `on`
// is Steam off: every call answers "nothing" and costs nothing. The game never needs
// Steam: a missing library, a failed init or the `steam` setting off all end here.

Kind :: enum {
	Off,
	Real,
	Fake,
}

Ticket :: struct {
	handle: u32, // for cancel_ticket (0: none)
	bytes:  [sc.MAX_TICKET]u8,
	len:    int,
}

// Client is not copied once opened: the implementations keep their state inside it.
Client :: struct {
	kind: Kind,
	real: Real,
	fake: Fake,
}

// open_real starts the real Steam from the library in `dir` (the executable's folder).
// `enabled` false (the `steam` setting) leaves it off without a word; a missing library
// or a failed init leaves it off and says so once in the log.
open_real :: proc(c: ^Client, dir: string, enabled: bool) {
	c^ = {}
	if !enabled {return}
	if real_open(&c.real, dir) {c.kind = .Real}
}

// open_fake starts the fake with a script; false when the script says init fails.
open_fake :: proc(c: ^Client, script: Fake_Script) -> bool {
	c^ = {}
	if !fake_open(&c.fake, script) {return false}
	c.kind = .Fake
	return true
}

on :: proc(c: ^Client) -> bool {return c.kind != .Off}

// shutdown ends the session; the client is off after it.
shutdown :: proc(c: ^Client) {
	switch c.kind {
	case .Off:
	case .Real:
		real_shutdown(&c.real)
	case .Fake:
	}
	c^ = {}
}

// run_callbacks lets Steam deliver what it has: once a frame. It allocates nothing.
run_callbacks :: proc(c: ^Client) {
	switch c.kind {
	case .Off:
	case .Real:
		c.real.run_callbacks()
	case .Fake:
		c.fake.callbacks += 1
	}
}

// steam_id: the local user's SteamID (INVALID_ID when Steam is off).
steam_id :: proc(c: ^Client) -> sc.Steam_ID {
	switch c.kind {
	case .Off:
	case .Real:
		return sc.Steam_ID(c.real.get_steam_id(c.real.user))
	case .Fake:
		return c.fake.id
	}
	return sc.INVALID_ID
}

// persona_name: the user's Steam name ("" when off). Valid until the next Steam call.
persona_name :: proc(c: ^Client) -> string {
	switch c.kind {
	case .Off:
	case .Real:
		return string(c.real.get_persona_name(c.real.friends))
	case .Fake:
		return c.fake.name
	}
	return ""
}

// auth_ticket asks for a ticket that proves the user's identity to a server.
auth_ticket :: proc(c: ^Client, ticket: ^Ticket) -> bool {
	ticket^ = {}
	switch c.kind {
	case .Off:
	case .Real:
		n: u32
		h := c.real.get_auth_ticket(c.real.user, &ticket.bytes[0], sc.MAX_TICKET, &n, nil)
		if h == 0 || int(n) > sc.MAX_TICKET {return false}
		ticket.handle, ticket.len = h, int(n)
		return true
	case .Fake:
		return fake_auth_ticket(&c.fake, ticket)
	}
	return false
}

// cancel_ticket tells Steam the ticket is no longer in use.
cancel_ticket :: proc(c: ^Client, ticket: ^Ticket) {
	if ticket.handle == 0 {return}
	switch c.kind {
	case .Off:
	case .Real:
		c.real.cancel_ticket(c.real.user, ticket.handle)
	case .Fake:
		c.fake.live_tickets -= 1
	}
	ticket.handle = 0
}

// UGC_Query: a Workshop query in flight (0: none). The answer is a Steam call result; the
// task that reads it adds its binding.
UGC_Query :: distinct u64

// ugc_query_all sends a query for one page of the app's Workshop items.
ugc_query_all :: proc(c: ^Client, app_id: u32, page: u32) -> (q: UGC_Query, ok: bool) {
	switch c.kind {
	case .Off:
	case .Real:
		r := &c.real
		if r.ugc == nil || r.ugc_create == nil {return}
		h := r.ugc_create(r.ugc, 0, 0, app_id, app_id, page) // RankedByVote, Items
		if h == 0 {return}
		r.ugc_send(r.ugc, h)
		return UGC_Query(h), true
	case .Fake:
		return fake_ugc_query(&c.fake)
	}
	return
}

// ugc_release frees a query once its answer is read.
ugc_release :: proc(c: ^Client, q: UGC_Query) {
	switch c.kind {
	case .Off:
	case .Real:
		if c.real.ugc != nil {c.real.ugc_release(c.real.ugc, u64(q))}
	case .Fake:
		c.fake.live_queries -= 1
	}
}

@(private)
log_off :: proc(why: string) {
	log.infof("steam off: %s", why)
}

@(private)
unload :: proc(lib: dynlib.Library) {
	if lib != nil {dynlib.unload_library(lib)}
}
