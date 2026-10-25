package server

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "../game"

// M13's exit check for chat: two players over UDP, one a moderator with a
// tag. Formatting where the role allows it (as written where not), an
// ignore, a mute, a line taken back, the rate; mutes and ignores kept with
// the world.
@(test)
test_chat_over_the_network :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "net_chat"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	os.make_directory_all(dir)
	perms := strings.concatenate(
		{DEFAULT_PERMISSIONS, "player alice\nrole mod\n"},
		context.temp_allocator,
	)
	cfg := filepath.join({dir, PERMISSIONS_FILE}, context.temp_allocator) or_else ""
	testing.expect(t, os.write_entire_file(cfg, transmute([]u8)perms) == nil)
	config := Config {
		seed        = 21,
		view_radius = 2,
		view_height = 1,
		workers     = 1,
		save_dir    = dir,
		max_players = 4,
		listen      = true,
		generator   = .Classic,
	}
	srv: Server
	if !testing.expect(t, start(&srv, config, {})) {return}
	stopped := false
	defer if !stopped {stop(&srv)}
	for !srv.listening {}
	port := srv.host.socket.port

	alice, bob: Net_Client
	net_connect(&alice, port, "alice")
	net_connect(&bob, port, "bob")
	defer net_close(&alice)
	defer net_close(&bob)
	both := []^Net_Client{&alice, &bob}
	ok := net_wait(t, both, proc(cs: []^Net_Client) -> bool {
		return len(cs[0].grants) > 0 && len(cs[1].grants) > 0 && len(cs[0].others) == 1
	})
	if !testing.expect(t, ok, "the players never met") {return}
	// heard: the plain text of what c heard last (or "").
	heard :: proc(c: ^Net_Client) -> string {
		if len(c.chat) == 0 {return ""}
		return game.format_strip(c.chat[len(c.chat) - 1].text)
	}
	@(static) want: string

	// A moderator's tag and colours; a player's codes shown as written.
	net_send(&alice, game.Chat{"&chi &lthere"})
	want = "Mod alice: hi there"
	ok = net_wait(
		t,
		both,
		proc(cs: []^Net_Client) -> bool {return heard(cs[1]) == want && heard(cs[0]) == want},
	)
	testing.expectf(t, ok, "bob heard %q", heard(&bob))
	if len(bob.chat) > 0 {
		testing.expect(
			t,
			strings.contains(bob.chat[len(bob.chat) - 1].text, "&chi"),
			"alice's colour lost",
		)
		testing.expect_value(t, bob.chat[len(bob.chat) - 1].sender, alice.welcome.player)
	}
	net_send(&bob, game.Chat{"&cnope\x07"})
	want = "bob: &cnope"
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {return heard(cs[0]) == want})
	testing.expectf(t, ok, "alice heard %q", heard(&alice))

	// Bob ignores alice: he does not hear her; she hears herself.
	net_send(&bob, game.Command{"ignore alice"})
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {return len(cs[1].notices) > 0})
	net_send(&alice, game.Chat{"secret"})
	want = "Mod alice: secret"
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {return heard(cs[0]) == want})
	testing.expect(t, ok)
	net_wait(t, both, proc(cs: []^Net_Client) -> bool {return false}, 0.3)
	testing.expect(t, heard(&bob) != "Mod alice: secret", "bob heard someone he ignores")
	net_send(&bob, game.Command{"ignore alice"}) // and not any more

	// Alice takes her line back: both are told.
	net_send(&alice, game.Command{"delmsg alice"})
	ok = net_wait(
		t,
		both,
		proc(cs: []^Net_Client) -> bool {return len(cs[0].deleted) > 0 && len(cs[1].deleted) > 0},
	)
	if testing.expect(t, ok) {
		testing.expect_value(t, alice.deleted[0], alice.chat[len(alice.chat) - 1].id)
	}

	// Bob may not mute; alice mutes him. (Among his notices: the answer to
	// his second ignore may still be on its way.)
	net_send(&bob, game.Command{"mute alice"})
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {
		for n in cs[1].notices {if strings.has_prefix(n, "You may not use mute") {return true}}
		return false
	})
	testing.expectf(t, ok, "bob was not refused: %v", bob.notices[:])
	net_send(&alice, game.Command{"mute bob 5m"})
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {
		for n in cs[1].notices {if strings.contains(n, "You were muted") {return true}}
		return false
	})
	testing.expect(t, ok, "bob was not told")
	lines := len(alice.chat)
	net_send(&bob, game.Chat{"let me speak"})
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {
		for n in cs[1].notices {if strings.has_prefix(n, "&cYou are muted") {return true}}
		return false
	})
	testing.expect(t, ok, "a muted player was not told")
	testing.expect_value(t, len(alice.chat), lines)

	// The rate: alice says eight lines at once; some are refused.
	for n in alice.notices {delete(n)}
	clear(&alice.notices)
	for _ in 0 ..< 8 {net_send(&alice, game.Chat{"spam"})}
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {
		for n in cs[0].notices {if n == "&cSlow down" {return true}}
		return false
	})
	testing.expect(t, ok, "no rate limit")

	// Kept with the world.
	testing.expect(t, stop(&srv))
	stopped = true
	data, err := os.read_entire_file_from_path(
		filepath.join({dir, COMMUNITY_FILE}, context.temp_allocator) or_else "",
		context.temp_allocator,
	)
	testing.expect(t, err == nil)
	text := string(data)
	testing.expect(t, strings.contains(text, "player bob\nmute "), text)
}
