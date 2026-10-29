package audio

import "../../base"
import "../../common/ogg"
import "core:log"
import "core:math"
import "core:sync"
import "core:thread"
import "core:time"

// Streams: sounds too long to keep decoded (music, ambience beds), read from
// an Ogg Vorbis file in memory by a decoder thread and played by the same
// voices as everything else.
//
// A stream is registered like a sound (add_stream) and has one voice at a
// time: the decoder writes the file's samples (one channel, or two: a file of
// more is mixed down to two) at its rate into a ring (a second ring for the
// right channel), the mixer reads them where a memory voice reads its
// samples (through the same sinc, so pitch, filters, buses and fades are
// shared), and tells the decoder how far it has read so the ring refills.
// When the voice ends the mixer asks the decoder to start over (an epoch
// counter, so a stale write is never mistaken for a fresh one). Looping is the
// decoder's: the ring is endless, the end of the file crossfaded (equal power)
// into its start, so the voice never sees a loop point.
//
// An underrun (the voice wanted samples the decoder had not written) is
// counted and never skipped over: the voice holds its place, silent for that
// block, and goes on where it was. Offline (tests, capture replays) a stream
// is `inline`: no thread; the mixer decodes it itself at the start of each
// block, so what comes out never depends on a thread's timing.

STREAM_RING :: 1 << 16 // mono samples (1.3 s at 48 kHz): a starved decoder has this long
STREAM_CHUNK :: 2048 // frames decoded at a time
STREAM_REACH :: SINC_HALF * SINC_MAX_STEP // samples the widest kernel reads each side
STREAM_HISTORY :: STREAM_REACH + 8 // samples kept behind the voice
STREAM_STAGE :: MAX_BLOCK * SINC_MAX_STEP + 2 * STREAM_REACH + 8 // one block's window of the ring

Stream :: struct {
	data:      []byte, // the whole file; owned by the caller, unchanged while registered
	loop:      bool,
	crossfade: int, // frames of the loop's equal-power crossfade
	rate:      u32, // the file's
	channels:  u8, // 1 or 2
	length:    int, // frames in the file
	inline:    bool, // decoded by the mixer, in `mix`, not by a thread
	ring:      [STREAM_RING]f32,
	ring_r:    [STREAM_RING]f32, // the right channel (a two-channel stream)
	// Decoder to mixer (atomic):
	written:   u64, // samples written this epoch
	have:      u32, // the epoch the ring holds
	total:     u64, // (finished) the stream's length in samples
	finished:  b32, // a stream that does not loop is decoded to its end
	// Mixer to decoder (atomic):
	read:      u64, // samples the voice no longer needs
	want:      u32, // the epoch asked for (a restart bumps it)
	quit:      b32,
	pause:     b32, // tests: the decoder does nothing
	underruns: u32, // blocks in which the voice found the ring empty, ever
	// Audio thread only:
	owner:     Voice_Id, // the voice playing it, 0 when idle
	epoch:     u32,
	// Decoder only:
	dec:       Decoder,
	thread:    ^thread.Thread,
}

@(private)
Decoder :: struct {
	d:       ^ogg.Decoder, // our own Odin decoder (M53c), made on the decoder thread's behalf
	open:    bool,
	epoch:   u32,
	pos:     int, // frames of the file consumed this pass
	since:   int, // frames produced since the file was last rewound
	head:    []f32, // the file's first `crossfade` frames
	tail:    []f32, // the blend, being handed out
	head_r:  []f32, // the same, right channel
	tail_r:  []f32,
	tail_at: int,
	broken:  bool, // the file stopped giving samples: treated as ended
}

// add_stream registers an Ogg Vorbis file (the whole file, in memory) as a
// sound: its id plays it, one voice at a time. A looping stream crossfades its
// end into its start over `crossfade` seconds (at most a quarter of it); `start`
// seconds into the file is where the first pass begins (an audition).
// Before the device starts; close with streams_close. ok is false (and the
// reason logged) for a file that cannot be decoded.
add_stream :: proc(
	m: ^Mixer,
	data: []byte,
	loop := false,
	crossfade: f32 = 0,
	inline := false,
	start: f32 = 0,
	allocator := context.allocator,
) -> (
	id: Sound_Id,
	ok: bool,
) {
	assert(m.count < MAX_SOUNDS)
	st := new(Stream, allocator)
	st.data, st.loop, st.inline = data, loop, inline
	if !dec_open(st, crossfade, start) {
		free(st, allocator)
		return 0, false
	}
	m.sounds[m.count] = {
		samples = nil,
		rate    = st.rate,
	}
	m.streams[m.count] = st
	m.count += 1
	if !inline {st.thread = thread.create_and_start_with_data(st, decoder_main, base.thread_context())}
	return Sound_Id(m.count - 1), true
}

// streams_close stops every decoder thread and frees the streams. The mixer
// must not be mixing, and plays none of them afterwards.
streams_close :: proc(m: ^Mixer, allocator := context.allocator) {
	for &st, i in m.streams[:m.count] {
		if st == nil {continue}
		sync.atomic_store(&st.quit, true)
		if st.thread != nil {
			thread.join(st.thread)
			thread.destroy(st.thread)
		}
		dec_close(st)
		free(st, allocator)
		st = nil
		m.sounds[i] = {}
	}
}

// stream_underruns: blocks in which a stream's voice found nothing to read.
stream_underruns :: proc(m: ^Mixer, id: Sound_Id) -> u32 {
	st := m.streams[id]
	return sync.atomic_load(&st.underruns) if st != nil else 0
}

// stream_pause stops (or restarts) a stream's decoder, as a test of a
// starved one.
stream_pause :: proc(m: ^Mixer, id: Sound_Id, paused: bool) {
	if st := m.streams[id]; st != nil {sync.atomic_store(&st.pause, b32(paused))}
}

@(private)
decoder_main :: proc(data: rawptr) {
	st := (^Stream)(data)
	for !sync.atomic_load(&st.quit) {
		if sync.atomic_load(&st.pause) || !stream_pump(st) {time.sleep(time.Millisecond)}
	}
}

// stream_pump decodes one chunk into the ring if there is room, after
// restarting if the mixer asked. False: nothing to do now.
@(private)
stream_pump :: proc "contextless" (st: ^Stream) -> bool {
	d := &st.dec
	if e := sync.atomic_load(&st.want); e != d.epoch {
		dec_rewind(st)
		d.broken = false
		sync.atomic_store(&st.written, 0)
		sync.atomic_store(&st.total, 0)
		sync.atomic_store(&st.finished, false)
		d.epoch = e
		sync.atomic_store(&st.have, e)
		return true
	}
	if sync.atomic_load(&st.finished) {return false}
	w := sync.atomic_load(&st.written)
	used := w - sync.atomic_load(&st.read)
	if used > STREAM_RING || STREAM_RING - used < STREAM_CHUNK {return false}
	buf, buf_r: [STREAM_CHUNK]f32
	n := produce(st, buf[:], buf_r[:])
	for i in 0 ..< n {st.ring[(w + u64(i)) & (STREAM_RING - 1)] = buf[i]}
	if st.channels == 2 {
		for i in 0 ..< n {st.ring_r[(w + u64(i)) & (STREAM_RING - 1)] = buf_r[i]}
	}
	if n > 0 {sync.atomic_store(&st.written, w + u64(n))}
	if n < len(buf) {
		sync.atomic_store(&st.total, w + u64(n))
		sync.atomic_store(&st.finished, true)
	}
	return true
}

@(private)
dec_open :: proc(st: ^Stream, crossfade: f32, start: f32) -> bool {
	d, err := ogg.open(st.data)
	if err != .None {
		log.warnf("audio stream: not an Ogg Vorbis file we can decode (%v)", err)
		return false
	}
	st.dec.d, st.dec.open = d, true
	// One or two channels, as the file's first link has them; more are folded down.
	inf := ogg.info(d)
	st.channels = u8(min(inf.channels, 2))
	rate, length := inf.rate, inf.frames
	if inf.channels < 1 || rate < 8000 || rate > 192000 || length < 2 || length > 1 << 36 {
		log.warnf("audio stream: unusable (rate=%d length=%d)", rate, length)
		dec_close(st)
		return false
	}
	st.rate, st.length = rate, int(length)
	if st.loop {
		st.crossfade = clamp(int(f64(crossfade) * f64(st.rate)), 0, st.length / 4)
		if st.crossfade > 0 {
			st.dec.head = make([]f32, st.crossfade)
			st.dec.tail = make([]f32, st.crossfade)
			if st.channels == 2 {
				st.dec.head_r = make([]f32, st.crossfade)
				st.dec.tail_r = make([]f32, st.crossfade)
			}
			n := dec_read(st, st.dec.head, st.dec.head_r)
			for i in n ..< len(st.dec.head) {st.dec.head[i] = 0}
			for i in n ..< len(st.dec.head_r) {st.dec.head_r[i] = 0}
			dec_rewind(st)
		}
	}
	if start > 0 {
		at := clamp(int(f64(start) * f64(st.rate)), 0, st.length - st.crossfade - 1)
		_ = ogg.seek(d, u64(at))
		st.dec.pos = at
	}
	return true
}

@(private)
dec_close :: proc(st: ^Stream) {
	d := &st.dec
	if d.open {ogg.close(d.d)}
	delete(d.head)
	delete(d.tail)
	delete(d.head_r)
	delete(d.tail_r)
	d.open = false
}

@(private)
dec_rewind :: proc "contextless" (st: ^Stream) {
	d := &st.dec
	_ = ogg.seek(d.d, 0)
	d.pos, d.since, d.tail_at = 0, 0, len(d.tail)
}

// dec_read: up to len(out) frames of the file; `right` (as long as `out`)
// gets the second channel of a two-channel stream. A file with more channels
// is folded to two (the centre into both, the rest dropped); a chained file's
// next link goes on without a gap, at the first link's rate and channel count.
@(private)
dec_read :: proc "contextless" (st: ^Stream, out, right: []f32) -> int {
	total := 0
	tmp: [ogg.MAX_CHANNELS * STREAM_CHUNK]f32
	for total < len(out) {
		want := min(len(out) - total, STREAM_CHUNK)
		got, err := ogg.read(st.dec.d, tmp[:], want)
		if got == 0 || err != .None {break}
		ch := int(ogg.info(st.dec.d).channels)
		for i in 0 ..< got {
			f := tmp[i * ch:][:ch]
			l, r := f[0], f[0] if ch == 1 else f[1]
			if ch > 2 {
				l += 0.707 * f[2]
				r += 0.707 * f[2]
			}
			out[total + i] = l if st.channels == 2 else 0.5 * (l + r)
			if st.channels == 2 {right[total + i] = r}
		}
		total += got
	}
	return total
}

// produce: the stream's next samples (endless for a loop, so fewer than
// asked only at the end of one that does not).
@(private)
produce :: proc "contextless" (st: ^Stream, out, out_r: []f32) -> int {
	d := &st.dec
	n := 0
	for n < len(out) {
		if d.tail_at < len(d.tail) {
			k := min(len(out) - n, len(d.tail) - d.tail_at)
			copy(out[n:n + k], d.tail[d.tail_at:][:k])
			if st.channels == 2 {copy(out_r[n:n + k], d.tail_r[d.tail_at:][:k])}
			d.tail_at += k
			n += k
			continue
		}
		if d.broken {break}
		if !st.loop {
			got := dec_read(st, out[n:], out_r[n:])
			if got == 0 {break}
			n += got
			continue
		}
		cut := st.length - st.crossfade // where the end begins to fade into the start
		if d.pos >= cut {
			if d.since == 0 {
				d.broken = true // a pass that gave nothing: the file cannot be read
				break
			}
			if st.crossfade > 0 {
				got := dec_read(st, d.tail, d.tail_r)
				for i in got ..< len(d.tail) {d.tail[i] = 0}
				for i in got ..< len(d.tail_r) {d.tail_r[i] = 0}
				for i in 0 ..< len(d.tail) {
					x := (f64(i) + 0.5) / f64(len(d.tail)) * math.PI / 2
					c, sn := f32(math.cos(x)), f32(math.sin(x))
					d.tail[i] = d.tail[i] * c + d.head[i] * sn
					if st.channels == 2 {d.tail_r[i] = d.tail_r[i] * c + d.head_r[i] * sn}
				}
				dec_rewind(st)
				// The head was heard in the blend: go on after it.
				skipped := 0
				for skipped < st.crossfade {
					junk, junk_r: [STREAM_CHUNK]f32
					k := min(STREAM_CHUNK, st.crossfade - skipped)
					k = dec_read(st, junk[:k], junk_r[:k])
					if k == 0 {break}
					skipped += k
				}
				d.pos = skipped
				d.since = 0
				d.tail_at = 0
			} else {
				dec_rewind(st)
			}
			continue
		}
		k := min(len(out) - n, cut - d.pos)
		got := dec_read(st, out[n:][:k], out_r[n:][:k])
		if got == 0 {
			d.pos = cut // the file is shorter than it said
			continue
		}
		d.pos += got
		d.since += got
		n += got
	}
	return n
}

// stream_window: for a stream voice, the ring's samples around its position
// copied into the mixer's stage (as a contiguous run starting at `base`), and
// how far they can be trusted (`avail`: samples written; infinite for a
// finished stream) and where the stream ends (`last`, when known).
@(private)
stream_window :: proc "contextless" (
	m: ^Mixer,
	st: ^Stream,
	v: ^Voice,
	n: int,
) -> (
	avail: f64,
	last: int,
	base: f64,
) {
	last = max(int) / 4
	if sync.atomic_load(&st.have) != st.epoch {return 0, last, 0} 	// restarting: nothing yet
	fin := sync.atomic_load(&st.finished)
	w := sync.atomic_load(&st.written)
	avail = f64(w)
	if fin {
		avail = math.INF_F64
		last = int(sync.atomic_load(&st.total)) - 1
	}
	lo := int(math.floor(v.pos)) - STREAM_REACH
	need :=
		int(math.ceil(f64(n) * min(max(v.step, v.step_to), SINC_MAX_STEP))) + 2 * STREAM_REACH + 4
	need = min(need, STREAM_STAGE)
	for k in 0 ..< need {
		idx := lo + k
		m.stage[k] = 0 if idx < 0 || u64(idx) >= w else st.ring[u64(idx) & (STREAM_RING - 1)]
	}
	if st.channels == 2 {
		for k in 0 ..< need {
			idx := lo + k
			m.stage_r[k] =
				0 if idx < 0 || u64(idx) >= w else st.ring_r[u64(idx) & (STREAM_RING - 1)]
		}
	}
	return avail, last, f64(lo)
}

// stream_consume tells the decoder how far the voice has got, so the ring
// behind it can be overwritten.
@(private)
stream_consume :: proc "contextless" (st: ^Stream, pos: f64) {
	if sync.atomic_load(&st.have) != st.epoch {return}
	r := int(math.floor(pos)) - STREAM_HISTORY
	if r <= 0 {return}
	sync.atomic_store(&st.read, min(u64(r), sync.atomic_load(&st.written)))
}

// stream_release: the voice playing a stream has ended; the stream starts
// over for the next.
@(private)
stream_release :: proc "contextless" (st: ^Stream, id: Voice_Id) {
	if st.owner != id {return}
	st.owner = 0
	st.epoch += 1
	sync.atomic_store(&st.read, 0)
	sync.atomic_store(&st.want, st.epoch)
}
