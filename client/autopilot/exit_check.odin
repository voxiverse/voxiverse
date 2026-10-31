package autopilot

import "core:fmt"
import "core:log"

import "client:engine"
import "client:render"
import "server:core"

// Exit checks (fly, tour, blast: `--check <name>`): they drive the game
// and check how it holds up. What they share lives here: starting in a
// world of our own (their memory checks need the server here), the memory
// baseline and its check, and finishing: the verdict logged, a screenshot,
// and with `quit` the end of the program (main fails the run if a check
// failed, or never finished).

// exit_check_start enters a world of our own for check c (its memory
// checks need the server here); false (said why) if it cannot run.
exit_check_start :: proc(app: ^engine.App, c: ^engine.Exit_Check, name: string) -> bool {
	if app.session == nil {
		// A still world (no sheep of their own, nothing growing or spreading): the checks measure what they do.
		engine.enter_world(app, "", engine.SCRATCH_SEED, engine.SCRATCH_SPAWN, benchmark = true)
	}
	if app.session == nil || !engine.session_hosting(app.session) {
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
	start:       proc(app: ^engine.App),
}

@(rodata)
CHECKS := [?]Check_Info {
	{
		"fly",
		"fly 400 blocks: memory stays flat while the world streams",
		6,
		3,
		proc(app: ^engine.App) {fly_test_begin(app, 400)},
	},
	{
		"fly_pad",
		"fly 400 blocks on a synthetic gamepad",
		6,
		3,
		proc(app: ^engine.App) {fly_test_begin(app, 400, pad = true)},
	},
	{
		"tour",
		"visit every biome: frame, generation and meshing budgets, memory",
		4,
		3,
		proc(app: ^engine.App) {tour_test_begin(app)},
	},
	{
		"blast",
		"12 rockets and explosions: budgets, meshes shown whole, memory, the client's chunks the server's",
		4,
		2,
		proc(app: ^engine.App) {blast_test_begin(app, 12)},
	},
	{
		"cull",
		"the GPU's culling pass against the CPU's rules: fixed chunks and cameras, every command compared",
		2,
		2,
		proc(app: ^engine.App) {cull_check_run(app)},
	},
	{
		"audio",
		"30 s of a busy session into the null device: no underruns, NaN, dropped or late commands, the callback in its block",
		3,
		2,
		proc(app: ^engine.App) {audio_check_begin(app)},
	},
}

check_find :: proc(name: string) -> (Check_Info, bool) {
	for c in CHECKS {if c.name == name {return c, true}}
	return {}, false
}

// exit_check_baseline: memory now, which must not grow until the end.
exit_check_baseline :: proc(c: ^engine.Exit_Check, s: ^engine.Session) {
	c.client_arena = s.arena.total_used
	c.server_arena = core.stats(&s.server).arena_used
}

// exit_check_memory adds a failure for each arena that grew.
exit_check_memory :: proc(c: ^engine.Exit_Check, s: ^engine.Session, failures: ^[dynamic]string) {
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
	if used := core.stats(&s.server).arena_used; used != c.server_arena {
		append(
			failures,
			fmt.tprintf("server session arena grew from %d to %d bytes", c.server_arena, used),
		)
	}
}

// exit_check_finish logs the verdict, takes the last screenshot and quits
// if asked.
exit_check_finish :: proc(app: ^engine.App, c: ^engine.Exit_Check, failures: []string) {
	for f in failures {log.errorf("%s %s", c.name, f)}
	if len(failures) == 0 {log.infof("%s passed", c.name)}
	if s := app.session; s != nil {
		s.autopilot = nil
		engine.screenshot_request(app, fmt.tprintf("%s_end", c.name)) // saved at exit too
	}
	c.failed = len(failures) > 0
	if c.quit {app.quit = true}
}

// cull_check_run: the cull check (render.world_cull_check), at once: no
// world, the world pass's culling pipeline on its own buffers.
cull_check_run :: proc(app: ^engine.App) {
	c := &app.cull_check
	c^ = {
		name = "cull_check",
		quit = true,
	}
	failures := render.world_cull_check(&app.world_pass, &app.g)
	exit_check_finish(app, c, failures[:])
}
