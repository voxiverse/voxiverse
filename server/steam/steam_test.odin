package steam_server

import "core:testing"

import sc "common:steam"

@(test)
test_fake_server_accepts_only_fake_tickets :: proc(t: ^testing.T) {
	s: Server
	testing.expect(t, open_fake(&s, {}))
	buf: [sc.MAX_TICKET]u8
	n := sc.fake_ticket_make(buf[:], sc.fake_id(3), 1)
	testing.expect_value(t, begin_auth(&s, sc.fake_id(3), buf[:n]), Auth_Result.Ok)
	testing.expect_value(t, sessions(&s), 1)
	testing.expect_value(t, begin_auth(&s, sc.fake_id(3), buf[:n]), Auth_Result.Duplicate_Request)
	// Someone else's ticket, and bytes no fake made.
	testing.expect_value(t, begin_auth(&s, sc.fake_id(4), buf[:n]), Auth_Result.Invalid_Ticket)
	real_like := [?]u8{1, 2, 3, 4, 5}
	testing.expect_value(
		t,
		begin_auth(&s, sc.fake_id(3), real_like[:]),
		Auth_Result.Invalid_Ticket,
	)
	end_auth(&s, sc.fake_id(3))
	testing.expect_value(t, sessions(&s), 0)
	testing.expect_value(t, begin_auth(&s, sc.fake_id(3), buf[:n]), Auth_Result.Ok)
}

@(test)
test_fake_server_scripted_failures :: proc(t: ^testing.T) {
	s: Server
	testing.expect(t, !open_fake(&s, {fail_init = true}))
	testing.expect(t, !on(&s))
	buf: [sc.MAX_TICKET]u8
	n := sc.fake_ticket_make(buf[:], sc.fake_id(3), 1)
	testing.expect_value(t, begin_auth(&s, sc.fake_id(3), buf[:n]), Auth_Result.Unavailable)

	testing.expect(t, open_fake(&s, {expire = true}))
	testing.expect_value(t, begin_auth(&s, sc.fake_id(3), buf[:n]), Auth_Result.Expired_Ticket)
}

@(test)
test_missing_library_leaves_server_steam_off :: proc(t: ^testing.T) {
	s: Server
	open_real(&s, "build/tmp/no_such_folder", true, 0, 27015, 27016, "0")
	testing.expect(t, !on(&s))
	run_callbacks(&s)
	shutdown(&s)
}
