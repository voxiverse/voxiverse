package music_tool

import "core:math"

// SoundFont 2.01, the subset in docs/history.md (M43): read into zones, then
// resolved for a key and velocity into the numbers a voice needs. Every index
// is checked before use: a damaged file is an error, never a crash.

Sf_Gen :: struct {
	op:     u16,
	amount: i16,
}

Sf_Zone :: struct {
	gens: []Sf_Gen,
}

Sf_Preset :: struct {
	name:         string,
	preset, bank: u16,
	zones:        []Sf_Zone,
}

Sf_Instrument :: struct {
	name:  string,
	zones: []Sf_Zone,
}

Sf_Sample :: struct {
	name:                             string,
	start, end, loop_start, loop_end: u32, // frames into the sample data
	rate:                             u32,
	pitch:                            u8,
	correction:                       i8,
	link, kind:                       u16,
}

Soundfont :: struct {
	name:        string,
	data:        []f32, // the 16-bit sample pool
	presets:     []Sf_Preset,
	instruments: []Sf_Instrument,
	samples:     []Sf_Sample,
}

// Generator numbers.
GEN_START :: 0
GEN_END :: 1
GEN_START_LOOP :: 2
GEN_END_LOOP :: 3
GEN_START_COARSE :: 4
GEN_FC :: 8
GEN_Q :: 9
GEN_END_COARSE :: 12
GEN_PAN :: 17
GEN_DELAY :: 33
GEN_ATTACK :: 34
GEN_HOLD :: 35
GEN_DECAY :: 36
GEN_SUSTAIN :: 37
GEN_RELEASE :: 38
GEN_KEY_HOLD :: 39
GEN_KEY_DECAY :: 40
GEN_INSTRUMENT :: 41
GEN_KEY_RANGE :: 43
GEN_VEL_RANGE :: 44
GEN_START_LOOP_COARSE :: 45
GEN_KEYNUM :: 46
GEN_VELOCITY :: 47
GEN_ATTENUATION :: 48
GEN_END_LOOP_COARSE :: 50
GEN_COARSE :: 51
GEN_FINE :: 52
GEN_SAMPLE_ID :: 53
GEN_SAMPLE_MODES :: 54
GEN_SCALE :: 56
GEN_EXCLUSIVE :: 57
GEN_ROOT :: 58
GEN_COUNT :: 64

@(private = "file")
le16 :: proc(b: []u8, at: int) -> u16 {return u16(b[at]) | u16(b[at + 1]) << 8}

@(private = "file")
le32 :: proc(b: []u8, at: int) -> u32 {return u32(le16(b, at)) | u32(le16(b, at + 2)) << 16}

@(private = "file")
Chunk :: struct {
	id:   string,
	kind: string, // of a LIST
	body: []u8, // of a LIST: after its type
}

// chunks splits a run of RIFF chunks; a chunk that runs past the end is an error.
@(private = "file")
chunks :: proc(b: []u8) -> (out: [dynamic]Chunk, ok: bool) {
	at := 0
	for at < len(b) {
		if at + 8 > len(b) {return}
		size := int(le32(b, at + 4))
		if at + 8 + size > len(b) {return}
		c := Chunk {
			id   = string(b[at:at + 4]),
			body = b[at + 8:at + 8 + size],
		}
		if c.id == "LIST" {
			if size < 4 {return}
			c.kind, c.body = string(c.body[:4]), c.body[4:]
		}
		append(&out, c)
		at += 8 + size + (size & 1)
	}
	return out, true
}

@(private = "file")
name_of :: proc(b: []u8) -> string {
	n := 0
	for n < 20 && b[n] != 0 {n += 1}
	return string(b[:n])
}

@(private = "file")
cstr :: proc(b: []u8) -> string {
	n := 0
	for n < len(b) && b[n] != 0 {n += 1}
	return string(b[:n])
}

// zones_of builds the zones of one list entry (preset or instrument) from its
// bag range; gen_count bounds the generator index of every bag.
@(private = "file")
zones_of :: proc(bags: []int, gens: []Sf_Gen, first, last: int) -> (zones: []Sf_Zone, ok: bool) {
	if first > last || last >= len(bags) {return}
	out := make([]Sf_Zone, last - first)
	for z in first ..< last {
		a, b := bags[z], bags[z + 1]
		if a > b || b > len(gens) {return}
		out[z - first] = Sf_Zone{gens[a:b]}
	}
	return out, true
}

// sf2_read parses a SoundFont file.
sf2_read :: proc(file: []u8) -> (sf: Soundfont, err: string, ok: bool) {
	bad :: proc(msg: string) -> (Soundfont, string, bool) {return {}, msg, false}
	if len(file) < 12 || string(file[:4]) != "RIFF" || string(file[8:12]) != "sfbk" {
		return bad("not a SoundFont (RIFF sfbk)")
	}
	if int(le32(file, 4)) + 8 > len(file) {return bad("the SoundFont is truncated")}
	top, tok := chunks(file[12:8 + int(le32(file, 4))])
	if !tok {return bad("the SoundFont is truncated")}
	smpl: []u8
	pdta: map[string][]u8
	have_pdta := false
	for c in top {
		if c.id != "LIST" {continue}
		sub, sok := chunks(c.body)
		if !sok {return bad("a SoundFont list is truncated")}
		switch c.kind {
		case "INFO":
			for s in sub {
				if s.id == "INAM" {sf.name = cstr(s.body)}
			}
		case "sdta":
			for s in sub {
				if s.id == "smpl" {smpl = s.body}
			}
		case "pdta":
			have_pdta = true
			for s in sub {pdta[s.id] = s.body}
		}
	}
	if !have_pdta {return bad("the SoundFont has no pdta list")}
	get :: proc(
		pdta: map[string][]u8,
		id: string,
		size: int,
	) -> (
		body: []u8,
		count: int,
		ok: bool,
	) {
		body = pdta[id] or_return
		if len(body) % size != 0 || len(body) < size {return nil, 0, false}
		return body, len(body) / size, true
	}
	phdr, nph, ok1 := get(pdta, "phdr", 38)
	pbag, npb, ok2 := get(pdta, "pbag", 4)
	pgen, npg, ok3 := get(pdta, "pgen", 4)
	inst, nin, ok4 := get(pdta, "inst", 22)
	ibag, nib, ok5 := get(pdta, "ibag", 4)
	igen, nig, ok6 := get(pdta, "igen", 4)
	shdr, nsh, ok7 := get(pdta, "shdr", 46)
	_, _, ok8 := get(pdta, "pmod", 10)
	_, _, ok9 := get(pdta, "imod", 10)
	if !(ok1 && ok2 && ok3 && ok4 && ok5 && ok6 && ok7 && ok8 && ok9) {
		return bad("a SoundFont list is missing, empty or has records of the wrong size")
	}
	if len(smpl) % 2 != 0 {return bad("the sample pool has an odd size")}
	sf.data = make([]f32, len(smpl) / 2)
	for i in 0 ..< len(sf.data) {sf.data[i] = f32(i16(le16(smpl, 2 * i))) / 32768}

	read_gens :: proc(b: []u8, n: int) -> []Sf_Gen {
		out := make([]Sf_Gen, n)
		for i in 0 ..< n {out[i] = Sf_Gen{le16(b, 4 * i), i16(le16(b, 4 * i + 2))}}
		return out
	}
	read_bags :: proc(b: []u8, n: int) -> []int {
		out := make([]int, n)
		for i in 0 ..< n {out[i] = int(le16(b, 4 * i))}
		return out
	}
	pgens, igens := read_gens(pgen, npg), read_gens(igen, nig)
	pbags, ibags := read_bags(pbag, npb), read_bags(ibag, nib)

	sf.samples = make([]Sf_Sample, nsh - 1)
	for i in 0 ..< nsh - 1 {
		r := shdr[46 * i:46 * i + 46]
		s := Sf_Sample {
			name       = name_of(r),
			start      = le32(r, 20),
			end        = le32(r, 24),
			loop_start = le32(r, 28),
			loop_end   = le32(r, 32),
			rate       = le32(r, 36),
			pitch      = r[40],
			correction = i8(r[41]),
			link       = le16(r, 42),
			kind       = le16(r, 44),
		}
		if s.kind & 0x8000 == 0 && (s.start > s.end || int(s.end) > len(sf.data)) {
			return bad("a sample lies outside the sample pool")
		}
		sf.samples[i] = s
	}

	sf.instruments = make([]Sf_Instrument, nin - 1)
	for i in 0 ..< nin - 1 {
		r := inst[22 * i:22 * i + 44]
		first, last := int(le16(r, 20)), int(le16(r, 42))
		zones, zok := zones_of(ibags, igens, first, last)
		if !zok {return bad("an instrument's zones are out of range")}
		sf.instruments[i] = {name_of(r), zones}
	}
	sf.presets = make([]Sf_Preset, nph - 1)
	for i in 0 ..< nph - 1 {
		r := phdr[38 * i:38 * i + 76]
		first, last := int(le16(r, 24)), int(le16(r, 62))
		zones, zok := zones_of(pbags, pgens, first, last)
		if !zok {return bad("a preset's zones are out of range")}
		sf.presets[i] = {name_of(r), le16(r, 20), le16(r, 22), zones}
	}
	// A zone's own references must point at something.
	for p in sf.presets {
		for z in p.zones {
			for g in z.gens {
				if g.op == GEN_INSTRUMENT &&
				   (g.amount < 0 || int(g.amount) >= len(sf.instruments)) {
					return bad("a preset zone names an instrument that does not exist")
				}
			}
		}
	}
	for ins in sf.instruments {
		for z in ins.zones {
			for g in z.gens {
				if g.op == GEN_SAMPLE_ID && (g.amount < 0 || int(g.amount) >= len(sf.samples)) {
					return bad("an instrument zone names a sample that does not exist")
				}
			}
		}
	}
	return sf, "", true
}

// Zone_Params: one sounding zone for one key and velocity, in plain units.
Zone_Params :: struct {
	sample:                           int,
	start, end, loop_start, loop_end: int, // frames in the pool
	mode:                             int, // 0 no loop, 1 loop, 3 loop, then play on at release
	semitones:                        f64, // pitch of the key, in semitones from the sample's own
	rate:                             f64, // the sample's rate
	delay, attack, hold, decay:       f64, // seconds
	release:                          f64,
	sustain:                          f64, // linear gain
	gain_db:                          f64, // attenuation as a negative dB
	fc_cents, q_cb:                   f64,
	pan:                              f64, // -1 .. 1
	exclusive:                        int,
}

@(private = "file")
Gen_Table :: struct {
	v:   [GEN_COUNT]i32,
	set: [GEN_COUNT]bool,
}

@(private = "file")
defaults :: proc() -> (t: Gen_Table) {
	t.v[GEN_FC] = 13500
	for g in ([?]int{GEN_DELAY, GEN_ATTACK, GEN_HOLD, GEN_DECAY, GEN_RELEASE}) {t.v[g] = -12000}
	t.v[GEN_KEYNUM] = -1
	t.v[GEN_VELOCITY] = -1
	t.v[GEN_SCALE] = 100
	t.v[GEN_ROOT] = -1
	return
}

@(private = "file")
apply :: proc(t: ^Gen_Table, z: Sf_Zone) {
	for g in z.gens {
		if int(g.op) < GEN_COUNT {
			t.v[g.op] = i32(g.amount)
			t.set[g.op] = true
		}
	}
}

@(private = "file")
in_range :: proc(z: Sf_Zone, gen: u16, x: int) -> bool {
	for g in z.gens {
		if g.op == gen {
			v := u16(g.amount)
			return x >= int(v & 0xff) && x <= int(v >> 8)
		}
	}
	return true
}

@(private = "file")
is_global :: proc(zones: []Sf_Zone, i: int, terminal: u16) -> bool {
	if i != 0 {return false}
	z := zones[0]
	return len(z.gens) == 0 || z.gens[len(z.gens) - 1].op != terminal
}

@(private = "file")
timecents :: proc(tc: i32) -> f64 {
	if tc <= -12000 {return 0}
	return math.pow(2, f64(min(tc, 8000)) / 1200)
}

// sf_find_preset: the preset for bank:program, else the same program in bank
// 0, else the first preset (-1 for a font without presets).
sf_find_preset :: proc(sf: ^Soundfont, bank: u16, program: u8) -> int {
	for p, i in sf.presets {
		if p.bank == bank && p.preset == u16(program) {return i}
	}
	for p, i in sf.presets {
		if p.bank == 0 && p.preset == u16(program) {return i}
	}
	return 0 if len(sf.presets) > 0 else -1
}

// sf_zones resolves the zones of preset `pi` that sound for key and velocity.
sf_zones :: proc(sf: ^Soundfont, pi: int, key, vel: int, out: ^[dynamic]Zone_Params) {
	if pi < 0 || pi >= len(sf.presets) {return}
	preset := sf.presets[pi]
	pglobal: Gen_Table
	if len(preset.zones) > 0 &&
	   is_global(preset.zones, 0, GEN_INSTRUMENT) {apply(&pglobal, preset.zones[0])}
	for pz, pzi in preset.zones {
		if is_global(preset.zones, pzi, GEN_INSTRUMENT) {continue}
		inst_id := -1
		for g in pz.gens {
			if g.op == GEN_INSTRUMENT {inst_id = int(g.amount)}
		}
		if inst_id < 0 || inst_id >= len(sf.instruments) {continue}
		if !in_range(pz, GEN_KEY_RANGE, key) || !in_range(pz, GEN_VEL_RANGE, vel) {continue}
		ptable := pglobal
		apply(&ptable, pz)
		inst := sf.instruments[inst_id]
		iglobal := defaults()
		if len(inst.zones) > 0 &&
		   is_global(inst.zones, 0, GEN_SAMPLE_ID) {apply(&iglobal, inst.zones[0])}
		for iz, izi in inst.zones {
			if is_global(inst.zones, izi, GEN_SAMPLE_ID) {continue}
			if !in_range(iz, GEN_KEY_RANGE, key) || !in_range(iz, GEN_VEL_RANGE, vel) {continue}
			t := iglobal
			apply(&t, iz)
			if !t.set[GEN_SAMPLE_ID] {continue}
			zp, zok := zone_params(sf, &t, &ptable, key, vel)
			if zok {append(out, zp)}
		}
	}
}

@(private = "file")
zone_params :: proc(
	sf: ^Soundfont,
	t, p: ^Gen_Table,
	key, vel: int,
) -> (
	z: Zone_Params,
	ok: bool,
) {
	sid := int(t.v[GEN_SAMPLE_ID])
	if sid < 0 || sid >= len(sf.samples) {return}
	s := sf.samples[sid]
	if s.kind & 0x8000 != 0 {return} 	// ROM samples
	// Preset generators add to the instrument's, except those that are the
	// instrument's alone.
	g :: proc(t, p: ^Gen_Table, i: int) -> i32 {
		switch i {
		case GEN_START,
		     GEN_END,
		     GEN_START_LOOP,
		     GEN_END_LOOP,
		     GEN_START_COARSE,
		     GEN_END_COARSE,
		     GEN_START_LOOP_COARSE,
		     GEN_END_LOOP_COARSE,
		     GEN_KEYNUM,
		     GEN_VELOCITY,
		     GEN_SAMPLE_MODES,
		     GEN_EXCLUSIVE,
		     GEN_ROOT,
		     GEN_SCALE:
			return t.v[i]
		}
		return t.v[i] + p.v[i]
	}
	k, v := key, vel
	if t.v[GEN_KEYNUM] >= 0 {k = int(t.v[GEN_KEYNUM])}
	if t.v[GEN_VELOCITY] > 0 {v = int(t.v[GEN_VELOCITY])}
	v = clamp(v, 1, 127)
	pool := len(sf.data)
	z.sample = sid
	z.start = int(s.start) + int(t.v[GEN_START]) + 32768 * int(t.v[GEN_START_COARSE])
	z.end = int(s.end) + int(t.v[GEN_END]) + 32768 * int(t.v[GEN_END_COARSE])
	z.loop_start =
		int(s.loop_start) + int(t.v[GEN_START_LOOP]) + 32768 * int(t.v[GEN_START_LOOP_COARSE])
	z.loop_end = int(s.loop_end) + int(t.v[GEN_END_LOOP]) + 32768 * int(t.v[GEN_END_LOOP_COARSE])
	z.end = clamp(z.end, 0, pool)
	z.start = clamp(z.start, 0, z.end)
	z.loop_start = clamp(z.loop_start, z.start, z.end)
	z.loop_end = clamp(z.loop_end, z.loop_start, z.end)
	z.mode = int(t.v[GEN_SAMPLE_MODES]) & 3
	if z.mode == 2 {z.mode = 0}
	if z.loop_end - z.loop_start < 2 {z.mode = 0}
	if z.end - z.start < 1 {return}
	root := int(s.pitch) if s.pitch < 128 else 60
	if t.v[GEN_ROOT] >= 0 {root = int(t.v[GEN_ROOT])}
	scale := f64(t.v[GEN_SCALE])
	z.semitones =
		f64(k - root) * scale / 100 +
		f64(g(t, p, GEN_COARSE)) +
		(f64(g(t, p, GEN_FINE)) + f64(s.correction)) / 100
	z.rate = f64(s.rate) if s.rate > 0 else 44100
	z.delay = timecents(g(t, p, GEN_DELAY))
	z.attack = timecents(g(t, p, GEN_ATTACK))
	z.hold = timecents(g(t, p, GEN_HOLD) + i32(60 - k) * g(t, p, GEN_KEY_HOLD))
	z.decay = timecents(g(t, p, GEN_DECAY) + i32(60 - k) * g(t, p, GEN_KEY_DECAY))
	z.release = timecents(g(t, p, GEN_RELEASE))
	z.sustain = math.pow(10, -f64(clamp(g(t, p, GEN_SUSTAIN), 0, 1440)) / 200)
	// The default velocity-to-attenuation modulator (concave, 960 cB at most).
	vel_cb := min(400 * math.log10(127 / f64(v)), 960)
	z.gain_db = -(f64(max(g(t, p, GEN_ATTENUATION), 0)) + vel_cb) / 10
	z.fc_cents = f64(g(t, p, GEN_FC))
	// The default velocity-to-filter modulator: down to -2400 cents below velocity 64.
	if v < 64 {z.fc_cents -= 2400 * f64(64 - v) / 64}
	z.q_cb = f64(max(g(t, p, GEN_Q), 0))
	z.pan = clamp(f64(g(t, p, GEN_PAN)) / 500, -1, 1)
	switch s.kind & 0x7fff {
	case 2:
		z.pan = 1
	case 4:
		z.pan = -1
	}
	z.exclusive = int(t.v[GEN_EXCLUSIVE])
	return z, true
}
