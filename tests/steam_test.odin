package tests

import "core:testing"

import steam "client:steam"
import sc "common:steam"
import steam_server "server:steam"

// The fake client's ticket validates against the fake server and against nothing else.
@(test)
test_fake_ticket_validates_only_against_fake_server :: proc(t: ^testing.T) {
	c: steam.Client
	testing.expect(t, steam.open_fake(&c, {account = 9}))
	defer steam.shutdown(&c)
	s: steam_server.Server
	testing.expect(t, steam_server.open_fake(&s, {}))
	defer steam_server.shutdown(&s)

	ticket: steam.Ticket
	testing.expect(t, steam.auth_ticket(&c, &ticket))
	id := steam.steam_id(&c)
	testing.expect_value(t, id, sc.fake_id(9))
	testing.expect_value(
		t,
		steam_server.begin_auth(&s, id, ticket.bytes[:ticket.len]),
		steam_server.Auth_Result.Ok,
	)
	steam_server.end_auth(&s, id)
	steam.cancel_ticket(&c, &ticket)

	// A server that is off, or a ticket claimed for another ID, does not accept it.
	off: steam_server.Server
	testing.expect_value(
		t,
		steam_server.begin_auth(&off, id, ticket.bytes[:ticket.len]),
		steam_server.Auth_Result.Unavailable,
	)
	testing.expect_value(
		t,
		steam_server.begin_auth(&s, sc.fake_id(10), ticket.bytes[:ticket.len]),
		steam_server.Auth_Result.Invalid_Ticket,
	)
}
