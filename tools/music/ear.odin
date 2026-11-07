package music_tool

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"

// The ear: what an agent that cannot listen gets instead. It reads a piece
// (from the score parser or the MIDI reader) and measures what a listener
// reacts to, then says where an author can act on it, bar by bar. Nothing
// here is a gate (docs/audio.md, "Music pipeline").
//
// Times are ticks; a "slice" is a stretch in which the sounding notes do not
// change, a "window" is half a bar.

Ear :: struct {
	name:              string,
	file:              string,
	melody:            string, // the part the melody measures read
	melody_notes:      int,
	// the melody
	stepwise:          f64, // share of intervals of 2 semitones or less
	big_leaps:         f64, // share of intervals over 9 semitones
	leap_recovered:    f64, // of leaps of 5 or more, the share answered by a step the other way
	motif_return:      f64, // of the 3-interval figures, the share heard again
	range:             int, // semitones
	longest_run:       int, // intervals in one direction
	// the whole
	harmony_fit:       f64, // mean share of the sounding weight inside the best chord
	strong_beats:      int, // melody notes starting on a half bar
	strong_beat_clash: int, // ... outside that chord
	roughness_mean:    f64, // beats-weighted mean of the worst pair per slice
	roughness_p95:     f64,
	accomp_variety:    f64, // distinct bars among the other parts' bars
	critique:          []string,
}

// A melody note: the highest note at an onset.
Mel :: struct {
	start, length: u32,
	key:           u8,
}

// A note as it sounds: written, then (under the pedal) a half-weight tail.
Sound :: struct {
	start, end, tail_end: u32,
	key, part:            u8,
}

Finding :: struct {
	severity: f64,
	text:     string,
}

TAIL_WEIGHT :: 0.5
LEAP :: 5 // semitones: a leap
BIG_LEAP :: 9 // semitones: over this is a big leap
CRITIQUE_LEAP :: 7 // the critique names unanswered leaps from this size
CRITIQUE_RUN :: 8 // ... and a bar of an accompaniment part played this many times
CRITIQUE_LINES :: 30 // printed lines of one piece's critique (--json has all)

Chord_Type :: struct {
	name:      string,
	intervals: []int,
}

CHORDS := [?]Chord_Type {
	{"major", {0, 4, 7}},
	{"minor", {0, 3, 7}},
	{"dim", {0, 3, 6}},
	{"sus4", {0, 5, 7}},
	{"7", {0, 4, 7, 10}},
	{"min7", {0, 3, 7, 10}},
}

CHORD_SIZE_PRICE :: 0.15 * 4.0 / 12.0 // a 4-note chord pays this share, so size does not win

NOTE_NAMES := [12]string{"c", "c#", "d", "d#", "e", "f", "f#", "g", "g#", "a", "a#", "b"}
ROOT_NAMES := [12]string{"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}

note_name :: proc(key: u8) -> string {
	return fmt.tprintf("%s%d", NOTE_NAMES[key % 12], int(key / 12) - 1)
}

// ---- the piece's bars -------------------------------------------------------

piece_end :: proc(p: ^Piece) -> u32 {
	end := p.end
	for n in p.notes {end = max(end, n.start + n.length)}
	return end
}

// bar_starts is the tick each bar starts at (the meter in force may change).
bar_starts :: proc(p: ^Piece) -> []u32 {
	out: [dynamic]u32
	end := piece_end(p)
	tick := u32(0)
	for tick < end || len(out) == 0 {
		append(&out, tick)
		tick += meter_bar_ticks(meter_at(p.meters[:], tick))
	}
	return out[:]
}

// bar_of is the 1-based bar a tick falls in.
bar_of :: proc(starts: []u32, tick: u32) -> int {
	lo, hi := 0, len(starts) - 1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if starts[mid] <= tick {lo = mid} else {hi = mid - 1}
	}
	return lo + 1
}

// beat_in_bar is the 1-based beat (fractions dropped) of a tick in its bar.
beat_in_bar :: proc(p: ^Piece, starts: []u32, tick: u32) -> int {
	bar := bar_of(starts, tick)
	m := meter_at(p.meters[:], starts[bar - 1])
	return int((tick - starts[bar - 1]) / (4 * PPQ / u32(m.den))) + 1
}

// ---- the melody -------------------------------------------------------------

// melody_part is the part marked `melody`, else the one with the highest mean
// pitch; -1 for a piece without notes.
melody_part :: proc(p: ^Piece) -> int {
	for part, i in p.parts {
		if part.melody {return i}
	}
	best, best_mean := -1, -1.0
	for i in 0 ..< len(p.parts) {
		sum, count := 0.0, 0
		for n in p.notes {
			if int(n.part) == i {sum += f64(n.key); count += 1}
		}
		if count > 0 && sum / f64(count) > best_mean {
			best, best_mean = i, sum / f64(count)
		}
	}
	return best
}

// melody_line is the part's highest note at each onset, in time.
melody_line :: proc(p: ^Piece, part: int) -> []Mel {
	out: [dynamic]Mel
	for n in p.notes {
		if int(n.part) != part {continue}
		if len(out) > 0 && out[len(out) - 1].start == n.start {
			last := &out[len(out) - 1]
			if n.key > last.key {last.key = n.key}
			last.length = max(last.length, n.length)
		} else {
			append(&out, Mel{n.start, n.length, n.key})
		}
	}
	return out[:]
}

interval :: proc(m: []Mel, i: int) -> int {
	return int(m[i + 1].key) - int(m[i].key)
}

sign_of :: proc(v: int) -> int {
	return 1 if v > 0 else -1 if v < 0 else 0
}

// leap_answered: the leap at interval i is followed by a step (at most 4
// semitones) the other way.
leap_answered :: proc(m: []Mel, i: int) -> bool {
	if i + 2 >= len(m) {return false}
	a, b := interval(m, i), interval(m, i + 1)
	return b != 0 && sign_of(a) != sign_of(b) && abs(b) <= 4
}

// note_duration is the time to the next onset (the last note: its length).
note_duration :: proc(m: []Mel, i: int) -> u32 {
	if i + 1 < len(m) {return m[i + 1].start - m[i].start}
	return m[i].length
}

// figure_key names the figure of three intervals at i: the intervals and the
// ratios of the durations of the four notes.
figure_key :: proc(m: []Mel, i: int) -> string {
	b: strings.Builder
	for k in 0 ..< 3 {
		fmt.sbprintf(&b, "%d,", interval(m, i + k))
	}
	for k in 0 ..< 3 {
		a, c := note_duration(m, i + k + 1), note_duration(m, i + k)
		g := gcd(a, c)
		if g == 0 {g = 1}
		fmt.sbprintf(&b, "%d/%d,", a / g, c / g)
	}
	return strings.to_string(b)
}

gcd :: proc(a, b: u32) -> u32 {
	x, y := a, b
	for y != 0 {x, y = y, x % y}
	return x
}

// ---- the sound --------------------------------------------------------------

// sounding lists each note with the tail the pedal gives it: under `ped` a
// note sounds until `unped`, at half weight after its written length.
sounding :: proc(p: ^Piece) -> []Sound {
	end_all := piece_end(p)
	out: [dynamic]Sound
	for n in p.notes {
		end := n.start + n.length
		down := false
		for e in p.pedals {
			if e.part == n.part && e.at < end {down = e.down}
		}
		tail := end
		if down {
			tail = end_all
			for e in p.pedals {
				if e.part == n.part && !e.down && e.at >= end {
					tail = e.at
					break
				}
			}
		}
		append(&out, Sound{n.start, end, max(tail, end), n.key, n.part})
	}
	return out[:]
}

// weight_of is the weight (ticks, the tail at half) a sound has in [a, b).
weight_of :: proc(s: Sound, a, b: u32) -> f64 {
	overlap :: proc(x0, x1, a, b: u32) -> f64 {
		lo, hi := max(x0, a), min(x1, b)
		return f64(hi - lo) if hi > lo else 0
	}
	return overlap(s.start, s.end, a, b) + TAIL_WEIGHT * overlap(s.end, s.tail_end, a, b)
}

Window_Chord :: struct {
	root, kind: int,
	share:      f64, // of the window's weight, inside the chord
	total:      f64,
	pedal_from: u32, // the start of the oldest pedalled tail sounding in the window (0 if none)
	has_pedal:  bool,
}

// best_chord finds the chord that holds the most of a window's weight.
best_chord :: proc(sounds: []Sound, a, b: u32) -> Window_Chord {
	pc: [12]f64
	w := Window_Chord{}
	for s in sounds {
		x := weight_of(s, a, b)
		if x <= 0 {continue}
		pc[s.key % 12] += x
		w.total += x
		if s.end <= a && s.tail_end > a && (!w.has_pedal || s.start < w.pedal_from) {
			w.has_pedal, w.pedal_from = true, s.start
		}
	}
	if w.total <= 0 {return w}
	best: f64 = -1e9
	for root in 0 ..< 12 {
		for c, ci in CHORDS {
			inside := 0.0
			for iv in c.intervals {inside += pc[(root + iv) % 12]}
			share := inside / w.total
			score := share - (CHORD_SIZE_PRICE if len(c.intervals) == 4 else 0)
			if score > best + 1e-12 {
				best = score
				w.root, w.kind, w.share = root, ci, share
			}
		}
	}
	return w
}

in_chord :: proc(w: Window_Chord, key: u8) -> bool {
	for iv in CHORDS[w.kind].intervals {
		if (w.root + iv) % 12 == int(key % 12) {return true}
	}
	return false
}

chord_name :: proc(w: Window_Chord) -> string {
	name := CHORDS[w.kind].name
	if name == "7" {return fmt.tprintf("%s7", ROOT_NAMES[w.root])}
	return fmt.tprintf("%s %s", ROOT_NAMES[w.root], name)
}

// ---- roughness (Sethares) ---------------------------------------------------

HARMONICS :: 6
HARMONIC_DECAY :: 0.88

key_hz :: proc(key: int) -> f64 {
	return 440 * math.pow(2, f64(key - 69) / 12)
}

// sethares is the sensory dissonance of two partials (frequencies, amplitudes).
sethares :: proc(f1, f2, a1, a2: f64) -> f64 {
	lo, hi := min(f1, f2), max(f1, f2)
	s := 0.24 / (0.021 * lo + 19)
	d := hi - lo
	return a1 * a2 * (math.exp(-3.5 * s * d) - math.exp(-5.75 * s * d))
}

// pair_roughness is the dissonance of two notes of 6 harmonics, amplitudes 0.88^k.
pair_roughness :: proc(k1, k2: u8) -> f64 {
	f1, f2 := key_hz(int(k1)), key_hz(int(k2))
	total := 0.0
	for i in 0 ..< HARMONICS {
		for j in 0 ..< HARMONICS {
			total += sethares(
				f1 * f64(i + 1),
				f2 * f64(j + 1),
				math.pow(HARMONIC_DECAY, f64(i)),
				math.pow(HARMONIC_DECAY, f64(j)),
			)
		}
	}
	return total
}

// roughness measures the time-weighted mean and 95th percentile of each
// slice's worst pair (a pedalled tail at half loudness).
roughness :: proc(sounds: []Sound) -> (mean, p95: f64) {
	cuts: [dynamic]u32
	for s in sounds {append(&cuts, s.start, s.end, s.tail_end)}
	slice.sort(cuts[:])
	table := make([]f64, 128 * 128)
	for &v in table {v = -1}
	Slice :: struct {
		value, weight: f64,
	}
	slices: [dynamic]Slice
	active: [dynamic]int
	next := 0
	// sounds are in start order (the notes are)
	for ci in 0 ..< len(cuts) - 1 {
		a, b := cuts[ci], cuts[ci + 1]
		if b <= a {continue}
		for next < len(sounds) && sounds[next].start <= a {
			append(&active, next)
			next += 1
		}
		live: [dynamic]int
		for i in active {
			if sounds[i].tail_end > a {append(&live, i)}
		}
		clear(&active)
		append(&active, ..live[:])
		if len(live) == 0 {continue}
		worst := 0.0
		for x in 0 ..< len(live) {
			for y in x + 1 ..< len(live) {
				sx, sy := sounds[live[x]], sounds[live[y]]
				k1, k2 := min(sx.key, sy.key), max(sx.key, sy.key)
				if table[int(k1) * 128 + int(k2)] < 0 {
					table[int(k1) * 128 + int(k2)] = pair_roughness(k1, k2)
				}
				ax := 1.0 if a < sx.end else TAIL_WEIGHT
				ay := 1.0 if a < sy.end else TAIL_WEIGHT
				worst = max(worst, ax * ay * table[int(k1) * 128 + int(k2)])
			}
		}
		append(&slices, Slice{worst, f64(b - a)})
	}
	total := 0.0
	for s in slices {
		mean += s.value * s.weight
		total += s.weight
	}
	if total <= 0 {return 0, 0}
	mean /= total
	slice.sort_by(slices[:], proc(x, y: Slice) -> bool {return x.value < y.value})
	acc := 0.0
	for s in slices {
		acc += s.weight
		p95 = s.value
		if acc >= 0.95 * total {break}
	}
	return
}

// ---- the accompaniment ------------------------------------------------------

// bar_signatures is, per bar, the pitches and rhythm of a part's notes
// ("" for a bar without notes).
bar_signatures :: proc(p: ^Piece, starts: []u32, part: int) -> []string {
	builders := make([]strings.Builder, len(starts))
	for n in p.notes {
		if int(n.part) != part {continue}
		bar := bar_of(starts, n.start)
		fmt.sbprintf(&builders[bar - 1], "%d:%d:%d,", n.start - starts[bar - 1], n.length, n.key)
	}
	out := make([]string, len(starts))
	for &b, i in builders {out[i] = strings.to_string(b)}
	return out
}

// ---- the ear ----------------------------------------------------------------

// listen measures a piece and writes its critique.
listen :: proc(p: ^Piece, name, file: string) -> Ear {
	e := Ear {
		name = name,
		file = file,
	}
	starts := bar_starts(p)
	findings: [dynamic]Finding
	sources := make(map[u64][2]u32)
	for s in p.sources {
		sources[u64(s.start) << 16 | u64(s.part) << 8 | u64(s.key)] = {s.line, s.col}
	}
	where_ :: proc(
		file: string,
		sources: map[u64][2]u32,
		start: u32,
		part: int,
		key: u8,
	) -> string {
		pos, ok := sources[u64(start) << 16 | u64(part) << 8 | u64(key)]
		if !ok || pos[0] == 0 {return file}
		return fmt.tprintf("%s:%d:%d", file, pos[0], pos[1])
	}
	add :: proc(findings: ^[dynamic]Finding, severity: f64, place, text: string) {
		append(findings, Finding{severity, fmt.tprintf("%s: %s", place, text)})
	}

	mp := melody_part(p)
	m: []Mel
	if mp >= 0 {
		e.melody = p.parts[mp].name
		m = melody_line(p, mp)
	}
	e.melody_notes = len(m)

	if len(m) >= 2 {
		n_iv := len(m) - 1
		steps, bigs, leaps, answered := 0, 0, 0, 0
		lo, hi := 128, 0
		run, longest := 0, 0
		last_dir := 0
		for i in 0 ..< n_iv {
			iv := interval(m, i)
			if abs(iv) <= 2 {steps += 1}
			if abs(iv) > BIG_LEAP {bigs += 1}
			if abs(iv) >= LEAP {
				leaps += 1
				if leap_answered(m, i) {
					answered += 1
				} else if abs(iv) >= CRITIQUE_LEAP {
					to := m[i + 1]
					add(
						&findings,
						f64(abs(iv)),
						where_(file, sources, to.start, mp, to.key),
						fmt.tprintf(
							"bar %d: leap of %d semitones (%s to %s) not answered",
							bar_of(starts, to.start),
							abs(iv),
							note_name(m[i].key),
							note_name(to.key),
						),
					)
				}
			}
			dir := sign_of(iv)
			run = run + 1 if dir != 0 && dir == last_dir else 1 if dir != 0 else 0
			last_dir = dir
			longest = max(longest, run)
		}
		for n in m {
			lo, hi = min(lo, int(n.key)), max(hi, int(n.key))
		}
		e.stepwise = f64(steps) / f64(n_iv)
		e.big_leaps = f64(bigs) / f64(n_iv)
		e.leap_recovered = f64(answered) / f64(leaps) if leaps > 0 else 1
		e.range = hi - lo
		e.longest_run = longest
	}
	if len(m) >= 4 {
		figures := len(m) - 3
		seen := make(map[string]int)
		keys := make([]string, figures)
		for i in 0 ..< figures {
			keys[i] = figure_key(m, i)
			seen[keys[i]] += 1
		}
		back := 0
		for k in keys {
			if seen[k] > 1 {back += 1}
		}
		e.motif_return = f64(back) / f64(figures)
		if back == 0 {
			add(
				&findings,
				50,
				where_(file, sources, m[0].start, mp, m[0].key),
				fmt.tprintf("bars 1-%d: no figure of the melody comes back", len(starts)),
			)
		}
	}

	// the whole
	sounds := sounding(p)
	fit_sum, fit_n := 0.0, 0
	for bi in 0 ..< len(starts) {
		bar_end :=
			starts[bi + 1] if bi + 1 < len(starts) else starts[bi] + meter_bar_ticks(meter_at(p.meters[:], starts[bi]))
		half := (bar_end - starts[bi]) / 2
		for w in 0 ..< 2 {
			a := starts[bi] + u32(w) * half
			b := a + half if w == 0 else bar_end
			chord := best_chord(sounds, a, b)
			if chord.total <= 0 {continue}
			fit_sum += chord.share
			fit_n += 1
			for n in m {
				if n.start != a {continue}
				e.strong_beats += 1
				if in_chord(chord, n.key) {continue}
				e.strong_beat_clash += 1
				text := fmt.tprintf(
					"bar %d beat %d: %s over %s",
					bi + 1,
					beat_in_bar(p, starts, a),
					note_name(n.key),
					chord_name(chord),
				)
				if chord.has_pedal {
					text = fmt.tprintf(
						"%s (pedalled from bar %d)",
						text,
						bar_of(starts, chord.pedal_from),
					)
				}
				// the melody's own onset is the position
				place := where_(file, sources, n.start, mp, n.key)
				append(&findings, Finding{12, fmt.tprintf("%s: %s", place, text)})
			}
		}
	}
	e.harmony_fit = fit_sum / f64(fit_n) if fit_n > 0 else 0
	e.roughness_mean, e.roughness_p95 = roughness(sounds)

	sigs: map[string]bool
	sigs = make(map[string]bool)
	bars_total := 0
	for pi in 0 ..< len(p.parts) {
		if pi == mp {continue}
		part_sigs := bar_signatures(p, starts, pi)
		count := make(map[string]int)
		first, last: map[string]int
		first, last = make(map[string]int), make(map[string]int)
		worst_sig := ""
		for sig, i in part_sigs {
			if sig == "" {continue}
			sigs[sig] = true
			bars_total += 1
			if count[sig] == 0 {first[sig] = i}
			count[sig] += 1
			last[sig] = i
			if count[sig] > count[worst_sig] ||
			   (count[sig] == count[worst_sig] && first[sig] < first[worst_sig]) {
				worst_sig = sig
			}
		}
		// the bar this part plays most, when it plays it over and over
		if count[worst_sig] >= CRITIQUE_RUN {
			place := file
			for n in p.notes {
				if int(n.part) == pi && bar_of(starts, n.start) == first[worst_sig] + 1 {
					place = where_(file, sources, n.start, pi, n.key)
					break
				}
			}
			add(
				&findings,
				f64(count[worst_sig]),
				place,
				fmt.tprintf(
					"bars %d-%d: the %s part plays one bar %d times",
					first[worst_sig] + 1,
					last[worst_sig] + 1,
					p.parts[pi].name,
					count[worst_sig],
				),
			)
		}
	}
	e.accomp_variety = f64(len(sigs)) / f64(bars_total) if bars_total > 0 else 1

	slice.stable_sort_by(findings[:], proc(a, b: Finding) -> bool {
		if a.severity != b.severity {return a.severity > b.severity}
		return a.text < b.text
	})
	lines := make([]string, len(findings))
	for f, i in findings {lines[i] = f.text}
	e.critique = lines
	return e
}

// ear_report is the text an author reads for one piece.
ear_report :: proc(e: Ear, b: ^strings.Builder) {
	fmt.sbprintfln(
		b,
		"%s (melody: %s, %d notes)",
		e.name,
		e.melody if e.melody != "" else "-",
		e.melody_notes,
	)
	fmt.sbprintfln(
		b,
		"  melody: stepwise %.2f  big_leaps %.2f  leap_recovered %.2f  motif_return %.2f  range %d  longest_run %d",
		e.stepwise,
		e.big_leaps,
		e.leap_recovered,
		e.motif_return,
		e.range,
		e.longest_run,
	)
	fmt.sbprintfln(
		b,
		"  whole: harmony_fit %.2f  strong_beat_clash %d/%d  roughness mean %.2f p95 %.2f  accomp_variety %.2f",
		e.harmony_fit,
		e.strong_beat_clash,
		e.strong_beats,
		e.roughness_mean,
		e.roughness_p95,
		e.accomp_variety,
	)
	if len(e.critique) == 0 {return}
	fmt.sbprintln(b, "  critique:")
	for line, i in e.critique {
		if i >= CRITIQUE_LINES {
			fmt.sbprintfln(b, "    ... and %d more (--json has them all)", len(e.critique) - i)
			break
		}
		fmt.sbprintfln(b, "    %s", line)
	}
}
