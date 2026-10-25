package server

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "../game"

@(private = "file")
want_text: string

// told: c has a notice (or chat line) starting with want_text.
@(private = "file")
told :: proc(cs: []^Net_Client) -> bool {
	c := cs[0]
	for n in c.notices {if strings.has_prefix(game.format_strip(n), want_text) {return true}}
	for l in c.chat {if strings.has_prefix(game.format_strip(l.text), want_text) {return true}}
	return false
}

@(private = "file")
expect_told :: proc(
	t: ^testing.T,
	c: ^Net_Client,
	others: []^Net_Client,
	text: string,
	loc := #caller_location,
) -> bool {
	want_text = text
	all := make([dynamic]^Net_Client, context.temp_allocator)
	append(&all, c)
	append(&all, ..others)
	ok := net_wait(t, all[:], told, 5)
	testing.expectf(t, ok, "%s was not told %q", c.name, text, loc = loc)
	return ok
}

@(private = "file")
forget :: proc(c: ^Net_Client) {
	for n in c.notices {delete(n)}
	clear(&c.notices)
	for l in c.chat {delete(l.text)}
	clear(&c.chat)
}

@(private = "file")
near :: proc(a, b: [3]f64) -> bool {
	d := a - b
	return abs(d.x) + abs(d.z) < 0.01
}

// M13's commands over UDP, an admin and a player: warps, homes (as many as
// the role's max_homes), teleport requests and back, whispers and answers,
// actions, nicknames, who is here, kicking, bans by name and address, the
// server's status; kept with the world.
@(test)
test_commands_over_the_network :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "net_commands"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	os.make_directory_all(dir)
	perms := strings.concatenate(
		{DEFAULT_PERMISSIONS, "player alice\nrole admin\n"},
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
		max_players = 8,
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
		ready :: proc(c: ^Net_Client) -> bool {return(
				c.welcomed &&
				c.update.acked > 0 &&
				len(c.grants) > 0 \
			)}
		return ready(cs[0]) && ready(cs[1]) && len(cs[0].others) == 1
	})
	if !testing.expect(t, ok, "the players never landed") {return}

	// Alice flies off and sets a warp there; bob warps to it.
	net_send(&alice, game.Command{"tp 40.5 60 40.5"})
	@(static) at: [3]f64
	at = {40.5, 0, 40.5}
	ok = net_wait(
		t,
		both,
		proc(cs: []^Net_Client) -> bool {return near(cs[0].update.state.position, at)},
	)
	testing.expect(t, ok, "tp did not move alice")
	net_send(&alice, game.Command{"setwarp market"})
	expect_told(t, &alice, {&bob}, "Warp market set")
	bob_was := bob.update.state.position
	net_send(&bob, game.Command{"warp market"})
	ok = net_wait(
		t,
		both,
		proc(cs: []^Net_Client) -> bool {return near(cs[1].update.state.position, at)},
	)
	testing.expect(t, ok, "bob did not warp")
	net_send(&bob, game.Command{"setwarp mine"})
	expect_told(t, &bob, {&alice}, "You may not use setwarp")

	// Back where he was; then three homes, not four.
	net_send(&bob, game.Command{"back"})
	at = bob_was
	ok = net_wait(
		t,
		both,
		proc(cs: []^Net_Client) -> bool {return near(cs[1].update.state.position, at)},
	)
	testing.expect(t, ok, "back did not go back")
	for h in ([]string{"a", "b", "c"}) {net_send(&bob, game.Command{strings.concatenate({"sethome ", h}, context.temp_allocator)})}
	expect_told(t, &bob, {&alice}, "Home c set")
	net_send(&bob, game.Command{"sethome d"})
	expect_told(t, &bob, {&alice}, "You have 3 homes")

	// A teleport request: bob asks, alice accepts, bob arrives.
	net_send(&bob, game.Command{"tpa alice"})
	expect_told(t, &alice, {&bob}, "bob asks to teleport to you")
	net_send(&alice, game.Command{"tpaccept"})
	at = alice.update.state.position
	ok = net_wait(
		t,
		both,
		proc(cs: []^Net_Client) -> bool {return near(cs[1].update.state.position, at)},
	)
	testing.expect(t, ok, "tpaccept did not bring bob")

	// Whispers and answers; actions.
	net_send(&alice, game.Command{"msg bob psst"})
	expect_told(t, &bob, {&alice}, "[Admin alice -> me] psst")
	net_send(&bob, game.Command{"r what"})
	expect_told(t, &alice, {&bob}, "[bob -> me] what")
	net_send(&bob, game.Command{"me waves"})
	expect_told(t, &alice, {&bob}, "* bob waves")

	// Nicknames: not for bob; alice is Ally.
	net_send(&bob, game.Command{"nick &cBobby"})
	expect_told(t, &bob, {&alice}, "You may not use nick")
	net_send(&alice, game.Command{"nick &bAlly"})
	expect_told(t, &alice, {&bob}, "alice is now Ally")
	net_send(&alice, game.Chat{"hello"})
	expect_told(t, &bob, {&alice}, "Admin Ally: hello")
	net_send(&bob, game.Command{"realname Ally"})
	expect_told(t, &bob, {&alice}, "Ally is alice")

	// Who is here, and who was.
	net_send(&bob, game.Command{"list"})
	expect_told(t, &bob, {&alice}, "Here (2 of 8): Admin Ally, bob")
	net_send(&bob, game.Command{"seen carol"})
	expect_told(t, &bob, {&alice}, "carol has never been here")
	net_send(&alice, game.Command{"status"})
	expect_told(t, &alice, {&bob}, "Voxiverse ")

	// Kicks: bob may not; alice may not be kicked; bob is.
	net_send(&bob, game.Command{"kick alice"})
	expect_told(t, &bob, {&alice}, "You may not use kick")
	net_send(&alice, game.Command{"kick bob be nice"})
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {return cs[1].rejected != ""})
	testing.expect_value(t, bob.rejected, "be nice")

	// A ban by name keeps him out; unbanned, he is back.
	net_send(&alice, game.Command{"ban bob griefing"})
	expect_told(t, &alice, {}, "Banned bob for good")
	again: Net_Client
	net_connect(&again, port, "bob")
	defer net_close(&again)
	ok = net_wait(
		t,
		{&again, &alice},
		proc(cs: []^Net_Client) -> bool {return cs[0].rejected != ""},
	)
	testing.expect_value(t, again.rejected, "Banned for good: griefing")
	net_send(&alice, game.Command{"unban bob"})
	expect_told(t, &alice, {}, "Unbanned bob")
	back_again: Net_Client
	net_connect(&back_again, port, "bob")
	defer net_close(&back_again)
	ok = net_wait(
		t,
		{&back_again, &alice},
		proc(cs: []^Net_Client) -> bool {return cs[0].welcomed},
	)
	testing.expect(t, ok, "unbanned bob could not join")

	// A ban by address (loopback: everyone here but the one banning).
	net_send(&alice, game.Command{"ban-ip bob spam"})
	ok = net_wait(
		t,
		{&back_again, &alice},
		proc(cs: []^Net_Client) -> bool {return cs[0].rejected != ""},
	)
	testing.expect_value(t, back_again.rejected, "Banned: spam")
	carol: Net_Client
	net_connect(&carol, port, "carol")
	defer net_close(&carol)
	ok = net_wait(
		t,
		{&carol, &alice},
		proc(cs: []^Net_Client) -> bool {return cs[0].rejected != ""},
	)
	testing.expect_value(t, carol.rejected, "Banned for good: spam")

	// Kept with the world.
	testing.expect(t, stop(&srv))
	stopped = true
	data, err := os.read_entire_file_from_path(
		filepath.join({dir, COMMUNITY_FILE}, context.temp_allocator) or_else "",
		context.temp_allocator,
	)
	testing.expect(t, err == nil)
	text := string(data)
	for line in ([]string{"warp market 40.500", "ban_ip 127.0.0.1 0 alice spam", "player alice\nnick &bAlly", "home a ", "home c "}) {
		testing.expectf(t, strings.contains(text, line), "%q not kept:\n%s", line, text)
	}
	testing.expect(t, !strings.contains(text, "home d "), "a fourth home")
	testing.expect(t, !strings.contains(text, "ban bob"), "the ban by name stayed")
	_ = forget
}
