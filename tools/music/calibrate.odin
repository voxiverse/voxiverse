package music_tool

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"

// Calibration: the ear's measures scored on masters against scrambled copies of
// them. A measure that tells the two apart (AUC at least GATE_AUC against the
// random-in-key copy) gates; its band is the masters' 10th to 90th percentile.
// See docs/audio.md, "The ear".

BANDS_FILE :: "assets/music/ear_bands.txt"
GATE_AUC :: 0.9
SEED_SHUFFLE :: 1
SEED_IN_KEY :: 2

Measure :: struct {
	name:          string,
	higher_better: bool, // a master scores higher (else lower) than its copies
}

// The measures, in report order. Their direction is a constant.
MEASURES := [?]Measure {
	{"stepwise", true},
	{"surprise", false},
	{"big_leaps", false},
	{"motif_return", true},
	{"leap_recovered", true},
	{"harmony_fit", true},
	{"strong_beat_clash", false}, // the share of strong-beat melody notes outside the chord
}

measure_values :: proc(e: Ear) -> (v: [len(MEASURES)]f64) {
	v[0] = e.stepwise
	v[1] = e.surprise
	v[2] = e.big_leaps
	v[3] = e.motif_return
	v[4] = e.leap_recovered
	v[5] = e.harmony_fit
	if e.strong_beats > 0 {v[6] = f64(e.strong_beat_clash) / f64(e.strong_beats)}
	return
}

Band :: struct {
	name:      string,
	low, high: f64, // the open side of a one-sided measure is 0 (or 1)
	auc:       f64,
}

Calibration :: struct {
	auc_shuffle: [len(MEASURES)]f64,
	auc_in_key:  [len(MEASURES)]f64,
	bands:       [len(MEASURES)]Band, // every measure; those that gate go to the file
	gating:      [len(MEASURES)]bool,
}

// auc is how often the master scores better than its copy; ties count half.
auc :: proc(masters, copies: []f64, higher_better: bool) -> f64 {
	if len(masters) == 0 {return 0}
	wins := 0.0
	for m, i in masters {
		switch {
		case m == copies[i]:
			wins += 0.5
		case (m > copies[i]) == higher_better:
			wins += 1
		}
	}
	return wins / f64(len(masters))
}

// percentile is the q-th (0..1) percentile of sorted values, by linear interpolation.
percentile :: proc(sorted: []f64, q: f64) -> f64 {
	if len(sorted) == 0 {return 0}
	pos := q * f64(len(sorted) - 1)
	lo := int(math.floor(pos))
	hi := min(lo + 1, len(sorted) - 1)
	return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - f64(lo))
}

// round4 rounds to the 4 digits the bands file keeps.
round4 :: proc(v: f64) -> f64 {
	return math.round(v * 10000) / 10000
}

// calibrate listens to every piece and to its two scrambled copies, with the
// expectation trained on the pieces (each scored with its own counts left out).
calibrate :: proc(pieces: []Piece, names: []string) -> (c: Calibration) {
	model := expectation_train(pieces)
	for n in names {append(&model.names, n)}
	master_v, shuffle_v, key_v: [len(MEASURES)][dynamic]f64
	for &p, i in pieces {
		sh := scramble_shuffle(p, SEED_SHUFFLE)
		ik := scramble_in_key(p, SEED_IN_KEY)
		em := measure_values(listen(&p, names[i], "", &model))
		es := measure_values(listen(&sh, strings.concatenate({names[i], "~shuffle"}), "", &model))
		ek := measure_values(listen(&ik, strings.concatenate({names[i], "~in-key"}), "", &model))
		for k in 0 ..< len(MEASURES) {
			append(&master_v[k], em[k])
			append(&shuffle_v[k], es[k])
			append(&key_v[k], ek[k])
		}
	}
	for m, k in MEASURES {
		c.auc_shuffle[k] = auc(master_v[k][:], shuffle_v[k][:], m.higher_better)
		c.auc_in_key[k] = auc(master_v[k][:], key_v[k][:], m.higher_better)
		c.gating[k] = c.auc_in_key[k] >= GATE_AUC
		sorted := slice.clone(master_v[k][:])
		slice.sort(sorted)
		b := Band {
			name = m.name,
			auc  = round4(c.auc_in_key[k]),
		}
		if m.higher_better {
			b.low, b.high = round4(percentile(sorted, 0.1)), 1
		} else {
			b.low, b.high = 0, round4(percentile(sorted, 0.9))
		}
		c.bands[k] = b
	}
	return
}

// calibration_report is what `--calibrate` prints.
calibration_report :: proc(c: Calibration, n_pieces: int, b: ^strings.Builder) {
	fmt.sbprintfln(b, "calibrated on %d masters, each against two scrambled copies", n_pieces)
	fmt.sbprintfln(b, "%-18s %12s %12s  %s", "measure", "AUC shuffle", "AUC in-key", "band")
	for m, k in MEASURES {
		band := c.bands[k]
		fmt.sbprintfln(
			b,
			"%-18s %12s %12s  %s",
			m.name,
			fmt.tprintf("%.3f", c.auc_shuffle[k]),
			fmt.tprintf("%.3f", c.auc_in_key[k]),
			fmt.tprintf("%.4f..%.4f", band.low, band.high) if c.gating[k] else "reported, not gated",
		)
	}
}

// gating_bands are the bands of the measures that gate, in MEASURES order.
gating_bands :: proc(c: Calibration) -> []Band {
	out: [dynamic]Band
	for k in 0 ..< len(MEASURES) {
		if c.gating[k] {append(&out, c.bands[k])}
	}
	return out[:]
}

// ---- the bands file ---------------------------------------------------------
//
// `measure<TAB>low<TAB>high<TAB>auc` per gating measure, 4 decimals; lines
// starting with # are comments.

bands_write :: proc(bands: []Band) -> string {
	b: strings.Builder
	fmt.sbprintln(&b, "# The ear's gating measures: name, band low, band high, AUC against")
	fmt.sbprintln(&b, "# random-in-key. Written by `build music ear --calibrate`.")
	for x in bands {
		fmt.sbprintfln(&b, "%s\t%.4f\t%.4f\t%.4f", x.name, x.low, x.high, x.auc)
	}
	return strings.to_string(b)
}

bands_read :: proc(text: string) -> (bands: [dynamic]Band, ok: bool) {
	rest := text_lf(text)
	for line in strings.split_lines_iterator(&rest) {
		if len(strings.trim_space(line)) == 0 || line[0] == '#' {continue}
		cols := strings.split(line, "\t")
		if len(cols) != 4 {return}
		low := strconv.parse_f64(cols[1]) or_return
		high := strconv.parse_f64(cols[2]) or_return
		a := strconv.parse_f64(cols[3]) or_return
		append(&bands, Band{cols[0], low, high, a})
	}
	return bands, true
}
