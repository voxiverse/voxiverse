package core

import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "common:base"
import "common:game"

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
	h := new(Harness)
	defer free(h)
	srv := &h.srv
	if !testing.expect(
		t,
		harness_start(
			h,
			Config {
				seed = 21,
				mode = "survival",
				view_radius = 2,
				view_height = 1,
				save_dir = dir,
				max_players = 4,
				listen = true,
				generator = .Classic,
			},
		),
	) {return}
	defer harness_stop(h)
	alice := new(Net_Client)
	defer free(alice)
	bob := new(Net_Client)
	defer free(bob)
	net_connect(alice, 0, "alice", h = h)
	net_connect(bob, 0, "bob", h = h)
	defer net_close(alice)
	defer net_close(bob)
	both := []^Net_Client{alice, bob}
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
		p := probe(srv, name)
		testing.expect_value(t, p.label, "survival")
		testing.expect(
			t,
			.Health in p.abilities && .Fly not_in p.abilities && .Catalog not_in p.abilities,
		)
	}

	// The operator makes themselves creative: they may fly; bob stays in survival.
	net_send(alice, game.Command{"gamemode creative"})
	expect_told(t, alice, {bob}, "alice: game mode creative")
	a, b := probe(srv, "alice"), probe(srv, "bob")
	testing.expect(t, .Fly in a.abilities && .Invulnerable in a.abilities, "alice can fly")
	testing.expect(t, .Fly not_in b.abilities && b.label == "survival", "bob stays in survival")
	testing.expect_value(t, alice.mode, "voxiverse:creative") // (replicated)
	testing.expect_value(t, bob.mode, "voxiverse:survival")

	// Without the nodes: refused, clearly, whoever the target is.
	net_send(bob, game.Command{"gamemode creative"})
	expect_told(t, bob, {alice}, "You may not change your own game mode.")
	net_send(bob, game.Command{"gamemode creative alice"})
	expect_told(t, bob, {alice}, "You may not change another player's game mode.")
	testing.expect_value(t, probe(srv, "bob").label, "survival")
	net_send(bob, game.Command{"gamemode"}) // asking is free
	expect_told(t, bob, {alice}, "game mode survival")

	// The operator changes bob's; he is told; a mode that does not exist is refused.
	net_send(alice, game.Command{"gamemode creative bob"})
	expect_told(t, bob, {alice}, "Your game mode is now creative")
	testing.expect_value(t, probe(srv, "bob").label, "creative")
	net_send(alice, game.Command{"gamemode spectator"})
	expect_told(t, alice, {bob}, "No game mode spectator")

	// The journal says who changed what.
	Journal_Probe :: struct {
		found_self, found_bob: bool,
	}
	jp: Journal_Probe
	call(srv, proc(s: ^Server, data: rawptr) {
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
	net_send(bob, game.Command{"rule pvp false"})
	expect_told(t, bob, {alice}, "You may not change rules here.")
	net_send(bob, game.Command{"rule pvp"})
	expect_told(t, bob, {alice}, "pvp = true")
	net_send(alice, game.Command{"rule pvp false"})
	expect_told(t, alice, {bob}, "pvp = false")
	net_send(alice, game.Command{"rule default_game_mode creative"})
	expect_told(t, alice, {bob}, "default_game_mode = creative")
	net_send(alice, game.Command{"rule keep_inventory false"})
	expect_told(t, alice, {bob}, "keep_inventory = false")
	rules_found: int
	call(srv, proc(s: ^Server, data: rawptr) {
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

// A mode with the spectate ability only watches: the server refuses its edits and
// rockets, which the same player in creative makes.
@(test)
test_spectators_change_nothing :: proc(t: ^testing.T) {
	MODES :: `{"watcher": {"abilities": ["fly", "invulnerable", "spectate"], "kit": [], "rules": {}}}`
	PACK :: `{"format": 1, "namespace": "watching", "version": "1.0.0", "title": "Watching", "requires": ["voxiverse"]}`
	config := harness_world()
	config.extra_packs = []game.Pack_Source {
		{
			"watching",
			{
				{"pack.json", transmute([]u8)string(PACK)},
				{"data/game_modes/watcher.json", transmute([]u8)string(MODES)},
			},
		},
	}
	sess := new(Session)
	defer free(sess)
	if !testing.expect(t, session_start(sess, {}, false, with = config)) {return}
	defer session_stop(sess)
	welcomed :: proc(data: rawptr) -> bool {return (^Session)(data).mirror.welcomed}
	_, ok := harness_step_until(&sess.h, welcomed, sess, 600)
	if !testing.expect(t, ok, "the player never joined") {return}
	harness_step(&sess.h, 30)
	s := &sess.h.srv
	c := &s.clients[0]
	watcher, found := game.mode_find(s.registry, "watching:watcher")
	if !testing.expect(t, found, "the pack's mode is not there") {return}
	creative, _ := game.mode_find(s.registry, "creative")

	p := c.player.position
	under := game.Block_Pos{i32(math.floor(p.x)), i32(math.floor(p.y)) - 1, i32(math.floor(p.z))}
	was, _ := chunks_block(&c.world.chunks, under)
	testing.expect(t, was != .Air, "the player stands on air")
	testing.expect_value(t, set_game_mode(s, c, watcher, {"command", ""}), Mode_Result.Ok)
	testing.expect(t, has_ability(s, c, .Spectate))
	queue_action(s, c, game.edit_plain(1, c.inputs.last, under, .Air))
	queue_action(s, c, game.Fire{c.inputs.last, 0, -1.5})
	b, _ := chunks_block(&c.world.chunks, under)
	testing.expect_value(t, b, was)
	testing.expect_value(t, c.fired_at, 0)

	testing.expect_value(t, set_game_mode(s, c, creative, {"command", ""}), Mode_Result.Ok)
	queue_action(s, c, game.edit_plain(2, c.inputs.last, under, .Air))
	queue_action(s, c, game.Fire{c.inputs.last, 0, -1.5})
	b, _ = chunks_block(&c.world.chunks, under)
	testing.expect_value(t, b, game.Block.Air)
	testing.expect_value(t, c.fired_at, s.tick)
}

// A mode with the bodiless ability has no body: its player has no entity (so a blast, a
// pickup or a walker's push finds nothing), others are not shown where it is, a block may
// go where it is, and a blast beside it does no harm; back in survival it has a body.
@(test)
test_bodiless_has_no_body :: proc(t: ^testing.T) {
	MODES :: `{"planner": {"abilities": ["bodiless"], "kit": [], "rules": {}}}`
	PACK :: `{"format": 1, "namespace": "planning", "version": "1.0.0", "title": "Planning", "requires": ["voxiverse"]}`
	config := harness_world()
	config.extra_packs = []game.Pack_Source {
		{
			"planning",
			{
				{"pack.json", transmute([]u8)string(PACK)},
				{"data/game_modes/planner.json", transmute([]u8)string(MODES)},
			},
		},
	}
	sess := new(Session)
	defer free(sess)
	if !testing.expect(t, session_start(sess, {}, false, with = config)) {return}
	defer session_stop(sess)
	welcomed :: proc(data: rawptr) -> bool {return (^Session)(data).mirror.welcomed}
	_, ok := harness_step_until(&sess.h, welcomed, sess, 600)
	if !testing.expect(t, ok, "the player never joined") {return}
	harness_step(&sess.h, 30)
	s := &sess.h.srv
	c := &s.clients[0]
	testing.expect(t, c.entity_id != 0, "a player in survival has a body")
	planner, found := game.mode_find(s.registry, "planning:planner")
	if !testing.expect(t, found, "the pack's mode is not there") {return}
	testing.expect_value(t, set_game_mode(s, c, planner, {"command", ""}), Mode_Result.Ok)
	harness_step(&sess.h, 2)
	testing.expect(t, bodiless(s, c))
	testing.expect_value(t, c.entity_id, game.Entity_Id(0))
	testing.expect_value(t, len(players_near(c.world, c.player.position, 4, 4)), 0)
	health := c.health
	explode_by(s, "", game.block_of_position(c.player.position) + {1, 0, 0}, 3)
	harness_step(&sess.h, 2)
	testing.expect_value(t, c.health, health)
	testing.expect(t, !c.dead)
	survival, _ := game.mode_find(s.registry, "survival")
	testing.expect_value(t, set_game_mode(s, c, survival, {"command", ""}), Mode_Result.Ok)
	harness_step(&sess.h, 2)
	testing.expect(t, c.entity_id != 0, "back in survival it has no body")
}
