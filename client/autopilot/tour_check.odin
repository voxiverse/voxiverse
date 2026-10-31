package autopilot

import "core:fmt"
import "core:log"
import "core:strings"
import "core:time"

import "client:engine"
import "client:screen"
import "common:base"
import "common:game"
import "common:worldgen"
import "server:core"

// M10's exit check (`--check tour`, exit_check.odin's CHECKS): it visits every
// biome of an Earth world in turn (`locate`, then waiting for the land to
// load and mesh) and screenshots each (biome_<name>). Then it checks that
// frames, and chunk generation and meshing on the workers, kept within
// budget, that memory did not grow after the first biome, and that every
// biome was found. With `quit` it ends the program, failing the run if a
// check failed.
//
//	voxiverse --check tour

TOUR_FRAME_BUDGET_MS :: 100 // p99 (software Vulkan in CI included)
// p99 per chunk, on a worker thread: a fully optimized build's, ten times
// that otherwise (unoptimized is 7-15x slower, -o:minimal 3-8x).
@(private = "file")
FULLY_OPTIMIZED :: ODIN_OPTIMIZATION_MODE >= .Size
TOUR_GENERATE_BUDGET_MS :: 5 when FULLY_OPTIMIZED else 50
TOUR_MESH_BUDGET_MS :: 10 when FULLY_OPTIMIZED else 100
TOUR_TIMEOUT :: 90 * time.Second // per biome

@(private)
tour_test_begin :: proc(app: ^engine.App) {
	t := &app.tour_test
	if !exit_check_start(app, &t.check, "tour_test") {
		t.check.failed = true
		app.quit = true
		return
	}
	t.phase, t.biome, t.started, t.measuring, t.missing =
		.Loading, worldgen.Biome(0), engine.app_tick(app), false, {}
	log.info("tour_test waiting for the world")
}

tour_test_update :: proc(app: ^engine.App) {
	t := &app.tour_test
	s := app.session
	if t.phase == .Off {return}
	if s == nil || (t.phase != .Loading && s.state != .Playing) {
		tour_test_finish(app, "left the world")
		return
	}
	if engine.app_since(app, t.started) > TOUR_TIMEOUT {
		tour_test_finish(app, fmt.tprintf("stuck in phase %v at %v", t.phase, t.biome))
		return
	}
	if t.measuring {base.frame_stats_add(&t.frames, app.last_frame_ms)}
	name := worldgen.BIOME_NAMES[t.biome]
	switch t.phase {
	case .Off:
	case .Loading:
		if !screen.world_settled(app) {return}
		if !s.has_worldgen {
			tour_test_finish(app, "not an Earth world")
			return
		}
		tour_locate(app, t, s)
	case .Locating:
		for n in s.notices {
			switch {
			case strings.has_prefix(n, fmt.tprintf("%s at ", name)):
				t.phase, t.started = .Arriving, engine.app_tick(app)
			case strings.has_prefix(n, fmt.tprintf("No %s ", name)):
				t.missing += {t.biome}
				tour_next(app, t, s)
			}
		}
	case .Arriving:
		// A moment for the server to drop what is left behind, then the
		// whole area loaded and meshed.
		if engine.app_since(app, t.started) < 500 * time.Millisecond ||
		   !screen.world_settled(app) {return}
		engine.screenshot_request(app, fmt.tprintf("biome_%s", name))
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
tour_locate :: proc(app: ^engine.App, t: ^engine.Tour_Test, s: ^engine.Session) {
	engine.send_message(s, game.Command{fmt.tprintf("locate %s", worldgen.BIOME_NAMES[t.biome])})
	t.phase, t.started = .Locating, engine.app_tick(app)
}

@(private = "file")
tour_next :: proc(app: ^engine.App, t: ^engine.Tour_Test, s: ^engine.Session) {
	if int(t.biome) == len(worldgen.Biome) - 1 {
		tour_test_finish(app, "")
		return
	}
	t.biome += worldgen.Biome(1)
	tour_locate(app, t, s)
}

@(private = "file")
tour_test_finish :: proc(app: ^engine.App, failure: string) {
	t := &app.tour_test
	s := app.session
	failures := make([dynamic]string, context.temp_allocator)
	if failure != "" {append(&failures, failure)}
	if failure == "" {
		if t.missing != {} {append(&failures, fmt.tprintf("biomes not found: %v", t.missing))}
		exit_check_memory(&t.check, s, &failures)
		frames := base.frame_stats_summary(&t.frames)
		generate := core.stats(&s.server).generate // (published each second)
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
	}
	t.phase = .Off
	exit_check_finish(app, &t.check, failures[:])
}
