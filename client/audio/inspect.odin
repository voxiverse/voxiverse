package audio

import "core:math"
import "core:mem"
import "core:sync"
import "core:time"

// The freeze-and-solo inspector's engine (M32e; the overlay is
// client/dev_audio_inspector.odin). A freeze takes the rolling capture's newest
// window out of the live mixer (capture_ring_bytes), replays it through a
// mixer of its own with the live mixer's sounds, and keeps what it did: the
// voices with the engine's last decision about each, the buses' levels, the
// last INSPECT_LOOP_SECONDS of Master. The live mixer's output is replaced by
// that loop (a Monitor) until the freeze ends. Solo and mute rewrite the
// window's commands (a solo drops the plays of every other voice and the
// state's other voices) and replay it again.
//
// Streams are not replayed: their plays and voices are dropped from the
// window (a second mixer must not pull from the live mixer's streams).

INSPECT_LOOP_SECONDS :: 0.5
INSPECT_BANDS :: 48

// Monitor: audio that replaces the mixer's output, looped. `samples` is
// interleaved stereo and not touched while the monitor is set; `pos` is the
// audio thread's.
Monitor :: struct {
	samples: []f32,
	pos:     int, // frames
}

@(private)
monitor_fill :: proc "contextless" (mon: ^Monitor, out: []f32) {
	frames := len(mon.samples) / 2
	if frames == 0 {
		for &x in out {x = 0}
		return
	}
	for f in 0 ..< len(out) / 2 {
		out[2 * f] = mon.samples[2 * mon.pos]
		out[2 * f + 1] = mon.samples[2 * mon.pos + 1]
		mon.pos = (mon.pos + 1) % frames
	}
}

// monitor_set makes m play mon instead of its output (nil: its own again).
// Setting nil waits for a mix that may be reading the monitor to finish, so
// the caller may free it after.
monitor_set :: proc(m: ^Mixer, mon: ^Monitor) {
	sync.atomic_store(&m.monitor, mon)
	if mon == nil {time.sleep(5 * time.Millisecond)}
}

Inspect_Mode :: enum u8 {
	Off,
	Solo, // only the picked voice or bus is heard
	Mute, // everything but it
}

Inspect_Pick :: struct {
	mode:  Inspect_Mode,
	voice: bool, // the pick is a voice (else a bus)
	id:    Voice_Id,
	bus:   Bus,
}

// Frozen_Voice: one voice of the window.
Frozen_Voice :: struct {
	id:       Voice_Id,
	sound:    Sound_Id,
	bus:      Bus,
	gain:     [2]f32,
	pitch:    f32,
	priority: u8,
	last:     Decision_Kind, // what the engine did with it last, in the current replay
	heard:    bool, // the current replay has it
}

Frozen :: struct {
	live:    ^Mixer, // whose sounds these are
	mixer:   ^Mixer, // the replay's
	file:    Capture_File, // the window as frozen
	voices:  [dynamic]Frozen_Voice,
	pick:    Inspect_Pick,
	an:      Analysis, // of the current replay
	loop:    []f32, // the monitor's audio
	monitor: Monitor,
	bands:   [INSPECT_BANDS]f32, // dB of the loop, log frequency, low to high
	bytes:   []byte, // (the file's parse points into nothing of it, but keep it for a save)
}

// inspect_freeze takes the window and replays it. nil if the ring holds
// nothing yet, is not running, or the window does not parse.
inspect_freeze :: proc(live: ^Mixer) -> ^Frozen {
	bytes := capture_ring_bytes(live)
	if bytes == nil {return nil}
	fz := new(Frozen)
	fz.live, fz.bytes = live, bytes
	ok: bool
	fz.file, ok = capture_parse(bytes)
	if !ok {
		inspect_destroy(fz)
		return nil
	}
	fz.mixer = new(Mixer)
	for r in fz.file.records {
		if p, is_play := r.cmd.(Play_Cmd); is_play {note_voice(fz, p.id, p.play)}
	}
	if st := fz.file.state; st != nil {
		for v in st.voices {
			if v.state == .Playing {
				note_voice(
					fz,
					v.id,
					Play {
						sound = v.sound,
						gain = v.gain,
						pitch = f32(
							v.step * f64(fz.live.rate) / f64(max(fz.live.sounds[v.sound].rate, 1)),
						),
						bus = v.bus,
						priority = v.priority,
					},
				)
			}
		}
	}
	if !inspect_replay(fz) {
		inspect_destroy(fz)
		return nil
	}
	return fz
}

@(private = "file")
note_voice :: proc(fz: ^Frozen, id: Voice_Id, p: Play) {
	for &v in fz.voices {if v.id == id {return}}
	append(
		&fz.voices,
		Frozen_Voice {
			id = id,
			sound = p.sound,
			bus = p.bus,
			gain = p.gain,
			pitch = p.pitch if p.pitch > 0 else 1,
			priority = p.priority,
		},
	)
}

// inspect_pick sets what is soloed or muted and replays. Picking the same
// thing in the mode it already has clears it. False if the replay failed
// (the freeze then plays what it had).
inspect_pick :: proc(fz: ^Frozen, pick: Inspect_Pick) -> bool {
	prev := fz.pick
	fz.pick = pick
	if pick.mode == .Off || (pick.mode == .Solo && !pick.voice && pick.bus == .Master) {
		fz.pick = {}
	}
	if !inspect_replay(fz) {
		fz.pick = prev
		return false
	}
	return true
}

// inspect_keeps: whether the picked rule lets a voice through.
@(private = "file")
inspect_keeps :: proc(fz: ^Frozen, id: Voice_Id, bus: Bus, sound: Sound_Id) -> bool {
	if fz.live.streams[sound] != nil {return false}
	p := fz.pick
	if p.mode == .Off {return true}
	hit := p.id == id if p.voice else p.bus == bus
	return hit if p.mode == .Solo else !hit
}

@(private = "file")
bus_of :: proc(fz: ^Frozen, id: Voice_Id) -> (Bus, Sound_Id, bool) {
	for v in fz.voices {if v.id == id {return v.bus, v.sound, true}}
	return .World, 0, false
}

// inspect_replay mixes the window again through a fresh mixer with the
// pick's rewrite, and takes what the overlay shows from it.
@(private = "file")
inspect_replay :: proc(fz: ^Frozen) -> bool {
	m, live := fz.mixer, fz.live
	mixer_init(m, live.rate)
	m.sounds, m.names, m.streams, m.bandwidth, m.count =
		live.sounds, live.names, live.streams, live.bandwidth, live.count
	f := fz.file
	records := make([dynamic]Record, 0, len(f.records))
	defer delete(records)
	for r in f.records {
		keep := true
		if r.frames == 0 && r.drops == 0 {
			switch c in r.cmd {
			case Play_Cmd:
				keep = inspect_keeps(fz, c.id, c.play.bus, c.play.sound)
			case Voice_Param:
				keep = voice_kept(fz, c.id)
			case Stop_Cmd:
				keep = voice_kept(fz, c.id)
			case Fade_Cmd:
				keep = voice_kept(fz, c.id)
			case Bus_Cmd, Duck_Cmd, Snapshot_Cmd, Reverb_Cmd, Listener_Cmd:
			}
		}
		if keep {append(&records, r)}
	}
	f.records = records[:]
	st: ^Mixer_State // (freed with the replay: a defer in the block below would free it at its end)
	defer free(st)
	if f.state != nil {
		st = new(Mixer_State)
		// (not `st^ = f.state^`: the state is most of a megabyte, which the
		// compiler may build on the stack first, and a thread's stack is small)
		mem.copy(st, f.state, size_of(Mixer_State))
		for &v in st.voices {
			if v.state == .Playing && !inspect_keeps(fz, v.id, v.bus, v.sound) {v.state = .Free}
		}
		f.state = st
	}
	// (the stream check of capture_replay reads the streams: they match the
	// table, and none is played)
	an: Analysis
	if !analyze_replay(m, &f, {.Master}, &an) {
		analysis_destroy(&an)
		return false
	}
	// (the audio thread may be reading the loop: look away while it changes)
	on := sync.atomic_load(&live.monitor) == &fz.monitor
	if on {monitor_set(live, nil)}
	defer if on {monitor_set(live, &fz.monitor)}
	analysis_destroy(&fz.an)
	fz.an = an
	for &v in fz.voices {
		v.heard, v.last = false, .Ended
		for d in an.decisions {
			if d.voice == v.id {v.heard, v.last = true, d.kind}
		}
	}
	loop_frames := int(INSPECT_LOOP_SECONDS * f64(m.rate))
	master := an.audio[.Master][:]
	loop_frames = min(loop_frames, len(master) / 2)
	delete(fz.loop)
	fz.loop = make([]f32, 2 * loop_frames)
	copy(fz.loop, master[len(master) - 2 * loop_frames:])
	spectrum_bands(fz.loop, m.rate, fz.bands[:])
	fz.monitor.samples = fz.loop
	fz.monitor.pos = 0
	return true
}

@(private = "file")
voice_kept :: proc(fz: ^Frozen, id: Voice_Id) -> bool {
	bus, sound, known := bus_of(fz, id)
	if !known {return fz.pick.mode != .Solo}
	return inspect_keeps(fz, id, bus, sound)
}

// inspect_start makes the live mixer play the loop in place of its output.
inspect_start :: proc(fz: ^Frozen) {
	monitor_set(fz.live, &fz.monitor)
}

// inspect_destroy ends the freeze: the live mixer plays itself again.
inspect_destroy :: proc(fz: ^Frozen) {
	if fz == nil {return}
	if sync.atomic_load(&fz.live.monitor) == &fz.monitor {monitor_set(fz.live, nil)}
	analysis_destroy(&fz.an)
	capture_file_destroy(&fz.file)
	delete(fz.voices)
	delete(fz.loop)
	delete(fz.bytes)
	free(fz.mixer)
	free(fz)
}

// spectrum_bands: the level, in dB of a full-scale sine, of the last
// SPEC_WINDOW frames of x on a log frequency axis, into bands.
spectrum_bands :: proc(x: []f32, rate: u32, bands: []f32) {
	for &b in bands {b = SPEC_FLOOR_DB}
	frames := len(x) / 2
	if frames == 0 {return}
	re := make([]f64, SPEC_WINDOW)
	im := make([]f64, SPEC_WINDOW)
	defer {delete(re); delete(im)}
	norm := 0.0
	start := max(0, frames - SPEC_WINDOW)
	for i in 0 ..< SPEC_WINDOW {
		w := 0.5 - 0.5 * math.cos(2 * math.PI * f64(i) / SPEC_WINDOW)
		norm += w
		v := 0.0
		if j := start + i; j < frames {v = 0.5 * f64(x[2 * j] + x[2 * j + 1])}
		re[i] = v * w
	}
	norm *= 0.5
	fft(re, im)
	top := min(SPEC_HIGH_HZ, 0.5 * f64(rate))
	bin_hz := f64(rate) / SPEC_WINDOW
	for b in 0 ..< len(bands) {
		f0 := SPEC_LOW_HZ * math.pow(top / SPEC_LOW_HZ, f64(b) / f64(len(bands)))
		f1 := SPEC_LOW_HZ * math.pow(top / SPEC_LOW_HZ, f64(b + 1) / f64(len(bands)))
		lo := int(f0 / bin_hz)
		hi := max(int(f1 / bin_hz), lo + 1)
		peak := 0.0
		for k in lo ..< min(hi, SPEC_WINDOW / 2) {
			peak = max(peak, math.sqrt(re[k] * re[k] + im[k] * im[k]))
		}
		bands[b] = f32(max(20 * math.log10(max(peak / norm, 1e-12)), SPEC_FLOOR_DB))
	}
}
