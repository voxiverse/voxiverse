package synth

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

import "client:audio"

// The measures of a sound and the targets of its class (docs/audio.md). A
// variant is measured at RATE, as the game plays it (mono, in both ears).

Measures :: struct {
	peak:           f64, // sample peak, dBFS
	loud:           f64, // the loudest 400 ms momentary loudness, LUFS, with 400 ms of silence after
	length:         f64, // s: start to the end of the last 5 ms RMS frame above -60 dB re peak
	decay:          f64, // s: the peak to the first 5 ms RMS frame under -30 dB re peak
	centroid:       f64, // Hz, of the whole sound
	low, mid, high: f64, // dB re the total: below 250 Hz, 250-2500, above 2500
}

RMS_FRAME :: RATE / 200 // 5 ms

measure :: proc(x: []f32) -> (m: Measures) {
	peak: f32
	at := 0
	for y, i in x {
		if abs(y) > peak {peak, at = abs(y), i}
	}
	m.peak = to_db(f64(peak))
	if peak == 0 {
		m.loud, m.centroid = -200, 0
		m.low, m.mid, m.high = -200, -200, -200
		return
	}

	// RMS frames: length and decay.
	last := -1
	decayed := -1
	for f in 0 ..< (len(x) + RMS_FRAME - 1) / RMS_FRAME {
		lo, hi := f * RMS_FRAME, min((f + 1) * RMS_FRAME, len(x))
		sum: f64
		for i in lo ..< hi {sum += f64(x[i]) * f64(x[i])}
		db := to_db(math.sqrt(sum / f64(RMS_FRAME))) - m.peak
		if db > -60 {last = f}
		if decayed < 0 && hi > at && db < -30 {decayed = f}
	}
	m.length = f64(last + 1) * RMS_FRAME / RATE
	if decayed < 0 {decayed = (len(x) + RMS_FRAME - 1) / RMS_FRAME}
	m.decay = max(f64(decayed * RMS_FRAME - at) / RATE, 0)

	// Loudness: one ear, 400 ms of silence after, the loudest momentary value.
	pad := RATE * 4 / 10
	st := make([]f32, 2 * (len(x) + pad), context.temp_allocator)
	defer delete(st, context.temp_allocator)
	for y, i in x {st[2 * i] = y} 	// the left ear alone: both ears would read 3 LU more
	meter := new(audio.Meter, context.temp_allocator)
	defer free(meter, context.temp_allocator)
	audio.meter_init(meter, RATE)
	m.loud = -200
	step := RATE / 10
	for from := 0; from + step <= len(st) / 2; from += step {
		audio.meter_push(meter, st[2 * from:2 * (from + step)])
		m.loud = max(m.loud, f64(meter.momentary))
	}

	// Spectrum.
	n := 1
	for n < len(x) {n <<= 1}
	re := make([]f64, n, context.temp_allocator)
	im := make([]f64, n, context.temp_allocator)
	defer {delete(re, context.temp_allocator); delete(im, context.temp_allocator)}
	for y, i in x {re[i] = f64(y)}
	audio.fft(re, im)
	total, weighted, lo_e, mid_e, hi_e: f64
	for k in 1 ..< n / 2 {
		p := re[k] * re[k] + im[k] * im[k]
		f := f64(k) * RATE / f64(n)
		total += p
		weighted += p * f
		switch {
		case f < 250:
			lo_e += p
		case f < 2500:
			mid_e += p
		case:
			hi_e += p
		}
	}
	if total > 0 {
		m.centroid = weighted / total
		m.low = to_db_power(lo_e / total)
		m.mid = to_db_power(mid_e / total)
		m.high = to_db_power(hi_e / total)
	}
	return
}

@(private)
to_db :: proc(x: f64) -> f64 {return 20 * math.log10(max(x, 1e-10))}

@(private)
to_db_power :: proc(x: f64) -> f64 {return 10 * math.log10(max(x, 1e-20))}

// A target row: ranges for the measures, and floors for the bands (-inf: none).
Target :: struct {
	set:                                 bool,
	peak, loud, length, decay, centroid: Range,
	low, mid, high:                      f64,
}

Material_Centroid :: struct {
	word:     string,
	centroid: Range,
}

Targets :: struct {
	classes:   [Class]Target,
	materials: [dynamic]Material_Centroid,
}

targets_destroy :: proc(t: ^Targets) {
	for m in t.materials {delete(m.word)}
	delete(t.materials)
	t^ = {}
}

// parse_targets reads targets.txt (an error message is on the temp allocator):
//
//	class block_break
//	  peak -3..-1
//	  loud -24..-14
//	  length 0.15..0.6
//	  decay 0.04..0.35
//	  centroid 0..24000      # block classes: the material's row decides instead
//	  mid >= -8
//	end
//	material stone 1500..4000
parse_targets :: proc(text, file: string) -> (t: Targets, err: string) {
	cur: ^Target
	class: Class
	line_no := 0
	fail :: proc(file: string, n: int, format: string, args: ..any) -> string {
		return fmt.tprintf("%s:%d: %s", file, n, fmt.tprintf(format, ..args))
	}
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		line_no += 1
		l := line
		if h := strings.index_byte(l, '#'); h >= 0 {l = l[:h]}
		w := strings.fields(l, context.temp_allocator)
		if len(w) == 0 {continue}
		switch w[0] {
		case "class":
			if cur != nil ||
			   len(w) !=
				   2 {return t, fail(file, line_no, "expected 'class <name>' outside a class")}
			found := false
			for c in Class {
				if class_word(c) == w[1] {class, found = c, true}
			}
			if !found {return t, fail(file, line_no, "'%s' is not a class: %s", w[1], class_names())}
			cur = &t.classes[class]
			cur^ = {
				set  = true,
				low  = math.inf_f64(-1),
				mid  = math.inf_f64(-1),
				high = math.inf_f64(-1),
			}
		case "end":
			if cur == nil {return t, fail(file, line_no, "'end' without a class")}
			cur = nil
		case "material":
			if cur != nil ||
			   len(w) != 3 {return t, fail(file, line_no, "expected 'material <word> <lo>..<hi>'")}
			r, ok := parse_range(w[2])
			if !ok {return t, fail(file, line_no, "'%s' is not a range lo..hi", w[2])}
			append(&t.materials, Material_Centroid{strings.clone(w[1]), r})
		case "peak", "loud", "length", "decay", "centroid":
			if cur == nil ||
			   len(w) !=
				   2 {return t, fail(file, line_no, "expected '%s <lo>..<hi>' inside a class", w[0])}
			r, ok := parse_range(w[1])
			if !ok {return t, fail(file, line_no, "'%s' is not a range lo..hi", w[1])}
			switch w[0] {
			case "peak":
				cur.peak = r
			case "loud":
				cur.loud = r
			case "length":
				cur.length = r
			case "decay":
				cur.decay = r
			case "centroid":
				cur.centroid = r
			}
		case "low", "mid", "high":
			if cur == nil ||
			   len(w) != 3 ||
			   w[1] !=
				   ">=" {return t, fail(file, line_no, "expected '%s >= <dB>' inside a class", w[0])}
			v, ok := strconv.parse_f64(w[2])
			if !ok {return t, fail(file, line_no, "'%s' is not a number", w[2])}
			switch w[0] {
			case "low":
				cur.low = v
			case "mid":
				cur.mid = v
			case "high":
				cur.high = v
			}
		case:
			return t, fail(
				file,
				line_no,
				"'%s' is not a targets word: class, end, material, peak, loud, length, decay, centroid, low, mid, high",
				w[0],
			)
		}
	}
	if cur != nil {return t, fail(file, line_no, "class '%s' has no 'end'", class_word(class))}
	return t, ""
}

@(private)
parse_range :: proc(s: string) -> (r: Range, ok: bool) {
	i := strings.index(s, "..")
	if i < 0 {return}
	r.lo = strconv.parse_f64(s[:i]) or_return
	r.hi = strconv.parse_f64(s[i + 2:]) or_return
	return r, r.lo <= r.hi
}

// material_word: the part of a sound's name before the first dot.
material_of :: proc(name: string) -> string {
	if i := strings.index_byte(name, '.'); i >= 0 {return name[:i]}
	return name
}

// check_targets: what is out of its range, one line each (none: inside).
// A block class takes its centroid from the material of the sound's name.
check_targets :: proc(
	t: ^Targets,
	s: ^Sound,
	m: Measures,
	allocator := context.temp_allocator,
) -> []string {
	out := make([dynamic]string, allocator)
	row := t.classes[s.class]
	if !row.set {
		append(
			&out,
			fmt.aprintf("no targets for class %s", class_word(s.class), allocator = allocator),
		)
		return out[:]
	}
	centroid := row.centroid
	if s.class == .Block_Break || s.class == .Block_Place || s.class == .Block_Step {
		word := material_of(s.name)
		found := false
		for e in t.materials {
			if e.word == word {centroid, found = e.centroid, true}
		}
		if !found {
			append(
				&out,
				fmt.aprintf("no centroid row for material %s", word, allocator = allocator),
			)
		}
	}
	chk :: proc(
		out: ^[dynamic]string,
		a: runtime.Allocator,
		what: string,
		v: f64,
		r: Range,
		unit: string,
	) {
		if v < r.lo || v > r.hi {
			append(
				out,
				fmt.aprintf(
					"%s %.3g%s outside %.4g..%.4g",
					what,
					v,
					unit,
					r.lo,
					r.hi,
					allocator = a,
				),
			)
		}
	}
	chk(&out, allocator, "peak", m.peak, row.peak, " dB")
	chk(&out, allocator, "loud", m.loud, row.loud, " LUFS")
	chk(&out, allocator, "length", m.length, row.length, " s")
	chk(&out, allocator, "decay", m.decay, row.decay, " s")
	chk(&out, allocator, "centroid", m.centroid, centroid, " Hz")
	floor :: proc(out: ^[dynamic]string, a: runtime.Allocator, what: string, v, f: f64) {
		if v < f {append(out, fmt.aprintf("%s %.3g dB under %.3g", what, v, f, allocator = a))}
	}
	floor(&out, allocator, "low", m.low, row.low)
	floor(&out, allocator, "mid", m.mid, row.mid)
	floor(&out, allocator, "high", m.high, row.high)
	return out[:]
}
