package client

import "core:fmt"
import "core:log"
import "core:strings"
import "core:time"

import "../base"
import "../game"
import "../server"
import "../worldgen"

// M10's exit check, as a console command: `tour_test [quit]` visits every
// biome of an Earth world in turn (`locate`, then waiting for the land to
// load and mesh) and screenshots each (biome_<name>). Then it checks that
// frames, and chunk generation and meshing on the workers, kept within
// budget, that memory did not grow after the first biome, and that every
// biome was found. With `quit` it ends the program, failing the run if a
// check failed.
//
//	voxiverse --exec "tour_test quit"

Tour_Test_Phase :: enum u8 {
	Off,
	Loading,
	Locating, // asked the server; waiting for its answer
	Arriving, // there: waiting for the land around to load and mesh
}

Tour_Test :: struct {
	using check: Exit_Check,
	phase:       Tour_Test_Phase,
	biome:       worldgen.Biome, // the one being visited
	started:     time.Tick, // of the phase
	missing:     bit_set[worldgen.Biome], // not found within reach
	measuring:   bool, // memory baseline taken (after the first biome)
}

TOUR_FRAME_BUDGET_MS :: 100 // p99 (software Vulkan in CI included)
// p99 per chunk, on a worker thread: a fully optimized build's, ten times
// that otherwise (unoptimized is 7-15x slower, -o:minimal 3-8x).
@(private = "file")
FULLY_OPTIMIZED :: ODIN_OPTIMIZATION_MODE >= .Size
TOUR_GENERATE_BUDGET_MS :: 5 when FULLY_OPTIMIZED else 50
TOUR_MESH_BUDGET_MS :: 10 when FULLY_OPTIMIZED else 100
TOUR_TIMEOUT :: 90 * time.Second // per biome

@(private)
tour_test_command :: proc(app: ^App, args: []string) {
	t := &app.tour_test
	ok: bool
	// Exit_Check wants an amount first: there is none here.
	_, ok = exit_check_start(app, &t.check, "tour_test", {"1", args[0] if len(args) > 0 else ""})
	if !ok {return}
	t.phase, t.biome, t.started, t.measuring, t.missing =
		.Loading, worldgen.Biome(0), time.tick_now(), false, {}
	log.info("tour_test waiting for the world")
}

@(private)
tour_test_update :: proc(app: ^App) {
	t := &app.tour_test
	s := app.session
	if t.phase == .Off {return}
	if s == nil || (t.phase != .Loading && s.state != .Playing) {
		tour_test_finish(app, "left the world")
		return
	}
	if time.tick_since(t.started) > TOUR_TIMEOUT {
		tour_test_finish(app, fmt.tprintf("stuck in phase %v at %v", t.phase, t.biome))
		return
	}
	if t.measuring {base.frame_stats_add(&t.frames, app.last_frame_ms)}
	name := worldgen.BIOME_NAMES[t.biome]
	switch t.phase {
	case .Off:
	case .Loading:
		if !world_settled(app) {return}
		if !s.has_worldgen {
			tour_test_finish(app, "not an Earth world")
			return
		}
		tour_locate(t, s)
	case .Locating:
		for n in s.notices {
			switch {
			case strings.has_prefix(n, fmt.tprintf("%s at ", name)):
				t.phase, t.started = .Arriving, time.tick_now()
			case strings.has_prefix(n, fmt.tprintf("No %s ", name)):
				t.missing += {t.biome}
				tour_next(app, t, s)
			}
		}
	case .Arriving:
		// A moment for the server to drop what is left behind, then the
		// whole area loaded and meshed.
		if time.tick_since(t.started) < 500 * time.Millisecond || !world_settled(app) {return}
		screenshot_request(app, fmt.tprintf("biome_%s", name))
		log.infof("tour_test biome=%s chunks=%d", name, s.world.chunks.count)
		if !t.measuring {
			// From here on memory must stay put: everything is sized by now.
			exit_check_baseline(&t.check, s)
			t.measuring = true
		}
		tour_next(app, t, s)
	}
}

@(private = "file")
tour_locate :: proc(t: ^Tour_Test, s: ^Session) {
	send_message(s, game.Command{fmt.tprintf("locate %s", worldgen.BIOME_NAMES[t.biome])})
	t.phase, t.started = .Locating, time.tick_now()
}

@(private = "file")
tour_next :: proc(app: ^App, t: ^Tour_Test, s: ^Session) {
	if int(t.biome) == len(worldgen.Biome) - 1 {
		tour_test_finish(app, "")
		return
	}
	t.biome += worldgen.Biome(1)
	tour_locate(t, s)
}

@(private = "file")
tour_test_finish :: proc(app: ^App, failure: string) {
	t := &app.tour_test
	s := app.session
	failures := make([dynamic]string, context.temp_allocator)
	if failure != "" {append(&failures, failure)}
	if failure == "" {
		if t.missing != {} {append(&failures, fmt.tprintf("biomes not found: %v", t.missing))}
		exit_check_memory(&t.check, s, &failures)
		frames := base.frame_stats_summary(&t.frames)
		generate := server.stats(&s.server).generate // (published each second)
		mesh := base.frame_stats_summary(&s.world.stats.mesh_times)
		budget :: proc(failures: ^[dynamic]string, what: string, p99: f32, limit: int) {
			if p99 >
			   f32(
				   limit,
			   ) {append(failures, fmt.tprintf("%s p99 %.1f ms over %d", what, p99, limit))}
		}
		budget(&failures, "frames", frames.p99, TOUR_FRAME_BUDGET_MS)
		budget(&failures, "chunk generation", generate.p99, TOUR_GENERATE_BUDGET_MS)
		budget(&failures, "chunk meshing", mesh.p99, TOUR_MESH_BUDGET_MS)
		log.infof(
			"tour_test frames=%d p99=%.2f generate avg=%.2f p99=%.2f (%d chunks) mesh avg=%.2f p99=%.2f (%d chunks)",
			frames.count,
			frames.p99,
			generate.avg,
			generate.p99,
			generate.count,
			mesh.avg,
			mesh.p99,
			mesh.count,
		)
		base.perf_history_append(
			"tour_test",
			{
				{"frame_p99_ms", f64(frames.p99)},
				{"generate_mean_ms", f64(generate.avg)},
				{"generate_p99_ms", f64(generate.p99)},
				{"mesh_mean_ms", f64(mesh.avg)},
				{"mesh_p99_ms", f64(mesh.p99)},
			},
		)
	}
	t.phase = .Off
	exit_check_finish(app, &t.check, failures[:])
}
