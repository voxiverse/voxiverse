package steam_common

import "core:testing"

@(test)
test_fake_ticket_round_trips :: proc(t: ^testing.T) {
	buf: [MAX_TICKET]u8
	n := fake_ticket_make(buf[:], fake_id(7), 99)
	testing.expect_value(t, n, FAKE_TICKET_LEN)
	id, ok := fake_ticket_check(buf[:n])
	testing.expect(t, ok)
	testing.expect_value(t, id, fake_id(7))
}

@(test)
test_fake_ticket_rejects_damage :: proc(t: ^testing.T) {
	buf: [MAX_TICKET]u8
	n := fake_ticket_make(buf[:], fake_id(7), 99)
	for i in 0 ..< n {
		damaged := buf
		damaged[i] ~= 1
		_, ok := fake_ticket_check(damaged[:n])
		testing.expectf(t, !ok, "byte %d", i)
	}
	_, ok := fake_ticket_check(buf[:n - 1])
	testing.expect(t, !ok)
	_, ok = fake_ticket_check(nil)
	testing.expect(t, !ok)
}

@(test)
test_missing_library_is_not_loaded :: proc(t: ^testing.T) {
	_, ok := library_open("build/tmp/no_such_folder")
	testing.expect(t, !ok)
}
