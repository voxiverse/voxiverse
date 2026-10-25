package client

import "core:fmt"
import "core:log"
import "core:math"
import "core:strings"
import "core:time"

import "../base"
import "../game"
import "../gpu"
import "../server"

// Benchmarks (PLAN.md, M19): `voxiverse --benchmark <scenario>` runs a
// scenario by itself and writes its result (base.bench_result_write); `build
// bench <scenario>` does that with a release build. Everything that changes
// the numbers is fixed here, not taken from the player: the settings
// (BENCHMARK_SETTINGS; the settings file is neither read nor written), the
// world (the scratch world, its fixed spawn), the time of day (stopped), the
// clouds (still), no sheep appearing, no sound device. Each repetition
// is a session of its own: join, load, warm up, measure, leave.

Bench_Kind :: enum u8 {
	Load, // joining until the world around is loaded and meshed
	Views, // still views all round: the GPU's work
	Flight, // flying over the land: streaming while drawing
	Edits, // explosions round the spawn: bulk edits re-meshed, water let loose
}

Scenario :: struct {
	name:        string,
	kind:        Bench_Kind,
	version:     int, // bump when what it does changes: results of other versions never compare
	repetitions: int,
	description: string,
}

@(rodata)
SCENARIOS := [?]Scenario {
	{"load", .Load, 1, 3, "join the scratch world until it is loaded and meshed"},
	{
		"views",
		.Views,
		1,
		3,
		"sixteen still views from the spawn (eight ways, at the horizon and down)",
	},
	{
		"flight",
		.Flight,
		1,
		3,
		"fly 600 blocks over the land at 40 blocks/s, looking ahead and down",
	},
	{
		"edits",
		.Edits,
		1,
		3,
		"12 explosions round the spawn, until re-meshed and the water is still",
	},
}

// BENCH_SIZE: what benchmarks draw at, offscreen (gpu.set_offscreen),
// whatever the window is.
BENCH_SIZE :: [2]u32{1280, 720}

// BENCHMARK_SETTINGS: what benchmarks run with instead of the player's
// settings: no vsync, nothing extra on screen, the default view. Never
// saved.
@(rodata)
BENCHMARK_SETTINGS := Settings {
	gui_scale         = 1,
	mouse_sensitivity = 1,
	fov               = 70,
	render_distance   = 12, // 12 x 6 chunks (view_size)
	clouds            = true,
	vsync             = false,
	volume            = 0,
	keys              = DEFAULT_BINDINGS,
	chat_text_size    = 1,
}

BENCH_TIME_OF_DAY :: "0.45" // late morning: the sun up, the sky lit
BENCH_WARMUP_FRAMES :: 120
BENCH_LOAD_TIMEOUT :: 120 // seconds
BENCH_VIEW_YAWS :: 8
BENCH_VIEW_PITCHES :: [2]f32{-0.1, -0.6}
BENCH_VIEW_FRAMES :: 60 // each view held
BENCH_VIEW_SETTLE :: 10 // of those, not measured: GPU times arrive a few frames late
BENCH_FLIGHT_HEIGHT :: 70.0
BENCH_FLIGHT_SPEED :: 40
BENCH_FLIGHT_BLOCKS :: 600.0
// Smoke runs (CI): the same scripts, shorter.
BENCH_SMOKE_WARMUP :: 10
BENCH_SMOKE_VIEW_FRAMES :: 4
BENCH_SMOKE_VIEW_SETTLE :: 2
BENCH_SMOKE_FLIGHT_BLOCKS :: 64.0
BENCH_SMOKE_VIEW_RADIUS :: 4
BENCH_SMOKE_VIEW_HEIGHT :: 2
BENCH_FLIGHT_PITCH :: -0.35
BENCH_EDITS :: 12 // explosions, on a ring round the spawn
BENCH_EDIT_RING :: 24.0 // blocks from the spawn
BENCH_EDIT_RADIUS :: 6
BENCH_EDIT_EVERY :: 250 * time.Millisecond
BENCH_EDIT_TIMEOUT :: 60 // seconds for it all to settle

Bench_Phase :: enum u8 {
	Off,
	Joining, // entering the world, waiting for it to load and mesh
	Warming,
	Lifting, // (flight) up and the flying rules, waiting for the server
	Measuring,
}

Bench :: struct {
	scenario:  Scenario,
	smoke:     bool, // one short repetition (CI)
	phase:     Bench_Phase,
	rep:       int,
	frames:    int, // in this phase
	started:   time.Tick, // this phase's start
	view:      int,
	start_x:   f64, // (flight)
	targets:   [BENCH_EDITS]game.Block_Pos, // (edits) where the explosions go
	fired:     int,
	next_shot: time.Tick,
	first:     time.Tick, // the first explosion
	result:    base.Bench_Result,
	failed:    bool,
	done:      bool,
}

// scenario_find: the scenario called name.
scenario_find :: proc(name: string) -> (Scenario, bool) {
	for s in SCENARIOS {if s.name == name {return s, true}}
	return {}, false
}

scenario_names :: proc() -> string {
	names := make([dynamic]string, context.temp_allocator)
	for s in SCENARIOS {append(&names, s.name)}
	return strings.join(names[:], ", ", context.temp_allocator)
}

// bench_begin starts the scenario (after app_init).
// smoke: one short repetition, written as "<scenario>-smoke" (never
// compared with the real thing): CI keeps every scenario working with it.
bench_begin :: proc(app: ^App, scenario: Scenario, smoke := false) {
	b := &app.bench
	scenario := scenario
	if smoke {
		// Short, and a small world around: a smoke run only shows the
		// scenario still works (its numbers compare with nothing).
		scenario.repetitions = 1
		app.fixed_view = {BENCH_SMOKE_VIEW_RADIUS, BENCH_SMOKE_VIEW_HEIGHT}
	}
	b^ = {
		scenario = scenario,
		smoke = smoke,
		result = {
			scenario = scenario.name,
			version = scenario.version,
			gpu = app.g.device_name,
			driver = app.g.driver,
		},
	}
	log.infof(
		"bench %s: %s (%d repetitions)",
		scenario.name,
		scenario.description,
		scenario.repetitions,
	)
	if !gpu.set_offscreen(&app.g, BENCH_SIZE.x, BENCH_SIZE.y) {
		bench_fail(app, "cannot draw offscreen at a fixed size here")
		return
	}
	b.result.resolution = {int(BENCH_SIZE.x), int(BENCH_SIZE.y)}
	bench_join(app)
}

@(private = "file")
bench_join :: proc(app: ^App) {
	b := &app.bench
	enter_world(app, "", SCRATCH_SEED, SCRATCH_SPAWN, benchmark = true)
	b.phase, b.frames, b.started = .Joining, 0, time.tick_now()
	if b.scenario.kind == .Load {base.metrics_start()}
}

// bench_update drives the scenario; once a frame.
bench_update :: proc(app: ^App) {
	b := &app.bench
	if b.phase == .Off {return}
	s := app.session
	if s == nil || s.state == .Failed {
		bench_fail(app, "the session ended")
		return
	}
	b.frames += 1
	seconds := time.duration_seconds(time.tick_since(b.started))
	switch b.phase {
	case .Off:
	case .Joining:
		if !world_settled(app) {
			if seconds > BENCH_LOAD_TIMEOUT {bench_fail(app, "the world did not load")}
			return
		}
		if b.scenario.kind == .Load {
			base.metric_add(.Load_Seconds, f32(seconds))
			bench_repetition_done(app)
			return
		}
		// The conditions: the time of day stopped where it is set.
		session_set_rule(s, "rules.daylight_cycle", "0")
		send_message(s, game.Command{"time " + BENCH_TIME_OF_DAY})
		b.phase, b.frames, b.started = .Warming, 0, time.tick_now()
	case .Warming:
		if b.frames < (BENCH_SMOKE_WARMUP if b.smoke else BENCH_WARMUP_FRAMES) {return}
		if b.scenario.kind == .Flight {
			p := s.prediction.state.position
			session_teleport(
				s,
				{{p.x, BENCH_FLIGHT_HEIGHT, p.z}, -math.PI / 2, BENCH_FLIGHT_PITCH},
			)
			session_set_rule(s, "rules.fly_sprint_speed", fmt.tprint(BENCH_FLIGHT_SPEED))
			b.phase, b.frames, b.started = .Lifting, 0, time.tick_now()
			return
		}
		if b.scenario.kind == .Edits {
			// The ground at fixed places round the spawn (the world is fixed).
			query := game.Block_Query{&s.world, world_block}
			for &t, k in b.targets {
				angle := f64(k) * 2 * math.PI / BENCH_EDITS
				x := SCRATCH_SPAWN.x + BENCH_EDIT_RING * math.cos(angle)
				z := SCRATCH_SPAWN.z + BENCH_EDIT_RING * math.sin(angle)
				// Down from 80 blocks up, or the top of what is loaded if lower
				// (a smoke run's small view).
				up := min(80, f64(s.welcome.view_height) * game.CHUNK_SIZE - 8)
				from := [3]f64 {
					math.floor(x) + 0.5,
					s.prediction.state.position.y + up,
					math.floor(z) + 0.5,
				}
				hit, found := game.raycast(query, from, {0, -1, 0}, 200)
				if !found {
					bench_fail(app, "no ground where an explosion goes")
					return
				}
				t = hit.block
			}
			s.camera.yaw, s.camera.pitch = 0, -0.5
			b.phase, b.frames, b.fired = .Measuring, 0, 0
			b.first, b.next_shot = time.tick_now(), time.tick_now()
			base.metrics_start()
			return
		}
		b.phase, b.frames, b.view = .Measuring, 0, 0
		base.metrics_start()
		base.metrics_stop() // (the first view's settle)
	case .Lifting:
		if s.prediction.state.position.y < BENCH_FLIGHT_HEIGHT - 1 ||
		   s.rules.fly_sprint_speed != BENCH_FLIGHT_SPEED {
			if seconds >
			   BENCH_LOAD_TIMEOUT {bench_fail(app, "the teleport or rule change never arrived")}
			return
		}
		if !s.prediction.state.flying {s.toggle_fly = true}
		s.autopilot = game.Player_Input {
			move    = {0, 1},
			yaw     = -math.PI / 2,
			pitch   = BENCH_FLIGHT_PITCH,
			buttons = {.Sprint},
		}
		b.start_x = s.prediction.state.position.x
		b.phase, b.frames = .Measuring, 0
		base.metrics_start()
	case .Measuring:
		switch b.scenario.kind {
		case .Load:
		case .Views:
			pitches := BENCH_VIEW_PITCHES
			s.camera.yaw = f32(b.view % BENCH_VIEW_YAWS) * 2 * math.PI / BENCH_VIEW_YAWS
			s.camera.pitch = pitches[b.view / BENCH_VIEW_YAWS]
			if b.frames ==
			   (BENCH_SMOKE_VIEW_SETTLE if b.smoke else BENCH_VIEW_SETTLE) {base.metrics_resume()}
			if b.frames < (BENCH_SMOKE_VIEW_FRAMES if b.smoke else BENCH_VIEW_FRAMES) {return}
			base.metrics_stop()
			b.view, b.frames = b.view + 1, 0
			if b.view == BENCH_VIEW_YAWS * len(BENCH_VIEW_PITCHES) {bench_repetition_done(app)}
		case .Edits:
			if b.fired < BENCH_EDITS {
				if time.tick_diff(time.tick_now(), b.next_shot) > 0 {return}
				t := b.targets[b.fired]
				server_explode(s, t, BENCH_EDIT_RADIUS)
				b.fired += 1
				b.next_shot = time.tick_add(b.next_shot, BENCH_EDIT_EVERY)
				return
			}
			// Settled: everything re-meshed and shown, the water still (how long
			// that takes is mostly the water's ticks: not a measure of speed;
			// edit_shown is).
			since := time.duration_seconds(time.tick_since(b.first))
			if since > BENCH_EDIT_TIMEOUT {
				bench_fail(app, "the explosions never settled")
				return
			}
			if time.tick_diff(b.next_shot, time.tick_now()) < 500 * time.Millisecond {return}
			if !world_settled(app) || len(s.world.groups) > 0 {return}
			if server.stats(&s.server).updates_waiting > 0 {return}
			bench_repetition_done(app)
		case .Flight:
			p := s.prediction.state
			if !p.flying && p.position.x - b.start_x > 2 {
				bench_fail(app, "stopped flying")
				return
			}
			blocks := BENCH_SMOKE_FLIGHT_BLOCKS if b.smoke else BENCH_FLIGHT_BLOCKS
			if p.position.x - b.start_x >= blocks {bench_repetition_done(app)}
		}
	}
}

// bench_repetition_done keeps this repetition's metrics and goes on: the
// next repetition in a new session, or the result.
@(private = "file")
bench_repetition_done :: proc(app: ^App) {
	b := &app.bench
	base.bench_repetition_end(&b.result)
	if len(b.result.repetitions) == 1 {
		// Exact counts: the same world gives the same, or the work changed.
		s := app.session
		append(
			&b.result.counts,
			base.Bench_Count{"chunks", s.world.chunks.count},
			base.Bench_Count{"meshes", app.world_pass.stats.meshes},
		)
	}
	if app.session != nil {app.session.autopilot = nil}
	leave_world(app)
	b.rep += 1
	if b.rep < b.scenario.repetitions {
		bench_join(app)
		return
	}
	bench_finish(app)
}

@(private = "file")
bench_finish :: proc(app: ^App) {
	b := &app.bench
	b.phase = .Off
	if b.smoke {b.result.scenario = fmt.tprintf("%s-smoke", b.scenario.name)}
	path := base.bench_result_write(&b.result)
	if path == "" {
		bench_fail(app, "could not write the result (run from the repository: build/ must exist)")
		return
	}
	// The log: each metric's median over the repetitions.
	for m in base.Metric {
		medians := make([dynamic]f64, context.temp_allocator)
		for rep in b.result.repetitions {if rep[m].count > 0 {append(&medians, base.metric_value(m, rep[m]))}}
		if len(medians) == 0 {continue}
		info := base.METRIC_INFO[m]
		lo, hi := medians[0], medians[0]
		for v in medians {lo, hi = min(lo, v), max(hi, v)}
		log.infof(
			"bench %s %s %.3f %s (repetitions %.3f..%.3f)",
			b.scenario.name,
			info.name,
			base.median_of(medians[:]),
			info.unit,
			lo,
			hi,
		)
	}
	log.infof("bench %s result=%s", b.scenario.name, path)
	base.bench_result_destroy(&b.result)
	b.done = true
	app.quit = true
}

@(private = "file")
bench_fail :: proc(app: ^App, why: string) {
	b := &app.bench
	log.errorf("bench %s failed: %s", b.scenario.name, why)
	base.metrics_stop()
	base.bench_result_destroy(&b.result)
	b.phase, b.failed, b.done = .Off, true, true
	app.quit = true
}
