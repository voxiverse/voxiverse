package stopwatch_server

import "core:log"
import "core:strings"
import "core:testing"

import "server:core"

// The game on a stepped server with the local player: every hook runs, and both
// blocks of state hold what the hooks did.
@(test)
test_stopwatch_hooks :: proc(t: ^testing.T) {
	sess := new(core.Session)
	defer free(sess)
	config := core.harness_world()
	config.game = GAME
	if !testing.expect(t, core.session_start(sess, {}, false, with = config)) {return}
	srv := &sess.h.srv
	c := &srv.clients[0]
	// configure: a new universe in survival; start: the game's state is there.
	testing.expect_value(t, srv.config.mode, "survival")
	testing.expect_value(t, watch(srv).started, 0)

	// joined: counted and told.
	welcomed :: proc(data: rawptr) -> bool {return (^core.Session)(data).mirror.welcomed}
	_, ok := core.harness_step_until(&sess.h, welcomed, sess, 600)
	if !testing.expect(t, ok, "the player never joined") {return}
	testing.expect_value(t, watch(srv).joins, 1)
	testing.expect(t, told(sess, "Stopwatch: your time runs from now"))

	// tick: the game's ticks are the server's, the player's from when it joined.
	core.harness_step(&sess.h, 30)
	testing.expect_value(t, watch(srv).ticks, srv.tick)
	played := lap(srv, c).ticks
	testing.expect(t, played >= 30 && played < srv.tick, "the player's time is not its own")

	// command: the game's commands come through the server's; others stay unknown.
	core.command(&sess.mirror, "stopwatch")
	core.harness_step(&sess.h, 2)
	testing.expect(t, told(sess, "Your time: "))
	core.command(&sess.mirror, "stopwatch reset")
	core.harness_step(&sess.h, 2)
	testing.expect(t, told(sess, "Your time runs from zero again"))
	testing.expect(t, lap(srv, c).ticks <= 2, "reset did not reset")
	core.command(&sess.mirror, "nonesuch")
	core.harness_step(&sess.h, 2)
	testing.expect(t, told(sess, "Unknown server command: nonesuch"))

	// left: the local player cannot be sent away, but a second Hello drops it as any
	// disconnect does. Its time becomes the record and its seat's state is zero again.
	core.harness_step(&sess.h, 10)
	stayed := lap(srv, c).ticks
	core.mirror_send(&sess.mirror, core.test_hello("stopwatch"))
	core.harness_step(&sess.h, 1)
	testing.expect_value(t, c.state, core.Client_State.Gone)
	testing.expect(t, watch(srv).record >= stayed, "leaving set no record")
	testing.expect_value(t, lap(srv, c)^, Lap{})

	// stop: it reports, before the session (and the game's state) is gone.
	lines: [dynamic]string
	defer {
		for l in lines {delete(l)}
		delete(lines)
	}
	{
		context.logger = {keep_line, &lines, .Info, {}}
		core.session_stop(sess)
	}
	stopped := false
	for l in lines {stopped ||= strings.has_prefix(l, "stopwatch stopped ")}
	testing.expect(t, stopped, "stop did not report")
}

// A server with no game is the engine alone: no state, no hooks.
@(test)
test_no_game :: proc(t: ^testing.T) {
	sess := new(core.Session)
	defer free(sess)
	if !testing.expect(
		t,
		core.session_start(sess, {}, false, with = core.harness_world()),
	) {return}
	defer core.session_stop(sess)
	testing.expect_value(t, sess.h.srv.config.mode, "")
	testing.expect(t, sess.h.srv.game_state == nil && sess.h.srv.clients[0].game_state == nil)
}

// told: the server told the player text, at the start of a Notice.
told :: proc(sess: ^core.Session, text: string) -> bool {
	for n in sess.mirror.notices {
		if strings.has_prefix(n, text) {return true}
	}
	return false
}

// keep_line: a logger that keeps every line in a [dynamic]string (data).
keep_line :: proc(
	data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	append((^[dynamic]string)(data), strings.clone(text))
}
