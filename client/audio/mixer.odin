package audio

import "base:intrinsics"
import "core:fmt"
import "core:math"
import "core:sync"

// The mixer: plays sounds on voices, through buses, into interleaved
// stereo f32. It knows nothing of devices (device.odin feeds it to the
// sound card; tests call mix directly).
//
// Threads: the game thread registers sounds (before the device starts) and
// queues commands (play, stop, fade, set a bus); the audio thread runs mix,
// which takes the queued commands first, and answers on a second ring
// (voices that ended) which the game thread reads with poll / drain. Both
// rings have one producer and one consumer and never block: when the command
// ring is full a command is dropped (and counted), as one that late would be
// wrong anyway.
//
// Voices are handles (docs/plan.md ground rule 2). The game thread hands them out
// from its own table (MAX_VOICES slots, a generation each) and a slot is free
// again when its end has been read from the return ring, so a handle the game
// holds is never reused under it, and a stale one does nothing. There are
// MAX_VOICES voices and the REAL_VOICES that matter most (priority, then
// audibility) are mixed each block; the rest are virtual: they keep their
// place in time (position, fades, loop) and cost nothing, and resume when
// they become audible again.
//
// The mix is deterministic: no clock and no random source on the audio
// thread (the game draws randomness before it sends a command).

MAX_VOICES :: 128
REAL_VOICES :: 64
MAX_SOUNDS :: 256
MAX_BLOCK :: 512 // frames mixed at a time; parameters move once per block
COMMAND_RING :: 512 // power of two
EVENT_RING :: 256 // power of two
MAX_DUCKS :: 4
SOUND_NAME_LEN :: 24
MAX_HELD :: 128 // commands waiting for their frame

Sound_Id :: distinct u16

// Voice_Id: a handle to a playing voice, 0 for none (a play that was
// dropped). Low 8 bits the slot, the rest its generation.
Voice_Id :: distinct u32

// Sound: samples (-1..1) at their own rate; owned by whoever registered them,
// unchanged while the mixer may play them. `right` (nil: mono) is the right
// channel of a stereo sound (music), as long as `samples`, the left; a stereo
// voice is never panned: its gain is the left's and the right's own.
Sound :: struct {
	samples: []f32,
	rate:    u32,
	right:   []f32,
}

// Play: one sound. gain: left and right (spatial position and loudness, see
// spatial_gain); pitch: playback speed (1 = as made, 0 = 1).
Play :: struct {
	sound:       Sound_Id,
	gain:        [2]f32,
	pitch:       f32,
	bus:         Bus, // World unless said
	priority:    u8, // higher is kept over lower when voices run out
	loop:        bool, // plays until stopped
	loop_start:  int, // samples; the loop is [loop_start, loop_end)
	loop_end:    int, // 0: the sound's end
	fade_in:     f32, // seconds
	cutoff:      f32, // Hz of a low-pass on this voice, 0 for none
	start_frame: u64, // the mixer frame (see `clock`) the sound starts on; 0 or past: at once
}

End_Reason :: enum u8 {
	Ended, // played to its end
	Stopped, // stopped (and faded out) on request
}

// Voice_Event: what the audio thread tells the game.
Voice_Event :: struct {
	voice:  Voice_Id,
	reason: End_Reason,
}

Mixer :: struct {
	rate:       u32, // output frames per second
	sounds:     [MAX_SOUNDS]Sound,
	streams:    [MAX_SOUNDS]^Stream, // of a sound registered with add_stream (which has no samples)
	names:      [MAX_SOUNDS][SOUND_NAME_LEN]u8, // for captures and the dump (set_sound_name)
	bandwidth:  [MAX_SOUNDS]f32, // Hz of the highest content of a sound, 0 if unknown (see set_bandwidth)
	count:      int,
	// Game thread only: the handle table.
	handles:    [MAX_VOICES]Handle_Slot,
	// Audio thread only:
	voices:     [MAX_VOICES]Voice,
	buses:      [Bus]Bus_State,
	ducks:      [MAX_DUCKS]Duck,
	bus_buf:    [Bus][2 * MAX_BLOCK]f32,
	limiter:    Limiter,
	meter:      Meter,
	sinc:       Sinc_Table,
	reverb:     Reverb,
	rev_in:     [2 * MAX_BLOCK]f32, // what the buses send to the reverb, this block
	night:      Compressor, // the compressor on Master (Night mode)
	listener:   Listener,
	cross:      [2]f32, // headphone cross-feed filter state
	clock:      u64, // frames mixed; the audio thread's time, which scheduled plays use
	order:      [MAX_VOICES]u8, // scratch: voices by rank
	// The command ring: written by the game thread, read by the audio thread.
	commands:   [COMMAND_RING]Queued,
	written:    u32, // (atomic) commands written ever
	read:       u32, // (atomic) commands read ever
	dropped:    u32, // (atomic) commands that found the ring full (or no free handle), plays of a busy stream
	// Audio thread only: commands taken off the ring that wait for their frame.
	held:       [MAX_HELD]Queued,
	held_n:     int,
	capture:    ^Capture, // (atomic) the recorder, when on
	monitor:    ^Monitor, // (atomic) audio that takes the place of the output, when set (inspect.odin)
	probe:      proc "contextless" (m: ^Mixer, user: rawptr, n: int), // offline analysis: called after each block (analyze.odin); nil in the game
	probe_user: rawptr,
	stage:      [STREAM_STAGE]f32, // a stream voice's window of its ring, this block
	stage_r:    [STREAM_STAGE]f32, // ... the right channel of a two-channel stream
	// The return ring: the other way round.
	events:     [EVENT_RING]Voice_Event,
	ev_write:   u32, // (atomic)
	ev_read:    u32, // (atomic)
	stats:      Stats, // (atomic fields) written by the audio thread
}

// Queued: a command and the mixer frame it takes effect on (0: the next block
// there is; one already past is late: it takes effect at once and is counted).
@(private)
Queued :: struct {
	frame: u64,
	cmd:   Command,
}

@(private)
Handle_Slot :: struct {
	gen:  u32,
	busy: bool,
}

// Stats: what the mixer has done, for the debug overlay and the log. Plain
// reads are fine from any thread through stats().
Stats :: struct {
	voices:      u32, // playing after the last mix (real and virtual)
	real:        u32, // of them mixed
	played:      u32, // sounds started, ever
	virtualized: u32, // voice-blocks spent virtual, ever
	nan_guarded: u32, // samples zeroed because they were not finite, ever
	late:        u32, // scheduled sounds and commands that came late (their frame had passed), ever
	underruns:   u32, // blocks in which a stream voice found its ring empty, ever
	callbacks:   u32, // device callbacks, ever (device.odin)
	cb_last_ns:  u32, // the last callback's duration, its own mixing included
	cb_max_ns:   u32, // the longest since the last read of stats
	drift_ppm:   f32, // device clock against the system's, parts per million (f32 bits)
	frames:      u64, // frames mixed, ever
	momentary:   f32, // LUFS of the last 400 ms (f32 bits)
	reduction:   f32, // the limiter's lowest gain since the last read
	bus_peak:    [Bus]f32, // peak of each bus in the last mix
}

// stats_drift_ppm: the device clock's drift alone (stats resets the callback's
// worst case, which a second reader would take from the first).
stats_drift_ppm :: proc(m: ^Mixer) -> f32 {
	return load_f32(&m.stats.drift_ppm)
}

// stats reads the mixer's statistics from any thread.
stats :: proc(m: ^Mixer) -> Stats {
	s := Stats {
		voices      = sync.atomic_load(&m.stats.voices),
		real        = sync.atomic_load(&m.stats.real),
		played      = sync.atomic_load(&m.stats.played),
		virtualized = sync.atomic_load(&m.stats.virtualized),
		nan_guarded = sync.atomic_load(&m.stats.nan_guarded),
		late        = sync.atomic_load(&m.stats.late),
		underruns   = sync.atomic_load(&m.stats.underruns),
		callbacks   = sync.atomic_load(&m.stats.callbacks),
		cb_last_ns  = sync.atomic_load(&m.stats.cb_last_ns),
		cb_max_ns   = sync.atomic_exchange(&m.stats.cb_max_ns, 0),
		drift_ppm   = load_f32(&m.stats.drift_ppm),
		frames      = sync.atomic_load(&m.stats.frames),
		momentary   = load_f32(&m.stats.momentary),
		reduction   = load_f32(&m.stats.reduction),
	}
	for b in Bus {s.bus_peak[b] = load_f32(&m.stats.bus_peak[b])}
	return s
}

@(private)
load_f32 :: proc(p: ^f32) -> f32 {
	return transmute(f32)sync.atomic_load((^u32)(p))
}

@(private)
store_f32 :: proc "contextless" (p: ^f32, v: f32) {
	sync.atomic_store((^u32)(p), transmute(u32)v)
}

Voice_State :: enum u8 {
	Free,
	Playing,
	Done, // ended; waiting for room on the return ring
}

@(private)
Voice :: struct {
	id:         Voice_Id,
	state:      Voice_State,
	reason:     End_Reason, // when Done
	virtual:    bool,
	start_at:   u64, // first frame of the sound (0: already started)
	sound:      Sound_Id,
	bus:        Bus,
	priority:   u8,
	loop:       bool,
	loop_start: f64, // samples
	loop_end:   f64,
	pos:        f64, // in the sound's samples
	step:       f64, // sound samples per output frame, now
	step_to:    f64, // ... and wanted
	gain:       [2]f32, // wanted
	gain_now:   [2]f32,
	fade:       f32, // multiplier now
	fade_to:    f32,
	fade_step:  f32, // per frame, signed; 0 when not fading
	stop_fade:  bool, // stop when the fade reaches zero
	cutoff:     f32, // Hz wanted (open = rate / 2.2)
	cutoff_now: f32,
	filter:     Svf,
	filter_r:   Svf, // the right channel's, of a stereo sound
	key:        f32, // scratch: audibility
}

Command :: union {
	Play_Cmd,
	Voice_Param,
	Stop_Cmd,
	Fade_Cmd,
	Bus_Cmd,
	Duck_Cmd,
	Snapshot_Cmd,
	Reverb_Cmd,
	Listener_Cmd,
}

@(private)
Reverb_Cmd :: struct {
	rt60, damping, wet, early: f32,
}

@(private)
Listener_Cmd :: struct {
	options: Listener,
}

// Listener: what the player chose about how they hear (Options). Applied to
// Master before the limiter, so the ceiling holds for all of it.
Listener :: struct {
	mono:       bool, // both ears the same
	swap:       bool, // left and right exchanged
	crossfeed:  f32, // 0..0.6: headphone cross-feed, the other ear's lows
	night:      bool, // the compressor: loud things down, so nothing wakes the house
	ceiling_db: f32, // hearing-safety ceiling, dBFS, 0 for the default (-1); at most -0.1
}

@(private)
Play_Cmd :: struct {
	id:   Voice_Id,
	play: Play,
}

// Voice_Param: one parameter of a voice, smoothed by the mixer.
@(private)
Voice_Param :: struct {
	id:    Voice_Id,
	which: enum u8 {
		Gain,
		Pitch,
		Cutoff,
	},
	value: [2]f32,
}

@(private)
Stop_Cmd :: struct {
	id:     Voice_Id,
	frames: u32,
}

@(private)
Fade_Cmd :: struct {
	id:     Voice_Id,
	to:     f32,
	frames: u32,
}

mixer_init :: proc(m: ^Mixer, rate: u32) {
	// Zeroed in place: the mixer is most of a megabyte, and `m^ = {...}` may
	// build it on the stack first (a Windows thread has 1 MB).
	intrinsics.mem_zero(m, size_of(Mixer))
	m.rate = rate
	for &b in m.buses {bus_defaults(&b, f32(rate))}
	limiter_init(&m.limiter, f64(rate), 0.002, -1, 0.15)
	sinc_table_init(&m.sinc)
	reverb_init(&m.reverb, f64(rate))
	compressor_init(&m.night, f64(rate), 0, 1, 0, 0, 0.005, 0.15)
	meter_init(&m.meter, f64(rate))
	store_f32(&m.stats.momentary, -math.INF_F32)
	store_f32(&m.stats.reduction, 1)
}

// add_sound registers a sound (before the device starts); its id plays it.
add_sound :: proc(m: ^Mixer, s: Sound) -> Sound_Id {
	assert(m.count < MAX_SOUNDS && s.rate > 0)
	assert(s.right == nil || len(s.right) == len(s.samples))
	m.sounds[m.count] = s
	m.count += 1
	return Sound_Id(m.count - 1)
}

// set_sound_name gives a sound a name for captures and the dump (cut to
// SOUND_NAME_LEN bytes).
set_sound_name :: proc(m: ^Mixer, id: Sound_Id, name: string) {
	n := copy(m.names[id][:], name)
	for i in n ..< SOUND_NAME_LEN {m.names[id][i] = 0}
}

// sound_name: what set_sound_name gave, or "sound N".
sound_name :: proc(name: ^[SOUND_NAME_LEN]u8, id: int, buf: []u8) -> string {
	n := 0
	for n < SOUND_NAME_LEN && name[n] != 0 {n += 1}
	if n == 0 {return fmt.bprintf(buf, "sound %d", id)}
	return string(name[:n])
}

// set_bandwidth declares that a sound has nothing above `hz` (a sound made at
// 16 kHz and converted up has nothing above 8000). Playing it pitched up then
// needs no anti-aliasing stretch of the resampler's kernel as long as the
// content stays under the new Nyquist, which makes pitched voices several
// times cheaper (the unstretched kernel is read by phase, in 8 lanes). A sound
// without a declared bandwidth is taken to fill the band.
set_bandwidth :: proc(m: ^Mixer, id: Sound_Id, hz: f32) {
	m.bandwidth[id] = hz
}

// latency: frames between a command taking effect and its sound leaving the
// mixer (the limiter's look-ahead), besides the device's own buffer.
latency :: proc(m: ^Mixer) -> int {
	return limiter_delay(&m.limiter)
}

// play queues a sound to start at the next mix and returns its handle; 0 when
// dropped (the command ring or all MAX_VOICES handles are in use).
play :: proc(m: ^Mixer, p: Play) -> Voice_Id {
	assert(int(p.sound) < m.count)
	id := alloc_handle(m)
	if id == 0 {
		sync.atomic_add(&m.dropped, 1)
		return 0
	}
	if !push(m, Play_Cmd{id, p}) {
		free_handle(m, id)
		return 0
	}
	return id
}

// stop fades a voice out over `fade` seconds (0: at once) and ends it.
stop :: proc(m: ^Mixer, id: Voice_Id, fade: f32 = 0, at: u64 = 0) {
	if id != 0 {push(m, Stop_Cmd{id, seconds(m, fade)}, at)}
}

// fade_voice moves a voice's fade gain to `to` (0..1) over `seconds`.
fade_voice :: proc(m: ^Mixer, id: Voice_Id, to: f32, over: f32, at: u64 = 0) {
	if id != 0 {push(m, Fade_Cmd{id, clamp(to, 0, 4), seconds(m, over)}, at)}
}

set_voice_gain :: proc(m: ^Mixer, id: Voice_Id, gain: [2]f32, at: u64 = 0) {
	if id != 0 {push(m, Voice_Param{id, .Gain, gain}, at)}
}

set_voice_pitch :: proc(m: ^Mixer, id: Voice_Id, pitch: f32, at: u64 = 0) {
	if id != 0 && pitch > 0 {push(m, Voice_Param{id, .Pitch, {pitch, 0}}, at)}
}

// set_voice_cutoff: Hz of the voice's low-pass; 0 opens it.
set_voice_cutoff :: proc(m: ^Mixer, id: Voice_Id, hz: f32, at: u64 = 0) {
	if id != 0 {push(m, Voice_Param{id, .Cutoff, {hz, 0}}, at)}
}

// set_reverb: the room (see reverb_set); buses send to it with set_bus_reverb.
set_reverb :: proc(m: ^Mixer, rt60, damping, wet, early: f32, at: u64 = 0) {
	push(m, Reverb_Cmd{rt60, damping, wet, early}, at)
}

// set_listener sets the listener's options.
set_listener :: proc(m: ^Mixer, o: Listener, at: u64 = 0) {
	push(m, Listener_Cmd{o}, at)
}

// clock: the mixer's time in frames, as of the last mix (game thread). A sound
// scheduled with Play.start_frame = clock(m) + k + latency-sized slack starts
// on exactly that frame; its sound leaves the mixer `latency(m)` frames later.
// Every other command takes the same `at` (default 0: the next block): the
// mixer holds it until that frame and cuts the block there, so it lands on
// the frame exactly; one that arrives after its frame is applied at once and
// counted in Stats.late.
clock :: proc(m: ^Mixer) -> u64 {
	return sync.atomic_load(&m.stats.frames)
}

// set_volume sets the master volume (0..1) from the next mix on.
set_volume :: proc(m: ^Mixer, volume: f32) {
	set_bus_gain(m, .Master, volume)
}

// poll takes the next end the audio thread reported (a voice ended or was
// stopped), freeing its handle. Game thread.
poll :: proc(m: ^Mixer) -> (e: Voice_Event, ok: bool) {
	r := sync.atomic_load_explicit(&m.ev_read, .Relaxed)
	w := sync.atomic_load_explicit(&m.ev_write, .Acquire)
	if r == w {return {}, false}
	e = m.events[r & (EVENT_RING - 1)]
	sync.atomic_store_explicit(&m.ev_read, r + 1, .Release)
	free_handle(m, e.voice)
	return e, true
}

// drain reads every end reported so far; call it every frame, or handles
// are only freed when play runs out of them.
drain :: proc(m: ^Mixer) {
	for {
		_ = poll(m) or_break
	}
}

// alive: whether the game still holds this handle (no end read for it yet).
alive :: proc(m: ^Mixer, id: Voice_Id) -> bool {
	slot := int(id & 0xff)
	return(
		id != 0 &&
		slot < MAX_VOICES &&
		m.handles[slot].busy &&
		m.handles[slot].gen == u32(id >> 8) \
	)
}

@(private)
seconds :: proc(m: ^Mixer, s: f32) -> u32 {
	return u32(max(s, 0) * f32(m.rate))
}

@(private)
alloc_handle :: proc(m: ^Mixer) -> Voice_Id {
	for attempt in 0 ..< 2 {
		for &h, i in m.handles {
			if h.busy {continue}
			h.busy = true
			h.gen = h.gen + 1 & 0xffffff
			if h.gen == 0 {h.gen = 1}
			return Voice_Id(h.gen << 8 | u32(i))
		}
		if attempt == 0 {drain(m)}
	}
	return 0
}

@(private)
free_handle :: proc(m: ^Mixer, id: Voice_Id) {
	slot := int(id & 0xff)
	if slot < MAX_VOICES && m.handles[slot].gen == u32(id >> 8) {m.handles[slot].busy = false}
}

@(private)
push :: proc(m: ^Mixer, c: Command, at: u64 = 0) -> bool {
	w := sync.atomic_load_explicit(&m.written, .Relaxed)
	r := sync.atomic_load_explicit(&m.read, .Acquire)
	if w - r == COMMAND_RING {
		sync.atomic_add(&m.dropped, 1)
		return false
	}
	m.commands[w & (COMMAND_RING - 1)] = {at, c}
	sync.atomic_store_explicit(&m.written, w + 1, .Release)
	return true
}

// mix fills out (interleaved stereo, len = 2 * frames) with the next
// frames. Audio thread; no allocation, no locks.
mix :: proc "contextless" (m: ^Mixer, out: []f32) {
	frames := len(out) / 2
	if rec := sync.atomic_load(&m.capture); rec != nil && frames > 0 {
		capture_call(m, rec, frames)
	}
	guarded: u32
	for done := 0; done < frames; {
		take_commands(m)
		n := min(MAX_BLOCK, frames - done)
		if due := next_held(m); due > m.clock {n = min(n, int(due - m.clock))}
		guarded += mix_block(m, out[2 * done:][:2 * n], n)
		m.clock += u64(n)
		done += n
	}
	if mon := sync.atomic_load(&m.monitor); mon != nil {monitor_fill(mon, out)}
	report_ends(m)
	real, total: u32
	for v in m.voices {
		if v.state == .Playing {
			total += 1
			if !v.virtual {real += 1}
		}
	}
	sync.atomic_store(&m.stats.voices, total)
	sync.atomic_store(&m.stats.real, real)
	sync.atomic_add(&m.stats.nan_guarded, guarded)
	sync.atomic_add(&m.stats.frames, u64(frames))
	store_f32(&m.stats.momentary, m.meter.momentary)
	store_f32(&m.stats.reduction, m.limiter.lowest)
	m.limiter.lowest = 1
	for b in Bus {store_f32(&m.stats.bus_peak[b], m.buses[b].peak)}
}

// mix_block: one block of at most MAX_BLOCK frames. Returns the samples the
// not-finite guard zeroed.
@(private)
mix_block :: proc "contextless" (m: ^Mixer, out: []f32, n: int) -> (guarded: u32) {
	for &buf in m.bus_buf {
		for i in 0 ..< 2 * n {buf[i] = 0}
	}
	for i in 0 ..< 2 * n {m.rev_in[i] = 0}
	for st in m.streams[:m.count] {
		if st != nil && st.inline {
			for stream_pump(st) {}
		}
	}
	rank_voices(m, n)
	for &v in m.voices {
		if v.state != .Playing || v.start_at >= m.clock + u64(n) {continue}
		off := 0
		if v.start_at > m.clock {off = int(v.start_at - m.clock)}
		v.start_at = 0
		if v.virtual {
			skip_voice(m, &v, n - off)
		} else {
			guarded += render_voice(m, &v, m.bus_buf[v.bus][:2 * n], n, off)
		}
	}
	for b in Bus {
		if b == .Master {run_reverb(m, n)}
		process_bus(m, b, n)
	}
	master := m.bus_buf[.Master][:2 * n]
	apply_listener(m, master)
	limiter_run(&m.limiter, master)
	for i in 0 ..< 2 * n {
		x := master[i]
		if x != x || abs(x) > 1 {
			// Not finite (or past full scale, which the limiter rules out): silence.
			x = 0
			guarded += 1
		}
		out[i] = x
	}
	meter_push(&m.meter, out)
	if m.probe != nil {m.probe(m, m.probe_user, n)}
	for &v in m.voices {
		if v.state == .Playing {
			svf_flush(&v.filter)
			svf_flush(&v.filter_r)
		}
	}
	return
}

// run_reverb adds the reverb's return to Master while there is input or a
// tail left to hear.
@(private)
run_reverb :: proc "contextless" (m: ^Mixer, n: int) {
	r := &m.reverb
	sending := false
	for b in m.buses {if b.send > 0 || b.send_now > 0 {sending = true}}
	if !sending && r.tail < 1e-7 {
		if r.tail != 0 {reverb_clear(r)}
		return
	}
	reverb_run(r, m.rev_in[:2 * n], m.bus_buf[.Master][:2 * n])
}

// apply_listener: the listener's options on the finished mix, before the
// limiter.
@(private)
apply_listener :: proc "contextless" (m: ^Mixer, buf: []f32) {
	o := &m.listener
	if compressor_active(&m.night) {compressor_run(&m.night, buf)}
	frames := len(buf) / 2
	if o.mono {
		for f in 0 ..< frames {
			x := (buf[2 * f] + buf[2 * f + 1]) * 0.5
			buf[2 * f], buf[2 * f + 1] = x, x
		}
	}
	if o.swap {
		for f in 0 ..< frames {buf[2 * f], buf[2 * f + 1] = buf[2 * f + 1], buf[2 * f]}
	}
	if o.crossfeed > 0 {
		// The other ear gets the lows (700 Hz one-pole), the sum scaled back so
		// a centered signal keeps its level.
		k := f32(1 - math.exp(-2 * math.PI * 700 / f64(m.rate)))
		scale := 1 / (1 + o.crossfeed)
		for f in 0 ..< frames {
			l, r := buf[2 * f], buf[2 * f + 1]
			m.cross[0] += (l - m.cross[0]) * k
			m.cross[1] += (r - m.cross[1]) * k
			buf[2 * f] = (l + o.crossfeed * m.cross[1]) * scale
			buf[2 * f + 1] = (r + o.crossfeed * m.cross[0]) * scale
		}
		for i in 0 ..< 2 {if abs(m.cross[i]) < 1e-25 {m.cross[i] = 0}}
	}
}

// rank_voices decides which voices are real this block: by priority, then by
// audibility; REAL_VOICES of them, and none that cannot be heard.
@(private)
rank_voices :: proc "contextless" (m: ^Mixer, n: int) {
	count := 0
	for &v, i in m.voices {
		if v.state != .Playing {continue}
		if v.start_at >= m.clock + u64(n) {
			v.virtual = false // waiting, not mixed and not counted as virtual
			continue
		}
		chain := bus_level(m, v.bus)
		v.key =
			(max(v.gain[0], v.gain_now[0]) + max(v.gain[1], v.gain_now[1])) *
			max(v.fade, v.fade_to) *
			chain
		v.virtual = true
		if v.key <= 0 {continue}
		// Insertion sort, best first; the list is short.
		j := count
		for j > 0 && better(&m.voices[m.order[j - 1]], &v) == false {
			m.order[j] = m.order[j - 1]
			j -= 1
		}
		m.order[j] = u8(i)
		count += 1
	}
	for k in 0 ..< min(count, REAL_VOICES) {m.voices[m.order[k]].virtual = false}
}

// better: whether voice a is kept over voice b.
@(private)
better :: proc "contextless" (a, b: ^Voice) -> bool {
	if a.priority != b.priority {return a.priority > b.priority}
	return a.key >= b.key
}

// bus_level: the gain of a bus and every bus it feeds, as of now.
@(private)
bus_level :: proc "contextless" (m: ^Mixer, b: Bus) -> f32 {
	level: f32 = 1
	for at := b;; at = BUS_PARENT[at] {
		s := &m.buses[at]
		level *= s.gain_now * s.snap_now * s.duck_now
		if at == .Master {break}
	}
	return level
}

// cubic: Catmull-Rom between samples i and i+1, t in [0, 1).
@(private)
cubic :: #force_inline proc "contextless" (p0, p1, p2, p3, t: f32) -> f32 {
	return(
		p1 +
		0.5 * t * (p2 - p0 + t * (2 * p0 - 5 * p1 + 4 * p2 - p3 + t * (3 * (p1 - p2) + p3 - p0))) \
	)
}

// render_voice adds one voice into buf (interleaved stereo) for n frames.
@(private)
render_voice :: proc "contextless" (
	m: ^Mixer,
	v: ^Voice,
	buf: []f32,
	n: int,
	off: int,
) -> (
	guarded: u32,
) {
	s := m.sounds[v.sound].samples
	sr := m.sounds[v.sound].right
	last := len(s) - 1
	looping := v.loop
	// A stream voice reads a window of its ring copied into the stage: s is
	// the stage, `base` the stream sample it starts at, and the stream's end
	// and the samples written so far limit the voice (see stream.odin).
	st := m.streams[v.sound]
	base: f64
	avail := math.INF_F64
	if st != nil {
		avail, last, base = stream_window(m, st, v, n)
		s = m.stage[:]
		sr = m.stage_r[:] if st.channels == 2 else nil
		looping = false
		v.step = min(v.step, SINC_MAX_STEP)
		v.step_to = min(v.step_to, SINC_MAX_STEP)
	}
	slast := len(s) - 1
	underrun := false
	loop_len := v.loop_end - v.loop_start
	// Parameters move once per block: gain and step linearly across it, the
	// cutoff in the log domain.
	g0 := v.gain_now
	g1 := v.gain
	step0 := v.step
	step1 := v.step_to
	span := n - off
	dg := (g1 - g0) / f32(span)
	dstep := (step1 - step0) / f64(span)
	// Cubic only where it is as good as a sinc: the mixer's own rate and a
	// pitch within a semitone; everything else gets the windowed sinc.
	rate_ratio := f64(m.sounds[v.sound].rate) / f64(m.rate)
	cheap := rate_ratio == 1 && abs(math.ln(step0)) < 0.0578 && abs(math.ln(step1)) < 0.0578
	filtering := false
	if v.cutoff != v.cutoff_now {
		v.cutoff_now = glide(v.cutoff_now, v.cutoff, n, f32(m.rate))
	}
	if v.cutoff_now < f32(m.rate) / 2.4 {
		svf_set(&v.filter, f64(v.cutoff_now), 0.7071, f64(m.rate))
		if sr != nil {svf_set(&v.filter_r, f64(v.cutoff_now), 0.7071, f64(m.rate))}
		filtering = true
	}
	// The voice's own state in locals for the loop (the compiler cannot keep
	// fields of v in registers across writes to buf).
	pos := v.pos
	gl, gr := g0[0], g0[1]
	fade, fade_step := v.fade, v.fade_step
	loop_start, loop_end := int(v.loop_start), int(v.loop_end)
	// The unstretched kernel serves a pitch-up too when the sound's content
	// stays under the new Nyquist (set_bandwidth), with a margin.
	reach := f64(m.bandwidth[v.sound]) * max(step0, step1)
	fast_sinc :=
		(step0 <= 1 && step1 <= 1) || (reach > 0 && reach <= 0.4 * f64(m.sounds[v.sound].rate))
	#no_bounds_check for f in off ..< n {
		if !looping && pos >= f64(last) {
			end_voice(v, .Ended)
			break
		}
		k := f - off
		step := step0 + dstep * f64(k)
		if st != nil && pos + SINC_HALF * clamp(step, 1, SINC_MAX_STEP) + 2 > avail {
			underrun = true // the decoder is behind: hold the place, say nothing
			break
		}
		rel := pos - base
		i := int(rel)
		x := voice_read(
			m,
			v,
			s,
			rel,
			i,
			step,
			cheap,
			fast_sinc,
			looping,
			loop_start,
			loop_end,
			slast,
			last,
		)
		xr: f32
		if sr != nil {
			xr = voice_read(
				m,
				v,
				sr,
				rel,
				i,
				step,
				cheap,
				fast_sinc,
				looping,
				loop_start,
				loop_end,
				slast,
				last,
			)
			if !(abs(xr) <= 1e6) {
				xr = 0
				guarded += 1
			}
		}
		if !(abs(x) <= 1e6) { 	// (also true for NaN)
			x = 0
			guarded += 1
		}
		if filtering {
			x = svf_lowpass(&v.filter, x)
			if sr != nil {xr = svf_lowpass(&v.filter_r, xr)}
		}
		if fade_step != 0 {
			fade += fade_step
			if (fade_step > 0 && fade >= v.fade_to) || (fade_step < 0 && fade <= v.fade_to) {
				fade = v.fade_to
				fade_step = 0
				if v.stop_fade {
					end_voice(v, .Stopped)
					break
				}
			}
		}
		x *= fade
		if sr != nil {
			buf[2 * f] += x * gl
			buf[2 * f + 1] += xr * fade * gr
		} else {
			buf[2 * f] += x * gl
			buf[2 * f + 1] += x * gr
		}
		gl += dg[0]
		gr += dg[1]
		pos += step
		if looping && pos >= v.loop_end {
			for pos >= v.loop_end {pos -= loop_len}
		}
	}
	v.pos, v.fade, v.fade_step = pos, fade, fade_step
	v.gain_now = g1
	v.step = step1
	if st != nil {
		stream_consume(st, v.pos)
		if underrun {
			sync.atomic_add(&st.underruns, 1)
			sync.atomic_add(&m.stats.underruns, 1)
		}
	}
	return
}

// voice_read: one channel of a voice at `rel` (its position less the
// stage's base): the cubic where it is as good as the sinc, else the sinc.
@(private)
voice_read :: #force_inline proc "contextless" (
	m: ^Mixer,
	v: ^Voice,
	s: []f32,
	rel: f64,
	i: int,
	step: f64,
	cheap, fast_sinc, looping: bool,
	loop_start, loop_end, slast, last: int,
) -> (
	x: f32,
) {
	if !cheap {
		if fast_sinc &&
		   i >= SINC_HALF - 1 &&
		   i + SINC_HALF <= (loop_end - 1 if looping else slast) {
			x = sinc_fast(&m.sinc, s, rel)
		} else {
			x = sinc_read(&m.sinc, s, rel, step, loop_start, loop_end, looping)
		}
	} else if looping && (i < 1 || i + 2 >= loop_end) {
		x = cubic(
			s[wrap(i - 1, last, v)],
			s[wrap(i, last, v)],
			s[wrap(i + 1, last, v)],
			s[wrap(i + 2, last, v)],
			f32(rel - f64(i)),
		)
	} else if looping {
		x = cubic(s[i - 1], s[i], s[i + 1], s[i + 2], f32(rel - f64(i)))
	} else {
		x = cubic(s[max(i - 1, 0)], s[i], s[i + 1], s[min(i + 2, slast)], f32(rel - f64(i)))
	}
	return
}

// wrap: a sample index for the cubic's taps inside a loop.
@(private)
wrap :: #force_inline proc "contextless" (i, last: int, v: ^Voice) -> int {
	j := i
	end := int(v.loop_end)
	if j >= end {j -= end - int(v.loop_start)}
	if j < 0 {j += end - int(v.loop_start)}
	return clamp(j, 0, last)
}

// glide moves a frequency toward its target in the log domain (tau seconds,
// 5 ms unless said), exactly there once close.
@(private)
glide :: proc "contextless" (now, target: f32, frames: int, rate: f32, tau: f32 = 0.005) -> f32 {
	k := 1 - math.exp(-f32(frames) / (tau * rate))
	next := math.exp(math.ln(now) + (math.ln(target) - math.ln(now)) * k)
	if abs(math.ln(next) - math.ln(target)) < 0.002 {return target}
	return next
}

// skip_voice: a virtual voice lives on without being mixed.
@(private)
skip_voice :: proc "contextless" (m: ^Mixer, v: ^Voice, n: int) {
	sync.atomic_add(&m.stats.virtualized, 1)
	v.gain_now = v.gain
	v.step = v.step_to
	v.cutoff_now = v.cutoff
	if v.fade_step != 0 {
		v.fade += v.fade_step * f32(n)
		if (v.fade_step > 0 && v.fade >= v.fade_to) || (v.fade_step < 0 && v.fade <= v.fade_to) {
			v.fade = v.fade_to
			v.fade_step = 0
			if v.stop_fade {
				end_voice(v, .Stopped)
				return
			}
		}
	}
	v.pos += v.step * f64(n)
	if st := m.streams[v.sound]; st != nil {
		// A virtual stream voice keeps its place in time and lets the ring move on.
		v.step = min(v.step, SINC_MAX_STEP)
		stream_consume(st, v.pos)
		if sync.atomic_load(&st.finished) && v.pos >= f64(sync.atomic_load(&st.total) - 1) {
			end_voice(v, .Ended)
		}
		return
	}
	if v.loop {
		for v.pos >= v.loop_end {v.pos -= v.loop_end - v.loop_start}
	} else if v.pos >= f64(len(m.sounds[v.sound].samples) - 1) {
		end_voice(v, .Ended)
	}
}

@(private)
end_voice :: proc "contextless" (v: ^Voice, reason: End_Reason) {
	v.state = .Done
	v.reason = reason
}

// report_ends tells the game of voices that ended; one that finds the ring
// full stays Done and is reported next mix.
@(private)
report_ends :: proc "contextless" (m: ^Mixer) {
	for &v in m.voices {
		if v.state != .Done {continue}
		if st := m.streams[v.sound]; st != nil {stream_release(st, v.id)}
		w := sync.atomic_load_explicit(&m.ev_write, .Relaxed)
		r := sync.atomic_load_explicit(&m.ev_read, .Acquire)
		if w - r == EVENT_RING {return}
		m.events[w & (EVENT_RING - 1)] = {v.id, v.reason}
		sync.atomic_store_explicit(&m.ev_write, w + 1, .Release)
		v = {}
	}
}

@(private)
find_voice :: proc "contextless" (m: ^Mixer, id: Voice_Id) -> ^Voice {
	slot := int(id & 0xff)
	if slot >= MAX_VOICES {return nil}
	v := &m.voices[slot]
	if v.id != id || v.state != .Playing {return nil}
	return v
}

// take_commands moves what the game queued into `held` and applies, in the
// order they came, every command whose frame has come. The rest wait; the
// mix cuts its block at the next of them (next_held).
@(private)
take_commands :: proc "contextless" (m: ^Mixer) {
	r := sync.atomic_load_explicit(&m.read, .Relaxed)
	w := sync.atomic_load_explicit(&m.written, .Acquire)
	rec := sync.atomic_load(&m.capture)
	for {
		for r != w && m.held_n < MAX_HELD {
			q := m.commands[r & (COMMAND_RING - 1)]
			if q.frame != 0 && q.frame < m.clock {sync.atomic_add(&m.stats.late, 1)}
			m.held[m.held_n] = q
			m.held_n += 1
			r += 1
		}
		kept := 0
		for i in 0 ..< m.held_n {
			q := m.held[i]
			if q.frame > m.clock {
				m.held[kept] = q
				kept += 1
				continue
			}
			if rec != nil {capture_command(rec, m.clock, q.cmd)}
			apply_command(m, q.cmd)
		}
		applied := m.held_n - kept
		m.held_n = kept
		// Room again (a full table of waiting commands): take more of the ring.
		if r == w || applied == 0 {break}
	}
	sync.atomic_store_explicit(&m.read, r, .Release)
}

// next_held: the frame of the soonest command still waiting, 0 if none.
@(private)
next_held :: proc "contextless" (m: ^Mixer) -> u64 {
	due: u64
	for i in 0 ..< m.held_n {
		if f := m.held[i].frame; due == 0 || f < due {due = f}
	}
	return due
}

// apply_command carries one command out.
@(private)
apply_command :: proc "contextless" (m: ^Mixer, cmd: Command) {
	switch c in cmd {
	case Play_Cmd:
		start(m, c)
	case Voice_Param:
		v := find_voice(m, c.id)
		if v == nil {return}
		switch c.which {
		case .Gain:
			v.gain = c.value
		case .Pitch:
			v.step_to = f64(m.sounds[v.sound].rate) / f64(m.rate) * f64(c.value.x)
		case .Cutoff:
			v.cutoff = c.value.x if c.value.x > 0 else open_cutoff(m)
		}
	case Stop_Cmd:
		v := find_voice(m, c.id)
		if v == nil {return}
		if c.frames == 0 {
			end_voice(v, .Stopped)
		} else {
			v.fade_to = 0
			v.fade_step = -v.fade / f32(c.frames)
			v.stop_fade = true
			if v.fade_step == 0 {end_voice(v, .Stopped)}
		}
	case Fade_Cmd:
		v := find_voice(m, c.id)
		if v == nil {return}
		v.stop_fade = false
		v.fade_to = c.to
		if c.frames == 0 {
			v.fade, v.fade_step = c.to, 0
		} else {
			v.fade_step = (c.to - v.fade) / f32(c.frames)
		}
	case Bus_Cmd:
		bus_command(m, c)
	case Duck_Cmd:
		m.ducks[c.index] = c.duck
		m.ducks[c.index].held = 1
	case Snapshot_Cmd:
		apply_snapshot(m, c)
	case Reverb_Cmd:
		reverb_set(&m.reverb, c.rt60, c.damping, c.wet, c.early)
	case Listener_Cmd:
		apply_options(m, c.options)
	}
}

@(private)
open_cutoff :: proc "contextless" (m: ^Mixer) -> f32 {
	return f32(m.rate) / 2.2
}

// apply_options takes a listener's options: the ceiling goes to the limiter,
// Night mode to the compressor (off lets a reduction in progress release).
@(private)
apply_options :: proc "contextless" (m: ^Mixer, o: Listener) {
	m.listener = o
	ceiling := o.ceiling_db if o.ceiling_db != 0 else -1
	limiter_set_ceiling(&m.limiter, f64(min(ceiling, -0.1)))
	if o.night {
		compressor_init(&m.night, f64(m.rate), -24, 4, 6, 3, 0.005, 0.2)
	} else {
		m.night.ratio, m.night.makeup, m.night.knee = 1, 0, 0
	}
}

// start puts a sound on its voice (the handle names the slot).
@(private)
start :: proc "contextless" (m: ^Mixer, c: Play_Cmd) {
	p := c.play
	slot := int(c.id & 0xff)
	sound := m.sounds[p.sound]
	if st := m.streams[p.sound]; st != nil {
		if st.owner != 0 {
			// A stream has one voice at a time.
			sync.atomic_add(&m.dropped, 1)
			m.voices[slot] = {
				id     = c.id,
				state  = .Done,
				reason = .Ended,
			}
			return
		}
		st.owner = c.id
	} else if len(sound.samples) < 2 {
		// Nothing to play; the game still gets its end.
		m.voices[slot] = {
			id     = c.id,
			state  = .Done,
			reason = .Ended,
		}
		return
	}
	pitch := p.pitch if p.pitch > 0 else 1
	length := len(sound.samples)
	loop := p.loop && m.streams[p.sound] == nil // a stream's loop is its decoder's
	loop_end := p.loop_end if p.loop_end > 0 else length
	loop_end = min(loop_end, length)
	loop_start := clamp(p.loop_start, 0, max(loop_end - 2, 0))
	step := f64(sound.rate) / f64(m.rate) * f64(pitch)
	open := open_cutoff(m)
	cutoff := p.cutoff if p.cutoff > 0 else open
	fade: f32 = 1
	fade_step: f32 = 0
	if p.fade_in > 0 {
		fade = 0
		fade_step = 1 / (p.fade_in * f32(m.rate))
	}
	start_at := p.start_frame
	if start_at != 0 && start_at < m.clock {
		sync.atomic_add(&m.stats.late, 1) // its frame passed; it starts at once
		start_at = 0
	}
	m.voices[slot] = {
		id         = c.id,
		start_at   = start_at,
		state      = .Playing,
		sound      = p.sound,
		bus        = p.bus,
		priority   = p.priority,
		loop       = loop,
		loop_start = f64(loop_start),
		loop_end   = f64(loop_end),
		step       = step,
		step_to    = step,
		gain       = p.gain,
		gain_now   = p.gain,
		fade       = fade,
		fade_to    = 1,
		fade_step  = fade_step,
		cutoff     = cutoff,
		cutoff_now = cutoff,
	}
	sync.atomic_add(&m.stats.played, 1)
}

// soft_clip leaves quiet signals alone and bends loud ones under 1. The
// limiter does this job now; it stays for callers that want a cheap bend.
@(private)
soft_clip :: proc "contextless" (x: f32) -> f32 {
	KNEE :: 0.8
	a := abs(x)
	if a <= KNEE {return x}
	over := a - KNEE
	return math.sign(x) * (KNEE + (1 - KNEE) * over / (over + (1 - KNEE)))
}

// spatial_gain: left and right gains for a sound at offset (from the
// listener, in blocks) heard facing `right` (unit, horizontal): quieter
// with distance (silent beyond range) and panned by direction, never
// fully to one side.
spatial_gain :: proc(offset: [3]f32, right: [3]f32, volume: f32, range: f32) -> [2]f32 {
	d := math.sqrt(offset.x * offset.x + offset.y * offset.y + offset.z * offset.z)
	if d >= range {return {}}
	near := 1 - d / range
	loud := volume * near * near
	pan: f32 = 0
	if d > 0.001 {pan = (offset.x * right.x + offset.y * right.y + offset.z * right.z) / d}
	pan *= 0.7 * min(d / 2, 1) // close by, sounds come from everywhere
	// Constant power: left² + right² stays loud².
	angle := (pan + 1) * math.PI / 4
	return {loud * math.cos(angle), loud * math.sin(angle)} * math.SQRT_TWO
}
