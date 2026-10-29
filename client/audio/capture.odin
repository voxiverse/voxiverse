package audio

import "core:hash"
import "core:log"
import "core:mem"
import "core:os"
import "core:slice"
import "core:sync"
import "core:time"

// Capture: everything the audio thread was told, so any mix can be made again.
//
// The recorder sits on the audio thread's side, in memory the game
// preallocated (capture_start), because that is where the facts are: the
// size of each `mix` call (block boundaries, and so every smoothed parameter,
// depend on it) and the frame each command was applied on. Records are
// appended without allocating or blocking; a full recorder counts what it
// could not keep (`overflow`) and stops there, it never wraps silently.
//
// Replay hands the commands back with their recorded frames and calls `mix`
// with the recorded sizes. The mixer has no clock and no random source of its
// own and streams offline are decoded inline, so the samples come out
// bit-identical on the same build (both optimization levels: tested).
//
// A capture starts when the mixer does (clock 0) with the same sounds
// registered in the same order; the file says which (a checksum of each) and
// replay refuses a different table. One begun mid-session cannot be replayed
// from nothing (the voices playing then are state the records do not hold):
// so the rolling capture (capture_start_ring) keeps, besides the last records,
// a Mixer_State taken at the start of a mix call every CAPTURE_SNAP_SECONDS,
// and a file written from it carries the oldest one still covered by the
// records; replay restores it and goes on from there. The state is the audio
// thread's (voices, buses, ducks, limiter, meter, reverb, compressor, listener,
// clock); not a stream's decoder and ring, so a window with a stream voice
// playing replays without it (`streams` in the header says how many there were).
//
// File: `Capture_Header`, `sound_count` x `Capture_Sound`, `record_count`
// records (frame u64, frames u32, kind u8, size u8, the command's raw bytes:
// kind 0 is a mix call, k + 1 the Command variant k, 10 commands the live
// mixer dropped since the last call: the count in 4 bytes), then, if
// `state_size` is not 0, the state. The raw bytes make a file
// good for the build that wrote it (the header's sizes say so); it is a
// debugging artifact, not a save format.

CAPTURE_MAGIC :: [4]u8{'V', 'X', 'A', 'C'}
CAPTURE_VERSION :: 4
CAPTURE_MAX_RECORDS :: 1 << 24
CAPTURE_RING_SNAPS :: 6 // states kept by a rolling capture
CAPTURE_SNAP_SECONDS :: 15 // between two of them: the window a dump covers is 4 to 5 times this
CAPTURE_RING_MARGIN :: 256 // records of the ring's oldest end a dump does not trust (a mix may be writing them)
CAPTURE_KIND_DROP :: 10

// Mixer_State: what the audio thread holds that a replay from the middle of
// a session needs (the sounds, the handle table and the rings are not it).
Mixer_State :: struct {
	voices:   [MAX_VOICES]Voice,
	buses:    [Bus]Bus_State,
	ducks:    [MAX_DUCKS]Duck,
	limiter:  Limiter,
	meter:    Meter,
	reverb:   Reverb,
	night:    Compressor,
	listener: Listener,
	cross:    [2]f32,
	clock:    u64,
}

Capture :: struct {
	records:     []Record, // a ring's length is a power of two
	count:       u32, // (atomic) records kept (a ring: ever)
	overflow:    u32, // (atomic) records that did not fit
	start_clock: u64,
	rate:        u32,
	// A rolling capture (capture_start_ring):
	ring:        bool,
	states:      []Mixer_State, // CAPTURE_RING_SNAPS slots, used in turn
	snap_at:     [CAPTURE_RING_SNAPS]u32, // the record count each was taken at
	snaps:       u32, // (atomic) states taken, ever
	valid_from:  u32, // the first state a dump may start from (the ones before a gap are not)
	next_snap:   u64, // the clock the next is due at (audio thread)
	seen_drops:  u32, // the mixer's `dropped` as of the last call (audio thread)
}

// Record: one mix call (frames > 0) or one command applied at `frame`.
@(private)
Record :: struct {
	frame:  u64,
	frames: u32,
	drops:  u32, // commands the mixer dropped since the last call (a record of its own)
	cmd:    Command,
}

Capture_Header :: struct #packed {
	magic:        [4]u8,
	version:      u32,
	rate:         u32,
	start_clock:  u64,
	buses:        u32,
	max_voices:   u32,
	play_size:    u32, // sizes of what is stored raw: a file from another layout is refused
	sound_count:  u32,
	record_count: u32,
	overflow:     u32,
	dropped:      u32, // commands the live mixer dropped, ever (ring full, no free handle, busy stream)
	state_size:   u32, // bytes of the Mixer_State after the sound table, 0 if the capture began at clock 0
	state_hash:   u64, // fnv-1a of them
	streams:      u32, // stream voices the state had playing (replayed without)
}

Capture_Sound :: struct #packed {
	length:   u64, // samples, or bytes of a stream's file
	rate:     u32,
	stream:   u16, // 1: a stream (length: bytes of its file)
	channels: u16, // 1 or 2 (a stream's, or a memory sound's: its right channel is in the checksum)
	checksum: u64,
	name:     [SOUND_NAME_LEN]u8,
}

// Capture_File: a parsed capture.
Capture_File :: struct {
	header:  Capture_Header,
	sounds:  []Capture_Sound,
	records: []Record,
	state:   ^Mixer_State, // nil: begins at clock 0
}

// capture_start begins recording at the next mix, room for `capacity` records
// (a call and a command are a record each). False if one is already running.
capture_start :: proc(m: ^Mixer, capacity: int, allocator := context.allocator) -> bool {
	if sync.atomic_load(&m.capture) != nil {return false}
	c := new(Capture, allocator)
	c.records = make([]Record, capacity, allocator)
	c.start_clock = clock(m)
	c.rate = m.rate
	sync.atomic_store(&m.capture, c)
	return true
}

// capture_start_ring begins a rolling capture: the last `capacity` records
// (a power of two) and the states that make them replayable. It never fills;
// capture_ring_save writes what it holds now. False if one is running.
capture_start_ring :: proc(m: ^Mixer, capacity: int, allocator := context.allocator) -> bool {
	assert(capacity > 2 * CAPTURE_RING_MARGIN && capacity & (capacity - 1) == 0)
	if sync.atomic_load(&m.capture) != nil {return false}
	c := new(Capture, allocator)
	c.records = make([]Record, capacity, allocator)
	c.states = make([]Mixer_State, CAPTURE_RING_SNAPS, allocator)
	c.ring = true
	c.rate = m.rate
	sync.atomic_store(&m.capture, c)
	return true
}

// capture_ring_save writes the ring's last window to path and goes on
// recording. The recorder is off for a few milliseconds meanwhile (the mixes
// of that time are not in it), so the states from before are not used again:
// the next window starts at the first state taken after. False if no ring is
// running or it holds nothing a file can start from yet (less than one state
// interval of audio).
capture_ring_save :: proc(m: ^Mixer, path: string) -> bool {
	c := sync.atomic_exchange(&m.capture, nil)
	if c == nil {return false}
	if !c.ring {
		sync.atomic_store(&m.capture, c)
		return false
	}
	time.sleep(5 * time.Millisecond) // (a mix that has the pointer finishes)
	ok := capture_save(m, c, path)
	c.next_snap = 0
	c.valid_from = sync.atomic_load(&c.snaps)
	sync.atomic_store(&m.capture, c)
	return ok
}

// capture_ring_bytes is capture_ring_save into memory: the file's bytes (nil
// if there is nothing to write yet), in `allocator`, from the newest state
// (see capture_encode).
capture_ring_bytes :: proc(m: ^Mixer, allocator := context.allocator) -> []byte {
	c := sync.atomic_exchange(&m.capture, nil)
	if c == nil {return nil}
	if !c.ring {
		sync.atomic_store(&m.capture, c)
		return nil
	}
	time.sleep(5 * time.Millisecond)
	data := capture_encode(m, c, allocator, newest = true)
	c.next_snap = 0
	c.valid_from = sync.atomic_load(&c.snaps)
	sync.atomic_store(&m.capture, c)
	return data
}

// capture_stop ends recording and hands the capture over (nil if none). The
// audio thread may be inside a mix: the count is read once, after the
// pointer is gone, so every record counted was written whole.
capture_stop :: proc(m: ^Mixer) -> ^Capture {
	c := sync.atomic_exchange(&m.capture, nil)
	return c
}

capture_destroy :: proc(c: ^Capture, allocator := context.allocator) {
	if c == nil {return}
	delete(c.records, allocator)
	delete(c.states, allocator)
	free(c, allocator)
}

// capture_records: how many records were kept, and how many were lost.
capture_records :: proc(c: ^Capture) -> (kept, lost: u32) {
	return sync.atomic_load(&c.count), sync.atomic_load(&c.overflow)
}

@(private)
capture_add :: proc "contextless" (c: ^Capture, r: Record) {
	i := sync.atomic_load_explicit(&c.count, .Relaxed)
	if c.ring {
		c.records[int(i) & (len(c.records) - 1)] = r
		sync.atomic_store_explicit(&c.count, i + 1, .Release)
		return
	}
	if int(i) >= len(c.records) {
		sync.atomic_add(&c.overflow, 1)
		return
	}
	c.records[i] = r
	sync.atomic_store_explicit(&c.count, i + 1, .Release)
}

@(private)
capture_call :: proc "contextless" (m: ^Mixer, c: ^Capture, frames: int) {
	if c.ring && m.clock >= c.next_snap {
		// The state at the start of this call, which is the record's place.
		n := sync.atomic_load_explicit(&c.snaps, .Relaxed)
		slot := int(n) % CAPTURE_RING_SNAPS
		state_take(m, &c.states[slot])
		c.snap_at[slot] = sync.atomic_load_explicit(&c.count, .Relaxed)
		sync.atomic_store_explicit(&c.snaps, n + 1, .Release)
		c.next_snap = m.clock + u64(CAPTURE_SNAP_SECONDS) * u64(m.rate)
	}
	if d := sync.atomic_load(&m.dropped); d != c.seen_drops {
		capture_add(c, {frame = m.clock, drops = d - c.seen_drops})
		c.seen_drops = d
	}
	capture_add(c, {frame = m.clock, frames = u32(frames)})
}

@(private)
state_take :: proc "contextless" (m: ^Mixer, s: ^Mixer_State) {
	s.voices = m.voices
	s.buses = m.buses
	s.ducks = m.ducks
	s.limiter = m.limiter
	s.meter = m.meter
	s.reverb = m.reverb
	s.night = m.night
	s.listener = m.listener
	s.cross = m.cross
	s.clock = m.clock
}

@(private)
state_restore :: proc(m: ^Mixer, s: ^Mixer_State) {
	m.voices = s.voices
	m.buses = s.buses
	m.ducks = s.ducks
	m.limiter = s.limiter
	m.meter = s.meter
	m.reverb = s.reverb
	m.night = s.night
	m.listener = s.listener
	m.cross = s.cross
	m.clock = s.clock
}

// state_valid: what replay would index or switch on, in range (a state is
// a debugging artifact, and its hash guards a damaged file, but a replay
// must not crash on one from another build).
@(private)
state_valid :: proc(s: ^Mixer_State, sounds: int) -> bool {
	for v in s.voices {
		if u8(v.state) > u8(max(Voice_State)) || u8(v.bus) >= len(Bus) {return false}
		if v.state == .Playing && int(v.sound) >= sounds {return false}
	}
	r := &s.reverb
	if r.pos < 0 || r.pos >= REVERB_MAX || r.pre_pos < 0 || r.pre_pos >= REVERB_MAX {return false}
	for l in r.len {if l < 1 || l >= REVERB_MAX {return false}}
	for e in r.early_at {if e < 1 || e >= REVERB_MAX {return false}}
	li := &s.limiter
	return(
		li.n >= 1 &&
		li.n <= LIMITER_MAX &&
		li.group >= 0 &&
		li.group < 8 &&
		li.tail - li.head <= LIMITER_MAX \
	)
}

@(private)
sound_checksum :: proc(s: Sound, st: ^Stream) -> Capture_Sound {
	if st != nil {
		return {u64(len(st.data)), st.rate, 1, u16(st.channels), hash.fnv64a(st.data), {}}
	}
	sum := hash.fnv64a(slice.to_bytes(s.samples))
	if s.right != nil {
		return {u64(len(s.samples)), s.rate, 0, 2, hash.fnv64a(slice.to_bytes(s.right), sum), {}}
	}
	return {u64(len(s.samples)), s.rate, 0, 1, sum, {}}
}

// capture_encode: the file's bytes for what c holds, with the sound table of m
// (as it is now). A ring writes its last window from the oldest state still
// covered; nil if it has none yet. Not while the audio thread may be writing
// to c (capture_stop first, or capture_ring_save).
// With `newest`, from the newest state instead (the shortest window: the
// inspector's freeze).
capture_encode :: proc(
	m: ^Mixer,
	c: ^Capture,
	allocator := context.allocator,
	newest := false,
) -> []byte {
	first, n := u32(0), int(sync.atomic_load(&c.count))
	state: ^Mixer_State
	h := Capture_Header {
		magic       = CAPTURE_MAGIC,
		version     = CAPTURE_VERSION,
		rate        = c.rate,
		start_clock = c.start_clock,
		buses       = len(Bus),
		max_voices  = MAX_VOICES,
		play_size   = size_of(Play),
		sound_count = u32(m.count),
		overflow    = sync.atomic_load(&c.overflow),
		dropped     = sync.atomic_load(&m.dropped),
	}
	if c.ring {
		snaps := sync.atomic_load(&c.snaps)
		// (the slot a mix would write next is the oldest: not one to use)
		from := max(c.valid_from, snaps - min(snaps, CAPTURE_RING_SNAPS - 1))
		for k in 0 ..< snaps - min(snaps, from) {
			j := snaps - 1 - k if newest else from + k
			at := c.snap_at[int(j) % CAPTURE_RING_SNAPS]
			if int(u32(n) - at) + CAPTURE_RING_MARGIN <= len(c.records) {
				first, state = at, &c.states[int(j) % CAPTURE_RING_SNAPS]
				break
			}
		}
		if state == nil {return nil}
		h.start_clock = state.clock
		h.state_size = size_of(Mixer_State)
		h.state_hash = hash.fnv64a(mem.ptr_to_bytes(state))
		for v in state.voices {
			if v.state == .Playing && m.streams[v.sound] != nil {h.streams += 1}
		}
	}
	kept := n - int(first)
	h.record_count = u32(kept)
	out := make([dynamic]byte, 0, 4096 + kept * 48 + int(h.state_size), allocator)
	append(&out, ..mem.ptr_to_bytes(&h))
	for s, i in m.sounds[:m.count] {
		cs := sound_checksum(s, m.streams[i])
		cs.name = m.names[i]
		append(&out, ..mem.ptr_to_bytes(&cs))
	}
	if state != nil {append(&out, ..mem.ptr_to_bytes(state))}
	mask := len(c.records) - 1
	for k in 0 ..< kept {
		r := c.records[(int(first) + k) & mask if c.ring else k]
		frame, frames := r.frame, r.frames
		append(&out, ..mem.ptr_to_bytes(&frame))
		append(&out, ..mem.ptr_to_bytes(&frames))
		kind, raw := command_raw(r.cmd)
		if frames > 0 {kind = 0}
		if r.drops > 0 {
			drops := r.drops
			kind, raw = CAPTURE_KIND_DROP, mem.ptr_to_bytes(&drops)
		}
		append(&out, kind, u8(len(raw)))
		append(&out, ..raw)
	}
	return out[:]
}

// capture_save writes the file.
capture_save :: proc(m: ^Mixer, c: ^Capture, path: string) -> bool {
	data := capture_encode(m, c, context.temp_allocator)
	if data == nil {
		log.warnf("audio capture: nothing to write yet (%s)", path)
		return false
	}
	if err := os.write_entire_file(path, data); err != nil {
		log.warnf("audio capture: cannot write %s: %v", path, err)
		return false
	}
	return true
}

// capture_parse reads a capture file, checking everything it will use (its
// sizes, counts, enums and indices) so replay can trust it.
capture_parse :: proc(
	data: []byte,
	allocator := context.allocator,
) -> (
	f: Capture_File,
	ok: bool,
) {
	if len(data) < size_of(Capture_Header) {return}
	mem.copy(&f.header, raw_data(data), size_of(Capture_Header))
	h := &f.header
	if h.magic != CAPTURE_MAGIC || h.version != CAPTURE_VERSION {return}
	if h.buses != len(Bus) || h.max_voices != MAX_VOICES || h.play_size != size_of(Play) {return}
	if h.sound_count > MAX_SOUNDS || h.record_count > CAPTURE_MAX_RECORDS || h.rate == 0 {return}
	at := size_of(Capture_Header)
	need := int(h.sound_count) * size_of(Capture_Sound)
	if len(data) - at < need {return}
	f.sounds = make([]Capture_Sound, h.sound_count, allocator)
	mem.copy(raw_data(f.sounds), raw_data(data[at:]), need)
	at += need
	records := make([dynamic]Record, 0, h.record_count, allocator)
	defer if !ok {
		delete(f.sounds, allocator)
		delete(records)
		free(f.state, allocator)
		f.sounds, f.records, f.state = nil, nil, nil
	}
	if h.state_size != 0 {
		if h.state_size != size_of(Mixer_State) || len(data) - at < size_of(Mixer_State) {return}
		f.state = new(Mixer_State, allocator)
		mem.copy(f.state, raw_data(data[at:]), size_of(Mixer_State))
		at += size_of(Mixer_State)
		if hash.fnv64a(mem.ptr_to_bytes(f.state)) != h.state_hash ||
		   f.state.clock != h.start_clock ||
		   !state_valid(f.state, int(h.sound_count)) {return}
	}
	for _ in 0 ..< h.record_count {
		if len(data) - at < 14 {return}
		r: Record
		mem.copy(&r.frame, raw_data(data[at:]), 8)
		mem.copy(&r.frames, raw_data(data[at + 8:]), 4)
		kind, size := data[at + 12], int(data[at + 13])
		at += 14
		if len(data) - at < size {return}
		if kind == 0 {
			if r.frames == 0 || size != 0 {return}
		} else if kind == CAPTURE_KIND_DROP {
			if r.frames != 0 || size != 4 {return}
			mem.copy(&r.drops, raw_data(data[at:]), 4)
			if r.drops == 0 {return}
		} else {
			cmd := command_from(kind, data[at:][:size], int(h.sound_count)) or_return
			if r.frames != 0 {return}
			r.cmd = cmd
		}
		at += size
		append(&records, r)
	}
	f.records = records[:]
	return f, at == len(data)
}

capture_file_destroy :: proc(f: ^Capture_File, allocator := context.allocator) {
	delete(f.sounds, allocator)
	delete(f.records, allocator)
	free(f.state, allocator)
	f^ = {}
}

// capture_frames: the frames of audio the capture makes (the size `out` of a
// replay must have, times two).
capture_frames :: proc(f: ^Capture_File) -> (frames: int) {
	for r in f.records {frames += int(r.frames)}
	return
}

// capture_replay mixes the capture through m, which must be new (clock 0, at
// the capture's rate), with the capture's sounds registered (streams inline).
// out takes 2 * capture_frames samples. False, with the reason logged, if m
// does not match or the capture asks for more than the mixer holds.
capture_replay :: proc(m: ^Mixer, f: ^Capture_File, out: []f32) -> bool {
	if m.rate != f.header.rate || m.clock != 0 || (f.state == nil && f.header.start_clock != 0) {
		log.warnf("audio replay: the mixer is not the capture's (rate, clock)")
		return false
	}
	if f.state != nil {
		state_restore(m, f.state)
		if f.header.streams > 0 {
			log.warnf(
				"audio replay: %d stream voices were playing at the start; replayed without",
				f.header.streams,
			)
		}
	}
	if m.count != len(f.sounds) {
		log.warnf("audio replay: %d sounds registered, capture has %d", m.count, len(f.sounds))
		return false
	}
	for s, i in m.sounds[:m.count] {
		// (the name is not part of the sound)
		got, want := sound_checksum(s, m.streams[i]), f.sounds[i]
		want.name = {}
		if got != want {
			log.warnf("audio replay: sound %d is not the one captured", i)
			return false
		}
	}
	if len(out) < 2 * capture_frames(f) {return false}
	// A call's record comes first, its commands after (they were applied
	// during it): so a call is mixed when the next one (or the end) shows.
	at, pending := 0, 0
	flush :: proc(m: ^Mixer, out: []f32, at, frames: int) {
		if frames == 0 {return}
		mix(m, out[2 * at:][:2 * frames])
		// The game's table of handles is not here: the ends are only dropped.
		sync.atomic_store(&m.ev_read, sync.atomic_load(&m.ev_write))
	}
	for r in f.records {
		if r.frames > 0 {
			flush(m, out, at, pending)
			at += pending
			pending = int(r.frames)
		} else if r.drops > 0 {
			// (only a note for the dump)
		} else if !push(m, r.cmd, r.frame) {
			log.warnf("audio replay: more commands in one call than the ring holds")
			return false
		}
	}
	flush(m, out, at, pending)
	return true
}

// command_raw: the variant number + 1 of a command and its bytes.
@(private)
command_raw :: proc(cmd: Command) -> (kind: u8, raw: []byte) {
	cmd := cmd
	switch &c in cmd {
	case Play_Cmd:
		return 1, bytes_of(&c)
	case Voice_Param:
		return 2, bytes_of(&c)
	case Stop_Cmd:
		return 3, bytes_of(&c)
	case Fade_Cmd:
		return 4, bytes_of(&c)
	case Bus_Cmd:
		return 5, bytes_of(&c)
	case Duck_Cmd:
		return 6, bytes_of(&c)
	case Snapshot_Cmd:
		return 7, bytes_of(&c)
	case Reverb_Cmd:
		return 8, bytes_of(&c)
	case Listener_Cmd:
		return 9, bytes_of(&c)
	}
	return 0, nil
}

// bytes_of: a copy of v's bytes (the temp allocator's), as v is a local.
@(private)
bytes_of :: proc(v: ^$T) -> []byte {
	b := make([]byte, size_of(T), context.temp_allocator)
	mem.copy(raw_data(b), v, size_of(T))
	return b
}

// command_from: the inverse, refusing what the mixer would index with or
// switch on out of range.
@(private)
command_from :: proc(kind: u8, raw: []byte, sounds: int) -> (cmd: Command, ok: bool) {
	load :: proc(raw: []byte, $T: typeid) -> (v: T, ok: bool) {
		if len(raw) != size_of(T) {return}
		mem.copy(&v, raw_data(raw), size_of(T))
		return v, true
	}
	valid_bus :: proc(b: Bus) -> bool {return u8(b) < len(Bus)}
	switch kind {
	case 1:
		c := load(raw, Play_Cmd) or_return
		if int(c.id & 0xff) >= MAX_VOICES ||
		   int(c.play.sound) >= sounds ||
		   !valid_bus(c.play.bus) ||
		   transmute(u8)c.play.loop > 1 {return}
		return c, true
	case 2:
		c := load(raw, Voice_Param) or_return
		if u8(c.which) > 2 || int(c.id & 0xff) >= MAX_VOICES {return}
		return c, true
	case 3:
		c := load(raw, Stop_Cmd) or_return
		if int(c.id & 0xff) >= MAX_VOICES {return}
		return c, true
	case 4:
		c := load(raw, Fade_Cmd) or_return
		if int(c.id & 0xff) >= MAX_VOICES {return}
		return c, true
	case 5:
		c := load(raw, Bus_Cmd) or_return
		if !valid_bus(c.bus) || u8(c.which) > 3 {return}
		return c, true
	case 6:
		c := load(raw, Duck_Cmd) or_return
		d := &c.duck
		if c.index < 0 ||
		   c.index >= MAX_DUCKS ||
		   !valid_bus(d.trigger) ||
		   !valid_bus(d.target) ||
		   d.trigger >= d.target ||
		   transmute(u8)d.active > 1 {return}
		return c, true
	case 7:
		return load(raw, Snapshot_Cmd)
	case 8:
		return load(raw, Reverb_Cmd)
	case 9:
		c := load(raw, Listener_Cmd) or_return
		o := &c.options
		if transmute(u8)o.mono > 1 || transmute(u8)o.swap > 1 || transmute(u8)o.night > 1 {return}
		return c, true
	}
	return
}
