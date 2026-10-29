package server

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "../common/game"
import "../common/netcode"

// test_key: the account a test client of name has (the same every run, so
// a restarted server knows it again).
@(private)
test_key :: proc(name: string) -> (k: game.Account_Key) {
	seed: [32]u8
	for i in 0 ..< 32 {seed[i] = u8(i) * 7 ~ (name[i % len(name)] if len(name) > 0 else 0)}
	game.account_key_set(&k, seed[:])
	return
}

@(private)
test_hello :: proc(name: string) -> game.Hello {
	schema := game.game_schema(context.temp_allocator)
	return {game.PROTOCOL_VERSION, test_key(name).account, name, schema.hash}
}

// A proof is good for its nonce and account only.
@(test)
test_account_proofs :: proc(t: ^testing.T) {
	alice, bob := test_key("alice"), test_key("bob")
	testing.expect(t, alice.account != bob.account)
	n := game.nonce_make()
	sig := game.account_sign(&alice, n)
	testing.expect(t, game.account_verify(alice.account, n, sig))
	testing.expect(t, !game.account_verify(bob.account, n, sig), "a proof for another account")
	testing.expect(
		t,
		!game.account_verify(alice.account, game.nonce_make(), sig),
		"a replayed proof",
	)
	text := game.account_text(alice.account)
	back, ok := game.account_parse(text)
	testing.expect(t, ok && back == alice.account && len(text) == 64)
}

// M16's exit check over UDP: an account is its key (a proof signed with
// another is refused); a name is its account's (another account can't take
// it); asking, a client is shown its characters and chooses; a character
// from before accounts goes to the first account that plays it; a ban
// follows the account to its other characters.
@(test)
test_accounts_over_the_network :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "net_accounts"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	os.make_directory_all(filepath.join({dir, PLAYERS_DIR}, context.temp_allocator) or_else "")
	// bea, from before accounts.
	old := `{"format": 1, "position": [3.5, 40, 3.5], "look": [0, 0], "flying": true, "selected": 0, "items": [{"slot": 2, "item": "sand", "count": 7}]}`
	bea_old := filepath.join({dir, PLAYERS_DIR, "bea.json"}, context.temp_allocator) or_else ""
	testing.expect(t, os.write_entire_file(bea_old, transmute([]u8)old) == nil)
	config := Config {
		seed        = 3,
		view_radius = 2,
		view_height = 1,
		save_dir    = dir,
		max_players = 8,
		listen      = true,
		generator   = .Classic,
	}
	h: Harness
	if !testing.expect(t, harness_start(&h, config)) {return}
	stopped := false
	defer if !stopped {harness_stop(&h)}

	alice: Net_Client
	net_connect(&alice, 0, "alice", h = &h)
	defer net_close(&alice)
	ok := net_wait(t, {&alice}, proc(cs: []^Net_Client) -> bool {return cs[0].welcomed})
	if !testing.expect(t, ok, "alice never joined") {return}

	// Claiming to be alice's account without its key.
	forger: Net_Client
	forger.key_name, forger.sign_name = "alice", "mallory"
	net_connect(&forger, 0, "alice2", h = &h)
	defer net_close(&forger)
	ok = net_wait(
		t,
		{&forger, &alice},
		proc(cs: []^Net_Client) -> bool {return cs[0].rejected != ""},
	)
	testing.expect_value(t, forger.rejected, "the account's proof is wrong")

	// Another account, alice's name (once she has left: not "playing").
	netcode_close_and_wait(t, &alice)
	thief: Net_Client
	thief.key_name = "mallory"
	net_connect(&thief, 0, "alice", h = &h)
	defer net_close(&thief)
	ok = net_wait(t, {&thief}, proc(cs: []^Net_Client) -> bool {return cs[0].rejected != ""})
	testing.expect_value(t, thief.rejected, "that name is another account's")

	// Asking: alice's account has alice; it chooses alice.
	again: Net_Client
	again.key_name, again.ask = "alice", true
	net_connect(&again, 0, "alice", h = &h)
	defer net_close(&again)
	ok = net_wait(t, {&again}, proc(cs: []^Net_Client) -> bool {return cs[0].welcomed})
	testing.expect(t, ok && again.characters == "alice", "alice was not offered alice")

	// bea from before accounts: the first account to play her has her (and
	// what she carried).
	bea: Net_Client
	bea.key_name = "beatrice"
	net_connect(&bea, 0, "bea", h = &h)
	defer net_close(&bea)
	ok = net_wait(t, {&bea}, proc(cs: []^Net_Client) -> bool {return cs[0].inv_updates > 0})
	testing.expect(t, ok)
	testing.expect_value(
		t,
		game.inventory_count(&bea.inventory, game.item_of_block(test_reg(), .Sand)),
		7,
	)

	// A ban follows the account: alice banned, her account can't play a new
	// character either.
	testing.expect(t, harness_stop(&h))
	stopped = true
	moved :=
		filepath.join(
			{dir, CHARACTERS_DIR, game.account_text(test_key("beatrice").account), "bea.json"},
			context.temp_allocator,
		) or_else ""
	testing.expect(t, os.exists(moved), "bea's file did not move to her account")
	testing.expect(t, !os.exists(bea_old), "bea's old file stayed")
	cfg := filepath.join({dir, COMMUNITY_FILE}, context.temp_allocator) or_else ""
	ban := strings.concatenate(
		{
			"ban alice 0 test griefing\nban_account ",
			game.account_text(test_key("alice").account),
			" 0 test griefing\n",
		},
		context.temp_allocator,
	)
	testing.expect(t, os.write_entire_file(cfg, transmute([]u8)ban) == nil)
	if !testing.expect(t, harness_start(&h, config)) {return}
	stopped = false
	alt: Net_Client
	alt.key_name = "alice"
	net_connect(&alt, 0, "alice_alt", h = &h)
	defer net_close(&alt)
	ok = net_wait(t, {&alt}, proc(cs: []^Net_Client) -> bool {return cs[0].rejected != ""})
	testing.expect_value(t, alt.rejected, "Banned for good: griefing")
}

// netcode_close_and_wait: c leaves (the server sees it go).
@(private = "file")
netcode_close_and_wait :: proc(t: ^testing.T, c: ^Net_Client) {
	netcode.link_close(&c.link, "bye")
	harness_step(c.stepper, 6) // (the server sees it go)
}
