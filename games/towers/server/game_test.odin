package towers_server

import "core:strings"
import "core:testing"

import "common:game"
import "games:towers"
import "server:core"

// Towers on a stepped server: the host (the harness's mirror, on the local pipe) and,
// for the test of two, a guest over the harness's network. The host's edits are made on
// the server's side through the engine's own path (core.apply_edit), as a click's would
// be, so the game's editing and block_changed hooks judge and charge them.

Rig :: struct {
	sess:  core.Session,
	guest: core.Harness_Player,
	with:  bool, // the guest joined
}

// rig_start: Towers on a stepped server (listening, for a guest), the field built.
rig_start :: proc(t: ^testing.T, rig: ^Rig, guest := false) -> bool {
	config := core.harness_world()
	config.game = GAME
	config.listen = true
	config.kit = "" // (the builder's kit is the mode's)
	if !testing.expect(t, core.session_start(&rig.sess, {}, false, with = config)) {return false}
	if guest {
		core.harness_player_join(&rig.sess.h, &rig.guest, "guest")
		rig.with = true
	}
	ready :: proc(data: rawptr) -> bool {
		rig := (^Rig)(data)
		s := &rig.sess.h.srv
		if !rig.sess.mirror.welcomed || s.clients[0].state != .Playing || !state(s).built {
			return false
		}
		if rig.with {
			g := core.harness_player_client(&rig.guest)
			return g != nil && g.state == .Playing
		}
		return true
	}
	_, ok := core.harness_step_until(&rig.sess.h, ready, rig, 600)
	return testing.expect(t, ok, "the field was never built, or the players never came")
}

rig_stop :: proc(rig: ^Rig) {
	core.session_stop(&rig.sess)
	if rig.with {core.harness_player_free(&rig.guest)}
}

srv :: proc(rig: ^Rig) -> ^core.Server {return &rig.sess.h.srv}
host :: proc(rig: ^Rig) -> ^core.Client {return &rig.sess.h.srv.clients[0]}
step :: proc(rig: ^Rig, n := 1) {core.harness_step(&rig.sess.h, n)}

coins :: proc(rig: ^Rig, c: ^core.Client) -> int {return core.item_count(c, state(srv(rig)).coin)}

// place: c places (or breaks: piece nil) at `at` as a click would, standing over it;
// whether the server let it.
place :: proc(rig: ^Rig, c: ^core.Client, at: game.Block_Pos, piece: Maybe(towers.Piece)) -> bool {
	s := srv(rig)
	d := state(s)
	c.player.position = {f64(at.x) + 0.5, 3, f64(at.z) + 0.5}
	block := game.Block.Air
	if p, given := piece.?; given {block = d.blocks[p]}
	r := core.apply_edit(s, c, game.edit_plain(1, 0, at, block))
	step(rig, 2) // (charged, or paid back, before the game's tick; a notice told)
	return r.accepted
}

told :: proc(rig: ^Rig, text: string) -> bool {
	for n in rig.sess.mirror.notices {if strings.contains(n, text) {return true}}
	return false
}

// creep_cost: what the creep's way to the core costs from where it stands.
creep_cost :: proc(s: ^core.Server, h: game.Entity_Handle, k: towers.Creep) -> (f32, bool) {
	p := core.entity_pos(s.home, h)
	return core.route_cost(s.home, state(s).routes[k], {i32(p.x), 0, i32(p.z)})
}

// first_creep: the creep with the lowest id on the field.
first_creep :: proc(s: ^core.Server) -> (game.Entity_Handle, bool) {
	it := core.entities_each(s.home)
	for h in core.entities_next(&it) {
		if _, ok := creep_of(state(s), core.entity_kind(s.home, h)); ok {return h, true}
	}
	return 0, false
}

// A wave walks from the gate to the core by the shortest way: each creep's way left
// never grows as it walks, the first gets there in about the time its way takes at its
// speed, and each that gets there costs a life; with no tower on the field all five get
// there, and the wave is over (held, for what it is worth).
@(test)
test_creeps_walk_the_shortest_way_to_the_core :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !rig_start(t, rig) {return}
	defer rig_stop(rig)
	s := srv(rig)
	d := state(s)
	start, has := core.route_cost(s.home, d.routes[.Runner], towers.GATE)
	if !testing.expect(t, has, "no way from the gate") {return}
	wave_begin(s)
	step(rig, 2)
	runner, found := first_creep(s)
	if !testing.expect(t, found, "no creep came out of the gate") {return}
	id := core.entity_id(s.home, runner)
	last := start
	ticks := 0
	for ; ticks < 60 * game.TICK_RATE; ticks += 1 {
		if _, there := core.entity_find(s.home, id); !there {break}
		if c, ok := creep_cost(s, runner, .Runner); ok {
			testing.expectf(t, c <= last + 0.01, "its way grew from %v to %v", last, c)
			last = c
		}
		step(rig)
	}
	seconds := f32(ticks) / game.TICK_RATE
	expected := start / 3.4 // (blocks of way at its walk speed)
	testing.expectf(
		t,
		seconds < expected * 1.4 + 1,
		"it took %v s for a way of %v s",
		seconds,
		expected,
	)
	for i := 0; i < 60 * game.TICK_RATE && d.phase == .Wave; i += 1 {step(rig)}
	testing.expect_value(t, d.lives, towers.DEFAULT_SETTINGS.lives - towers.wave_size(1))
	testing.expect_value(t, d.phase, towers.Phase.Building)
}

// A wall across the field with one gap: the way from the gate grows, a creep goes
// through the gap and never through the wall; the wall's blocks are charged.
@(test)
test_a_wall_sends_the_creeps_round :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !rig_start(t, rig) {return}
	defer rig_stop(rig)
	s := srv(rig)
	d := state(s)
	h := host(rig)
	core.item_give(s, h, d.coin, 500)
	before, _ := core.route_cost(s.home, d.routes[.Grunt], towers.GATE)
	had := coins(rig, h)
	built := 0
	for z in i32(3) ..< towers.SIZE_Z {
		if place(rig, h, {20, 0, z}, .Wall) {built += 1}
	}
	testing.expect(t, built > 20, "the wall was not built")
	testing.expect_value(t, coins(rig, h), had - built * towers.PIECES[.Wall].price)
	after, still := core.route_cost(s.home, d.routes[.Grunt], towers.GATE)
	testing.expect(t, still, "the wall shut the way")
	testing.expectf(t, after > before + 4, "the way did not grow: %v to %v", before, after)

	d.coming[.Grunt] = 1
	d.phase = .Wave
	step(rig, 2)
	grunt, found := first_creep(s)
	if !testing.expect(t, found) {return}
	id := core.entity_id(s.home, grunt)
	crossed := false
	for _ in 0 ..< 60 * game.TICK_RATE {
		if _, there := core.entity_find(s.home, id); !there {break}
		p := core.entity_pos(s.home, grunt)
		if p.x >= 20 && p.x < 21 {
			testing.expectf(t, p.z < 3 + 0.2, "walked through the wall at %v", p)
			crossed = true
		}
		step(rig)
	}
	testing.expect(t, crossed, "the grunt never went past the wall")
}

// A wall in the last gap would shut the way: refused, with the reason, and it costs
// nothing; a wall too dear is refused as well, and so is anything but a piece, or
// breaking the map.
@(test)
test_a_wall_that_shuts_the_way_is_refused :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !rig_start(t, rig) {return}
	defer rig_stop(rig)
	s := srv(rig)
	d := state(s)
	h := host(rig)
	core.item_give(s, h, d.coin, 500)
	for z in i32(1) ..< towers.SIZE_Z {place(rig, h, {20, 0, z}, .Wall)}
	// (the last gap: z 0, or where the line was refused)
	gap: game.Block_Pos
	for z in i32(0) ..< towers.SIZE_Z {
		if b, _ := core.block_at(s.home, {20, 0, z}); b == .Air {gap = {20, 0, z}}
	}
	had := coins(rig, h)
	testing.expect(t, !place(rig, h, gap, .Wall), "the last gap was walled")
	testing.expect_value(t, coins(rig, h), had)
	testing.expect(t, told(rig, "shut the creeps' way"), "the builder was not told why")
	testing.expect(t, core.route_reaches(s.home, d.routes[.Brute], towers.GATE))

	core.item_clear(s, h, d.coin)
	testing.expect(t, !place(rig, h, {10, 0, 10}, .Cannon), "a cannon with no coins")
	testing.expect(t, told(rig, "costs 25 coins"))
	testing.expect(t, !place(rig, h, {towers.CORE_X, 0, towers.MID_Z}, nil), "the core was broken")
}

// An arrow tower by the creeps' way kills a runner by itself: its builder is paid the
// bounty and counts the kill; breaking the tower pays half its price back.
@(test)
test_a_tower_kills_a_creep_and_pays :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !rig_start(t, rig) {return}
	defer rig_stop(rig)
	s := srv(rig)
	d := state(s)
	h := host(rig)
	at := game.Block_Pos{towers.BUILD_MIN_X + 1, 0, towers.MID_Z + 2}
	if !testing.expect(t, place(rig, h, at, .Arrow), "the tower was refused") {return}
	paid := coins(rig, h)
	testing.expect_value(t, paid, towers.DEFAULT_SETTINGS.coins - towers.PIECES[.Arrow].price)
	d.coming[.Runner] = 1
	d.phase = .Wave
	for i := 0; i < 20 * game.TICK_RATE && purse(s, h).kills == 0; i += 1 {step(rig)}
	testing.expect_value(t, purse(s, h).kills, 1)
	testing.expect_value(t, coins(rig, h), paid + towers.CREEPS[.Runner].bounty)
	testing.expect_value(t, d.lives, towers.DEFAULT_SETTINGS.lives)
	step(rig, 2) // (the wave of one is held: its bonus)
	testing.expect_value(t, d.phase, towers.Phase.Building)

	before := coins(rig, h)
	testing.expect(t, place(rig, h, at, nil), "the tower could not be broken")
	testing.expect_value(t, coins(rig, h), before + towers.refund(.Arrow))
	testing.expect_value(t, d.count, 0)
}

// Lives at nought lose the run: the creeps go, the results stand, then a new run on a
// new field, the lives and the coins back.
@(test)
test_lives_at_nought_lose_the_run :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !rig_start(t, rig) {return}
	defer rig_stop(rig)
	s := srv(rig)
	d := state(s)
	h := host(rig)
	d.lives = 2
	seed, run := d.seed, d.run
	wave_begin(s)
	for i := 0; i < 60 * game.TICK_RATE && d.phase == .Wave; i += 1 {step(rig)}
	testing.expect_value(t, d.phase, towers.Phase.Results)
	testing.expect_value(t, d.outcome, towers.Outcome.Lost)
	testing.expect_value(t, alive(s), 0)
	step(rig, 2)
	r := core.mirror_game_record(&rig.sess.mirror, towers.Run)
	testing.expect(t, r != nil && r.outcome == .Lost && r.phase == .Results)

	core.item_clear(s, h, d.coin)
	step(rig, int(towers.RESULTS * game.TICK_RATE) + 2)
	testing.expect_value(t, d.run, run + 1)
	testing.expect(t, d.seed != seed, "the same field")
	testing.expect_value(t, d.lives, towers.DEFAULT_SETTINGS.lives)
	testing.expect_value(t, coins(rig, h), towers.DEFAULT_SETTINGS.coins)
}

// The last wave held wins the run: a run of one wave, every creep shot down by the host
// as it comes out (each a bounty), then the wave's bonus and the run won.
@(test)
test_the_last_wave_held_wins :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !rig_start(t, rig) {return}
	defer rig_stop(rig)
	s := srv(rig)
	d := state(s)
	h := host(rig)
	d.settings.waves = 1
	had := coins(rig, h)
	wave_begin(s)
	for i := 0; i < 60 * game.TICK_RATE && d.phase == .Wave; i += 1 {
		it := core.entities_each(s.home)
		for e in core.entities_next(&it) {
			core.entity_harm(s.home, e, {amount = 1000, kind = .Weapon, by = h, weapon = "Rifle"})
		}
		step(rig)
	}
	testing.expect_value(t, d.outcome, towers.Outcome.Won)
	testing.expect_value(t, d.lives, towers.DEFAULT_SETTINGS.lives)
	size := towers.wave_size(1)
	testing.expect_value(t, purse(s, h).kills, size)
	bonus := towers.WAVE_BONUS + towers.WAVE_BONUS_STEP
	testing.expect_value(t, coins(rig, h), had + size * towers.CREEPS[.Runner].bounty + bonus)
}

// A second player shares the run: its own coins to start, both purses told to both,
// the same run on both screens, and its tower's kill is its own.
@(test)
test_a_second_builder_shares_the_run :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !rig_start(t, rig, guest = true) {return}
	defer rig_stop(rig)
	s := srv(rig)
	d := state(s)
	g := core.harness_player_client(&rig.guest)
	testing.expect_value(t, coins(rig, g), towers.DEFAULT_SETTINGS.coins)
	testing.expect_value(t, s.registry.game_modes[g.mode].id, towers.BUILDER_MODE)
	at := game.Block_Pos{towers.BUILD_MIN_X + 1, 0, towers.MID_Z - 2}
	if !testing.expect(t, place(rig, g, at, .Arrow), "the guest's tower was refused") {return}
	d.coming[.Runner] = 1
	d.phase = .Wave
	for i := 0; i < 20 * game.TICK_RATE && purse(s, g).kills == 0; i += 1 {step(rig)}
	testing.expect_value(t, purse(s, g).kills, 1)
	testing.expect_value(t, purse(s, host(rig)).kills, 0)
	step(rig, 3)
	for id in ([]u16{0, core.player_id(s, g)}) {
		key := game.key_player(id)
		on_host := core.mirror_game_record(&rig.sess.mirror, towers.Builder, key)
		on_guest := core.harness_player_record(&rig.guest, towers.Builder, key)
		testing.expect(
			t,
			on_host != nil && on_guest != nil && on_host^ == on_guest^,
			"the purses differ",
		)
	}
	mine := core.harness_player_record(
		&rig.guest,
		towers.Builder,
		game.key_player(core.player_id(s, g)),
	)
	testing.expect(t, mine != nil && mine.kills == 1 && mine.name == "guest")
	r1, r2 :=
		core.mirror_game_record(&rig.sess.mirror, towers.Run),
		core.harness_player_record(&rig.guest, towers.Run)
	testing.expect(t, r1 != nil && r2 != nil && r1^ == r2^, "the run differs")
}

// The rules are an admin's (towers.admin: the host's, not the guest's), kept with the
// universe and read back; a line Towers does not know is refused.
@(test)
test_the_rules_are_the_admins_and_kept :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !rig_start(t, rig) {return}
	defer rig_stop(rig)
	s := srv(rig)
	d := state(s)
	core.command(&rig.sess.mirror, "towers lives 7")
	core.command(&rig.sess.mirror, "towers coins 120")
	core.command(&rig.sess.mirror, "towers waves 3")
	core.command(&rig.sess.mirror, "towers build 45")
	step(rig, 3)
	testing.expect_value(
		t,
		d.settings,
		towers.Settings{coins = 120, lives = 7, waves = 3, build = 45},
	)
	testing.expect_value(t, d.lives, 7) // (no wave yet: this run's too)
	out := strings.builder_make(context.temp_allocator)
	save(s, &out)
	d.settings = towers.DEFAULT_SETTINGS
	testing.expect(t, load(s, strings.to_string(out)))
	testing.expect_value(
		t,
		d.settings,
		towers.Settings{coins = 120, lives = 7, waves = 3, build = 45},
	)
	testing.expect(t, !load(s, "speed = 3\n"), "a line Towers does not know")
	testing.expect(t, !load(s, "waves = 900\n"), "a value out of bounds")
}
