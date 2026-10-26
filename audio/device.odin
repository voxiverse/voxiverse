package audio

import "core:log"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import ma "vendor:miniaudio"

// The sound card, through miniaudio (only its device layer: it opens the
// default output and calls us for samples; mixing is ours). No device (a
// server, CI) is not an error: the game runs silent.
//
//	audio.device_open(&dev, &mixer) // sets mixer.rate, then starts
//	... audio.play(&mixer, ...) ...
//	audio.device_close(&dev)
//
// The callback runs on the card's thread, which miniaudio asks the system to
// make real-time (the context is opened with the realtime priority; on
// Windows its WASAPI backend also joins MMCSS's "Pro Audio" class). Each call
// flushes denormals to zero (FTZ/DAZ on x86-64, FZ on arm64), so a decaying
// filter or reverb tail never falls into the slow path, and measures itself:
// its duration goes into Stats (cb_last_ns, cb_max_ns) and the device's clock
// is compared with the system's (drift_ppm: what a sound scheduled by frame
// would be off by, in the long run, against the wall clock).
//
// Two devices need no sound card. The null device (device_open_null) is a
// thread that asks for a block every 10 ms by the wall clock, as a card
// would, and throws it away: CI's smoke run and a game on a machine without
// audio exercise the real callback path (timing, stats) with it. The file
// device (device_open_file) has no clock at all: the caller says how many
// frames to mix (device_render) and they are kept, as fast as the mixer goes,
// and written as a WAV at close (at most FILE_DEVICE_SECONDS): a game driven by
// a script, a tool listening to a scenario.

Device_Kind :: enum u8 {
	Card,
	Null,
	File,
}

Device :: struct {
	device:   ma.device,
	ma_ctx:   ma.context_type,
	has_ctx:  bool,
	open:     bool,
	kind:     Device_Kind,
	callback: Callback,
	thread:   ^thread.Thread, // the null device's
	stopping: bool, // (atomic) tells it to end
	path:     string, // the file device's WAV (owned: freed at close)
	wav:      [dynamic]f32, // ... and what it has mixed
	wav_full: bool,
	// The callback's, for the drift:
	first:    time.Tick,
	mark:     f64, // seconds on the system clock when the span measured began
	mark_at:  u64, // frames asked for by then
	frames:   u64,
}

// DEVICE_RATE: what we ask for; miniaudio converts if the card differs.
DEVICE_RATE :: 48000

// DRIFT_AFTER: seconds of running before the drift span begins, and its
// least length (a shorter span says more of the callbacks' timing than of
// the clock).
DRIFT_AFTER :: 5.0

// NULL_BLOCK: frames the null device mixes at a time (10 ms at 48 kHz, a
// card's usual period).
NULL_BLOCK :: 480

// FILE_DEVICE_SECONDS: the most the file device keeps (it is all in memory).
FILE_DEVICE_SECONDS :: 300

// device_open starts playing m through the default output. m must stay at
// its address until device_close; sounds are added before this. False:
// no sound (logged), and m is never mixed.
device_open :: proc(d: ^Device, m: ^Mixer) -> bool {
	cctx := ma.context_config_init()
	cctx.threadPriority = .realtime
	ctx: ^ma.context_type
	if r := ma.context_init(nil, 0, &cctx, &d.ma_ctx); r == .SUCCESS {
		d.has_ctx = true
		ctx = &d.ma_ctx
	} else {
		log.warnf("audio real-time priority unavailable, default context result=%v", r)
	}
	config := ma.device_config_init(.playback)
	config.playback.format = .f32
	config.playback.channels = 2
	config.sampleRate = DEVICE_RATE
	config.performanceProfile = .low_latency
	config.dataCallback = data_callback
	d.callback = {m, d}
	config.pUserData = &d.callback
	if r := ma.device_init(ctx, &config, &d.device); r != .SUCCESS {
		log.warnf("audio no output device, running silent result=%v", r)
		if d.has_ctx {ma.context_uninit(&d.ma_ctx)}
		d^ = {}
		return false
	}
	m.rate = d.device.sampleRate
	if r := ma.device_start(&d.device); r != .SUCCESS {
		log.warnf("audio device would not start, running silent result=%v", r)
		ma.device_uninit(&d.device)
		if d.has_ctx {ma.context_uninit(&d.ma_ctx)}
		d^ = {}
		return false
	}
	d.open = true
	d.kind = .Card
	log.infof(
		"audio device open rate=%d period=%d frames x %d",
		m.rate,
		d.device.playback.internalPeriodSizeInFrames,
		d.device.playback.internalPeriods,
	)
	return true
}

device_close :: proc(d: ^Device) {
	switch d.kind {
	case .Card:
		if d.open {ma.device_uninit(&d.device)} 	// stops the callbacks first
		if d.has_ctx {ma.context_uninit(&d.ma_ctx)}
	case .Null:
		if d.thread != nil {
			sync.atomic_store(&d.stopping, true)
			thread.join(d.thread)
			thread.destroy(d.thread)
		}
	case .File:
		if d.open && len(d.wav) > 0 {wav_write(d.path, d.wav[:], d.callback.mixer.rate)}
		delete(d.wav)
		delete(d.path)
	}
	d^ = {}
}

// device_open_null starts the null device: m is mixed in real time and the
// samples dropped. m must stay at its address until device_close, and its
// rate is the one it has (DEVICE_RATE).
device_open_null :: proc(d: ^Device, m: ^Mixer) -> bool {
	d^ = {
		kind     = .Null,
		callback = {m, d},
	}
	if m.rate == 0 {m.rate = DEVICE_RATE}
	d.thread = thread.create_and_start_with_data(d, null_main, context)
	d.open = d.thread != nil
	return d.open
}

@(private = "file")
null_main :: proc(data: rawptr) {
	d := (^Device)(data)
	m := d.callback.mixer
	block := make([]f32, 2 * NULL_BLOCK)
	defer delete(block)
	period := time.Duration(f64(time.Second) * NULL_BLOCK / f64(m.rate))
	next := time.tick_now()
	for !sync.atomic_load(&d.stopping) {
		flush_denormals()
		pump(&d.callback, block)
		next._nsec += i64(period)
		if wait := time.tick_diff(time.tick_now(), next); wait > 0 {time.sleep(wait)}
	}
}

// device_open_file starts the file device: nothing is mixed until
// device_render. path is written at close.
device_open_file :: proc(d: ^Device, m: ^Mixer, path: string) -> bool {
	if m.rate == 0 {m.rate = DEVICE_RATE}
	d^ = {
		kind     = .File,
		callback = {m, d},
		path     = strings.clone(path),
		open     = true,
	}
	return true
}

// device_render mixes `frames` frames into the file device, as fast as it
// can. False once FILE_DEVICE_SECONDS are full (and logged, once).
device_render :: proc(d: ^Device, frames: int) -> bool {
	if d.kind != .File || !d.open {return false}
	m := d.callback.mixer
	if (len(d.wav) / 2 + frames) > FILE_DEVICE_SECONDS * int(m.rate) {
		if !d.wav_full {log.warnf("audio file device full (%d s): not mixing more", FILE_DEVICE_SECONDS)}
		d.wav_full = true
		return false
	}
	at := len(d.wav)
	resize(&d.wav, at + 2 * frames)
	for done := 0; done < frames; {
		n := min(frames - done, NULL_BLOCK)
		pump(&d.callback, d.wav[at + 2 * done:][:2 * n])
		done += n
	}
	return true
}

// output_latency: milliseconds from a command taking effect to its sound
// leaving the card: the limiter's look-ahead and the device's buffer.
output_latency :: proc(d: ^Device, m: ^Mixer) -> f32 {
	if !d.open || m.rate == 0 {return 0}
	if d.kind != .Card {return 1000 * f32(latency(m)) / f32(m.rate)}
	buffer := d.device.playback.internalPeriodSizeInFrames * d.device.playback.internalPeriods
	return 1000 * f32(latency(m) + int(buffer)) / f32(m.rate)
}

@(private = "file")
data_callback :: proc "c" (device: ^ma.device, output, input: rawptr, frames: u32) {
	flush_denormals()
	pump((^Callback)(device.pUserData), ([^]f32)(output)[:frames * 2])
}

// pump is the callback's body: mix, and measure.
@(private = "file")
pump :: proc "contextless" (cb: ^Callback, out: []f32) {
	m, d := cb.mixer, cb.device
	frames := u32(len(out) / 2)
	start := time.tick_now()
	mix(m, out)
	spent := time.tick_diff(start, time.tick_now())
	ns := u32(clamp(i64(spent), 0, i64(max(u32))))
	sync.atomic_store(&m.stats.cb_last_ns, ns)
	for {
		old := sync.atomic_load(&m.stats.cb_max_ns)
		if ns <= old {break}
		if _, swapped := sync.atomic_compare_exchange_strong(&m.stats.cb_max_ns, old, ns);
		   swapped {break}
	}
	sync.atomic_add(&m.stats.callbacks, 1)
	// The device's clock against the system's: frames it has asked for, and the
	// time they took to be asked for.
	if d.first == {} {d.first = start}
	d.frames += u64(frames)
	wall := time.duration_seconds(time.tick_diff(d.first, start))
	if d.mark == 0 && wall > DRIFT_AFTER {
		// The span measured begins here: the card asks for its whole buffer at
		// once when it starts, which says nothing of its clock.
		d.mark, d.mark_at = wall, d.frames - u64(frames)
	}
	if d.mark != 0 && wall - d.mark > DRIFT_AFTER {
		// (frames asked before this call have been played by `start`, give or
		// take the buffer, which is the same at both ends of the span)
		played := f64(d.frames - u64(frames) - d.mark_at) / f64(m.rate)
		store_f32(&m.stats.drift_ppm, f32((played - (wall - d.mark)) / (wall - d.mark) * 1e6))
	}
}

@(private)
Callback :: struct {
	mixer:  ^Mixer,
	device: ^Device,
}
