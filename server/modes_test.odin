package server

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "../base"
import "../common/game"

// Game modes per player, through permissions: an operator's /gamemode changes
// their own mode (and another's); a player without the nodes is refused;
// what a character can do is its abilities; the journal says who changed it.

@(private = "file")
want_text: string

@(private = "file")
told :: proc(cs: []^Net_Client) -> bool {
	c := cs[0]
	for n in c.notices {if strings.has_prefix(game.format_strip(n), want_text) {return true}}
	return false
}

@(private = "file")
expect_told :: proc(
	t: ^testing.T,
	c: ^Net_Client,
	others: []^Net_Client,
	text: string,
	loc := #caller_location,
) {
	want_text = text
	all := make([dynamic]^Net_Client, context.temp_allocator)
	append(&all, c)
	append(&all, ..others)
	testing.expectf(t, net_wait(t, all[:], told, 5), "%s was not told %q", c.name, text, loc = loc)
}

@(private = "file")
Abilities_Probe :: struct {
	name:      string,
	abilities: game.Abilities,
	label:     string,
}

@(private = "file")
probe :: proc(srv: ^Server, name: string) -> (out: Abilities_Probe) {
	out.name = name
	call(srv, proc(s: ^Server, data: rawptr) {
			p := (^Abilities_Probe)(data)
			if c := client_by_name(s, p.name); c != nil {
				p.abilities = game.derive_abilities(s.registry, c.mode, &c.inventory)
				p.label = game.mode_label(s.registry, c.mode)
			}
		}, &out)
	return
}

@(test)
test_gamemode_is_per_player_and_guarded :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "game_modes"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	os.make_directory_all(dir)
	perms := strings.concatenate(
		{DEFAULT_PERMISSIONS, "player alice\nrole admin\n"},
		context.temp_allocator,
	)
	cfg := filepath.join({dir, PERMISSIONS_FILE}, context.temp_allocator) or_else ""
	testing.expect(t, os.write_entire_file(cfg, transmute([]u8)perms) == nil)
	srv: Server
	if !testing.expect(
		t,
		start(
			&srv,
			Config {
				seed = 21,
				mode = "survival",
				view_radius = 2,
				view_height = 1,
				workers = 1,
				save_dir = dir,
				max_players = 4,
				listen = true,
				generator = .Classic,
			},
			{},
		),
	) {return}
	defer stop(&srv)
	for !srv.listening {}
	port := srv.host.socket.port
	alice, bob: Net_Client
	net_connect(&alice, port, "alice")
	net_connect(&bob, port, "bob")
	defer net_close(&alice)
	defer net_close(&bob)
	both := []^Net_Client{&alice, &bob}
	ok := net_wait(t, both, proc(cs: []^Net_Client) -> bool {
		return(
			cs[0].welcomed &&
			cs[1].welcomed &&
			len(cs[0].grants) > 0 &&
			len(cs[1].grants) > 0 &&
			cs[0].mode != "" &&
			cs[1].mode != "" \
		)
	})
	if !testing.expect(t, ok, "never joined") {return}

	// Everyone starts in the universe's default: survival (health, no flight, no catalog).
	for name in ([]string{"alice", "bob"}) {
		p := probe(&srv, name)
		testing.expect_value(t, p.label, "survival")
		testing.expect(
			t,
			.Health in p.abilities && .Fly not_in p.abilities && .Catalog not_in p.abilities,
		)
	}

	// The operator makes themselves creative: they may fly; bob stays in survival.
	net_send(&alice, game.Command{"gamemode creative"})
	expect_told(t, &alice, {&bob}, "alice: game mode creative")
	a, b := probe(&srv, "alice"), probe(&srv, "bob")
	testing.expect(t, .Fly in a.abilities && .Invulnerable in a.abilities, "alice can fly")
	testing.expect(t, .Fly not_in b.abilities && b.label == "survival", "bob stays in survival")
	testing.expect_value(t, alice.mode, "voxiverse:creative") // (replicated)
	testing.expect_value(t, bob.mode, "voxiverse:survival")

	// Without the nodes: refused, clearly, whoever the target is.
	net_send(&bob, game.Command{"gamemode creative"})
	expect_told(t, &bob, {&alice}, "You may not change your own game mode.")
	net_send(&bob, game.Command{"gamemode creative alice"})
	expect_told(t, &bob, {&alice}, "You may not change another player's game mode.")
	testing.expect_value(t, probe(&srv, "bob").label, "survival")
	net_send(&bob, game.Command{"gamemode"}) // asking is free
	expect_told(t, &bob, {&alice}, "game mode survival")

	// The operator changes bob's; he is told; a mode that does not exist is refused.
	net_send(&alice, game.Command{"gamemode creative bob"})
	expect_told(t, &bob, {&alice}, "Your game mode is now creative")
	testing.expect_value(t, probe(&srv, "bob").label, "creative")
	net_send(&alice, game.Command{"gamemode spectator"})
	expect_told(t, &alice, {&bob}, "No game mode spectator")

	// The journal says who changed what.
	Journal_Probe :: struct {
		found_self, found_bob: bool,
	}
	jp: Journal_Probe
	call(&srv, proc(s: ^Server, data: rawptr) {
			p := (^Journal_Probe)(data)
			j := &s.home.journal
			for rec in j.actions {
				if rec.system != .Setting {continue}
				who := j.actors[rec.actor]
				if who.name == "alice" &&
				   strings.has_prefix(rec.command, "gamemode creative alice") {p.found_self = true}
				if who.name == "alice" &&
				   strings.has_prefix(rec.command, "gamemode creative bob") {p.found_bob = true}
			}
		}, &jp)
	testing.expect(
		t,
		jp.found_self && jp.found_bob,
		"the journal records both changes with alice as the actor",
	)

	// Rules: read by anyone, set only with the node, journalled with who set them.
	net_send(&bob, game.Command{"rule pvp false"})
	expect_told(t, &bob, {&alice}, "You may not change rules here.")
	net_send(&bob, game.Command{"rule pvp"})
	expect_told(t, &bob, {&alice}, "pvp = true")
	net_send(&alice, game.Command{"rule pvp false"})
	expect_told(t, &alice, {&bob}, "pvp = false")
	net_send(&alice, game.Command{"rule default_game_mode creative"})
	expect_told(t, &alice, {&bob}, "default_game_mode = creative")
	net_send(&alice, game.Command{"rule keep_inventory false"})
	expect_told(t, &alice, {&bob}, "keep_inventory = false")
	rules_found: int
	call(&srv, proc(s: ^Server, data: rawptr) {
			n := (^int)(data)
			j := &s.home.journal
			for rec in j.actions {
				if rec.system == .Setting &&
				   j.actors[rec.actor].name == "alice" &&
				   strings.has_prefix(rec.command, "rule ") {n^ += 1}
			}
		}, &rules_found)
	testing.expect_value(t, rules_found, 3)
}

// No code tests a game mode by name: systems ask for abilities. The creation
// screen's labels are the one place the base modes' words appear in a
// comparison (and the console's inventory tab is not a mode).
@(test)
test_no_code_tests_a_mode_by_name :: proc(t: ^testing.T) {
	allowed := []string{"screen_creation.odin", "screen_universes.odin", "overlay_console.odin"}
	found := 0
	for dir in ([]string{"server", "client", "common"}) {
		w := os.walker_create(dir)
		defer os.walker_destroy(&w)
		files: for info in os.walker_walk(&w) {
			if info.type == .Directory || !strings.has_suffix(info.name, ".odin") {continue}
			if strings.has_suffix(info.name, "_test.odin") {continue}
			for a in allowed {if info.name == a {continue files}}
			data, err := os.read_entire_file(info.fullpath, context.temp_allocator)
			if err != nil {continue}
			rest := string(data)
			for line in strings.split_lines_iterator(&rest) {
				code, _, _ := strings.partition(line, "//")
				for word in ([]string{"creative", "survival"}) {
					for op in ([]string{"== \"", "!= \""}) {
						plain := strings.concatenate({op, word, "\""}, context.temp_allocator)
						based := strings.concatenate({op, "base:", word}, context.temp_allocator)
						if strings.contains(code, plain) || strings.contains(code, based) {
							testing.expectf(
								t,
								false,
								"%s tests a mode by name: %s",
								info.fullpath,
								line,
							)
							found += 1
						}
					}
				}
			}
		}
	}
	testing.expect_value(t, found, 0)
}

// A character's mode is kept with it; a file from before modes has none, and the
// character takes the world's default.
@(test)
test_the_mode_is_saved_with_the_character :: proc(t: ^testing.T) {
	r: Player_Record
	base.var_text_set(&r.mode, "voxiverse:creative")
	back, ok := player_parse(test_reg(), player_json(test_reg(), &r))
	testing.expect(t, ok)
	testing.expect_value(t, base.var_text(&back.mode), "voxiverse:creative")
	r2: Player_Record
	old, ok2 := player_parse(test_reg(), player_json(test_reg(), &r2))
	testing.expect(t, ok2)
	testing.expect_value(t, base.var_text(&old.mode), "")
}
