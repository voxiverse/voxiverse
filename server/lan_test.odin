package server

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "../base"
import "../common/game"

// Open to LAN's two settings (the client's dialog sends them as commands): the
// guests' game mode (the rule default_game_mode: a guest who joins gets it,
// whatever the universe's is) and their role (the rule guest_role: `mod` gives
// the commands nodes, `default` only what everyone has; players already here
// are told at once); Close LAN shuts the port and takes the role away.

@(private = "file")
Probe :: struct {
	name:    string,
	node:    string,
	allowed: bool,
}

@(private = "file")
may :: proc(srv: ^Server, name, node: string) -> bool {
	p := Probe {
		name = name,
		node = node,
	}
	call(srv, proc(s: ^Server, data: rawptr) {
			p := (^Probe)(data)
			if c := client_by_name(s, p.name); c != nil {p.allowed = allowed(s, c, p.node)}
		}, &p)
	return p.allowed
}

@(private = "file")
joined :: proc(cs: []^Net_Client) -> bool {
	for c in cs {if !c.welcomed || len(c.grants) == 0 || c.mode == "" {return false}}
	return true
}

@(test)
test_open_to_lan_settings :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "open_lan"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	os.make_directory_all(dir)
	perms := strings.concatenate(
		{DEFAULT_PERMISSIONS, "player alice\nrole admin\n"},
		context.temp_allocator,
	)
	cfg := filepath.join({dir, PERMISSIONS_FILE}, context.temp_allocator) or_else ""
	testing.expect(t, os.write_entire_file(cfg, transmute([]u8)perms) == nil)
	h: Harness
	srv := &h.srv
	if !testing.expect(
		t,
		harness_start(
			&h,
			Config {
				seed = 22,
				mode = "creative",
				view_radius = 2,
				view_height = 1,
				save_dir = dir,
				max_players = 4,
				listen = true,
				generator = .Classic,
			},
		),
	) {return}
	defer harness_stop(&h)
	alice, bob, cy: Net_Client
	net_connect(&alice, 0, "alice", h = &h)
	net_connect(&bob, 0, "bob", h = &h)
	defer net_close(&alice)
	defer net_close(&bob)
	defer net_close(&cy)
	if !testing.expect(t, net_wait(t, {&alice, &bob}, joined), "never joined") {return}

	lan_srv = srv
	both := []^Net_Client{&alice, &bob}
	// Off (the default role only): the guest has no commands nodes.
	testing.expect(t, !may(srv, "bob", "teleport.tp"))
	testing.expect(t, may(srv, "alice", "teleport.tp"))
	// Allow commands: the mod role, for the guest already in, at once.
	net_send(&alice, game.Command{"rule guest_role mod"})
	testing.expect(
		t,
		net_wait(
			t,
			both,
			proc(_: []^Net_Client) -> bool {return may(lan_srv, "bob", "teleport.tp")},
			5,
		),
		"bob has the mod role",
	)
	testing.expect(t, !may(srv, "bob", "server.open_lan"), "mod is not admin")
	net_send(&alice, game.Command{"rule guest_role default"})
	testing.expect(
		t,
		net_wait(
			t,
			both,
			proc(_: []^Net_Client) -> bool {return !may(lan_srv, "bob", "teleport.tp")},
			5,
		),
		"off again",
	)

	// The guests' game mode: a guest who joins afterwards has it, not the universe's.
	net_send(&alice, game.Command{"rule default_game_mode survival"})
	testing.expect(
		t,
		net_wait(
			t,
			both,
			proc(_: []^Net_Client) -> bool {return(
					base_rule(lan_srv, "default_game_mode") ==
					"survival" \
				)},
			5,
		),
		"the rule is set",
	)
	net_connect(&cy, 0, "cy", h = &h)
	if !testing.expect(t, net_wait(t, {&alice, &cy}, joined), "cy never joined") {return}
	testing.expect_value(t, cy.mode, "voxiverse:survival")
	testing.expect_value(t, alice.mode, "voxiverse:creative") // (the host's own is theirs)

	// Close LAN: the port is shut, the guests' role is gone.
	net_send(&alice, game.Command{"rule guest_role mod"})
	net_send(&alice, game.Command{"close_lan"})
	testing.expect(
		t,
		net_wait(
			t,
			{&alice, &bob},
			proc(_: []^Net_Client) -> bool {return !listening(lan_srv)},
			5,
		),
		"the port is shut",
	)
	testing.expect_value(t, base_rule(srv, "guest_role"), "")
}

@(private = "file")
lan_srv: ^Server

@(private = "file")
listening :: proc(srv: ^Server) -> bool {
	on: bool
	call(srv, proc(s: ^Server, data: rawptr) {(^bool)(data)^ = s.listening}, &on)
	return on
}

@(private = "file")
base_rule :: proc(srv: ^Server, name: string) -> string {
	Query :: struct {
		name: string,
		text: [64]u8,
		n:    int,
	}
	q := Query {
		name = name,
	}
	call(srv, proc(s: ^Server, data: rawptr) {
			q := (^Query)(data)
			table := game.rules_table()
			if v, ok := base.var_find(table, rule_name(q.name)); ok {
				q.n = copy(q.text[:], base.var_format(table, &s.home.rules, v))
			}
		}, &q)
	return strings.clone(string(q.text[:q.n]), context.temp_allocator)
}
