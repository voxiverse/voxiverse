package client

import "core:fmt"
import "core:log"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:time"

import "../base"
import "../game"
import "../render"
import "../server"

// M9's exit check, as a console command: `blast_test <shots> [quit]` waits
// for the world, hovers above the spawn and fires: rockets and radius-6
// explosions in turn, a little further round each time. Then it checks the
// frames and server ticks kept within budget, no bulk edit's meshes had to
// be shown before all of them were ready (when a hole could show), memory
// did not grow, and the client's chunks are exactly the server's (a hash of
// every chunk the server has sent us, from each side). With `quit` it ends
// the program, failing the run if a check failed.
//
//	voxiverse --exec "singleplayer; blast_test 20 quit"

Blast_Test_Phase :: enum u8 {
	Off,
	Loading,
	Rising, // teleport requested; waiting to be up there, flying
	Firing,
	Settling, // the last shot is out: everything arriving, meshed
	Comparing, // asked the server for its hash
}

Blast_Test :: struct {
	phase:        Blast_Test_Phase,
	shots:        int,
	fired:        int,
	quit:         bool,
	started:      time.Tick, // of the phase
	next_shot:    time.Tick,
	frames:       base.Frame_Stats,
	tick_max:     f32, // the server's slowest tick seen while firing
	client_arena: uint,
	server_arena: uint,
	late_before:  int,
	shown_before: int,
	failed:       bool,
}

BLAST_SHOT_EVERY :: 300 * time.Millisecond // over the server's rocket rate limit
BLAST_FRAME_BUDGET_MS :: 100 // p99 (software Vulkan in CI included)
BLAST_TICK_BUDGET_MS :: 100 // the slowest server tick
BLAST_TIMEOUT :: 60 * time.Second // per phase

@(private)
blast_test_command :: proc(app: ^App, args: []string) {
	shots, ok := strconv.parse_int(args[0] if len(args) > 0 else "")
	if !ok || shots <= 0 {
		console_print(&app.console, "blast_test <shots> [quit]", .Warning)
		return
	}
	if app.session == nil {enter_world(app, "", 0x5eed)}
	if app.session == nil {return}
	t := &app.blast_test
	frames := t.frames
	t^ = {
		phase   = .Loading,
		shots   = shots,
		quit    = len(args) > 1 && args[1] == "quit",
		started = time.tick_now(),
		frames  = frames,
	}
	t.frames.count = 0
	log.infof("blast_test waiting for the world shots=%d", shots)
}

@(private)
blast_test_update :: proc(app: ^App) {
	t := &app.blast_test
	s := app.session
	if t.phase == .Off || s == nil {return}
	if t.phase != .Loading && s.state != .Playing {
		blast_test_finish(app, "left the world")
		return
	}
	if time.tick_since(t.started) > BLAST_TIMEOUT {
		blast_test_finish(app, fmt.tprintf("stuck in phase %v", t.phase))
		return
	}
	next :: proc(t: ^Blast_Test, phase: Blast_Test_Phase) {
		t.phase, t.started = phase, time.tick_now()
	}
	switch t.phase {
	case .Off:
	case .Loading:
		if !world_settled(app) {return}
		p := s.prediction.state.position
		session_teleport(s, {{p.x, p.y + 25, p.z}, -math.PI / 2, -0.7})
		next(t, .Rising)
	case .Rising:
		p := s.prediction.state
		if !p.flying {s.toggle_fly = true}
		v := p.velocity
		if !p.flying || v.x * v.x + v.y * v.y + v.z * v.z > 0.01 {return}
		s.autopilot = game.Player_Input {
			yaw   = s.camera.yaw,
			pitch = s.camera.pitch,
		}
		t.client_arena = s.arena.total_used
		t.server_arena = server.stats(&s.server).arena_used
		t.late_before = s.world.stats.groups_late
		t.shown_before = s.world.stats.groups_shown
		t.next_shot = time.tick_now()
		next(t, .Firing)
		log.info("blast_test firing")
	case .Firing:
		base.frame_stats_add(&t.frames, app.last_frame_ms)
		t.tick_max = max(t.tick_max, server.stats(&s.server).tick_ms)
		if time.tick_diff(time.tick_now(), t.next_shot) > 0 {return}
		t.next_shot = time.tick_add(time.tick_now(), BLAST_SHOT_EVERY)
		// A little further round each time: fresh ground.
		s.camera.yaw = -math.PI / 2 + f32(t.fired) * 0.35
		s.camera.pitch = -0.7
		s.autopilot = game.Player_Input {
			yaw   = s.camera.yaw,
			pitch = s.camera.pitch,
		}
		if t.fired % 2 == 0 {
			session_fire(s)
		} else {
			// Where the view meets the ground (beyond reach: we hover high).
			f := render.forward(s.camera.yaw, s.camera.pitch)
			query := game.Block_Query{&s.world, world_block}
			dir := [3]f64{f64(f.x), f64(f.y), f64(f.z)}
			hit, ok := game.raycast(query, s.camera.position, dir, 96)
			if !ok {
				blast_test_finish(app, "no ground in view to blow up")
				return
			}
			p := hit.block
			send_message(s, game.Admin{fmt.tprintf("explode %d %d %d 6", p.x, p.y, p.z)})
		}
		t.fired += 1
		if t.fired == t.shots {next(t, .Settling)}
	case .Settling:
		base.frame_stats_add(&t.frames, app.last_frame_ms)
		t.tick_max = max(t.tick_max, server.stats(&s.server).tick_ms)
		if time.tick_since(t.started) < 2 * time.Second || !world_settled(app) {return}
		if len(s.world.groups) > 0 {return}
		for n in s.notices {delete(n)}
		clear(&s.notices)
		send_message(s, game.Admin{"hash"})
		next(t, .Comparing)
	case .Comparing:
		for n in s.notices {
			if !strings.has_prefix(n, "hash ") {continue}
			f := strings.fields(n, context.temp_allocator)
			count, _ := strconv.parse_int(f[1])
			want, _ := strconv.parse_u64_of_base(f[2], 16)
			blast_test_compare(app, count, want)
			return
		}
	}
}

// blast_test_compare: the server's hash of the chunks it sent us against
// ours, then the rest of the checks.
@(private = "file")
blast_test_compare :: proc(app: ^App, count: int, server_sum: u64) {
	t := &app.blast_test
	s := app.session
	failures := make([dynamic]string, context.temp_allocator)
	// The same chunks: ours that the server says we have.
	sum: u64
	it: base.Pool_Iterator
	ours := 0
	for c in base.pool_next(&s.world.chunks, &it) {
		game.chunks_hash_add(&sum, c.pos, &c.blocks)
		ours += 1
	}
	if ours != count {
		append(
			&failures,
			fmt.tprintf("we hold %d chunks, the server says it sent %d", ours, count),
		)
	} else if sum != server_sum {
		append(&failures, "our chunks differ from the server's")
	}
	frames := base.frame_stats_summary(&t.frames)
	if frames.p99 > BLAST_FRAME_BUDGET_MS {
		append(
			&failures,
			fmt.tprintf("frames p99 %.1f ms over %d", frames.p99, BLAST_FRAME_BUDGET_MS),
		)
	}
	if t.tick_max > BLAST_TICK_BUDGET_MS {
		append(
			&failures,
			fmt.tprintf(
				"a server tick took %.1f ms (budget %d)",
				t.tick_max,
				BLAST_TICK_BUDGET_MS,
			),
		)
	}
	if late := s.world.stats.groups_late - t.late_before; late > 0 {
		append(
			&failures,
			fmt.tprintf("%d bulk edits shown before their meshes were all ready", late),
		)
	}
	// Every shot blew something up and was shown whole (a rocket may fly
	// off unseen: one may go missing).
	if shown := s.world.stats.groups_shown - t.shown_before; shown < t.fired - 1 {
		append(&failures, fmt.tprintf("only %d of %d blasts were shown as one", shown, t.fired))
	}
	if s.arena.total_used != t.client_arena {
		append(
			&failures,
			fmt.tprintf(
				"client session arena grew from %d to %d bytes",
				t.client_arena,
				s.arena.total_used,
			),
		)
	}
	if st := server.stats(&s.server); st.arena_used != t.server_arena {
		append(
			&failures,
			fmt.tprintf(
				"server session arena grew from %d to %d bytes",
				t.server_arena,
				st.arena_used,
			),
		)
	}
	log.infof(
		"blast_test shots=%d frames=%d p50=%.2f p99=%.2f max=%.2f server_tick_max=%.2f groups_shown=%d chunks=%d",
		t.fired,
		frames.count,
		frames.p50,
		frames.p99,
		frames.max,
		t.tick_max,
		s.world.stats.groups_shown,
		ours,
	)
	blast_test_finish(app, strings.join(failures[:], "; ", context.temp_allocator))
}

@(private = "file")
blast_test_finish :: proc(app: ^App, failure: string) {
	t := &app.blast_test
	if failure != "" {log.errorf("blast_test %s", failure)} else {log.info("blast_test passed")}
	if app.session != nil {
		app.session.autopilot = nil
		screenshot_request(app, "blast_test_end")
	}
	t.failed = failure != ""
	t.phase = .Off
	if t.quit {app.quit = true}
}
