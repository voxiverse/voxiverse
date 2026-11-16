package arena_server

import "core:os"
import "core:strings"
import "core:testing"

import "common:game"
import "games:arena"
import "server:core"

// Arena on a stepped server with two players: the host (the harness's mirror, on the
// local pipe) and a guest over the harness's network, so a match starts as it would
// over the LAN. The fighting is done on the server's side through the engine's damage
// pipeline (core.damage), as a shot or a rocket does it.

Rig :: struct {
	sess:  core.Session,
	guest: core.Harness_Player,
}

// rig_start: Arena on a listening stepped server, both players in it.
rig_start :: proc(t: ^testing.T, rig: ^Rig, save_dir := "") -> bool {
	config := core.harness_world()
	config.game = GAME
	config.listen = true
	config.save_dir = save_dir
	// (Not the engine's tests' kit, a hotbar of blocks the fighter's kit could not join.)
	config.kit = "rocket_launcher 1"
	if !testing.expect(t, core.session_start(&rig.sess, {}, false, with = config)) {return false}
	core.harness_player_join(&rig.sess.h, &rig.guest, "guest")
	joined :: proc(data: rawptr) -> bool {
		rig := (^Rig)(data)
		g := core.harness_player_client(&rig.guest)
		return rig.sess.mirror.welcomed && g != nil && g.state == .Playing
	}
	_, ok := core.harness_step_until(&rig.sess.h, joined, rig, 600)
	return testing.expect(t, ok, "the players never joined")
}

rig_stop :: proc(rig: ^Rig) {
	core.session_stop(&rig.sess)
	core.harness_player_free(&rig.guest)
}

srv :: proc(rig: ^Rig) -> ^core.Server {return &rig.sess.h.srv}
host :: proc(rig: ^Rig) -> ^core.Client {return &rig.sess.h.srv.clients[0]}
guest :: proc(rig: ^Rig) -> ^core.Client {return core.harness_player_client(&rig.guest)}

// until_phase steps until the match is in phase (false: not within seconds).
until_phase :: proc(rig: ^Rig, phase: arena.Phase, seconds := 20) -> bool {
	Wait :: struct {
		rig:   ^Rig,
		phase: arena.Phase,
	}
	wait := Wait{rig, phase}
	_, ok := core.harness_step_until(&rig.sess.h, proc(data: rawptr) -> bool {
			w := (^Wait)(data)
			return state(srv(w.rig)).phase == w.phase
		}, &wait, seconds * game.TICK_RATE)
	return ok
}

// say: the host's command, and the ticks for it to be done.
say :: proc(rig: ^Rig, text: string) {
	core.command(&rig.sess.mirror, text)
	core.harness_step(&rig.sess.h, 2)
}

told :: proc(rig: ^Rig, text: string) -> bool {
	for n in rig.sess.mirror.notices {if strings.has_prefix(n, text) {return true}}
	return false
}

// kill: by kills victim with a shot, through the engine's pipeline (by == victim: its
// own); by nil: a fall.
kill :: proc(rig: ^Rig, victim, by: ^core.Client) -> core.Damage_Result {
	s := srv(rig)
	if by == nil {return core.damage(s, victim, 1000, {kind = .Fall})}
	return core.damage(
		s,
		victim,
		1000,
		{kind = .Weapon, attacker = core.player_id(s, by), weapon = "Rifle"},
	)
}

mode_of :: proc(rig: ^Rig, c: ^core.Client) -> string {
	return srv(rig).registry.game_modes[c.mode].id
}

// at_spawn: c stands at one of the courtyard's spawn points.
at_spawn :: proc(rig: ^Rig, c: ^core.Client) -> bool {
	for p in state(srv(rig)).spawns {
		d := c.player.position - p
		if abs(d.x) < 0.01 && abs(d.z) < 0.01 && abs(d.y) < 1.01 {return true}
	}
	return false
}

// has_kit: c holds the fighter's kit: the launcher (in hand), the rifle and the hook.
has_kit :: proc(rig: ^Rig, c: ^core.Client) -> bool {
	reg := srv(rig).registry
	for id in ([]string{"rocket_launcher", "rifle", "grappling_hook"}) {
		item, _ := game.registry_item(reg, id)
		if game.inventory_count(&c.inventory, item) != 1 {return false}
	}
	launcher, _ := game.registry_item(reg, "rocket_launcher")
	return game.inventory_held(&c.inventory).item == launcher
}

// A match, whole: the warm-up holds until the second player is in, then the courtyard
// is built and counted down and both fight from spawn points with the kit. A kill is a
// frag for the killer and a death for the victim, told to both as scores and as a line
// of the feed; the victim comes back after the delay at a spawn point with the kit; a
// death by one's own hand or a fall takes a frag away. The frag limit ends the match
// with its winner; the next starts in a new courtyard, every score at nought.
@(test)
test_arena_match :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !rig_start(t, rig) {return}
	defer rig_stop(rig)
	s := srv(rig)
	a := state(s)
	h, g := host(rig), guest(rig)

	// Warm-up, then the countdown (two players: enough over the LAN), then the match.
	if !testing.expect(t, until_phase(rig, .Countdown), "no countdown") {return}
	testing.expect_value(t, a.match, 1)
	testing.expect_value(t, mode_of(rig, h), arena.WATCHING_MODE)
	if !testing.expect(t, until_phase(rig, .Playing), "the match never started") {return}
	testing.expect(t, a.built)
	core.harness_step(&rig.sess.h, 5)
	for c in ([]^core.Client{h, g}) {
		testing.expect_value(t, mode_of(rig, c), arena.FIGHTER_MODE)
		testing.expect(t, has_kit(rig, c), "a fighter without the kit")
		testing.expect(t, at_spawn(rig, c), "a fighter not at a spawn point")
	}
	testing.expect(t, h.player.position != g.player.position, "both at one spawn point")
	b, _ := core.block_at(s.home, {-1, 10, 10})
	testing.expect_value(t, b, game.Block.Bedrock)

	// The host kills the guest: a frag and a death, and both are told.
	testing.expect_value(t, kill(rig, g, h), core.Damage_Result.Killed)
	testing.expect_value(t, fighter(s, h).frags, 1)
	testing.expect_value(t, fighter(s, g).deaths, 1)
	testing.expect_value(t, fighter(s, g).frags, 0)
	core.harness_step(&rig.sess.h, 3)
	key := game.key_player(core.player_id(s, h))
	mine := core.mirror_game_record(&rig.sess.mirror, arena.Score, key)
	theirs := core.harness_player_record(&rig.guest, arena.Score, key)
	testing.expect(t, mine != nil && mine.frags == 1 && mine.name == core.client_name(h))
	testing.expect(t, theirs != nil && theirs.frags == 1, "the guest was not told the host's frag")
	victim := core.harness_player_record(
		&rig.guest,
		arena.Score,
		game.key_player(core.player_id(s, g)),
	)
	testing.expect(t, victim != nil && victim.deaths == 1)

	// The guest comes back by itself after the delay, at a spawn point, with the kit.
	testing.expect(t, g.dead)
	delay := int(a.settings.respawn_delay * game.TICK_RATE)
	core.harness_step(&rig.sess.h, delay - 2 - 3) // (3 stepped since the kill)
	testing.expect(t, g.dead, "back before the delay")
	core.harness_step(&rig.sess.h, 4)
	testing.expect(t, !g.dead, "not back after the delay")
	core.harness_step(&rig.sess.h, 3)
	testing.expect(t, at_spawn(rig, g), "back, but not at a spawn point")
	testing.expect(t, has_kit(rig, g), "back without the kit")
	testing.expect_value(t, g.health, g.max_health)

	// One's own death takes a frag away; so does a fall.
	testing.expect_value(t, kill(rig, h, h), core.Damage_Result.Killed)
	testing.expect_value(t, fighter(s, h).frags, 0)
	testing.expect_value(t, fighter(s, h).deaths, 1)
	core.harness_step(&rig.sess.h, delay + 10) // (back, and past the protection)
	core.harness_step(&rig.sess.h, int(arena.SPAWN_PROTECTION * game.TICK_RATE))
	testing.expect_value(t, kill(rig, g, nil), core.Damage_Result.Killed)
	testing.expect_value(t, fighter(s, g).frags, -1)
	core.harness_step(&rig.sess.h, delay + 10 + int(arena.SPAWN_PROTECTION * game.TICK_RATE))

	// The frag limit: the host reaches it and wins.
	say(rig, "arena frags 2")
	testing.expect(t, told(rig, "Arena: first to 2 frags"))
	testing.expect_value(t, kill(rig, g, h), core.Damage_Result.Killed)
	testing.expect_value(t, a.phase, arena.Phase.Playing)
	core.harness_step(&rig.sess.h, delay + 10 + int(arena.SPAWN_PROTECTION * game.TICK_RATE))
	testing.expect_value(t, kill(rig, g, h), core.Damage_Result.Killed)
	testing.expect_value(t, a.phase, arena.Phase.Results)
	testing.expect_value(t, string(a.winner[:a.winner_len]), core.client_name(h))
	testing.expect_value(t, a.top_frags, 2)
	core.harness_step(&rig.sess.h, 2)
	m := core.harness_player_record(&rig.guest, arena.Match)
	testing.expect(t, m != nil && m.phase == .Results && m.winner == core.client_name(h))
	testing.expect_value(t, mode_of(rig, h), arena.WATCHING_MODE)
	core.harness_step(&rig.sess.h, 5)
	apart := h.player.position - g.player.position
	testing.expect(t, abs(apart.x) >= 1, "the watchers float inside each other")

	// The next match: a new courtyard, every score at nought.
	seed := a.seed
	if !testing.expect(t, until_phase(rig, .Countdown), "no next match") {return}
	testing.expect_value(t, a.match, 2)
	testing.expect(t, a.seed != seed, "the same courtyard again")
	if !testing.expect(t, until_phase(rig, .Playing), "the next match never started") {return}
	core.harness_step(&rig.sess.h, 3)
	for c in ([]^core.Client{h, g}) {
		f := fighter(s, c)
		testing.expect(t, f.frags == 0 && f.deaths == 0 && f.match == 2, "a score not reset")
		testing.expect_value(t, c.health, c.max_health)
	}
	mine = core.mirror_game_record(&rig.sess.mirror, arena.Score, key)
	testing.expect(t, mine != nil && mine.frags == 0 && mine.deaths == 0)
	testing.expect_value(t, len(rig.sess.failures), 0)
}

// Hosted alone (nobody else can join), one player is enough for a match; the admin's
// rules are refused out of their bounds, and kept with the universe across a restart.
@(test)
test_arena_alone_and_its_rules_kept :: proc(t: ^testing.T) {
	dir := "build/test/arena_rules"
	os.remove_all(dir)
	defer os.remove_all(dir)
	sess := new(core.Session)
	defer free(sess)
	config := core.harness_world()
	config.game = GAME
	config.save_dir = dir
	config.kit = "rocket_launcher 1"
	if !testing.expect(t, core.session_start(sess, {}, false, with = config)) {return}
	s := &sess.h.srv
	Wait :: struct {
		s:     ^core.Server,
		phase: arena.Phase,
	}
	wait := Wait{s, .Playing}
	_, ok := core.harness_step_until(&sess.h, proc(data: rawptr) -> bool {
			w := (^Wait)(data)
			return state(w.s).phase == w.phase
		}, &wait, 20 * game.TICK_RATE)
	testing.expect(t, ok, "alone, the match never started")
	for text in ([]string{"arena frags 0", "arena time 10", "arena respawn 99", "arena frags 7", "arena time 120", "arena respawn 3.5"}) {
		core.command(&sess.mirror, text)
		core.harness_step(&sess.h, 2)
	}
	r := state(s).settings
	testing.expect_value(t, r, arena.Settings{7, 120, 3.5})
	testing.expect_value(t, s.home.rules.respawn_delay, 3.5)
	core.session_stop(sess)

	sess^ = {}
	if !testing.expect(t, core.session_start(sess, {}, false, with = config)) {return}
	defer core.session_stop(sess)
	s = &sess.h.srv
	testing.expect_value(t, state(s).settings, arena.Settings{7, 120, 3.5})
	testing.expect_value(t, s.home.rules.respawn_delay, 3.5)
}

// The spawn point chosen is the one farthest from everyone else; with nobody else, the
// turn's.
@(test)
test_arena_farthest_spawn :: proc(t: ^testing.T) {
	points := [][3]f64{{0, 0, 0}, {10, 0, 0}, {20, 0, 0}}
	testing.expect_value(t, arena.farthest(points, {{1, 0, 0}}, 0), 2)
	testing.expect_value(t, arena.farthest(points, {{19, 0, 0}}, 0), 0)
	testing.expect_value(t, arena.farthest(points, {{0, 0, 0}, {20, 0, 0}}, 0), 1)
	testing.expect_value(t, arena.farthest(points, {}, 2), 2)
}

// A countdown that loses its players (here: the world was opened to others, and two are
// needed now) goes back to the warm-up, and the match it counted down keeps its number
// for the next.
@(test)
test_arena_countdown_given_up :: proc(t: ^testing.T) {
	sess := new(core.Session)
	defer free(sess)
	config := core.harness_world()
	config.game = GAME
	config.kit = "rocket_launcher 1"
	if !testing.expect(t, core.session_start(sess, {}, false, with = config)) {return}
	defer core.session_stop(sess)
	s := &sess.h.srv
	counting :: proc(data: rawptr) -> bool {return state((^core.Server)(data)).phase == .Countdown}
	_, ok := core.harness_step_until(&sess.h, counting, s, 20 * game.TICK_RATE)
	if !testing.expect(t, ok, "alone, no countdown") {return}
	testing.expect_value(t, state(s).match, 1)
	s.listening = true // (as opening to the LAN does)
	core.harness_step(&sess.h, 2)
	testing.expect_value(t, state(s).phase, arena.Phase.Warmup)
	testing.expect_value(t, state(s).match, 0)
	s.listening = false
}
