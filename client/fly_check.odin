package client

import "core:fmt"
import "core:log"
import "core:math"

import "client:platform"
import "common:base"
import "common:game"
import "server:."

// The M3 exit check (`--check fly`, exit_check.odin's CHECKS): it waits
// for the world around the spawn to load, then flies the camera in a
// straight line and checks that memory stays put while it streams in new
// terrain and drops the old: the session arenas must not grow at all, and
// chunk storage must stay within the sizes fixed at join. It logs frame
// times for the flight, then ends the program (failing the run if a check
// failed).
//
//	voxiverse --check fly

Fly_Test_Phase :: enum u8 {
	Off,
	Loading,
	Lifting, // teleport and rule change requested, waiting for the server
	Flying,
}

Fly_Test :: struct {
	using check: Exit_Check,
	phase:       Fly_Test_Phase,
	distance:    f64, // blocks to fly
	start:       [3]f64,
	waited:      f32, // seconds spent loading
	rss_start:   int,
	pad:         bool, // the synthetic gamepad flies it, not the autopilot (fly_pad)
	pad_step:    int, // the pad's script: connect, the double tap, the stick
	pad_ticks:   int, // ticks flown on the pad
}

FLY_TEST_SPEED :: 40 // blocks per second (rules.fly_sprint_speed during the test)
FLY_TEST_HEIGHT :: 100 // above the highest terrain
FLY_TEST_LOAD_TIMEOUT :: 60 // seconds

@(private)
fly_test_begin :: proc(app: ^App, distance: f64, pad := false) {
	t := &app.fly_test
	if !exit_check_start(app, &t.check, "fly_test") {
		t.check.failed = true
		app.quit = true
		return
	}
	t.phase, t.distance, t.start, t.waited = .Loading, distance, {}, 0
	t.pad, t.pad_step, t.pad_ticks = pad, 0, 0
	log.infof("fly_test waiting for the world to load blocks=%.0f", distance)
}

@(private)
fly_test_update :: proc(app: ^App) {
	t := &app.fly_test
	s := app.session
	if t.phase == .Off {return}
	if s == nil {
		// The session failed (or was left): fail, never hang.
		fly_test_finish(app, "left the world")
		return
	}
	dt := app.last_frame_ms / 1000
	switch t.phase {
	case .Off:
	case .Loading:
		t.waited += dt
		if s.state != .Playing {
			if t.waited > FLY_TEST_LOAD_TIMEOUT {fly_test_finish(app, "never joined the world")}
			return
		}
		if !world_settled(app) {
			if t.waited >
			   FLY_TEST_LOAD_TIMEOUT {fly_test_finish(app, "the world did not finish loading")}
			return
		}
		// Like a player would: up above the hills (a cheat; singleplayer
		// allows it), faster flight, then fly towards +x holding sprint.
		p := s.prediction.state.position
		session_teleport(s, {{p.x, FLY_TEST_HEIGHT, p.z}, -math.PI / 2, -0.4})
		session_set_rule(s, "rules.fly_sprint_speed", fmt.tprint(FLY_TEST_SPEED))
		t.phase = .Lifting
		log.infof("fly_test loaded seconds=%.1f chunks=%d", t.waited, s.world.chunks.count)
	case .Lifting:
		t.waited += dt
		// (The pad's script starts once the teleport arrived; the player may fall meanwhile.)
		if t.pad_step == 0 &&
		   (s.prediction.state.position.y < FLY_TEST_HEIGHT - 1 ||
				   s.rules.fly_sprint_speed != FLY_TEST_SPEED) {
			if t.waited >
			   FLY_TEST_LOAD_TIMEOUT {fly_test_finish(app, "the teleport or rule change never arrived")}
			return
		}
		if t.pad {
			if !fly_test_pad_lift(app) {
				if t.waited > FLY_TEST_LOAD_TIMEOUT {fly_test_finish(app, "the pad never flew it")}
				return
			}
		} else {
			if !s.prediction.state.flying {s.toggle_fly = true} 	// (a teleport keeps a flyer flying)
			s.autopilot = game.Player_Input {
				move    = {0, 1},
				yaw     = -math.PI / 2,
				pitch   = -0.4,
				buttons = {.Sprint},
			}
		}
		t.start = s.prediction.state.position
		exit_check_baseline(&t.check, s)
		t.rss_start = base.resident_memory()
		t.phase = .Flying
		screenshot_request(app, "fly_test_start")
		log.infof("fly_test flying speed=%d", FLY_TEST_SPEED)
	case .Flying:
		if s.state != .Playing {
			fly_test_finish(app, "left the world mid-flight")
			return
		}
		base.frame_stats_add(&t.frames, app.last_frame_ms)
		if t.pad {
			// The pad's input must be what reaches the player.
			t.pad_ticks += 1
			if _, auto := s.autopilot.?; auto {
				fly_test_finish(
					app,
					"the pad's input did not reach the player (an autopilot flew)",
				)
				return
			}
			pr := &s.prediction
			if t.pad_ticks >= 10 && pr.count > 0 {
				newest := pr.pending[(pr.head + pr.count - 1) % game.PREDICTION_PENDING].input
				if newest.move != {0, 1} || .Sprint not_in newest.buttons {
					fly_test_finish(app, "the pad's input did not reach the player")
					return
				}
			}
		}
		p := s.prediction.state
		if !p.flying && p.position.x - t.start.x > 2 {
			fly_test_finish(app, "stopped flying (landed?)")
			return
		}
		if p.position.x - t.start.x >= t.distance {fly_test_finish(app, "")}
	}
}

@(private = "file")
fly_test_finish :: proc(app: ^App, error: string) {
	t := &app.fly_test
	s := app.session
	failures := make([dynamic]string, context.temp_allocator)
	if error != "" {append(&failures, error)}
	if error == "" {
		exit_check_memory(&t.check, s, &failures)
		st := server.stats(&s.server)
		w := &s.world
		capacity := len(w.chunks.items) - 1
		if w.arrays.allocated > capacity {append(&failures, "client chunk arrays past capacity")}
		if st.arrays_allocated > server.block_capacity(&s.server) {
			append(&failures, "server chunk arrays past capacity")
		}
		sum := base.frame_stats_summary(&t.frames)
		log.infof(
			"fly_test flew blocks=%.0f frames=%d avg_ms=%.2f p50=%.2f p99=%.2f max=%.2f",
			s.prediction.state.position.x - t.start.x,
			sum.count,
			sum.avg,
			sum.p50,
			sum.p99,
			sum.max,
		)
		log.infof(
			"fly_test memory client_chunks=%d client_capacity=%d client_arrays_mib=%.1f client_arena=%d server_chunks=%d server_arrays_mib=%.1f server_arena=%d stale_meshes=%d",
			w.chunks.count,
			capacity,
			f64(w.arrays.committed) / (1 << 20),
			s.arena.total_used,
			st.chunks_loaded,
			f64(st.arrays_bytes) / (1 << 20),
			st.arena_used,
			w.stats.stale_meshes,
		)
		if rss := base.resident_memory(); rss > 0 && t.rss_start > 0 {
			log.infof(
				"fly_test resident memory start_mib=%.1f end_mib=%.1f",
				f64(t.rss_start) / (1 << 20),
				f64(rss) / (1 << 20),
			)
		}
		log.infof(
			"fly_test prediction corrections=%d pending_inputs=%d",
			s.prediction.corrections,
			s.prediction.count,
		)
	}
	t.phase = .Off
	exit_check_finish(app, &t.check, failures[:])
}

// fly_test_pad_lift: the pad's script from the lifting on, one step a frame:
// a connect (an Xbox pad), then, if not flying, A pressed twice (the double
// tap: two presses two frames apart), repeated until flying; then the left
// stick pushed up and its button held. True once flying with the stick held.
@(private = "file")
fly_test_pad_lift :: proc(app: ^App) -> bool {
	t := &app.fly_test
	s := app.session
	inject :: proc(app: ^App, e: platform.Event) {append(&app.injected, e)}
	switch {
	case t.pad_step == 0:
		inject(app, platform.Pad_Connect_Event{pad = 0, connected = true, family = .Xbox})
		t.pad_step = 1
	case !s.prediction.state.flying:
		// 1: down, 2: up, 3: down, 4: up, then six frames to see it take.
		switch (t.pad_step - 1) % 10 {
		case 0, 2:
			inject(app, platform.Pad_Button_Event{pad = 0, button = .A, pressed = true})
		case 1, 3:
			inject(app, platform.Pad_Button_Event{pad = 0, button = .A, pressed = false})
		}
		t.pad_step += 1
	case t.pad_step < 100000:
		inject(app, platform.Pad_Axis_Event{pad = 0, axis = .Left_Y, value = 1})
		inject(app, platform.Pad_Button_Event{pad = 0, button = .Left_Stick, pressed = true})
		t.pad_step = 100000
		return false // (the stick takes a frame to arrive)
	case:
		return true
	}
	return false
}
