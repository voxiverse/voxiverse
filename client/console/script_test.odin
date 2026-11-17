package console

import "core:testing"

import "client:engine"

// `ticks <n>` with no server of our own to hurry waits the ticks' time on the clock: the
// script stops there, not done, hurrying nothing.
@(test)
test_script_ticks_without_a_server :: proc(t: ^testing.T) {
	app := new(engine.App) // (the heap: an App is large, a test thread's stack is not)
	defer free(app)
	s: engine.Script
	script_init(&s, "ticks 40; quit")
	defer script_destroy(&s)
	script_run(app, &s)
	testing.expect_value(t, s.next, 1)
	testing.expect(t, !s.hurried, "hurried with no server")
	testing.expect(t, s.until != {}, "not waiting for the ticks' time")
	testing.expect(t, !script_done(&s), "done while waiting for the ticks")
	testing.expect(t, !app.quit, "went on past the ticks")
}

// After our own server has hurried its ticks, the script waits until the session has heard
// the last of them: what they did is here when it goes on (a screenshot shows it).
@(test)
test_script_ticks_wait_to_be_heard :: proc(t: ^testing.T) {
	app := new(engine.App)
	defer free(app)
	app.session = new(engine.Session) // (its server not hurrying: none was started)
	defer free(app.session)
	app.session.state = .Playing
	app.session.render_clock = {
		newest = 100,
		heard  = true,
	}
	s: engine.Script
	script_init(&s, "wait 0")
	defer script_destroy(&s)
	s.hurried, s.heard = true, 106
	script_run(app, &s)
	testing.expect(t, s.hurried, "went on before the ticks were heard")
	app.session.render_clock.newest = 106
	script_run(app, &s)
	testing.expect(t, !s.hurried, "still waiting once they were heard")
}
