package client

import "core:fmt"
import "core:log"
import "core:strconv"

import "../base"
import "../server"

// Exit checks (fly_test, blast_test): console commands that drive the game
// and check how it holds up. What they share lives here: starting in a
// world of our own (their memory checks need the server here), the memory
// baseline and its check, and finishing: the verdict logged, a screenshot,
// and with `quit` the end of the program (main fails the run if a check
// failed, or never finished).

Exit_Check :: struct {
	name:         string,
	quit:         bool,
	failed:       bool,
	frames:       base.Frame_Stats, // frame times while it measures
	client_arena: uint,
	server_arena: uint,
}

// exit_check_start reads `<amount> [quit]` and makes sure we are in a world
// of our own; false (said why) if the check cannot run.
exit_check_start :: proc(
	app: ^App,
	c: ^Exit_Check,
	name: string,
	args: []string,
) -> (
	amount: f64,
	ok: bool,
) {
	amount, ok = strconv.parse_f64(args[0] if len(args) > 0 else "")
	if !ok || amount <= 0 {
		console_print(&app.console, fmt.tprintf("usage: %s <amount> [quit]", name), .Warning)
		return 0, false
	}
	if app.session == nil {enter_world(app, "", SCRATCH_SEED)}
	if app.session == nil {return 0, false}
	if !session_hosting(app.session) {
		console_print(&app.console, fmt.tprintf("%s runs in a world of your own", name), .Warning)
		return 0, false
	}
	frames := c.frames // keep the (large) stats buffer's storage
	c^ = {
		name   = name,
		quit   = len(args) > 1 && args[1] == "quit",
		frames = frames,
	}
	c.frames.count = 0
	return amount, true
}

// exit_check_baseline: memory now, which must not grow until the end.
exit_check_baseline :: proc(c: ^Exit_Check, s: ^Session) {
	c.client_arena = s.arena.total_used
	c.server_arena = server.stats(&s.server).arena_used
}

// exit_check_memory adds a failure for each arena that grew.
exit_check_memory :: proc(c: ^Exit_Check, s: ^Session, failures: ^[dynamic]string) {
	if s.arena.total_used != c.client_arena {
		append(
			failures,
			fmt.tprintf(
				"client session arena grew from %d to %d bytes",
				c.client_arena,
				s.arena.total_used,
			),
		)
	}
	if used := server.stats(&s.server).arena_used; used != c.server_arena {
		append(
			failures,
			fmt.tprintf("server session arena grew from %d to %d bytes", c.server_arena, used),
		)
	}
}

// exit_check_finish logs the verdict, takes the last screenshot and quits
// if asked.
exit_check_finish :: proc(app: ^App, c: ^Exit_Check, failures: []string) {
	for f in failures {log.errorf("%s %s", c.name, f)}
	if len(failures) == 0 {log.infof("%s passed", c.name)}
	if s := app.session; s != nil {
		s.autopilot = nil
		screenshot_request(app, fmt.tprintf("%s_end", c.name)) // saved at exit too
	}
	c.failed = len(failures) > 0
	if c.quit {app.quit = true}
}
