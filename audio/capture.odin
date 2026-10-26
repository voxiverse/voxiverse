package audio

import "core:hash"
import "core:log"
import "core:mem"
import "core:os"
import "core:slice"
import "core:sync"

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
// bit for bit (the voices playing then are state the file does not hold):
// that is what M32b's rolling capture adds.
//
// File: `Capture_Header`, `sound_count` x `Capture_Sound`, `record_count`
// records (frame u64, frames u32, kind u8, size u8, the command's raw bytes:
// kind 0 is a mix call, k + 1 the Command variant k). The raw bytes make a file
// good for the build that wrote it (the header's sizes say so); it is a
// debugging artifact, not a save format.

CAPTURE_MAGIC :: [4]u8{'V', 'X', 'A', 'C'}
CAPTURE_VERSION :: 1
CAPTURE_MAX_RECORDS :: 1 << 24

Capture :: struct {
	records:     []Record,
	count:       u32, // (atomic) records kept
	overflow:    u32, // (atomic) records that did not fit
	start_clock: u64,
	rate:        u32,
}

// Record: one mix call (frames > 0) or one command applied at `frame`.
@(private)
Record :: struct {
	frame:  u64,
	frames: u32,
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
}

Capture_Sound :: struct #packed {
	length:   u64, // samples, or bytes of a stream's file
	rate:     u32,
	stream:   u32,
	checksum: u64,
}

// Capture_File: a parsed capture.
Capture_File :: struct {
	header:  Capture_Header,
	sounds:  []Capture_Sound,
	records: []Record,
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
	free(c, allocator)
}

// capture_records: how many records were kept, and how many were lost.
capture_records :: proc(c: ^Capture) -> (kept, lost: u32) {
	return sync.atomic_load(&c.count), sync.atomic_load(&c.overflow)
}

@(private)
capture_add :: proc "contextless" (c: ^Capture, r: Record) {
	i := sync.atomic_load_explicit(&c.count, .Relaxed)
	if int(i) >= len(c.records) {
		sync.atomic_add(&c.overflow, 1)
		return
	}
	c.records[i] = r
	sync.atomic_store_explicit(&c.count, i + 1, .Release)
}

@(private)
capture_call :: proc "contextless" (c: ^Capture, frame: u64, frames: int) {
	capture_add(c, {frame = frame, frames = u32(frames)})
}

@(private)
capture_command :: proc "contextless" (c: ^Capture, frame: u64, cmd: Command) {
	capture_add(c, {frame = frame, cmd = cmd})
}

@(private)
sound_checksum :: proc(s: Sound, st: ^Stream) -> Capture_Sound {
	if st != nil {
		return {u64(len(st.data)), st.rate, 1, hash.fnv64a(st.data)}
	}
	return {u64(len(s.samples)), s.rate, 0, hash.fnv64a(slice.to_bytes(s.samples))}
}

// capture_encode: the file's bytes for what c holds, with the sound table of m
// (as it is now).
capture_encode :: proc(m: ^Mixer, c: ^Capture, allocator := context.allocator) -> []byte {
	n := int(sync.atomic_load(&c.count))
	out := make([dynamic]byte, 0, 4096 + n * 48, allocator)
	h := Capture_Header {
		magic        = CAPTURE_MAGIC,
		version      = CAPTURE_VERSION,
		rate         = c.rate,
		start_clock  = c.start_clock,
		buses        = len(Bus),
		max_voices   = MAX_VOICES,
		play_size    = size_of(Play),
		sound_count  = u32(m.count),
		record_count = u32(n),
		overflow     = sync.atomic_load(&c.overflow),
	}
	append(&out, ..mem.ptr_to_bytes(&h))
	for s, i in m.sounds[:m.count] {
		cs := sound_checksum(s, m.streams[i])
		append(&out, ..mem.ptr_to_bytes(&cs))
	}
	for r in c.records[:n] {
		frame, frames := r.frame, r.frames
		append(&out, ..mem.ptr_to_bytes(&frame))
		append(&out, ..mem.ptr_to_bytes(&frames))
		kind, raw := command_raw(r.cmd)
		if frames > 0 {kind = 0}
		append(&out, kind, u8(len(raw)))
		append(&out, ..raw)
	}
	return out[:]
}

// capture_save writes the file.
capture_save :: proc(m: ^Mixer, c: ^Capture, path: string) -> bool {
	data := capture_encode(m, c, context.temp_allocator)
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
		f.sounds, f.records = nil, nil
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
	if m.rate != f.header.rate || m.clock != 0 || f.header.start_clock != 0 {
		log.warnf("audio replay: the mixer is not the capture's (rate, clock)")
		return false
	}
	if m.count != len(f.sounds) {
		log.warnf("audio replay: %d sounds registered, capture has %d", m.count, len(f.sounds))
		return false
	}
	for s, i in m.sounds[:m.count] {
		if sound_checksum(s, m.streams[i]) != f.sounds[i] {
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
