package core

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "common:game"
import steam_common "common:steam"
import steam_server "server:steam"

// steam_config: a saved universe in build/test/<name>, listening on the harness's network,
// its Steam (the fake) the given one.
@(private = "file")
steam_config :: proc(dir: string, steam: ^steam_server.Server) -> Config {
	return {
		seed = 3,
		view_radius = 2,
		view_height = 1,
		save_dir = dir,
		max_players = 8,
		listen = true,
		generator = .Classic,
		steam = steam,
	}
}

// steam_join: a client named `name` with the account of test_key(key) and, when `number`
// is not 0, the fake Steam account of that number's ticket (a bad one when `corrupt`).
@(private = "file")
steam_join :: proc(
	t: ^testing.T,
	h: ^Harness,
	name, key: string,
	number: u32,
	corrupt := false,
) -> ^Net_Client {
	c := new(Net_Client)
	c.key_name = key
	if number != 0 {
		ticket := make([]u8, steam_common.FAKE_TICKET_LEN, context.temp_allocator)
		id := steam_common.fake_id(number)
		steam_common.fake_ticket_make(ticket, id, 1)
		if corrupt {ticket[len(ticket) - 1] ~= 0xff}
		c.steam_id, c.ticket = u64(id), ticket
	}
	net_connect(c, 0, name, h = h)
	net_wait(
		t,
		{c},
		proc(cs: []^Net_Client) -> bool {return cs[0].welcomed || cs[0].rejected != ""},
	)
	return c
}

@(private = "file")
steam_free :: proc(c: ^Net_Client) {
	net_close(c)
	free(c)
}

// The exit check of joining with a Steam identity, on the simulated network with the fake:
// a Steam client joins a Steam server and the link is stored (in community.cfg, and still
// there after a restart); the same SteamID with another key is refused, with its reason; a
// client without Steam still joins; a bad ticket is refused, with its reason.
@(test)
test_steam_join_links_the_account :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "steam_join"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	fake: steam_server.Server
	testing.expect(t, steam_server.open_fake(&fake, {}))
	h := new(Harness)
	defer free(h)
	if !testing.expect(t, harness_start(h, steam_config(dir, &fake))) {return}
	stopped := false
	defer if !stopped {harness_stop(h)}

	alice := steam_join(t, h, "alice", "alice", 9)
	defer steam_free(alice)
	testing.expect(t, alice.welcomed, "the Steam client did not join a Steam server")
	testing.expect_value(t, steam_server.sessions(&fake), 0) // (the check's session is closed)

	carol := steam_join(t, h, "carol", "carol", 0)
	defer steam_free(carol)
	testing.expect(t, carol.welcomed, "a client without Steam did not join")

	bad := steam_join(t, h, "dave", "dave", 11, corrupt = true)
	defer steam_free(bad)
	testing.expect(t, !bad.welcomed)
	testing.expect_value(t, bad.rejected, "Steam refused your ticket")

	// Not alice's account yet, but linked to it from here on: bob with her SteamID.
	bob := steam_join(t, h, "bob", "bob", 9)
	defer steam_free(bob)
	testing.expect(t, !bob.welcomed)
	testing.expect_value(
		t,
		bob.rejected,
		"this Steam account is linked to another account key on this server",
	)

	testing.expect(t, harness_stop(h))
	stopped = true
	cfg := filepath.join({dir, COMMUNITY_FILE}, context.temp_allocator) or_else ""
	data, err := os.read_entire_file_from_path(cfg, context.temp_allocator)
	testing.expect(t, err == nil)
	line := strings.concatenate(
		{
			"steam ",
			steam_common_text(steam_common.fake_id(9)),
			" ",
			game.account_text(test_key("alice").account),
		},
		context.temp_allocator,
	)
	testing.expectf(t, strings.contains(string(data), line), "no %q in community.cfg", line)
	testing.expect(
		t,
		!strings.contains(string(data), "steam 76561197960265739"),
		"dave was linked",
	)

	// The link survives a restart: alice joins again with it, bob is still refused.
	if !testing.expect(t, harness_start(h, steam_config(dir, &fake))) {return}
	stopped = false
	again := steam_join(t, h, "alice", "alice", 9)
	defer steam_free(again)
	testing.expect(t, again.welcomed, "alice could not join again")
	other := steam_join(t, h, "bob", "bob", 9)
	defer steam_free(other)
	testing.expect(t, !other.welcomed && other.rejected != "")
}

// An expired ticket is refused with its reason, and nothing is linked.
@(test)
test_steam_expired_ticket_is_refused :: proc(t: ^testing.T) {
	fake: steam_server.Server
	testing.expect(t, steam_server.open_fake(&fake, {expire = true}))
	h := new(Harness)
	defer free(h)
	if !testing.expect(t, harness_start(h, steam_config("", &fake))) {return}
	defer harness_stop(h)
	c := steam_join(t, h, "alice", "alice", 9)
	defer steam_free(c)
	testing.expect(t, !c.welcomed)
	testing.expect_value(
		t,
		c.rejected,
		"your Steam ticket has expired; restart the game and join again",
	)
	testing.expect_value(t, len(h.srv.community.steam_links), 0)
}

// A server without Steam ignores the ticket: the account key alone, no link.
@(test)
test_server_without_steam_ignores_ticket :: proc(t: ^testing.T) {
	h := new(Harness)
	defer free(h)
	if !testing.expect(t, harness_start(h, steam_config("", nil))) {return}
	defer harness_stop(h)
	c := steam_join(t, h, "alice", "alice", 9)
	defer steam_free(c)
	testing.expect(t, c.welcomed)
	testing.expect_value(t, len(h.srv.community.steam_links), 0)
}

@(private = "file")
steam_common_text :: proc(id: steam_common.Steam_ID) -> string {
	return fmt.tprintf("%d", u64(id))
}

@(private = "file")
Admin_Probe :: struct {
	names:  [4]string,
	admins: [4]bool,
}

// admin_probe: whether each of the named players has every permission (the admin role).
@(private = "file")
admin_probe :: proc(h: ^Harness, names: [4]string) -> [4]bool {
	probe := Admin_Probe {
		names = names,
	}
	call(&h.srv, proc(s: ^Server, data: rawptr) {
			p := (^Admin_Probe)(data)
			for name, i in p.names {
				if c := client_by_name(s, name); c != nil {
					p.admins[i] = allowed(s, c, "permissions.edit")
				}
			}
		}, &probe)
	return probe.admins
}

// The exit check of admins by SteamID: a `steam:` line in admins.cfg makes the player whose
// ticket Steam accepted an admin, and no one else: not the same account key without Steam,
// not another SteamID, not a client that sends the ID with a ticket for another one, and
// not any client on a server without Steam (it cannot check the ID, so it never trusts it).
@(test)
test_steam_admin_line_grants_only_the_validated_player :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "steam_admin"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	os.make_directory_all(dir)
	line := fmt.tprintf("# the owner\nsteam:%d # me\n", u64(steam_common.fake_id(9)))
	_ = os.write_entire_file(
		filepath.join({dir, ADMINS_FILE}, context.temp_allocator) or_else "",
		transmute([]u8)line,
	)
	fake: steam_server.Server
	testing.expect(t, steam_server.open_fake(&fake, {}))
	h := new(Harness)
	defer free(h)
	if !testing.expect(t, harness_start(h, steam_config(dir, &fake))) {return}
	defer harness_stop(h)

	owner := steam_join(t, h, "owner", "owner", 9)
	defer steam_free(owner)
	other := steam_join(t, h, "other", "other", 10)
	defer steam_free(other)
	plain := steam_join(t, h, "plain", "plain", 0)
	defer steam_free(plain)
	// A client that claims the owner's SteamID with a ticket made for another one.
	liar := new(Net_Client)
	defer steam_free(liar)
	liar.key_name = "liar"
	ticket := make([]u8, steam_common.FAKE_TICKET_LEN, context.temp_allocator)
	steam_common.fake_ticket_make(ticket, steam_common.fake_id(11), 1)
	liar.steam_id, liar.ticket = u64(steam_common.fake_id(9)), ticket
	net_connect(liar, 0, "liar", h = h)
	net_wait(
		t,
		{liar},
		proc(cs: []^Net_Client) -> bool {return cs[0].welcomed || cs[0].rejected != ""},
	)
	testing.expect(t, owner.welcomed && other.welcomed && plain.welcomed)
	admins := admin_probe(h, {"owner", "other", "plain", "liar"})
	testing.expect(t, admins[0], "the validated owner is not an admin")
	testing.expect(t, !admins[1], "another SteamID is an admin")
	testing.expect(t, !admins[2], "a client without Steam is an admin")
	testing.expect(t, !admins[3], "a client that claims the ID is an admin")

	// The same account key without Steam is not the SteamID.
	owner2 := steam_join(t, h, "owner2", "owner", 0)
	defer steam_free(owner2)
	testing.expect(t, owner2.welcomed)
	testing.expect(t, !admin_probe(h, {"owner2", "", "", ""})[0], "the key alone was an admin")
}

// A server without Steam never trusts a claimed SteamID, listed or not.
@(test)
test_steam_admin_line_needs_steam_on :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "steam_admin_off"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	os.make_directory_all(dir)
	line := fmt.tprintf("steam:%d\n", u64(steam_common.fake_id(9)))
	_ = os.write_entire_file(
		filepath.join({dir, ADMINS_FILE}, context.temp_allocator) or_else "",
		transmute([]u8)line,
	)
	h := new(Harness)
	defer free(h)
	if !testing.expect(t, harness_start(h, steam_config(dir, nil))) {return}
	defer harness_stop(h)
	c := steam_join(t, h, "owner", "owner", 9)
	defer steam_free(c)
	testing.expect(t, c.welcomed)
	testing.expect(t, !admin_probe(h, {"owner", "", "", ""})[0], "a claimed ID was trusted")
}
