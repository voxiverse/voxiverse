package steam

import sc "common:steam"

// The fake: what tests use instead of the library. Its SteamIDs are deterministic
// (common/steam fake_id), its tickets validate only against the fake server
// (server/steam), and failures are scripted.

Fake_Script :: struct {
	account:     u32, // the account number: the SteamID follows from it
	name:        string, // "" : "Fake<account>"
	fail_init:   bool, // init fails, as with no Steam client running
	fail_ticket: bool, // auth_ticket fails
	fail_ugc:    bool, // ugc_query_all fails
}

Fake :: struct {
	script:       Fake_Script,
	id:           sc.Steam_ID,
	name:         string,
	name_buf:     [32]u8,
	callbacks:    int, // run_callbacks calls
	next_nonce:   u32,
	live_tickets: int,
	live_queries: int,
}

@(private)
fake_open :: proc(f: ^Fake, script: Fake_Script) -> bool {
	f^ = {
		script = script,
	}
	if script.fail_init {return false}
	f.id = sc.fake_id(script.account)
	if script.name != "" {
		n := copy(f.name_buf[:], script.name)
		f.name = string(f.name_buf[:n])
	} else {
		// "Fake" and the account's digits, written without allocating.
		n := copy(f.name_buf[:], "Fake")
		digits: [10]u8
		d, a := 0, script.account
		for {
			digits[d] = u8('0' + a % 10)
			d += 1
			a /= 10
			if a == 0 {break}
		}
		for d > 0 {
			d -= 1
			f.name_buf[n] = digits[d]
			n += 1
		}
		f.name = string(f.name_buf[:n])
	}
	return true
}

@(private)
fake_auth_ticket :: proc(f: ^Fake, t: ^Ticket) -> bool {
	if f.script.fail_ticket {return false}
	f.next_nonce += 1
	t.len = sc.fake_ticket_make(t.bytes[:], f.id, f.next_nonce)
	t.handle = f.next_nonce
	f.live_tickets += 1
	return true
}

@(private)
fake_ugc_query :: proc(f: ^Fake) -> (UGC_Query, bool) {
	if f.script.fail_ugc {return 0, false}
	f.live_queries += 1
	return UGC_Query(f.live_queries), true
}
