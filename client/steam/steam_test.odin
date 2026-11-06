package steam

import "core:mem"
import "core:testing"

import sc "common:steam"

@(test)
test_fake_init_gives_id_and_name :: proc(t: ^testing.T) {
	c: Client
	testing.expect(t, open_fake(&c, {account = 5, name = "Ada"}))
	defer shutdown(&c)
	testing.expect(t, on(&c))
	testing.expect_value(t, steam_id(&c), sc.fake_id(5))
	testing.expect_value(t, persona_name(&c), "Ada")

	d: Client
	testing.expect(t, open_fake(&d, {account = 120}))
	testing.expect_value(t, persona_name(&d), "Fake120")
}

@(test)
test_scripted_init_failure_is_off :: proc(t: ^testing.T) {
	c: Client
	testing.expect(t, !open_fake(&c, {fail_init = true}))
	testing.expect(t, !on(&c))
	testing.expect_value(t, steam_id(&c), sc.INVALID_ID)
	testing.expect_value(t, persona_name(&c), "")
	ticket: Ticket
	testing.expect(t, !auth_ticket(&c, &ticket))
	run_callbacks(&c) // off: nothing happens
}

@(test)
test_missing_library_starts_with_steam_off :: proc(t: ^testing.T) {
	c: Client
	open_real(&c, "build/tmp/no_such_folder", true)
	testing.expect(t, !on(&c))
	testing.expect_value(t, steam_id(&c), sc.INVALID_ID)
	run_callbacks(&c)
	shutdown(&c)
}

@(test)
test_setting_off_does_not_look_for_the_library :: proc(t: ^testing.T) {
	c: Client
	open_real(&c, ".", false)
	testing.expect(t, !on(&c))
}

@(test)
test_callbacks_run_without_allocating :: proc(t: ^testing.T) {
	c: Client
	testing.expect(t, open_fake(&c, {account = 1}))
	defer shutdown(&c)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		context.temp_allocator = mem.tracking_allocator(&track)
		for _ in 0 ..< 1000 {run_callbacks(&c)}
	}
	testing.expect_value(t, c.fake.callbacks, 1000)
	testing.expect_value(t, track.total_allocation_count, 0)
}

@(test)
test_tickets_are_counted_and_can_fail :: proc(t: ^testing.T) {
	c: Client
	testing.expect(t, open_fake(&c, {account = 2}))
	ticket: Ticket
	testing.expect(t, auth_ticket(&c, &ticket))
	testing.expect_value(t, ticket.len, sc.FAKE_TICKET_LEN)
	testing.expect_value(t, c.fake.live_tickets, 1)
	cancel_ticket(&c, &ticket)
	testing.expect_value(t, c.fake.live_tickets, 0)
	shutdown(&c)

	testing.expect(t, open_fake(&c, {fail_ticket = true}))
	testing.expect(t, !auth_ticket(&c, &ticket))
	testing.expect_value(t, ticket.len, 0)
}

@(test)
test_ugc_query_and_release :: proc(t: ^testing.T) {
	c: Client
	testing.expect(t, open_fake(&c, {}))
	q, ok := ugc_query_all(&c, 480, 1)
	testing.expect(t, ok)
	ugc_release(&c, q)
	testing.expect_value(t, c.fake.live_queries, 0)
	shutdown(&c)
	testing.expect(t, open_fake(&c, {fail_ugc = true}))
	_, ok = ugc_query_all(&c, 480, 1)
	testing.expect(t, !ok)
}
