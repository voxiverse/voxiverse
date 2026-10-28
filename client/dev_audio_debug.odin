package client

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:time"

import "../base"
import "audio"

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
	last_path:  string, // the file written last (owned, clones into the heap)
	frozen:     ^audio.Frozen, // the inspector's freeze (dev_audio_inspector.odin)
	autosaved:  time.Tick, // audio-last.vxac, written while the mixer is busy
}

// How often the ring goes to captures/audio-last.vxac while any voice plays:
// the crash handler cannot write a capture (it runs in a signal handler), so
// the last window is already on disk and the crash report names it.
AUDIO_LAST_EVERY :: 30 * time.Second
// The most a report carries along (a larger file is only named).
AUDIO_REPORT_MAX_BYTES :: 4 << 20

// audio_ring_start begins the rolling capture (not in a benchmark, which has
// no live mixer).
audio_ring_start :: proc(app: ^App) {
	app.audio_debug.recording = audio.capture_start_ring(app.mixer, AUDIO_RING_RECORDS)
}

// audio_ring_stop ends it and frees it (before the mixer goes).
audio_ring_stop :: proc(app: ^App) {
	audio_inspector_thaw(app)
	delete(app.audio_debug.last_path)
	app.audio_debug.last_path = ""
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
	audio_note_saved(d, path)
	log.infof("audio capture written path=%s why=%s (build audiodump %s)", path, why, path)
	return true
}

// audio_note_saved remembers the last file written, for the report.
@(private = "file")
audio_note_saved :: proc(d: ^Audio_Debug, path: string) {
	delete(d.last_path)
	d.last_path = strings.clone(path)
}

// audio_ring_autosave writes the ring to captures/audio-last.vxac (and tells
// the crash report about it). Quiet: it is routine, not an event.
@(private = "file")
audio_ring_autosave :: proc(app: ^App) {
	path := fmt.tprintf("%s/audio-last.vxac", path_next_to_exe("captures"))
	os.make_directory_all(path_next_to_exe("captures"))
	if audio.capture_ring_save(app.mixer, path) {
		base.debug_attach(path)
		log.debugf("audio window kept path=%s", path)
	}
}

// audio_report_lines: what a report says of the audio window: the file, and
// how long ago it was written (empty when no ring is running or none written).
audio_report_lines :: proc(app: ^App) -> string {
	d := &app.audio_debug
	if d.last_path == "" {return ""}
	return fmt.tprintf("audio window: %s (build audiodump)\n", d.last_path)
}

// audio_report_copy puts the last audio window beside a report in dir
// (dir/reports, where the uploader does not look: the upload carries text only,
// so the file waits there): copied when it is at most AUDIO_REPORT_MAX_BYTES. Returns
// what to tell the person: "" when there is nothing to copy.
audio_report_copy :: proc(app: ^App, dir: string) -> string {
	d := &app.audio_debug
	if d.last_path == "" {return ""}
	data, err := os.read_entire_file(d.last_path, context.temp_allocator)
	if err != nil {return ""}
	if len(data) > AUDIO_REPORT_MAX_BYTES {
		return fmt.tprintf(
			"the audio window is %d bytes: named in the report, not kept",
			len(data),
		)
	}
	rdir := fmt.tprintf("%s/reports", dir)
	os.make_directory_all(rdir)
	name := fmt.tprintf("%s/%s", rdir, filepath.base(d.last_path))
	if os.write_entire_file(name, data) != nil {return "the audio window could not be copied"}
	return "the audio window is kept beside it"
}

// audio_debug_update: the key, and the underrun watch.
audio_debug_update :: proc(app: ^App) {
	d := &app.audio_debug
	audio_inspector_sync(app)
	if !d.recording {return}
	if sync.atomic_load(&app.mixer.stats.voices) > 0 &&
	   (d.autosaved == {} || time.tick_since(d.autosaved) > AUDIO_LAST_EVERY) {
		d.autosaved = time.tick_now()
		audio_ring_autosave(app)
	}
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
