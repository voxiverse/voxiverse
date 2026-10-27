package music_tool

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import "core:testing"

import "../../base"
import "../../client/audio"

PHRASE :: #load("testdata/phrase.score", string)

// ---- a synthetic soundfont, so no download is needed -----------------------

Test_Sample :: struct {
	name:                 string,
	data:                 []i16,
	rate:                 u32,
	loop_start, loop_end: u32, // within the sample
	root:                 u8,
	kind, link:           u16,
}

Test_Zone :: struct {
	gens: []Sf_Gen,
}

Test_Inst :: struct {
	name:  string,
	zones: []Test_Zone,
}

Test_Preset :: struct {
	name:         string,
	preset, bank: u16,
	zones:        []Test_Zone,
}

key_range :: proc(lo, hi: int) -> i16 {return i16(u16(lo) | u16(hi) << 8)}

timecents_of :: proc(seconds: f64) -> i16 {return i16(math.round(1200 * math.log2(seconds)))}

sf2_write :: proc(samples: []Test_Sample, insts: []Test_Inst, presets: []Test_Preset) -> []u8 {
	out: [dynamic]u8
	u16le :: proc(b: ^[dynamic]u8, v: u16) {append(b, u8(v), u8(v >> 8))}
	u32le :: proc(b: ^[dynamic]u8, v: u32) {u16le(b, u16(v)); u16le(b, u16(v >> 16))}
	name20 :: proc(b: ^[dynamic]u8, s: string) {
		for i in 0 ..< 20 {append(b, u8(s[i]) if i < len(s) else 0)}
	}
	chunk :: proc(dst: ^[dynamic]u8, id: string, body: []u8) {
		append(dst, id)
		u32le(dst, u32(len(body)))
		append(dst, ..body)
		if len(body) & 1 == 1 {append(dst, 0)}
	}
	list :: proc(dst: ^[dynamic]u8, kind: string, body: []u8) {
		inner: [dynamic]u8
		append(&inner, kind)
		append(&inner, ..body)
		chunk(dst, "LIST", inner[:])
	}

	info: [dynamic]u8
	{
		v: [dynamic]u8
		u16le(&v, 2)
		u16le(&v, 1)
		chunk(&info, "ifil", v[:])
		chunk(&info, "INAM", transmute([]u8)string("test font\x00"))
	}
	// The pool: each sample followed by 46 zero frames.
	pool: [dynamic]u8
	starts := make([]u32, len(samples))
	for s, i in samples {
		starts[i] = u32(len(pool) / 2)
		for v in s.data {u16le(&pool, u16(v))}
		for _ in 0 ..< 46 {u16le(&pool, 0)}
	}
	sdta: [dynamic]u8
	chunk(&sdta, "smpl", pool[:])

	pbag, pgen, phdr, ibag, igen, inst, shdr: [dynamic]u8
	zones_out :: proc(bag, gen: ^[dynamic]u8, zones: []Test_Zone, count: ^int, gens: ^int) {
		for z in zones {
			u16le(bag, u16(gens^))
			u16le(bag, 0)
			count^ += 1
			for g in z.gens {
				u16le(gen, g.op)
				u16le(gen, u16(g.amount))
				gens^ += 1
			}
		}
	}
	pb, pg, ib, ig: int
	for p in presets {
		name20(&phdr, p.name)
		u16le(&phdr, p.preset)
		u16le(&phdr, p.bank)
		u16le(&phdr, u16(pb))
		for _ in 0 ..< 3 {u32le(&phdr, 0)}
		zones_out(&pbag, &pgen, p.zones, &pb, &pg)
	}
	name20(&phdr, "EOP")
	u16le(&phdr, 0)
	u16le(&phdr, 0)
	u16le(&phdr, u16(pb))
	for _ in 0 ..< 3 {u32le(&phdr, 0)}
	u16le(&pbag, u16(pg))
	u16le(&pbag, 0)
	u16le(&pgen, 0)
	u16le(&pgen, 0)
	for i in insts {
		name20(&inst, i.name)
		u16le(&inst, u16(ib))
		zones_out(&ibag, &igen, i.zones, &ib, &ig)
	}
	name20(&inst, "EOI")
	u16le(&inst, u16(ib))
	u16le(&ibag, u16(ig))
	u16le(&ibag, 0)
	u16le(&igen, 0)
	u16le(&igen, 0)
	for s, i in samples {
		name20(&shdr, s.name)
		u32le(&shdr, starts[i])
		u32le(&shdr, starts[i] + u32(len(s.data)))
		u32le(&shdr, starts[i] + s.loop_start)
		u32le(&shdr, starts[i] + s.loop_end)
		u32le(&shdr, s.rate)
		append(&shdr, s.root, 0)
		u16le(&shdr, s.link)
		u16le(&shdr, s.kind)
	}
	name20(&shdr, "EOS")
	for _ in 0 ..< 5 {u32le(&shdr, 0)}
	for _ in 0 ..< 3 {u16le(&shdr, 0)} 	// pitch and correction, link, kind
	pdta: [dynamic]u8
	chunk(&pdta, "phdr", phdr[:])
	chunk(&pdta, "pbag", pbag[:])
	pmod: [dynamic]u8
	for _ in 0 ..< 10 {append(&pmod, 0)}
	chunk(&pdta, "pmod", pmod[:])
	chunk(&pdta, "pgen", pgen[:])
	chunk(&pdta, "inst", inst[:])
	chunk(&pdta, "ibag", ibag[:])
	chunk(&pdta, "imod", pmod[:])
	chunk(&pdta, "igen", igen[:])
	chunk(&pdta, "shdr", shdr[:])

	body: [dynamic]u8
	append(&body, "sfbk")
	list(&body, "INFO", info[:])
	list(&body, "sdta", sdta[:])
	list(&body, "pdta", pdta[:])
	append(&out, "RIFF")
	u32le(&out, u32(len(body)))
	append(&out, ..body[:])
	return out[:]
}

// synth_font: a looped sine (A4 = 440 Hz, key zones; an envelope), a decaying
// noise (velocity zones, a filter) and a stereo pair of A3.
synth_font :: proc() -> []u8 {
	sine := make([]i16, 4410)
	for i in 0 ..< len(sine) {sine[i] = i16(26000 * math.sin(2 * math.PI * 440 * f64(i) / 4410))}
	rng := base.rng_make(3)
	noise := make([]i16, 2205)
	for i in 0 ..< len(noise) {
		noise[i] = i16(20000 * (base.rng_f64(&rng) * 2 - 1) * math.exp(-f64(i) / 600))
	}
	low := make([]i16, 441)
	for i in 0 ..< len(low) {low[i] = i16(20000 * math.sin(2 * math.PI * 220 * f64(i) / 4410))}
	samples := []Test_Sample {
		{"sine", sine, 4410, 0, 4410, 69, 1, 0},
		{"noise", noise, 4410, 0, 0, 60, 1, 0},
		{"pair L", low, 4410, 0, 441, 57, 4, 3},
		{"pair R", low, 4410, 0, 441, 57, 2, 2},
	}
	insts := []Test_Inst {
		{
			"Sine",
			{
				{
					{
						{GEN_ATTACK, timecents_of(0.05)},
						{GEN_RELEASE, timecents_of(0.3)},
						{GEN_SAMPLE_MODES, 1},
					},
				},
				{{{GEN_KEY_RANGE, key_range(0, 71)}, {GEN_ROOT, 69}, {GEN_SAMPLE_ID, 0}}},
				{{{GEN_KEY_RANGE, key_range(72, 127)}, {GEN_ROOT, 69}, {GEN_SAMPLE_ID, 0}}},
			},
		},
		{
			"Noise",
			{
				{{{GEN_VEL_RANGE, key_range(0, 63)}, {GEN_FC, 9486}, {GEN_SAMPLE_ID, 1}}},
				{{{GEN_VEL_RANGE, key_range(64, 127)}, {GEN_SAMPLE_ID, 1}}},
			},
		},
		{
			"Pair",
			{
				{{{GEN_SAMPLE_MODES, 1}, {GEN_SAMPLE_ID, 2}}},
				{{{GEN_SAMPLE_MODES, 1}, {GEN_SAMPLE_ID, 3}}},
			},
		},
	}
	presets := []Test_Preset {
		{"Sine", 0, 0, {{{{GEN_FINE, 0}}}, {{{GEN_INSTRUMENT, 0}}}}},
		{"Noise", 1, 0, {{{{GEN_INSTRUMENT, 1}}}}},
		{"Pair", 2, 0, {{{{GEN_INSTRUMENT, 2}}}}},
	}
	return sf2_write(samples, insts, presets)
}

load_font :: proc(t: ^testing.T) -> (sf: Soundfont, ok: bool) {
	msg: string
	sf, msg, ok = sf2_read(synth_font())
	testing.expectf(t, ok, "the synthetic font does not read: %s", msg)
	return
}

// ---- the score --------------------------------------------------------------

@(test)
test_score_parses :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	p, err, ok := score_parse(PHRASE, "phrase.score")
	testing.expectf(t, ok, "phrase.score: %s", err)
	if !ok {return}
	testing.expect_value(t, p.title, "Test phrase")
	testing.expect_value(t, p.key, "d")
	testing.expect_value(t, p.mode, "dorian")
	testing.expect(t, p.loop)
	testing.expect_value(t, p.seed, 7)
	testing.expect_value(t, p.humanize_ms, 6)
	testing.expect_value(t, p.humanize_vel, 5)
	testing.expect_value(t, p.end, 4320)
	testing.expect_value(t, len(p.parts), 2)
	testing.expect_value(t, p.parts[1].volume_db, -3)
	testing.expect_value(t, p.parts[1].pan, -0.2)
	testing.expect(t, slice.equal(p.tempos[:], []Tempo{{0, 80}}))
	testing.expect(t, slice.equal(p.meters[:], []Meter{{0, 3, 4}}))
	want := []Note {
		{0, 480, 62, 49, 0},
		{0, 1440, 50, 49, 1},
		{480, 480, 65, 49, 0},
		{960, 480, 69, 49, 0},
		{1440, 1440, 60, 49, 0},
		{1440, 1440, 64, 49, 0},
		{1440, 1440, 67, 49, 0},
		{1440, 1440, 45, 49, 1},
		{2880, 240, 74, 49, 0},
		{2880, 960, 50, 49, 1},
		{3120, 240, 72, 49, 0},
		{3360, 960, 69, 49, 0}, // the tie, merged
	}
	testing.expect(t, slice.equal(p.notes[:], want), fmt.tprintf("notes: %v", p.notes))
	testing.expect(
		t,
		slice.equal(p.pedals[:], []Pedal{{2880, 0, true}, {4320, 0, false}}),
		fmt.tprintf("pedals: %v", p.pedals),
	)

	// A repeat plays its bars again; the second playing starts a bar later.
	header := "meter 3/4\ninstrument i preset 0:0\npart a i\n"
	q, qerr, qok := score_parse(
		strings.concatenate({header, "  |: d4:h. :|x3 | r:h. |\n"}),
		"r.score",
	)
	testing.expectf(t, qok, "repeat: %s", qerr)
	testing.expect_value(t, len(q.notes), 3)
	testing.expect_value(t, q.end, 4 * 1440)
	testing.expect_value(t, q.notes[2].start, 2880)

	// Errors name the file, line and column.
	cases := []struct {
		src, msg: string,
		needle:   string, // where the error points
	} {
		{
			"meter 3/4\ninstrument i preset 0:0\npart a i\n  d4:q f4 |\n",
			"bar 1 has 2 beats, the meter 3/4 wants 3",
			"|",
		},
		{"bogus 1\n", "unknown word 'bogus'", "bogus"},
		{
			"instrument i preset 0:0\npart a nope\n  d4:w |\n",
			"instrument 'nope' is not declared",
			"nope",
		},
		{
			"instrument i preset 0:0\npart a i\n  |: d4:w |: d4:w :| :|\n",
			"repeats do not nest",
			"|: d4:w :|",
		},
		{"instrument i preset 0:0\npart a i\n  d4:w wat |\n", "unknown word 'wat'", "wat"},
		{"instrument i preset 0:0\npart a i\n  d4:w~ | e4:w |\n", "tie to nothing", "d4:w~"},
	}
	for c in cases {
		_, e, eok := score_parse(c.src, "e.score")
		testing.expect(t, !eok, c.src)
		// Find the line and column of the needle (the second match for the nested repeat).
		line, col := 1, 1
		at := strings.index(c.src, c.needle)
		if c.needle == "|: d4:w :|" {at = strings.index(c.src, "|: d4:w |:") + 8}
		for i in 0 ..< at {
			if c.src[i] == '\n' {line += 1; col = 1} else {col += 1}
		}
		want := fmt.tprintf("e.score:%d:%d: %s", line, col, c.msg)
		testing.expectf(t, strings.has_prefix(e, want), "got '%s', wanted '%s'", e, want)
	}
}

// ---- MIDI -------------------------------------------------------------------

@(test)
test_midi_round_trip :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	p, _, _ := score_parse(PHRASE, "phrase.score")
	bytes := midi_write(&p)
	q, err, ok := midi_read(bytes)
	testing.expectf(t, ok, "read back: %s", err)
	if !ok {return}
	testing.expect(t, slice.equal(q.notes[:], p.notes[:]), fmt.tprintf("notes: %v", q.notes))
	testing.expect(t, slice.equal(q.pedals[:], p.pedals[:]), fmt.tprintf("pedals: %v", q.pedals))
	testing.expect(t, slice.equal(q.tempos[:], p.tempos[:]))
	testing.expect(t, slice.equal(q.meters[:], p.meters[:]))
	testing.expect_value(t, q.end, p.end)
	testing.expect_value(t, len(q.parts), 2)
	testing.expect_value(t, q.parts[1].program, 0)
	testing.expect(t, abs(q.parts[1].pan - -0.2) < 0.02)
	testing.expect(t, abs(q.parts[1].volume_db - -3) < 0.2)

	// A format 0 file, by hand: running status, and a note off as velocity 0.
	track := []u8 {
		0x00,
		0xff,
		0x51,
		0x03,
		0x07,
		0xa1,
		0x20, // 120 bpm
		0x00,
		0x90,
		0x3c,
		0x64, // key 60 on
		0x83,
		0x60,
		0x3c,
		0x00, // running status: off 480 later
		0x00,
		0x3e,
		0x50, // key 62 on
		0x83,
		0x60,
		0x3e,
		0x00, // off
		0x00,
		0xff,
		0x2f,
		0x00,
	}
	file :: proc(division: []u8, track: []u8, format: u8 = 0) -> []u8 {
		out: [dynamic]u8
		append(&out, "MThd")
		append(&out, 0, 0, 0, 6, 0, format, 0, 1)
		append(&out, ..division)
		append(&out, "MTrk")
		append(&out, 0, 0, 0, u8(len(track)))
		append(&out, ..track)
		return out[:]
	}
	r, rerr, rok := midi_read(file({0x01, 0xe0}, track))
	testing.expectf(t, rok, "format 0: %s", rerr)
	testing.expect(
		t,
		slice.equal(r.notes[:], []Note{{0, 480, 60, 100, 0}, {480, 480, 62, 80, 0}}),
		fmt.tprintf("%v", r.notes),
	)
	testing.expect(t, slice.equal(r.tempos[:], []Tempo{{0, 120}}))
	// A division of 960 is rescaled to 480.
	r2, _, _ := midi_read(file({0x03, 0xc0}, track))
	testing.expect_value(t, r2.notes[1].start, 240)
	// Refused: truncated, SMPTE, drums.
	whole := file({0x01, 0xe0}, track)
	_, _, tok := midi_read(whole[:len(whole) - 6])
	testing.expect(t, !tok)
	_, _, sok := midi_read(file({0xe7, 0x28}, track))
	testing.expect(t, !sok)
	drums := slice.clone(track)
	drums[8] = 0x99
	_, _, dok := midi_read(file({0x01, 0xe0}, drums))
	testing.expect(t, !dok)
	for n in 0 ..< len(whole) {
		_, _, _ = midi_read(whole[:n]) // no crash
	}
}

// ---- the soundfont ----------------------------------------------------------

@(test)
test_sf2_reads :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	font := synth_font()
	sf, msg, ok := sf2_read(font)
	testing.expectf(t, ok, "reads: %s", msg)
	if !ok {return}
	testing.expect_value(t, sf.name, "test font")
	testing.expect_value(t, len(sf.presets), 3)
	testing.expect_value(t, len(sf.instruments), 3)
	testing.expect_value(t, len(sf.samples), 4)
	testing.expect_value(t, sf.presets[1].name, "Noise")
	testing.expect_value(t, sf.presets[2].preset, 2)
	testing.expect_value(t, len(sf.presets[0].zones), 2)
	testing.expect_value(t, len(sf.instruments[0].zones), 3)
	g := sf.instruments[0].zones[2].gens
	testing.expect(
		t,
		slice.equal(
			g,
			[]Sf_Gen{{GEN_KEY_RANGE, key_range(72, 127)}, {GEN_ROOT, 69}, {GEN_SAMPLE_ID, 0}},
		),
	)
	testing.expect_value(t, sf.samples[0].rate, 4410)
	testing.expect_value(t, sf.samples[0].end, 4410)
	testing.expect_value(t, sf.samples[2].kind, 4)
	testing.expect_value(t, sf.samples[3].link, 2)
	testing.expect(
		t,
		abs(sf.data[110] - f32(26000 * math.sin(2 * math.PI * 440 * 110 / 4410) / 32768)) < 1e-4,
	)

	zones: [dynamic]Zone_Params
	sf_zones(&sf, 0, 69, 100, &zones)
	testing.expect_value(t, len(zones), 1)
	testing.expect(t, abs(zones[0].semitones) < 1e-9)
	testing.expect(t, abs(zones[0].attack - 0.05) < 0.0005)
	testing.expect(t, abs(zones[0].release - 0.3) < 0.003)
	testing.expect_value(t, zones[0].mode, 1)
	clear(&zones)
	sf_zones(&sf, 0, 81, 100, &zones)
	testing.expect(t, len(zones) == 1 && abs(zones[0].semitones - 12) < 1e-9)
	clear(&zones)
	sf_zones(&sf, 1, 60, 30, &zones)
	testing.expect(t, len(zones) == 1 && zones[0].fc_cents < 9486)
	clear(&zones)
	sf_zones(&sf, 1, 60, 100, &zones)
	testing.expect(t, len(zones) == 1 && zones[0].fc_cents == 13500)
	clear(&zones)
	sf_zones(&sf, 2, 57, 100, &zones)
	testing.expect(t, len(zones) == 2 && zones[0].pan == -1 && zones[1].pan == 1)

	// Damage: every truncated prefix, and seeded byte flips, are refused or read
	// without a crash (and what reads can be resolved).
	probe :: proc(data: []u8) {
		sf, _, ok := sf2_read(data)
		if !ok {return}
		zones: [dynamic]Zone_Params
		for pi in 0 ..< len(sf.presets) {
			for key in ([]int{0, 60, 69, 127}) {
				for vel in ([]int{1, 64, 127}) {sf_zones(&sf, pi, key, vel, &zones)}
			}
		}
	}
	for n in 0 ..< len(font) {
		probe(font[:n])
		free_all(context.temp_allocator)
	}
	rng := base.rng_make(99)
	for _ in 0 ..< 1000 {
		bad := slice.clone(font)
		at := base.rng_int_max(&rng, len(bad))
		bad[at] = u8(base.rng_u32(&rng))
		probe(bad)
		free_all(context.temp_allocator)
	}
}

// ---- the renderer -----------------------------------------------------------

fnv1a :: proc(x: []f32) -> u64 {
	h: u64 = 0xcbf29ce484222325
	for v in x {
		b := transmute(u32)v
		for i in 0 ..< 4 {
			h ~= u64((b >> (8 * u32(i))) & 0xff)
			h *= 0x100000001b3
		}
	}
	return h
}

RENDER_GOLDEN :: 0x237615ce2dcd133

// The phrase's third-octave bands in dB (power), each OS within 1 dB.
RENDER_BANDS := [audio.BANDS]f64 {
	-100.69,
	-94.63,
	-85.55,
	-37.11,
	-57.73,
	-34.54,
	-84.19,
	-36.49,
	-29.93,
	-29.61,
	-34.75,
	-34.47,
	-100.43,
	-109.81,
	-116.81,
	-121.23,
	-125.81,
	-129.74,
	-133.72,
	-137.24,
	-140.32,
	-143.08,
	-145.73,
	-147.99,
}

@(test)
test_render_deterministic :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	sf, ok := load_font(t)
	if !ok {return}
	p, _, _ := score_parse(PHRASE, "phrase.score")
	a := render(&p, &sf)
	b := render(&p, &sf)
	testing.expect(t, slice.equal(a, b), "two renders differ")
	hash := fnv1a(a)
	when ODIN_OS == .Linux {
		testing.expectf(t, hash == RENDER_GOLDEN, "RENDER_GOLDEN :: 0x%x", hash)
	}
	bands := audio.third_octaves(a, RATE)
	for v, i in bands {
		if v < -60 && RENDER_BANDS[i] < -60 {continue} 	// too faint to hold across OSes
		testing.expectf(
			t,
			abs(v - RENDER_BANDS[i]) < 1,
			"band %d: %.2f dB, held %.2f",
			i,
			v,
			RENDER_BANDS[i],
		)
	}
	if t.error_count > 0 {
		fmt.printfln("RENDER_BANDS := %v", bands)
	}
}

one_note :: proc(key: u8, length: u32) -> Piece {
	p := piece_defaults()
	p.reverb_wet = 0
	append(&p.parts, Part{name = "a"})
	append(&p.notes, Note{0, length, key, 127, 0})
	append(&p.tempos, Tempo{0, 120})
	append(&p.meters, Meter{0, 4, 4})
	p.end = 1920
	return p
}

// pitch_of: the frequency of a steady tone from its upward zero crossings
// between two times, by linear interpolation.
pitch_of :: proc(x: []f32, from, to: f64) -> f64 {
	first, last: f64
	n := 0
	for i := int(from * RATE); i < int(to * RATE) - 1; i += 1 {
		a, b := x[2 * i], x[2 * (i + 1)]
		if a < 0 && b >= 0 {
			at := f64(i) + f64(-a) / f64(b - a)
			if n == 0 {first = at}
			last = at
			n += 1
		}
	}
	return f64(n - 1) * RATE / (last - first)
}

@(test)
test_render_pitch_and_envelope :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	sf, ok := load_font(t)
	if !ok {return}
	for c in ([]struct {
			key: u8,
			hz:  f64,
		}{{69, 440}, {81, 880}, {57, 220}}) {
		p := one_note(c.key, 960)
		x := render(&p, &sf)
		hz := pitch_of(x, 0.2, 0.7)
		cents := 1200 * math.log2(hz / c.hz)
		testing.expectf(
			t,
			abs(cents) < 1,
			"key %d: %.4f Hz, %.3f cents off %.0f",
			c.key,
			hz,
			cents,
			c.hz,
		)
	}
	// The envelope straight from the generators: the attack, and the release's -60 dB.
	zones: [dynamic]Zone_Params
	sf_zones(&sf, 0, 69, 127, &zones)
	e: Envelope
	envelope_init(&e, zones[0], RATE)
	frames := 0
	for e.gain < 1 {
		envelope_next(&e)
		frames += 1
	}
	testing.expectf(t, abs(f64(frames) / RATE - 0.05) < 0.002, "attack %d frames", frames)
	for _ in 0 ..< 100 {envelope_next(&e)}
	envelope_release(&e)
	frames = 0
	for e.gain > 0.001 {
		envelope_next(&e)
		frames += 1
	}
	testing.expectf(
		t,
		abs(f64(frames) / RATE - 0.18) < 0.002,
		"release to -60 dB: %d frames",
		frames,
	)
	// And in the render: half way up the attack the tone is about half as loud.
	p := one_note(69, 960)
	x := render(&p, &sf)
	peak :: proc(x: []f32, from, to: int) -> f32 {
		m: f32
		for i in from ..< to {m = max(m, abs(x[2 * i]), abs(x[2 * i + 1]))}
		return m
	}
	full := peak(x, 24000, 26000)
	half := peak(x, 1150, 1250) // 25 ms
	testing.expectf(t, abs(half / full - 0.5) < 0.1, "attack half way: %.3f of full", half / full)
	// The note ends: silence a second after its release.
	testing.expect(t, len(x) / 2 < 48000 + 25000 || peak(x, 48000 + 24000, 48000 + 25000) < 1e-4)
}

@(test)
test_master_loops :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	sf, ok := load_font(t)
	if !ok {return}
	p, _, _ := score_parse(PHRASE, "phrase.score")
	p.reverb_rt60, p.reverb_wet = 4, 0.4
	m, mok := master(&p, render(&p, &sf))
	testing.expect(t, mok)
	if !mok {return}
	x := m.stereo
	n := m.frames
	testing.expect_value(t, n, m.loop_end)
	testing.expect_value(t, n, int(ticks_to_seconds(&p, f64(p.end)) * RATE + 0.5))
	seam: f32
	for c in 0 ..< 2 {seam = max(seam, abs(x[2 * (n - 1) + c] - x[c]))}
	near: f32
	span := RATE / 100
	for i in 0 ..< span {
		for c in 0 ..< 2 {
			near = max(near, abs(x[2 * (i + 1) + c] - x[2 * i + c]))
			j := n - 1 - i
			near = max(near, abs(x[2 * j + c] - x[2 * (j - 1) + c]))
		}
	}
	testing.expectf(
		t,
		seam <= 1.5 * near,
		"the seam steps %.6f, neighbours step up to %.6f",
		seam,
		near,
	)
	testing.expectf(t, abs(m.lufs - MUSIC_LUFS) < 0.1, "loudness %.2f", m.lufs)
	testing.expect(t, m.true_peak_db <= -1)

	// A one-shot is trimmed after its last audible sample.
	q := one_note(69, 480)
	q.reverb_wet = 0
	r := render(&q, &sf)
	mq, qok := master(&q, r)
	testing.expect(t, qok && mq.loop_end == 0 && mq.frames < len(r) / 2 && mq.frames > 24000)
}

@(test)
test_json_round_trip :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	p, _, _ := score_parse(PHRASE, "phrase.score")
	m := Mastered {
		frames       = 172800,
		loop_end     = 172800,
		lufs         = -20.0004,
		true_peak_db = -3.2,
		stereo       = nil,
	}
	text := metadata_json(&p, m, Meta{"phrase.score", "ab12", "cd34", 48000})
	v, err := json.parse(transmute([]u8)text, parse_integers = true)
	testing.expectf(t, err == nil, "the metadata does not parse: %v\n%s", err, text)
	if err != nil {return}
	o := v.(json.Object)
	testing.expect_value(t, o["title"].(json.String), "Test phrase")
	testing.expect_value(t, o["source"].(json.String), "phrase.score")
	testing.expect_value(t, o["source_sha256"].(json.String), "ab12")
	testing.expect_value(t, o["soundfont_sha256"].(json.String), "cd34")
	testing.expect_value(t, o["rate"].(json.Integer), 48000)
	testing.expect_value(t, o["channels"].(json.Integer), 2)
	testing.expect_value(t, o["frames"].(json.Integer), 172800)
	testing.expect_value(t, o["loop"].(json.Boolean), true)
	testing.expect_value(t, o["loop_start"].(json.Integer), 0)
	testing.expect_value(t, o["loop_end"].(json.Integer), 172800)
	testing.expect_value(t, o["seconds"].(json.Float), 3.6)
	testing.expect_value(t, o["lufs"].(json.Float), -20.0)
	testing.expect_value(t, o["true_peak_db"].(json.Float), -3.2)
	testing.expect_value(t, o["key"].(json.String), "d dorian")
	testing.expect_value(t, o["tempo"].(json.Integer), 80)
	testing.expect_value(t, o["mood"].(json.Array)[0].(json.String), "calm")
	testing.expect_value(t, o["worlds"].(json.Array)[0].(json.String), "any")
	// Keys in the written order.
	last := -1
	for k in ([]string{"title", "source", "source_sha256", "soundfont_sha256", "rate", "channels", "frames", "seconds", "loop", "loop_start", "loop_end", "lufs", "true_peak_db", "key", "tempo", "mood", "place", "time", "depth", "worlds"}) {
		at := strings.index(text, fmt.tprintf("\"%s\":", k))
		testing.expectf(t, at > last, "key %s is out of order", k)
		last = at
	}
}
