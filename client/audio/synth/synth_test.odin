package synth

import "core:hash"
import "core:strings"
import "core:testing"

import "client:audio"
import "common:base"

// Tests: the parser's messages, and every sound's properties.

STONE :: `# the spec's example
sound stone.break
  class block_break
  length 0.5
  layer transient
    source click 0.85..0.95
    envelope attack 0 hold 0 decay 0.010
    filter highpass 1500
    level -6 dB
  layer body
    source modal stone hardness 0.6..0.8 spread 0.94..1.06 length 0.004
    envelope attack 0 hold 0 decay 0.12..0.18 curve exp
    level 0 dB
  layer debris
    source granular modal stone count 8..14 size 0.004..0.012 pitch 0.8..1.6 gain -18..-8 dB spread 0.02..0.30 density front
    envelope attack 0 hold 0.05 decay 0.25
    level -9 dB
  eq peak 3000 1.2 2 dB
end
`

OTHERS :: `
sound glass.place
  class block_place
  gain -3 dB
  layer ring
    source modal glass hardness 0.9 modes 4
    envelope attack 0 hold 0 decay 0.3
  layer shards
    source granular tone count 6 size 0.002..0.006 pitch 3000..6000 gain -20..-10 dB spread 0.1
    envelope attack 0 hold 0 decay 0.2 curve lin
    filter bandpass 4000 q 2
    delay 0.01
    pitch 0.9..1.1
  eq high_shelf 6000 -2 dB
  eq low_shelf 120 -3 dB
end
sound sheep.hurt
  class creature_hurt
  layer voice
    source formant pitch 560 to 430 vowel bleat to a vibrato 7 40 jitter 0.5 shimmer 0.5 breath 0.05
    envelope attack 0.02 hold 0.1 decay 0.2
  layer rumble
    source noise brown
    envelope attack 0.1 hold 0 decay 0.3
    filter lowpass 400
    level -30 dB
end
sound water.splash
  class land
  layer bubbles
    source bubble radius 0.002..0.008 count 10 spread 0.2
    envelope attack 0 hold 0.1 decay 0.2
  layer hiss
    source noise pink
    envelope attack 0.005 hold 0 decay 0.1
    level -20 dB
end
sound boom.big
  class boom
  layer thump
    source tone 50..250 to 30
    envelope attack 0 hold 0.05 decay 0.5
  layer crack
    source click 1
    envelope attack 0 hold 0 decay 0.02
  layer rumble
    source noise brown
    envelope attack 0.01 hold 0.1 decay 0.4
    filter lowpass 150..1500
    level -6 dB
end
`

@(private = "file")
parse_all :: proc(t: ^testing.T) -> (set: Recipe_Set, ok: bool) {
	text := strings.concatenate({STONE, OTHERS})
	defer delete(text)
	set, ok = parse(text, "test.recipe")
	if !ok {testing.expectf(t, false, "parse failed: %s", error_string(set.error))}
	return
}

@(test)
test_recipes_parse :: proc(t: ^testing.T) {
	set, ok := parse_all(t)
	defer recipes_destroy(&set)
	if !ok {return}
	testing.expect_value(t, len(set.sounds), 5)
	testing.expect_value(t, set.sounds[0].name, "stone.break")
	testing.expect_value(t, len(set.sounds[0].layers), 3)
	testing.expect_value(t, set.sounds[0].variants, 8)
	testing.expect_value(
		t,
		set.sounds[0].seed,
		u64(hash.fnv32a(transmute([]u8)string("stone.break"))),
	)
	// The ranges the stone recipe holds, in order: click hardness, body hardness,
	// spread, decay, debris count, spread (sizes, pitches and gains are per grain).
	testing.expect_value(t, len(set.sounds[0].ranges), 6)
}

@(private = "file")
Bad :: struct {
	text: string,
	want: string, // the error, with its file and line
}

@(test)
test_recipe_errors :: proc(t: ^testing.T) {
	cases := [?]Bad {
		{
			"sound a.b\n class block_break\n layer x\n  source modal stone hardnes 1\nend\n",
			"t.recipe:4: 'hardnes' is not a modal option: hardness, modes, spread, decay, brightness, length",
		},
		{
			"sound a.b\n class block_break\n layer x\n  source modal stone hardness 1.4\nend\n",
			"t.recipe:4: hardness 1.4 is out of range 0..1",
		},
		{
			"sound a.b\n class block_break\n layer x\n  source click 0.9..0.5\nend\n",
			"t.recipe:4: click hardness 0.9..0.5 has its low end above its high end",
		},
		{
			"sound a.b\n class block_break\n layer x\n  source noise white\n",
			"t.recipe:4: sound 'a.b' has no 'end'",
		},
		{
			"sound a.b\n layer x\n  source noise white\nend\n",
			"t.recipe:4: sound 'a.b' has no class: one of block_break, block_place, block_step, land, creature_hurt, creature_die, launch, boom",
		},
		{
			"sound a.b\n class nope\nend\n",
			"t.recipe:2: 'nope' is not a class: block_break, block_place, block_step, land, creature_hurt, creature_die, launch, boom",
		},
		{
			"sound A.b\n",
			"t.recipe:1: 'A.b' is not a sound name: lowercase words joined by '.', like stone.break",
		},
		{
			"sound a.b\n class land\n layer x\n  source modal water\nend\n",
			"t.recipe:4: water has no modes: make it with 'source bubble'",
		},
		{
			"sound a.b\n class land\n layer x\n  envelope attack\nend\n",
			"t.recipe:4: expected attack",
		},
		{
			"sound a.b\n class land\n variants 17\nend\n",
			"t.recipe:3: variants 17 is out of range 1..16",
		},
		{
			"sound a.b\n class land\n layer x\n  source tone 100 loud\nend\n",
			"t.recipe:4: expected 'to' but found 'loud'",
		},
		{
			"sound a.b\n class land\n layer x\n  envelope attack 0\nend\n",
			"t.recipe:5: layer 'x' has no source",
		},
		{
			"layer x\n",
			"t.recipe:1: 'layer' is outside a sound: a file is sounds, each 'sound <name>' ... 'end'",
		},
	}
	for c in cases {
		set, ok := parse(c.text, "t.recipe")
		defer recipes_destroy(&set)
		testing.expectf(t, !ok, "should not parse: %q", c.text)
		if ok {continue}
		testing.expect_value(t, error_string(set.error), c.want)
	}
}

@(test)
test_draw_order_is_stable :: proc(t: ^testing.T) {
	a, ok_a := parse(
		"sound a.b\n class land\n layer x\n  source modal stone hardness 0.1..0.9\nend\n",
		"a",
	)
	b, ok_b := parse(
		"sound a.b\n class land\n layer x\n  source modal stone hardness 0.1..0.9\n layer y\n  source modal wood decay 1..2\nend\n",
		"b",
	)
	defer {recipes_destroy(&a); recipes_destroy(&b)}
	testing.expect(t, ok_a && ok_b)
	if !(ok_a && ok_b) {return}
	for v in 0 ..< 8 {
		ra, rb :=
			base.rng_make(a.sounds[0].seed * 64 + u64(v)),
			base.rng_make(b.sounds[0].seed * 64 + u64(v))
		da := draw_ranges(&a.sounds[0], &ra, context.temp_allocator)
		db := draw_ranges(&b.sounds[0], &rb, context.temp_allocator)
		testing.expect_value(t, da[0], db[0])
		testing.expect_value(t, len(db), 2)
	}
}

// Every variant of every sound: no clipping, no DC, no click at either end.
@(test)
test_sound_properties :: proc(t: ^testing.T) {
	set, ok := parse_all(t)
	defer recipes_destroy(&set)
	if !ok {return}
	for &s in set.sounds {
		for v in 0 ..< s.variants {
			x := generate(&s, v)
			defer delete(x)
			testing.expectf(t, len(x) > 100, "%s.%d: %d samples", s.name, v, len(x))
			peak: f32
			sum: f64
			for y in x {
				testing.expectf(t, y == y, "%s.%d: NaN", s.name, v)
				peak = max(peak, abs(y))
				sum += f64(y)
			}
			testing.expectf(t, peak <= 1, "%s.%d: peak %v", s.name, v, peak)
			testing.expectf(t, peak >= 0.1, "%s.%d: silent, peak %v", s.name, v, peak)
			mean := sum / f64(len(x))
			testing.expectf(t, abs(mean) < 0.001, "%s.%d: DC %v", s.name, v, mean)
			for i in 0 ..< 8 {
				testing.expectf(t, abs(x[i]) < 0.001, "%s.%d: click at start %v", s.name, v, x[i])
				testing.expectf(
					t,
					abs(x[len(x) - 1 - i]) < 0.001,
					"%s.%d: click at end",
					s.name,
					v,
				)
			}
			// The sound's peak is its gain.
			want := f32(from_db_amp(s.gain_db))
			testing.expectf(
				t,
				abs(peak - want) < 1e-4,
				"%s.%d: peak %v, gain says %v",
				s.name,
				v,
				peak,
				want,
			)
		}
	}
}

@(private = "file")
stereo :: proc(x: []f32) -> []f32 {
	out := make([]f32, 2 * len(x))
	for y, i in x {out[2 * i], out[2 * i + 1] = y, y}
	return out
}

// Variants differ: third-octave spectra 1 dB apart (RMS over the bands), or
// decays 10% apart; and none are equal.
@(test)
test_variants_differ :: proc(t: ^testing.T) {
	set, ok := parse_all(t)
	defer recipes_destroy(&set)
	if !ok {return}
	for &s in set.sounds {
		vs: [dynamic][]f32
		bands: [dynamic][audio.BANDS]f64
		defer {for x in vs {delete(x)}; delete(vs); delete(bands)}
		for v in 0 ..< s.variants {
			x := generate(&s, v)
			append(&vs, x)
			st := stereo(x)
			defer delete(st)
			append(&bands, audio.third_octaves(st, RATE))
		}
		for i in 0 ..< len(vs) {
			for j in i + 1 ..< len(vs) {
				testing.expectf(
					t,
					!slice_equal(vs[i], vs[j]),
					"%s: variants %d and %d are equal",
					s.name,
					i,
					j,
				)
				sq: f64
				for k in 0 ..< audio.BANDS {
					d := bands[i][k] - bands[j][k]
					sq += d * d
				}
				rms := sqrt(sq / f64(audio.BANDS))
				ta := audio.decay_time(vs[i], RATE, 0, len(vs[i]))
				tb := audio.decay_time(vs[j], RATE, 0, len(vs[j]))
				apart := abs(ta - tb) > 0.1 * max(ta, tb)
				testing.expectf(
					t,
					rms >= 1.0 || apart,
					"%s: variants %d and %d sound alike (%v dB, decays %v and %v)",
					s.name,
					i,
					j,
					rms,
					ta,
					tb,
				)
			}
		}
	}
}

@(private = "file")
slice_equal :: proc(a, b: []f32) -> bool {
	if len(a) != len(b) {return false}
	for x, i in a {if x != b[i] {return false}}
	return true
}

@(private = "file")
fnv :: proc(x: []f32) -> u64 {
	return hash.fnv64a(transmute([]u8)(([^]f32)(raw_data(x)))[:len(x) * 4])
}

// Two generations are bit-identical, and the samples are the same on every
// OS: the hashes are recorded constants.
@(test)
test_determinism :: proc(t: ^testing.T) {
	set, ok := parse_all(t)
	defer recipes_destroy(&set)
	if !ok {return}
	for &s in set.sounds {
		a := generate(&s, 3)
		b := generate(&s, 3)
		defer {delete(a); delete(b)}
		testing.expectf(t, slice_equal(a, b), "%s: two generations differ", s.name)
	}
	golden := [?]struct {
		sound:   int,
		variant: int,
		hash:    u64,
	}{{0, 0, GOLDEN_STONE}, {1, 3, GOLDEN_GLASS}, {4, 0, GOLDEN_BOOM}}
	for g in golden {
		x := generate(&set.sounds[g.sound], g.variant)
		defer delete(x)
		testing.expectf(
			t,
			fnv(x) == g.hash,
			"%s.%d hashes to 0x%x, recorded 0x%x",
			set.sounds[g.sound].name,
			g.variant,
			fnv(x),
			g.hash,
		)
	}
}

GOLDEN_STONE :: u64(0x2496fa308c29c4ff) // recorded on Linux
GOLDEN_GLASS :: u64(0x11abf014faa46fe1)
GOLDEN_BOOM :: u64(0xb38dc9008550c879)

@(test)
test_loop_has_no_seam :: proc(t: ^testing.T) {
	set, ok := parse(
		"sound w.loop\n class land\n loop 0.1\n layer x\n  source noise pink\n  envelope attack 0 hold 1 decay 0.2\nend\n",
		"l",
	)
	defer recipes_destroy(&set)
	testing.expect(t, ok)
	if !ok {return}
	x := generate(&set.sounds[0], 0)
	defer delete(x)
	// The last sample flows into the first as an ordinary neighbour would:
	// no step much bigger than the loudest neighbouring pair.
	step: f32
	for i in 1 ..< len(x) {step = max(step, abs(x[i] - x[i - 1]))}
	testing.expect(t, abs(x[0] - x[len(x) - 1]) <= 2 * step)
}
