package client

import "core:fmt"
import "core:log"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:time"

import "../base"
import "../common/game"
import "../server"
import "audio"
import "gpu"
import "render"

// Benchmarks (docs/plan.md, M19): `voxiverse --benchmark <scenario>` runs a
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
	Audio, // the mixer alone: 64 voices on 4 buses, the reverb and a stream (no world, no GPU)
	Viewmodel, // the view model's vertices for a frame, the biggest model (no world, no GPU)
	Avatars, // other players in view: BENCH_AVATARS walking, each holding a weapon
}

Scenario :: struct {
	name:        string,
	kind:        Bench_Kind,
	version:     int, // bump when what it does changes: results of other versions never compare
	repetitions: int,
	description: string,
	view:        [2]i32, // view radius and height, chunks ({}: BENCHMARK_SETTINGS')
}

@(rodata)
SCENARIOS := [?]Scenario {
	{"load", .Load, 1, 3, "join the scratch world until it is loaded and meshed", {}},
	{
		"views",
		.Views,
		2, // 2: the view model (the start kit's rocket launcher) is drawn too (M48k)
		3,
		"sixteen still views from the spawn (eight ways, at the horizon and down)",
		{},
	},
	{
		"views-far",
		.Views,
		1,
		3,
		"views' sixteen still views at view radius 24, height 12 (R6: culling's cost as the view grows)",
		{24, 12},
	},
	{
		"flight",
		.Flight,
		2, // 2: the view model is drawn too (M48k)
		3,
		"fly 600 blocks over the land at 40 blocks/s, looking ahead and down",
		{},
	},
	{
		"edits",
		.Edits,
		2, // 2: the explosions are queued, not waited for (R2: server.call_async)
		3,
		"12 explosions round the spawn, until re-meshed and the water is still",
		{},
	},
	{
		"audio",
		.Audio,
		1,
		3,
		"the mixer offline: 64 looping voices on 4 buses, the reverb, a music stream; 10 s of blocks",
		{},
	},
	{
		"viewmodel",
		.Viewmodel,
		1,
		3,
		"the view model's vertices for a frame of the biggest model, 2000 frames",
		{},
	},
	{
		"avatars",
		.Avatars,
		1,
		3,
		"eight players walking in view from the spawn, each holding a weapon, 1200 frames",
		{},
	},
}

// The avatars scenario: how many, and for how long.
BENCH_AVATARS :: 8
BENCH_AVATAR_FRAMES :: 1200
BENCH_SMOKE_AVATAR_FRAMES :: 120
BENCH_AVATAR_DISTANCE :: 7 // blocks in front of the spawn: the ring's centre
BENCH_AVATAR_RING :: 3 // its radius, blocks

// BENCH_SIZE: what benchmarks draw at, offscreen (gpu.set_offscreen),
// whatever the window is, unless --bench-size says otherwise.
BENCH_SIZE :: [2]u32{1280, 720}

// bench_name: the scenario's name in results: its own at BENCH_SIZE, else with the size.
bench_name :: proc(scenario: string, size: [2]u32) -> string {
	if size == BENCH_SIZE {return scenario}
	return fmt.tprintf("%s-%dx%d", scenario, size.x, size.y)
}

// parse_size reads "WIDTHxHEIGHT" (each 64 to 8192).
parse_size :: proc(text: string) -> (size: [2]u32, ok: bool) {
	w, _, h := strings.partition(text, "x")
	width := strconv.parse_uint(w, 10) or_return
	height := strconv.parse_uint(h, 10) or_return
	if width < 64 || height < 64 || width > 8192 || height > 8192 {return}
	return {u32(width), u32(height)}, true
}

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
	music_volume      = 1,
	ambience_volume   = 1,
	effects_volume    = 1,
	stick_look_speed  = 1,
	stick_dead_zone   = 0.15,
	stick_response    = 2,
	keys              = DEFAULT_BINDINGS,
	pad               = DEFAULT_PAD_BINDINGS,
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
	size:      [2]u32, // drawn at (BENCH_SIZE, or --bench-size)
	phase:     Bench_Phase,
	rep:       int,
	frames:    int, // in this phase
	started:   time.Tick, // this phase's start
	view:      int,
	start_x:   f64, // (flight)
	targets:   [BENCH_EDITS]game.Block_Pos, // (edits) where the explosions go
	crowd:     [BENCH_AVATARS][3]f64, // (avatars) where each stands
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
// size: what it draws at; a size other than BENCH_SIZE is a scenario of its own in the
// results ("views-2560x1440"): numbers at different sizes never compare.
bench_begin :: proc(app: ^App, scenario: Scenario, smoke := false, size := BENCH_SIZE) {
	b := &app.bench
	scenario := scenario
	if smoke {
		// Short, and a small world around: a smoke run only shows the
		// scenario still works (its numbers compare with nothing).
		scenario.repetitions = 1
		app.fixed_view = {BENCH_SMOKE_VIEW_RADIUS, BENCH_SMOKE_VIEW_HEIGHT}
	} else if scenario.view != {} {
		app.fixed_view = scenario.view
	}
	b^ = {
		scenario = scenario,
		smoke = smoke,
		size = size,
		result = {
			scenario = bench_name(scenario.name, size),
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
	if scenario.kind == .Audio {
		bench_audio(app) // (nothing here draws, so nothing is set up for it)
		return
	}
	if scenario.kind == .Viewmodel {
		bench_viewmodel(app)
		return
	}
	if !gpu.set_offscreen(&app.g, size.x, size.y) {
		bench_fail(app, "cannot draw offscreen at a fixed size here")
		return
	}
	b.result.resolution = {int(size.x), int(size.y)}
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
			query := game.Block_Query{&s.world, world_block, &s.reg.blocks}
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
		if b.scenario.kind == .Avatars {
			// The ring in front of the spawn, each avatar on the ground there.
			query := game.Block_Query{&s.world, world_block, &s.reg.blocks}
			feet := s.prediction.state.position
			for &p, k in b.crowd {
				angle := f64(k) * 2 * math.PI / BENCH_AVATARS
				x := feet.x + BENCH_AVATAR_RING * math.cos(angle)
				z := feet.z - BENCH_AVATAR_DISTANCE + BENCH_AVATAR_RING * math.sin(angle)
				from := [3]f64{x, feet.y + 16, z}
				hit, found := game.raycast(query, from, {0, -1, 0}, 64)
				if !found {
					bench_fail(app, "no ground where an avatar stands")
					return
				}
				p = {x, f64(hit.block.y) + 1, z}
			}
			s.camera.yaw, s.camera.pitch = 0, -0.15
			b.phase, b.frames = .Measuring, 0
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
		case .Load, .Audio, .Viewmodel:
		case .Avatars:
			s.camera.yaw, s.camera.pitch = 0, -0.15
			frames := BENCH_SMOKE_AVATAR_FRAMES if b.smoke else BENCH_AVATAR_FRAMES
			if b.frames >= frames {bench_repetition_done(app)}
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
				base.profile_scope("queue explosion")
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
	// Named now: bench_name's string is the frame's (temp), long gone since bench_begin.
	b.result.scenario = bench_name(b.scenario.name, b.size)
	if b.smoke {b.result.scenario = fmt.tprintf("%s-smoke", b.result.scenario)}
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

BENCH_AUDIO_VOICES :: 64
BENCH_AUDIO_BLOCK :: 480 // frames: 10 ms at 48 kHz, a device callback's size
BENCH_AUDIO_BLOCKS :: 1000
BENCH_AUDIO_SMOKE_BLOCKS :: 100
BENCH_AUDIO_WARMUP :: 50
BENCH_AUDIO_STREAM :: #load("audio/testdata/tone.ogg")
// BENCH_AUDIO_BUDGET: a core's share the mix may take (docs/plan.md, M32c: 5%),
// judged on the median block of a release build.
BENCH_AUDIO_BUDGET :: 0.05

// bench_audio runs the audio scenario: the mixer alone, offline, in the same
// conditions every time: sixty-four looping voices (sounds made at 16 kHz as
// the effects are, converted at load, a quarter of the voices pitched about),
// spread over four buses with the reverb on for
// two of them, and a looping stream on Music, all mixed in blocks the size of
// a device callback. Each block's time is a sample.
@(private = "file")
bench_audio :: proc(app: ^App) {
	b := &app.bench
	blocks := BENCH_AUDIO_SMOKE_BLOCKS if b.smoke else BENCH_AUDIO_BLOCKS
	voices, real, underruns, late: u32
	for _ in 0 ..< b.scenario.repetitions {
		m := new(audio.Mixer)
		audio.mixer_init(m, audio.DEVICE_RATE)
		// Sounds: noise-and-tone bursts from a fixed generator.
		seed: u32 = 12345
		sounds: [16]audio.Sound_Id
		samples: [16][]f32
		for &id, k in sounds {
			samples[k] = make([]f32, 8000 + 500 * k)
			for &x, i in samples[k] {
				seed = seed * 1664525 + 1013904223
				noise := f32(seed >> 8) / f32(1 << 24) - 0.5
				x = 0.12 * (noise + f32(math.sin(f64(i) * (0.05 + 0.01 * f64(k)))))
			}
			// As the game does at load: at the mixer's rate, so a voice at its own
			// pitch takes the cheap path.
			converted := audio.resample_sound(
				{samples = samples[k], rate = 16000},
				audio.DEVICE_RATE,
			)
			delete(samples[k])
			samples[k] = converted.samples
			id = audio.add_sound(m, converted)
			audio.set_bandwidth(m, id, 8000)
		}
		music, _ := audio.add_stream(
			m,
			BENCH_AUDIO_STREAM,
			loop = true,
			crossfade = 0.1,
			inline = true,
		)
		audio.set_reverb(m, 1.4, 0.5, 0.25, 0.2)
		audio.set_bus_reverb(m, .World, 0.3)
		audio.set_bus_reverb(m, .Ambience, 0.5)
		audio.set_duck(
			m,
			0,
			{
				active = true,
				trigger = .Effects,
				target = .Music,
				threshold = 0.05,
				amount = 0.5,
				attack = 0.01,
				release = 0.3,
			},
		)
		buses := [4]audio.Bus{.World, .Player, .Ambience, .UI}
		for i in 0 ..< BENCH_AUDIO_VOICES {
			audio.play(
				m,
				{
					sound  = sounds[i % len(sounds)],
					gain   = {0.02, 0.02},
					// A quarter of them pitched about as effects are (the windowed
					// sinc), the rest within a semitone (the cubic).
					pitch  = 0.8 + 0.45 * f32(i % 7) / 6 if i % 4 == 0 else 0.97 + 0.06 * f32(i % 5) / 4,
					bus    = buses[i % len(buses)],
					loop   = true,
					cutoff = 6000 if i % 5 == 0 else 0,
				},
			)
		}
		audio.play(m, {sound = music, gain = {0.5, 0.5}, bus = .Music})
		out: [2 * BENCH_AUDIO_BLOCK]f32
		base.metrics_start()
		for blk in 0 ..< blocks + BENCH_AUDIO_WARMUP {
			start := time.tick_now()
			audio.mix(m, out[:])
			spent := time.tick_since(start)
			audio.drain(m)
			if blk >= BENCH_AUDIO_WARMUP {
				base.metric_add(.Audio_Mix, f32(time.duration_milliseconds(spent)))
			}
		}
		base.bench_repetition_end(&b.result)
		st := audio.stats(m)
		voices, real, underruns, late = st.voices, st.real, st.underruns, st.late
		audio.streams_close(m)
		for s in samples {delete(s)}
		free(m)
	}
	append(
		&b.result.counts,
		base.Bench_Count{"voices", int(voices)},
		base.Bench_Count{"real_voices", int(real)},
		base.Bench_Count{"underruns", int(underruns)},
		base.Bench_Count{"late", int(late)},
	)
	// The budget: the median block, against the 10 ms it has (release builds:
	// the others are slower on purpose).
	if base.build_name() == "release" {
		first := b.result.repetitions[0][.Audio_Mix].median
		share := first / (1000 * f64(BENCH_AUDIO_BLOCK) / audio.DEVICE_RATE)
		log.infof(
			"bench audio: a block takes %.1f%% of a core (budget %.0f%%)",
			100 * share,
			100 * BENCH_AUDIO_BUDGET,
		)
		if share > BENCH_AUDIO_BUDGET {
			bench_fail(app, "the 64-voice mix takes more than its share of a core")
			return
		}
	}
	bench_finish(app)
}

BENCH_VIEWMODEL_FRAMES :: 2000
// BENCH_VIEWMODEL_BUDGET_US: a frame of the view model is a few thousand
// vertices moved by one matrix, well inside a frame (judged, like the audio's,
// on a release build's median).
BENCH_VIEWMODEL_BUDGET_US :: 100

// view_model_bench_frame: the start kit's launcher (the biggest model) added to a
// held draw as a frame does; the draw is the caller's to destroy.
view_model_bench_frame :: proc(reg: ^game.Registry) -> (d: render.Held_Draw, ok: bool) {
	launcher := game.registry_item(reg, "rocket_launcher") or_return
	cache: Held_Cache
	defer held_cache_destroy(&cache)
	entry := held_entry(&cache, reg, launcher)
	arm := held_mesh_arm({196, 64, 52, 255})
	defer held_mesh_destroy(&arm)
	render.held_draw_init(&d)
	view_model_add(&d, entry.kind, &entry.mesh, &arm, {})
	return d, true
}

// bench_viewmodel runs the viewmodel scenario: each frame's time is a sample.
@(private = "file")
bench_viewmodel :: proc(app: ^App) {
	b := &app.bench
	reg := game.registry_base(context.allocator)
	defer game.registry_destroy(reg)
	frames := 200 if b.smoke else BENCH_VIEWMODEL_FRAMES
	launcher, found := game.registry_item(reg, "rocket_launcher")
	if !found {
		bench_fail(app, "the base pack has no rocket launcher")
		return
	}
	for _ in 0 ..< b.scenario.repetitions {
		cache: Held_Cache
		entry := held_entry(&cache, reg, launcher)
		arm := held_mesh_arm({196, 64, 52, 255})
		d: render.Held_Draw
		render.held_draw_init(&d)
		base.metrics_start()
		for _ in 0 ..< frames {
			start := time.tick_now()
			render.held_draw_clear(&d)
			view_model_add(&d, entry.kind, &entry.mesh, &arm, {})
			base.metric_add(.View_Model, f32(time.duration_microseconds(time.tick_since(start))))
		}
		base.bench_repetition_end(&b.result)
		render.held_draw_destroy(&d)
		held_mesh_destroy(&arm)
		held_cache_destroy(&cache)
	}
	counted, _ := view_model_bench_frame(reg)
	append(&b.result.counts, base.Bench_Count{"vertices", len(counted.view)})
	render.held_draw_destroy(&counted)
	if base.build_name() == "release" {
		median := b.result.repetitions[0][.View_Model].median
		log.infof(
			"bench viewmodel: a frame takes %.1f us (budget %d)",
			median,
			BENCH_VIEWMODEL_BUDGET_US,
		)
		if median > BENCH_VIEWMODEL_BUDGET_US {
			bench_fail(app, "a frame of the view model takes more than its budget")
			return
		}
	}
	bench_finish(app)
}

// bench_avatars_draw draws the avatars scenario's crowd while it measures: other
// players as the session draws them (avatar_draw, the entity and held passes), each
// walking on the spot with one of the kit's weapons. Called with the scene.
bench_avatars_draw :: proc(app: ^App, s: ^Session) {
	b := &app.bench
	if b.phase != .Measuring || b.scenario.kind != .Avatars {return}
	base.metric_scope(.Avatar_Draw)
	weapons := [?]string{"rifle", "shotgun", "sniper", "pistol", "rocket_launcher"}
	for p, k in b.crowd {
		item, _ := game.item_by_name(s.reg, weapons[k % len(weapons)])
		stride := f32(math.mod(f64(b.frames) * 0.12 + f64(k), math.TAU))
		pose := avatar_pose(
			s.rules.walk_speed,
			false,
			stride,
			hold_of(s.reg, item),
			s.rules.walk_speed,
			s.rules.sprint_speed,
		)
		yaw := f32(f64(k) * 2 * math.PI / BENCH_AVATARS)
		avatar_draw(
			s.reg,
			&app.entity_draw,
			p,
			yaw,
			0,
			pose,
			shirt_of(fmt.tprintf("bot%d", k + 1)),
			{},
			{&app.held_draw, held_entry(&app.held_cache, s.reg, item)},
		)
	}
}
