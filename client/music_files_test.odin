package client

import "../common/ogg"
import "audio"
import "core:encoding/json"
import "core:math"
import "core:os"
import "core:strings"
import "core:testing"

// The committed music (assets/music, M43b): every piece decodes to what its
// metadata says, at the loudness the mix expects, loops without a seam, and
// the set stays inside its size budget.

MUSIC_DIR :: #directory + "/../assets/music/"

Music_Meta :: struct {
	title:  string,
	source: string,
	rate:   int,
	frames: int,
	loop:   bool,
	lufs:   f64,
}

// music_decode: the whole file as interleaved stereo float, by common/ogg.
@(private = "file")
music_decode :: proc(file: []byte) -> (pcm: []f32, rate: int) {
	d, err := ogg.open(file)
	if err != .None {return}
	defer ogg.close(d)
	n := int(ogg.info(d).frames)
	rate = int(ogg.info(d).rate)
	pcm = make([]f32, 2 * n)
	block: [ogg.MAX_CHANNELS * 4096]f32
	got := 0
	for got < n {
		k, e := ogg.read(d, block[:], min(4096, n - got))
		if k == 0 || e != .None {break}
		ch := int(ogg.info(d).channels)
		for i in 0 ..< k {
			pcm[2 * (got + i)] = block[i * ch]
			pcm[2 * (got + i) + 1] = block[i * ch + (1 if ch > 1 else 0)]
		}
		got += k
	}
	return pcm[:2 * got], rate
}

@(test)
test_music_decodes_to_its_metadata :: proc(t: ^testing.T) {
	for f in MUSIC {
		meta: Music_Meta
		testing.expectf(
			t,
			json.unmarshal(transmute([]u8)f.json, &meta, allocator = context.temp_allocator) ==
			nil,
			"%s.json",
			f.name,
		)
		testing.expectf(t, meta.rate == 48000 && meta.frames > 0, "%s: %v", f.name, meta)
		_, err := os.stat(
			strings.concatenate({MUSIC_DIR, meta.source}, context.temp_allocator),
			context.temp_allocator,
		)
		testing.expectf(t, err == nil, "%s names %s, which does not exist", f.name, meta.source)
		// Through a mixer at 48 kHz, as the game plays it: the voice ends at `frames`.
		m := new(audio.Mixer)
		defer free(m)
		audio.mixer_init(m, 48000)
		id, ok := audio.add_stream(m, f.ogg, inline = true)
		defer audio.streams_close(m)
		testing.expectf(t, ok, "%s does not decode", f.name)
		if !ok {continue}
		testing.expect_value(t, m.streams[id].length, meta.frames)
		testing.expect_value(t, int(m.streams[id].rate), meta.rate)
		testing.expect_value(t, int(m.streams[id].channels), 2)
		v := audio.play(m, {sound = id, gain = {1, 1}, pitch = 1, bus = .Music})
		block := 480
		out := make([]f32, 2 * block)
		defer delete(out)
		played := 0
		for audio.alive(m, v) && played < meta.frames + 4 * block {
			audio.mix(m, out)
			audio.drain(m)
			played += block
		}
		late := audio.latency(m)
		testing.expectf(
			t,
			abs(played - late - meta.frames) <= block + 1,
			"%s: ends after %d frames (latency %d), says %d",
			f.name,
			played,
			late,
			meta.frames,
		)
		free_all(context.temp_allocator)
	}
}

@(test)
test_music_loudness_and_loops :: proc(t: ^testing.T) {
	for f in MUSIC {
		meta: Music_Meta
		json.unmarshal(transmute([]u8)f.json, &meta, allocator = context.temp_allocator)
		pcm, rate := music_decode(f.ogg)
		defer delete(pcm)
		testing.expect_value(t, rate, meta.rate)
		testing.expect_value(t, len(pcm) / 2, meta.frames)
		meter := new(audio.Meter)
		defer free(meter)
		audio.meter_init(meter, f64(rate))
		audio.meter_push(meter, pcm)
		lufs := f64(audio.meter_integrated(meter))
		testing.expectf(
			t,
			abs(lufs - -20) <= 1,
			"%s: %.2f LUFS, wanted -20 within 1",
			f.name,
			lufs,
		)
		if !meta.loop {continue}
		n := len(pcm) / 2
		near := rate / 100 // 10 ms
		for ch in 0 ..< 2 {
			jump := abs(pcm[ch] - pcm[2 * (n - 1) + ch])
			steps: f32
			for i in 0 ..< near {
				steps = max(steps, abs(pcm[2 * (i + 1) + ch] - pcm[2 * i + ch]))
				k := n - 1 - i
				steps = max(steps, abs(pcm[2 * k + ch] - pcm[2 * (k - 1) + ch]))
			}
			testing.expectf(
				t,
				jump <= 1.5 * steps + 1e-6,
				"%s ch %d: the loop jumps %v, its neighbours differ by %v",
				f.name,
				ch,
				jump,
				steps,
			)
		}
	}
}

@(test)
test_music_set :: proc(t: ^testing.T) {
	total := 0
	for f in MUSIC {total += len(f.ogg)}
	testing.expectf(t, total <= MUSIC_BUDGET, "the Oggs take %d bytes of %d", total, MUSIC_BUDGET)
	files, err := os.read_all_directory_by_path(MUSIC_DIR, context.temp_allocator)
	testing.expect(t, err == nil)
	scores := 0
	for e in files {
		if !strings.has_suffix(e.name, ".score") {continue}
		scores += 1
		stem := e.name[:len(e.name) - len(".score")]
		listed := false
		for f in MUSIC {listed ||= f.name == stem}
		testing.expectf(t, listed, "%s has no entry in MUSIC", e.name)
		for ext in ([]string{".ogg", ".json"}) {
			path := strings.concatenate({MUSIC_DIR, stem, ext}, context.temp_allocator)
			testing.expectf(t, os.exists(path), "%s%s is missing", stem, ext)
		}
	}
	testing.expect_value(t, scores, len(MUSIC))
	testing.expect_value(t, MUSIC[0].name, "title")
	_ = math.PI
	free_all(context.temp_allocator)
}
