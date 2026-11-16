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
