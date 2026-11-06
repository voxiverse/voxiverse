package synth

import "core:fmt"
import "core:hash"
import "core:mem/virtual"
import "core:strconv"
import "core:strings"

// The recipe parser: line oriented, `#` comments, indentation free.
//
//	sound stone.break
//	  class block_break
//	  length 0.5
//	  layer body
//	    source modal stone hardness 0.6..0.8 length 0.004
//	    envelope attack 0 hold 0 decay 0.12..0.18 curve exp
//	    level 0 dB
//	  eq peak 3000 1.2 2 dB
//	end
//
// A value is a number or a range `lo..hi` drawn once per variant, in the order
// the values appear. `gain` is the sound's peak in dBFS (default -2). An error
// names the file and line and says what is allowed: "stone.recipe:12: 'hardnes'
// is not a modal option: hardness, modes, ...". Parsing allocates in the set's
// arena; recipes_destroy frees it.

Parse_Error :: struct {
	file: string,
	line: int,
	msg:  string,
}

Recipe_Set :: struct {
	sounds: []Sound,
	error:  Parse_Error, // set when parse returned false
	arena:  virtual.Arena,
}

recipes_destroy :: proc(s: ^Recipe_Set) {
	virtual.arena_destroy(&s.arena)
	s^ = {}
}

error_string :: proc(e: Parse_Error, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%s:%d: %s", e.file, e.line, e.msg, allocator = allocator)
}

MAX_WORDS :: 64

@(private)
Parser :: struct {
	file:       string,
	line:       int,
	alloc:      ^virtual.Arena,
	sound:      ^Sound,
	layer:      ^Layer,
	have_src:   bool,
	have_class: bool,
	failed:     bool,
	msg:        string,
	words:      [MAX_WORDS]string,
	n, at:      int,
}

@(private)
fail :: proc(p: ^Parser, format: string, args: ..any) {
	if p.failed {return}
	p.failed = true
	p.msg = fmt.aprintf(format, ..args, allocator = virtual.arena_allocator(p.alloc))
}

// parse reads every sound in text; file names it in errors.
parse :: proc(text, file: string) -> (set: Recipe_Set, ok: bool) {
	_ = virtual.arena_init_growing(&set.arena)
	alloc := virtual.arena_allocator(&set.arena)
	context.allocator = alloc
	p := Parser {
		file  = strings.clone(file),
		alloc = &set.arena,
	}
	sounds: [dynamic]Sound
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		p.line += 1
		split_words(&p, line)
		if p.failed {break}
		if p.n == 0 {continue}
		parse_line(&p, &sounds)
		if p.failed {break}
	}
	if !p.failed && p.sound != nil {
		fail(&p, "sound '%s' has no 'end'", p.sound.name)
	}
	if p.failed {
		set.error = {p.file, p.line, p.msg}
		return set, false
	}
	set.sounds = sounds[:]
	return set, true
}

@(private)
split_words :: proc(p: ^Parser, line: string) {
	p.n, p.at = 0, 0
	l := line
	if i := strings.index_byte(l, '#'); i >= 0 {l = l[:i]}
	for w in strings.fields_iterator(&l) {
		if p.n == MAX_WORDS {
			fail(p, "more than %d words on a line", MAX_WORDS)
			return
		}
		p.words[p.n] = w
		p.n += 1
	}
}

@(private)
next :: proc(p: ^Parser, what: string) -> string {
	if p.failed {return ""}
	if p.at >= p.n {
		fail(p, "expected %s", what)
		return ""
	}
	p.at += 1
	return p.words[p.at - 1]
}

@(private)
more :: proc(p: ^Parser) -> bool {
	return !p.failed && p.at < p.n
}

@(private)
expect :: proc(p: ^Parser, word: string) {
	if w := next(p, word); !p.failed && w != word {
		fail(p, "expected '%s' but found '%s'", word, w)
	}
}

@(private)
is_word :: proc(s: string, dots: bool) -> bool {
	if len(s) == 0 {return false}
	for c in transmute([]u8)s {
		switch c {
		case 'a' ..= 'z', '0' ..= '9', '_':
		case '.':
			if !dots {return false}
		case:
			return false
		}
	}
	return true
}

@(private)
number :: proc(p: ^Parser, w, what: string) -> f64 {
	v, ok := strconv.parse_f64(w)
	if !ok || v != v || v - v != 0 {
		fail(p, "%s needs a number, not '%s'", what, w)
		return 0
	}
	return v
}

// value reads `n` or `lo..hi` within [lo, hi]. slotted: a range is drawn once
// per variant; otherwise the caller draws it itself (per grain).
@(private)
value :: proc(p: ^Parser, what: string, lo, hi: f64, slotted := true) -> Value {
	w := next(p, what)
	if p.failed {return {slot = -1}}
	a, b: f64
	if i := strings.index(w, ".."); i >= 0 {
		a, b = number(p, w[:i], what), number(p, w[i + 2:], what)
		if p.failed {return {slot = -1}}
		if a > b {
			fail(p, "%s %v..%v has its low end above its high end", what, a, b)
			return {slot = -1}
		}
	} else {
		a = number(p, w, what)
		b = a
	}
	if p.failed {return {slot = -1}}
	if a < lo || b > hi {
		fail(p, "%s %s is out of range %v..%v", what, w, lo, hi)
		return {slot = -1}
	}
	v := Value {
		lo   = a,
		hi   = b,
		slot = -1,
	}
	if slotted && a < b {
		v.slot = len(p.sound.ranges)
		append(&p.sound.ranges, Range{a, b})
	}
	return v
}

@(private)
fixed :: proc(x: f64) -> Value {
	return {lo = x, hi = x, slot = -1}
}

@(private)
range_of :: proc(v: Value) -> Range {
	return {v.lo, v.hi}
}

@(private)
db_value :: proc(p: ^Parser, what: string, lo, hi: f64, slotted := true) -> Value {
	v := value(p, what, lo, hi, slotted)
	expect(p, "dB")
	return v
}

@(private)
unknown :: proc(p: ^Parser, w, what: string, allowed: string) {
	fail(p, "'%s' is not %s: %s", w, what, allowed)
}

SOUND_WORDS :: "class, variants, seed, length, gain, character, loop, layer, eq, end"
LAYER_WORDS :: "source, envelope, filter, level, delay, pitch, layer, eq, end"

@(private)
parse_line :: proc(p: ^Parser, sounds: ^[dynamic]Sound) {
	kw := next(p, "a word")
	if p.sound == nil {
		if kw != "sound" {
			fail(p, "'%s' is outside a sound: a file is sounds, each 'sound <name>' ... 'end'", kw)
			return
		}
		name := next(p, "a sound name")
		if p.failed {return}
		if !is_word(name, true) {
			fail(
				p,
				"'%s' is not a sound name: lowercase words joined by '.', like stone.break",
				name,
			)
			return
		}
		for s in sounds {
			if s.name == name {
				fail(p, "sound '%s' is defined twice", name)
				return
			}
		}
		append(
			sounds,
			Sound {
				name = strings.clone(name),
				variants = 8,
				seed = u64(hash.fnv32a(transmute([]u8)name)),
				gain_db = DEFAULT_GAIN_DB,
			},
		)
		p.sound = &sounds[len(sounds) - 1]
		p.layer = nil
		p.have_src = false
		p.have_class = false
		return
	}
	s := p.sound
	switch kw {
	case "end":
		finish_sound(p)
		return
	case "layer":
		close_layer(p)
		name := next(p, "a layer name")
		if p.failed {return}
		if !is_word(name, false) {
			fail(p, "'%s' is not a layer name: lowercase letters, digits and '_'", name)
			return
		}
		append(
			&s.layers,
			Layer {
				name = strings.clone(name),
				envelope = {attack = fixed(0.001), hold = fixed(0), decay = fixed(0.1)},
				filter = {freq = fixed(1000), q = fixed(0.7071)},
				level_db = fixed(0),
				delay = fixed(0),
				pitch = fixed(1),
			},
		)
		p.layer = &s.layers[len(s.layers) - 1]
		p.have_src = false
		return
	case "eq":
		close_layer(p)
		parse_eq(p)
		return
	}
	if p.layer == nil {
		parse_sound_line(p, kw)
	} else {
		parse_layer_line(p, kw)
	}
	if more(p) {fail(p, "unexpected '%s' after the end of the line", p.words[p.at])}
}

@(private)
close_layer :: proc(p: ^Parser) {
	if p.layer != nil && !p.have_src {
		fail(p, "layer '%s' has no source", p.layer.name)
	}
	p.layer = nil
}

@(private)
finish_sound :: proc(p: ^Parser) {
	close_layer(p)
	if p.failed {return}
	s := p.sound
	if !p.have_class {
		fail(p, "sound '%s' has no class: one of %s", s.name, class_names())
		return
	}
	if len(s.layers) == 0 {
		fail(p, "sound '%s' has no layer", s.name)
		return
	}
	p.sound = nil
}

@(private)
class_names :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in Class {
		if c != min(Class) {strings.write_string(&b, ", ")}
		strings.write_string(&b, class_word(c))
	}
	return strings.to_string(b)
}

@(private)
class_word :: proc(c: Class) -> string {
	switch c {
	case .Block_Break:
		return "block_break"
	case .Block_Place:
		return "block_place"
	case .Block_Step:
		return "block_step"
	case .Land:
		return "land"
	case .Creature_Hurt:
		return "creature_hurt"
	case .Creature_Die:
		return "creature_die"
	case .Launch:
		return "launch"
	case .Boom:
		return "boom"
	}
	return ""
}

@(private)
parse_sound_line :: proc(p: ^Parser, kw: string) {
	s := p.sound
	switch kw {
	case "class":
		w := next(p, "a class")
		if p.failed {return}
		for c in Class {
			if class_word(c) == w {
				s.class = c
				p.have_class = true
				return
			}
		}
		unknown(p, w, "a class", class_names())
	case "variants":
		s.variants = int(value(p, "variants", 1, 16, false).lo)
	case "seed":
		w := next(p, "a seed")
		v, ok := strconv.parse_u64(w)
		if !p.failed && !ok {fail(p, "seed needs a whole number, not '%s'", w)}
		s.seed = v
	case "length":
		s.length = value(p, "length", 0.02, MAX_LENGTH, false).lo
	case "gain":
		s.gain_db = db_value(p, "gain", -60, 0, false).lo
	case "character":
		switch w := next(p, "clean or follow"); w {
		case "clean":
			s.character = .Clean
		case "follow":
			s.character = .Follow
		case:
			if !p.failed {unknown(p, w, "a character", "clean, follow")}
		}
	case "loop":
		s.loop = value(p, "loop", 0.005, 2, false).lo
	case:
		unknown(p, kw, "a sound line", SOUND_WORDS)
	}
}

FILTER_WORDS :: "lowpass, highpass, bandpass"
SOURCE_WORDS :: "noise, tone, click, modal, granular, formant, bubble"
MODAL_WORDS :: "hardness, modes, spread, decay, brightness, length"
GRANULAR_WORDS :: "count, size, pitch, gain, spread, density"
FORMANT_WORDS :: "pitch, vowel, vibrato, jitter, shimmer, breath"
BUBBLE_WORDS :: "radius, count, spread"

@(private)
parse_layer_line :: proc(p: ^Parser, kw: string) {
	l := p.layer
	switch kw {
	case "source":
		if p.have_src {
			fail(p, "layer '%s' has a source already", l.name)
			return
		}
		parse_source(p, l)
		p.have_src = true
	case "envelope":
		for more(p) {
			switch w := next(p, "an envelope word"); w {
			case "attack":
				l.envelope.attack = value(p, "attack", 0, MAX_LENGTH)
			case "hold":
				l.envelope.hold = value(p, "hold", 0, MAX_LENGTH)
			case "decay":
				l.envelope.decay = value(p, "decay", 0.0005, MAX_LENGTH)
			case "curve":
				switch c := next(p, "exp or lin"); c {
				case "exp":
					l.envelope.linear = false
				case "lin":
					l.envelope.linear = true
				case:
					if !p.failed {unknown(p, c, "a curve", "exp, lin")}
				}
			case:
				if !p.failed {unknown(p, w, "an envelope word", "attack, hold, decay, curve")}
			}
		}
	case "filter":
		switch w := next(p, "a filter"); w {
		case "lowpass":
			l.filter.kind = .Lowpass
		case "highpass":
			l.filter.kind = .Highpass
		case "bandpass":
			l.filter.kind = .Bandpass
		case:
			if !p.failed {unknown(p, w, "a filter", FILTER_WORDS)}
		}
		l.filter.freq = value(p, "filter frequency", 20, 20000)
		if more(p) {
			expect(p, "q")
			l.filter.q = value(p, "q", 0.1, 30)
		}
	case "level":
		l.level_db = db_value(p, "level", -90, 24)
	case "delay":
		l.delay = value(p, "delay", 0, MAX_LENGTH)
	case "pitch":
		l.pitch = value(p, "pitch", 0.1, 10)
	case:
		unknown(p, kw, "a layer line", LAYER_WORDS)
	}
}

@(private)
parse_material :: proc(p: ^Parser, w: string, allow_water: bool) -> Material {
	for m in Material {
		if material_word(m) == w {
			if m == .Water && !allow_water {
				fail(p, "water has no modes: make it with 'source bubble'")
			}
			return m
		}
	}
	if !p.failed {unknown(p, w, "a material", material_names())}
	return {}
}

@(private)
material_word :: proc(m: Material) -> string {
	switch m {
	case .Stone:
		return "stone"
	case .Wood:
		return "wood"
	case .Glass:
		return "glass"
	case .Metal:
		return "metal"
	case .Dirt:
		return "dirt"
	case .Gravel:
		return "gravel"
	case .Sand:
		return "sand"
	case .Wool:
		return "wool"
	case .Leaves:
		return "leaves"
	case .Snow:
		return "snow"
	case .Water:
		return "water"
	case .Ice:
		return "ice"
	}
	return ""
}

@(private)
material_names :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	for m in Material {
		if m != min(Material) {strings.write_string(&b, ", ")}
		strings.write_string(&b, material_word(m))
	}
	return strings.to_string(b)
}

@(private)
parse_source :: proc(p: ^Parser, l: ^Layer) {
	kind := next(p, "a source")
	if p.failed {return}
	switch kind {
	case "noise":
		n: Noise_Source
		switch w := next(p, "white, pink or brown"); w {
		case "white":
			n.color = .White
		case "pink":
			n.color = .Pink
		case "brown":
			n.color = .Brown
		case:
			if !p.failed {unknown(p, w, "a noise colour", "white, pink, brown")}
		}
		l.source = n
	case "tone":
		t: Tone_Source
		t.from = value(p, "tone frequency", 20, 20000)
		t.to = t.from
		if more(p) {
			expect(p, "to")
			t.to = value(p, "tone frequency", 20, 20000)
		}
		l.source = t
	case "click":
		l.source = Click_Source{value(p, "click hardness", 0, 1)}
	case "modal":
		m := Modal_Source {
			hardness   = fixed(0.5),
			modes      = fixed(TABLE_MODES),
			spread     = fixed(1),
			decay      = fixed(1),
			brightness = fixed(0),
			length     = fixed(0.004),
		}
		m.material = parse_material(p, next(p, "a material"), false)
		for more(p) {
			switch w := next(p, "a modal option"); w {
			case "hardness":
				m.hardness = value(p, "hardness", 0, 1)
			case "modes":
				m.modes = value(p, "modes", 1, TABLE_MODES)
			case "spread":
				m.spread = value(p, "spread", 0.25, 4)
			case "decay":
				m.decay = value(p, "decay", 0.05, 20)
			case "brightness":
				m.brightness = value(p, "brightness", -24, 24)
			case "length":
				m.length = value(p, "length", 0.0000208, 0.05) // one sample up
			case:
				if !p.failed {unknown(p, w, "a modal option", MODAL_WORDS)}
			}
		}
		l.source = m
	case "granular":
		g := Granular_Source {
			count   = fixed(8),
			spread  = fixed(0.1),
			size    = {0.005, 0.005},
			pitch   = {1, 1},
			gain    = {0, 0},
			density = .Flat,
		}
		switch w := next(p, "noise, tone or modal"); w {
		case "noise":
			g.kind = .Noise
			g.pitch = {0, 0}
		case "tone":
			g.kind = .Tone
			g.pitch = {1000, 1000}
		case "modal":
			g.kind = .Modal
			g.material = parse_material(p, next(p, "a material"), false)
		case:
			if !p.failed {unknown(p, w, "a grain", "noise, tone, modal <material>")}
		}
		pitch_hi := 1000.0 if g.kind == .Modal else 20000.0
		for more(p) {
			switch w := next(p, "a granular option"); w {
			case "count":
				g.count = value(p, "count", 0, 2000)
			case "size":
				g.size = range_of(value(p, "size", 0.0005, 0.5, false))
			case "pitch":
				g.pitch = range_of(
					value(p, "pitch", 0 if g.kind != .Modal else 0.05, pitch_hi, false),
				)
			case "gain":
				g.gain = range_of(db_value(p, "gain", -90, 24, false))
			case "spread":
				g.spread = value(p, "spread", 0, MAX_LENGTH)
			case "density":
				switch d := next(p, "flat, front or back"); d {
				case "flat":
					g.density = .Flat
				case "front":
					g.density = .Front
				case "back":
					g.density = .Back
				case:
					if !p.failed {unknown(p, d, "a density", "flat, front, back")}
				}
			case:
				if !p.failed {unknown(p, w, "a granular option", GRANULAR_WORDS)}
			}
		}
		l.source = g
	case "formant":
		f := Formant_Source {
			pitch_from    = fixed(200),
			pitch_to      = fixed(200),
			vowel_from    = .A,
			vowel_to      = .A,
			vibrato_rate  = fixed(0),
			vibrato_cents = fixed(0),
			jitter        = fixed(0),
			shimmer       = fixed(0),
			breath        = fixed(0),
		}
		for more(p) {
			switch w := next(p, "a formant option"); w {
			case "pitch":
				f.pitch_from = value(p, "pitch", 20, 4000)
				f.pitch_to = f.pitch_from
				if more(p) && p.words[p.at] == "to" {
					p.at += 1
					f.pitch_to = value(p, "pitch", 20, 4000)
				}
			case "vowel":
				f.vowel_from = parse_vowel(p, next(p, "a vowel"))
				f.vowel_to = f.vowel_from
				if more(p) && p.words[p.at] == "to" {
					p.at += 1
					f.vowel_to = parse_vowel(p, next(p, "a vowel"))
				}
			case "vibrato":
				f.vibrato_rate = value(p, "vibrato rate", 0, 20)
				f.vibrato_cents = value(p, "vibrato depth", 0, 600)
			case "jitter":
				f.jitter = value(p, "jitter", 0, 1)
			case "shimmer":
				f.shimmer = value(p, "shimmer", 0, 1)
			case "breath":
				f.breath = value(p, "breath", 0, 1)
			case:
				if !p.failed {unknown(p, w, "a formant option", FORMANT_WORDS)}
			}
		}
		l.source = f
	case "bubble":
		b := Bubble_Source {
			radius = {0.004, 0.004},
			count  = fixed(4),
			spread = fixed(0.1),
		}
		for more(p) {
			switch w := next(p, "a bubble option"); w {
			case "radius":
				b.radius = range_of(value(p, "radius", 0.0002, 0.1, false))
			case "count":
				b.count = value(p, "count", 0, 500)
			case "spread":
				b.spread = value(p, "spread", 0, MAX_LENGTH)
			case:
				if !p.failed {unknown(p, w, "a bubble option", BUBBLE_WORDS)}
			}
		}
		l.source = b
	case:
		unknown(p, kind, "a source", SOURCE_WORDS)
	}
}

@(private)
parse_vowel :: proc(p: ^Parser, w: string) -> Vowel {
	switch w {
	case "a":
		return .A
	case "e":
		return .E
	case "i":
		return .I
	case "o":
		return .O
	case "u":
		return .U
	case "bleat":
		return .Bleat
	}
	if !p.failed {unknown(p, w, "a vowel", "a, e, i, o, u, bleat")}
	return {}
}

@(private)
parse_eq :: proc(p: ^Parser) {
	e: Eq
	e.q = fixed(0.7071)
	switch w := next(p, "low_shelf, high_shelf or peak"); w {
	case "low_shelf":
		e.kind = .Low_Shelf
	case "high_shelf":
		e.kind = .High_Shelf
	case "peak":
		e.kind = .Peak
	case:
		if !p.failed {unknown(p, w, "an eq", "low_shelf, high_shelf, peak")}
	}
	e.freq = value(p, "eq frequency", 20, 20000)
	if e.kind == .Peak {e.q = value(p, "eq q", 0.1, 30)}
	e.gain_db = db_value(p, "eq gain", -24, 24)
	if more(p) {fail(p, "unexpected '%s' after the end of the line", p.words[p.at])}
	if !p.failed {append(&p.sound.eqs, e)}
}
