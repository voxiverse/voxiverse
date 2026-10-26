package client

import "core:fmt"
import "core:log"
import "core:math"
import "core:time"

import "../audio"

// M32d's real-time check (`--check audio`, exit_check.odin's CHECKS): the
// game mixes into the null device (audio.device_open_null: the real callback
// path, paced by the wall clock, no sound card) for 30 seconds while a world
// of our own stands about, and sounds are played into it as in a busy
// session: footsteps, breaks, hurt sheep, explosions. Then it checks the
// mixer's own counters: no underruns, no non-finite samples, no dropped
// commands, no late ones, the callback's worst case under three blocks, and the device really ran in real time (the frames mixed are the
// seconds elapsed). The rolling capture is saved at the end and must replay.
//
//	voxiverse --check audio

Audio_Check_Phase :: enum u8 {
	Off,
	Loading,
	Running,
}

Audio_Check :: struct {
	using check: Exit_Check,
	phase:       Audio_Check_Phase,
	started:     time.Tick,
	next:        time.Tick,
	events:      int,
	frames0:     u64,
	cb_max_ns:   u32, // the worst callback seen (each look at the stats resets it)
}

AUDIO_CHECK_SECONDS :: 30
AUDIO_CHECK_EVERY :: 60 * time.Millisecond
AUDIO_CHECK_TIMEOUT :: 90 * time.Second // loading, in the slowest runner
// The callback's worst case may not pass three blocks (30 ms): a card buffers
// two or three periods, so past it one would have underrun. (One block is what
// the mix usually takes a tenth of; on a runner whose cores the software
// rasterizer holds, a single preempted callback was seen at 9.5 ms, so the
// budget is for a stall, and the mean is the bench's to watch.)
AUDIO_CHECK_CALLBACK_NS :: 3_000_000_000 * audio.NULL_BLOCK / audio.DEVICE_RATE

@(private)
audio_check_begin :: proc(app: ^App) {
	t := &app.audio_check
	if !app.audio_device.open || app.audio_device.kind != .Null {
		log.error("audio_check needs the null device (--check audio opens it)")
		t.check.failed = true
		app.quit = true
		return
	}
	if !exit_check_start(app, &t.check, "audio_check") {
		t.check.failed = true
		app.quit = true
		return
	}
	// (the checks' settings are silent: here the mix must be audible, or every
	// voice would be virtual and cost nothing)
	app.settings.volume = 0.8
	t.phase, t.started = .Loading, time.tick_now()
	log.infof("audio_check waiting for the world")
}

@(private)
audio_check_update :: proc(app: ^App) {
	t := &app.audio_check
	s := app.session
	if t.phase == .Off {return}
	if s == nil || s.state != .Playing && t.phase != .Loading {
		audio_check_finish(app, "left the world")
		return
	}
	switch t.phase {
	case .Off:
	case .Loading:
		if time.tick_since(t.started) > AUDIO_CHECK_TIMEOUT {
			audio_check_finish(app, "the world never settled")
		} else if world_settled(app) {
			// Counted from here: loading the world is not what is measured.
			a := audio.stats(app.mixer)
			t.frames0, t.cb_max_ns = a.frames, 0
			t.started, t.next, t.phase = time.tick_now(), time.tick_now(), .Running
			log.info("audio_check mixing")
		}
	case .Running:
		t.cb_max_ns = max(t.cb_max_ns, audio.stats(app.mixer).cb_max_ns)
		if time.tick_diff(time.tick_now(), t.next) <= 0 {
			t.next = time.tick_add(time.tick_now(), AUDIO_CHECK_EVERY)
			// What a busy session tells the mixer, round the camera.
			kinds := [?]Sound_Kind{.Step, .Break, .Place, .Entity_Hurt, .Land, .Explosion, .Launch}
			k := t.events
			angle := f64(k) * 0.9
			at := s.camera.position + {6 * math.cos(angle), -1, 6 * math.sin(angle)}
			append(
				&s.sounds,
				Sound_Event {
					kind = kinds[k % len(kinds)],
					block = .Stone,
					position = at,
					volume = 1,
				},
			)
			t.events += 1
		}
		if time.tick_since(t.started) >= AUDIO_CHECK_SECONDS * time.Second {
			audio_check_finish(app, "")
		}
	}
}

@(private)
audio_check_finish :: proc(app: ^App, failure: string) {
	t := &app.audio_check
	was_running := t.phase == .Running
	t.phase = .Off
	failures := make([dynamic]string, context.temp_allocator)
	if failure != "" {append(&failures, failure)}
	if was_running {
		a := audio.stats(app.mixer)
		seconds := time.duration_seconds(time.tick_since(t.started))
		mixed := f64(a.frames - t.frames0) / f64(app.mixer.rate)
		log.infof(
			"audio_check events=%d voices_played=%d mixed=%.2fs of %.2fs underruns=%d nan=%d dropped=%d late=%d callback_max_us=%d",
			t.events,
			a.played,
			mixed,
			seconds,
			a.underruns,
			a.nan_guarded,
			app.mixer.dropped,
			a.late,
			t.cb_max_ns / 1000,
		)
		if a.underruns > 0 {append(&failures, fmt.tprintf("%d underruns", a.underruns))}
		if a.nan_guarded >
		   0 {append(&failures, fmt.tprintf("%d non-finite samples", a.nan_guarded))}
		if app.mixer.dropped >
		   0 {append(&failures, fmt.tprintf("%d commands dropped", app.mixer.dropped))}
		if a.late > 0 {append(&failures, fmt.tprintf("%d late commands", a.late))}
		if t.cb_max_ns > AUDIO_CHECK_CALLBACK_NS {
			append(
				&failures,
				fmt.tprintf(
					"callback took %d us (the budget is %d us)",
					t.cb_max_ns / 1000,
					AUDIO_CHECK_CALLBACK_NS / 1000,
				),
			)
		}
		// Real time: what the device mixed is what the wall clock allows (within a
		// block or two, and the frames that stutters would have lost).
		if abs(mixed - seconds) > 0.25 + 0.02 * seconds {
			append(&failures, fmt.tprintf("mixed %.2f s in %.2f s", mixed, seconds))
		}
		if a.played < u32(t.events / 2) {
			append(
				&failures,
				fmt.tprintf("only %d voices played for %d events", a.played, t.events),
			)
		}
		if !audio_ring_save(
			app,
			"audio_check",
		) {append(&failures, "the rolling capture wrote nothing")}
	}
	exit_check_finish(app, &t.check, failures[:])
}
