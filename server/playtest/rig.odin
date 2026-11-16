package playtest_server

import "core:strings"
import "core:testing"

import "common:game"
import "common:protocol"
import "server:core"
import "server:play"

// A game's server tests' rig (only tests import this package): the game on a stepped
// server in the harness's small flat world (the game's configure changes it as it
// would any), the host (the harness's mirror client, on the local pipe) welcomed, and
// guests: more players over the harness's network, each playing. A test steps it,
// waits for the game to reach a phase, speaks the host's commands and reads what the
// players were told.
//
//	rig := new(playtest.Rig)
//	defer free(rig)
//	if !playtest.start(t, rig, GAME, guests = 1) {return}
//	defer playtest.stop(rig)
//	playtest.until_phase(rig, &state(playtest.srv(rig)).phase, .Playing)

MAX_GUESTS :: 3

Rig :: struct {
	sess:   core.Session,
	guests: [MAX_GUESTS]core.Harness_Player,
	joined: int, // guests joined
}

// Options: what a test changes of the rig's world.
Options :: struct {
	guests:   int, // more players besides the host (the server then listens)
	listen:   bool, // the server listens with no guest (others could join: a LAN game)
	save_dir: string, // a universe kept on disk ("": a scratch world)
	kit:      string, // the players' kit ("": the game's modes' own)
	seed:     i64, // (0: the harness's)
	plain:    bool, // guests hold the default role, not the host's (everyone_cheats off)
}

// start: the game started and every player in it, playing; false (and the test told)
// when the server refused it or a player never got in.
start :: proc(t: ^testing.T, rig: ^Rig, g: core.Game, o := Options{}) -> bool {
	assert(o.guests <= MAX_GUESTS)
	config := core.harness_world()
	config.game = g
	config.listen = o.listen || o.guests > 0
	config.save_dir = o.save_dir
	config.kit = o.kit
	if o.seed != 0 {config.seed = o.seed}
	if o.plain {config.everyone_cheats = false}
	if !testing.expect(t, core.session_start(&rig.sess, {}, false, with = config), "no server") {
		return false
	}
	names := [MAX_GUESTS]string{"guest", "guest2", "guest3"}
	for i in 0 ..< o.guests {core.harness_player_join(&rig.sess.h, &rig.guests[i], names[i])}
	rig.joined = o.guests
	joined :: proc(data: rawptr) -> bool {
		rig := (^Rig)(data)
		if !rig.sess.mirror.welcomed {return false}
		for i in 0 ..< rig.joined {
			g := core.harness_player_client(&rig.guests[i])
			if g == nil || g.state != .Playing {return false}
		}
		return true
	}
	_, ok := core.harness_step_until(&rig.sess.h, joined, rig, 600)
	return testing.expect(t, ok, "the players never joined")
}

// stop: the server stopped and every player freed.
stop :: proc(rig: ^Rig) {
	core.session_stop(&rig.sess)
	for i in 0 ..< rig.joined {core.harness_player_free(&rig.guests[i])}
	rig.joined = 0
}

srv :: proc(rig: ^Rig) -> ^core.Server {return &rig.sess.h.srv}
host :: proc(rig: ^Rig) -> ^core.Client {return &rig.sess.h.srv.clients[0]}
guest :: proc(rig: ^Rig, i := 0) -> ^core.Client {return core.harness_player_client(
		&rig.guests[i],
	)}

// step: n ticks of the server and every player.
step :: proc(rig: ^Rig, n := 1) {core.harness_step(&rig.sess.h, n)}

// seconds: ticks for a time.
ticks :: proc(seconds: f64) -> int {return int(seconds * game.TICK_RATE + 0.5)}

// until: steps until done(data) (false: not within seconds).
until :: proc(rig: ^Rig, done: proc(data: rawptr) -> bool, data: rawptr, seconds := 20.0) -> bool {
	_, ok := core.harness_step_until(&rig.sess.h, done, data, ticks(seconds))
	return ok
}

// until_phase: steps until the game's phase (a play.Phase in its state) is want (false:
// not within seconds).
until_phase :: proc(rig: ^Rig, p: ^play.Phase($P), want: P, seconds := 20.0) -> bool {
	Wait :: struct {
		p:    ^play.Phase(P),
		want: P,
	}
	w := Wait{p, want}
	return until(rig, proc(data: rawptr) -> bool {
			w := (^Wait)(data)
			return w.p.now == w.want
		}, &w, seconds)
}

// until_seconds: steps until the phase has run seconds (at most that long: a phase
// that starts over first starts the count again).
until_seconds :: proc(rig: ^Rig, clock: ^play.Clock, seconds: f64) {
	for _ in 0 ..= ticks(seconds) {
		if play.phase_seconds(srv(rig), clock) >= seconds {return}
		step(rig)
	}
}

// say: the host's command (as typed, without its slash), and the ticks for it to be done.
say :: proc(rig: ^Rig, text: string) {
	core.command(&rig.sess.mirror, text)
	step(rig, 2)
}

// told: the host was told a notice that begins with text.
told :: proc(rig: ^Rig, text: string) -> bool {
	for n in rig.sess.mirror.notices {if strings.has_prefix(n, text) {return true}}
	return false
}

// guest_told: a guest was told a notice that begins with text.
guest_told :: proc(rig: ^Rig, text: string, i := 0) -> bool {
	for n in rig.guests[i].notices {if strings.has_prefix(n, text) {return true}}
	return false
}

// mode_of: c's game mode's id.
mode_of :: proc(rig: ^Rig, c: ^core.Client) -> string {
	return srv(rig).registry.game_modes[c.mode].id
}

// host_record, guest_record: what the server last put of the game's kind T for the host
// or a guest (under key), or nil.
host_record :: proc(rig: ^Rig, $T: typeid, key := protocol.Key{}) -> ^T {
	return core.mirror_game_record(&rig.sess.mirror, T, key)
}

guest_record :: proc(rig: ^Rig, $T: typeid, key := protocol.Key{}, i := 0) -> ^T {
	return core.harness_player_record(&rig.guests[i], T, key)
}

// kill: by kills victim through the engine's damage pipeline as a shot does (by ==
// victim: its own; by nil: a fall), whatever its health.
kill :: proc(rig: ^Rig, victim, by: ^core.Client, weapon := "Rifle") -> core.Damage_Result {
	s := srv(rig)
	if by == nil {return core.damage(s, victim, 1000, {kind = .Fall})}
	return core.damage(
		s,
		victim,
		1000,
		{kind = .Weapon, attacker = core.player_id(s, by), weapon = weapon},
	)
}
