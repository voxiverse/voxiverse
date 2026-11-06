package synth

import "core:strings"
import "core:testing"

import "common:base"

// The measures and the targets parser.

@(test)
test_targets_errors :: proc(t: ^testing.T) {
	Case :: struct {
		text, want: string,
	}
	cases := [?]Case {
		{"class blok_break\n", "t.txt:1: 'blok_break' is not a class: "},
		{"class land\n  peak -3\nend\n", "t.txt:2: '-3' is not a range lo..hi"},
		{"class land\n  peak 3..-3\nend\n", "t.txt:2: '3..-3' is not a range lo..hi"},
		{"class land\n  mid -3\nend\n", "t.txt:2: expected 'mid >= <dB>' inside a class"},
		{"class land\n  peak -3..-1\n", "t.txt:2: class 'land' has no 'end'"},
		{"peak -3..-1\n", "t.txt:1: expected 'peak <lo>..<hi>' inside a class"},
		{"class land\n  pek -3..-1\nend\n", "t.txt:2: 'pek' is not a targets word: "},
	}
	for c in cases {
		tg, err := parse_targets(c.text, "t.txt")
		defer targets_destroy(&tg)
		testing.expectf(
			t,
			strings.has_prefix(err, c.want),
			"%q: got %q, want a message starting %q",
			c.text,
			err,
			c.want,
		)
	}
}

@(test)
test_measures :: proc(t: ^testing.T) {
	// A 1 kHz sine of 0.5 s at -6 dBFS peak: its centroid is 1 kHz, its energy is
	// all in the middle band, its length is the whole of it.
	x := make([]f32, RATE / 2)
	defer delete(x)
	for i in 0 ..< len(x) {
		x[i] = 0.5 * f32(sin_turns(f64(i) * 1000 / RATE))
	}
	m := measure(x)
	testing.expectf(t, abs(m.peak + 6.02) < 0.05, "peak %v", m.peak)
	testing.expectf(t, abs(m.centroid - 1000) < 20, "centroid %v", m.centroid)
	testing.expectf(t, m.mid > -0.5, "mid %v", m.mid)
	testing.expectf(t, abs(m.length - 0.5) < 0.006, "length %v", m.length)
	// One ear: -6 dBFS peak is -9 dB RMS, the K-weighting adds 0.7 at 1 kHz,
	// the scale takes 0.7; the loudest 400 ms of a steady tone is its level.
	testing.expectf(t, abs(m.loud + 9.0) < 0.4, "loud %v", m.loud)
}

@(private = "file")
sin_turns :: proc(turns: f64) -> f64 {
	return base.sin(turns * 2 * PI)
}
