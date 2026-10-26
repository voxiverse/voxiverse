package client

import "core:fmt"
import "core:log"
import "core:os"
import "core:sync"
import "core:time"

import "../audio"

// The audio recorder in the running game (M32d). From the start the mixer
// keeps its last minute or so in a ring (audio.capture_start_ring: the commands
// and mix calls, and the mixer's state every 15 s so what is kept can be
// replayed from its middle). It is written to captures/audio-<n>.vxac, for
// `build audiodump`, on F9, with the `audio_capture` console command, and
// when the mixer underruns (at most once in AUDIO_CAPTURE_COOLDOWN, and
// AUDIO_CAPTURE_MAX files a run: a machine that underruns all the time does
// not fill the disk).

// A power of two: 2^16 records are a few minutes of a busy session.
AUDIO_RING_RECORDS :: 1 << 16
AUDIO_CAPTURE_COOLDOWN :: 30 * time.Second
AUDIO_CAPTURE_MAX :: 8

Audio_Debug :: struct {
	recording:  bool,
	underruns:  u32, // as of the last look
	last:       time.Tick,
	written:    int,
	last_saved: bool,
}

// audio_ring_start begins the rolling capture (not in a benchmark, which has
// no live mixer).
audio_ring_start :: proc(app: ^App) {
	app.audio_debug.recording = audio.capture_start_ring(app.mixer, AUDIO_RING_RECORDS)
}

// audio_ring_stop ends it and frees it (before the mixer goes).
audio_ring_stop :: proc(app: ^App) {
	if app.audio_debug.recording {
		audio.capture_destroy(audio.capture_stop(app.mixer))
		app.audio_debug.recording = false
	}
}

// audio_ring_save writes what the ring holds to captures/audio-<n>.vxac. Why
// goes in the log. False if there is nothing to write yet (the first state is
// taken when the mixer starts, so only a mixer that has not run) or the file
// cannot be written.
audio_ring_save :: proc(app: ^App, why: string) -> bool {
	d := &app.audio_debug
	if !d.recording {return false}
	dir := path_next_to_exe("captures")
	os.make_directory_all(dir)
	path := fmt.tprintf("%s/audio-%d.vxac", dir, d.written + 1)
	if !audio.capture_ring_save(app.mixer, path) {return false}
	d.written += 1
	log.infof("audio capture written path=%s why=%s (build audiodump %s)", path, why, path)
	return true
}

// audio_debug_update: the key, and the underrun watch.
audio_debug_update :: proc(app: ^App) {
	d := &app.audio_debug
	if !d.recording {return}
	if .F9 in app.input.pressed {
		if !audio_ring_save(
			app,
			"key",
		) {console_print(&app.console, "audio capture: nothing to write yet", .Warning)}
	}
	// (not audio.stats: reading it resets the callback's worst case)
	u := sync.atomic_load(&app.mixer.stats.underruns)
	if u > d.underruns {
		d.underruns = u
		cooled := d.last == {} || time.tick_since(d.last) > AUDIO_CAPTURE_COOLDOWN
		if cooled && d.written < AUDIO_CAPTURE_MAX {
			d.last = time.tick_now()
			audio_ring_save(app, "underrun")
		}
	}
}
