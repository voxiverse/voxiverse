package client

import "core:fmt"
import "core:log"

import "../base"
import "../server"

// Exit checks (fly, tour, blast: `--check <name>`): they drive the game
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

// exit_check_start enters a world of our own for check c (its memory
// checks need the server here); false (said why) if it cannot run.
exit_check_start :: proc(app: ^App, c: ^Exit_Check, name: string) -> bool {
	if app.session == nil {
		// A still world (no sheep of their own, nothing growing or spreading): the checks measure what they do.
		enter_world(app, "", SCRATCH_SEED, SCRATCH_SPAWN, benchmark = true)
	}
	if app.session == nil || !session_hosting(app.session) {
		log.errorf("%s runs in a world of our own", name)
		return false
	}
	frames := c.frames // keep the (large) stats buffer's storage
	c^ = {
		name   = name,
		quit   = true,
		frames = frames,
	}
	c.frames.count = 0
	return true
}

// Check_Info: an exit check run by `--check <name>` (main.odin), in a fixed
// view (its settings are BENCHMARK_SETTINGS', with this view: the same run
// anywhere), after any --exec script (which may set things up first: a
// network trace).
Check_Info :: struct {
	name:        string,
	description: string,
	view_radius: i32,
	view_height: i32,
	start:       proc(app: ^App),
}

@(rodata)
CHECKS := [?]Check_Info {
	{
		"fly",
		"fly 400 blocks: memory stays flat while the world streams",
		6,
		3,
		proc(app: ^App) {fly_test_begin(app, 400)},
	},
	{
		"fly_pad",
		"fly 400 blocks on a synthetic gamepad",
		6,
		3,
		proc(app: ^App) {fly_test_begin(app, 400, pad = true)},
	},
	{
		"tour",
		"visit every biome: frame, generation and meshing budgets, memory",
		4,
		3,
		proc(app: ^App) {tour_test_begin(app)},
	},
	{
		"blast",
		"12 rockets and explosions: budgets, meshes shown whole, memory, the client's chunks the server's",
		4,
		2,
		proc(app: ^App) {blast_test_begin(app, 12)},
	},
	{
		"audio",
		"30 s of a busy session into the null device: no underruns, NaN, dropped or late commands, the callback in its block",
		3,
		2,
		proc(app: ^App) {audio_check_begin(app)},
	},
}

check_find :: proc(name: string) -> (Check_Info, bool) {
	for c in CHECKS {if c.name == name {return c, true}}
	return {}, false
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
