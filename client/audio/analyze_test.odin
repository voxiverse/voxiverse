package audio

import "core:math"
import "core:testing"

// Tests for M32b: what the analysis says about a mix, and the baselines.

@(private = "file")
tone_sound :: proc(seconds: f32, hz: f64, gain: f32) -> []f32 {
	x := make([]f32, int(seconds * 48000))
	for i in 0 ..< len(x) {x[i] = gain * f32(math.sin(2 * math.PI * hz * f64(i) / 48000))}
	return x
}

// With more audible voices than REAL_VOICES the dump names the ones made
// virtual (priority), a silent one (inaudible), a second play of a busy
// stream (dropped), and the ends of the others.
@(test)
test_analysis_names_decisions :: proc(t: ^testing.T) {
	m := new(Mixer)
	defer free(m)
	mixer_init(m, 48000)
	loud := tone_sound(1, 300, 0.05)
	short := tone_sound(0.1, 500, 0.05)
	defer {delete(loud); delete(short)}
	a_id := add_sound(m, {samples = loud, rate = 48000})
	b_id := add_sound(m, {samples = short, rate = 48000})
	set_sound_name(m, a_id, "loud")
	stream, ok := add_stream(m, TONE, loop = true, crossfade = 0.1, inline = true)
	defer streams_close(m)
	testing.expect(t, ok)
	cap_ok := capture_start(m, 4096)
	testing.expect(t, cap_ok)
	for i in 0 ..< REAL_VOICES + 6 {
		play(m, {sound = a_id, gain = {0.01, 0.01}, loop = true, priority = u8(i % 2)})
	}
	silent := play(m, {sound = a_id, gain = {0, 0}, loop = true, priority = 9})
	play(m, {sound = b_id, gain = {0.2, 0.2}, priority = 9})
	play(m, {sound = stream, gain = {0.2, 0.2}, bus = .Music})
	play(m, {sound = stream, gain = {0.2, 0.2}, bus = .Music}) // busy
	out := make([]f32, 2 * 4800)
	defer delete(out)
	mix(m, out)
	stop(m, silent)
	mix(m, out)
	c := capture_stop(m)
	defer capture_destroy(c)
	data := capture_encode(m, c)
	defer delete(data)
	f, parsed := capture_parse(data)
	testing.expect(t, parsed)
	defer capture_file_destroy(&f)
	testing.expect_value(t, string(f.sounds[a_id].name[:4]), "loud")

	// The replay goes through a fresh mixer with the same sounds.
	r := new(Mixer)
	defer free(r)
	mixer_init(r, 48000)
	add_sound(r, {samples = loud, rate = 48000})
	add_sound(r, {samples = short, rate = 48000})
	_, ok = add_stream(r, TONE, loop = true, crossfade = 0.1, inline = true)
	defer streams_close(r)
	an: Analysis
	defer analysis_destroy(&an)
	testing.expect(t, analyze_replay(r, &f, {.Master}, &an))
	count: [Decision_Kind]int
	why: [Virtual_Reason]int
	for d in an.decisions {
		count[d.kind] += 1
		if d.kind == .Virtualized {why[d.why] += 1}
	}
	testing.expect_value(t, count[.Started], REAL_VOICES + 6 + 3)
	testing.expect_value(t, count[.Dropped], 1)
	testing.expect_value(t, count[.Stopped], 1)
	testing.expect_value(t, count[.Ended], 1) // the short sound
	testing.expect(t, why[.Priority] >= 6, "the low-priority extras are virtual by rank")
	testing.expect_value(t, why[.Inaudible], 1)
	testing.expect(t, an.voices_peak > REAL_VOICES)
	testing.expect(t, an.real_peak <= REAL_VOICES)
	testing.expect_value(t, an.frames, 2 * 4800)
}

// The report's loudness is the mixer's own meter's on the same signal.
@(test)
test_analysis_loudness_matches_meter :: proc(t: ^testing.T) {
	m := new(Mixer)
	defer free(m)
	mixer_init(m, 48000)
	x := tone_sound(3, 997, 0.25)
	defer delete(x)
	id := add_sound(m, {samples = x, rate = 48000})
	an: Analysis
	defer analysis_destroy(&an)
	analysis_attach(m, &an, {.Master, .World})
	play(m, {sound = id, gain = {1, 1}})
	out := make([]f32, 2 * 1000)
	defer delete(out)
	for _ in 0 ..< 144 {
		mix(m, out)
		drain(m)
	}
	r := analysis_report(&an, .Master)
	want := meter_integrated(&m.meter)
	testing.expect(t, abs(r.integrated - want) < 0.01, "same meter, same number")
	// A full-scale-ish 0.25 sine in both ears: about -9 dBFS peak, correlation 1.
	testing.expect(t, abs(r.peak - (-12.04)) < 0.2)
	testing.expect(t, r.true_peak >= r.peak - 0.01)
	testing.expect(t, r.correlation > 0.99)
	testing.expect(t, r.range < 1)
	// World is the same signal before the buses' gains: (nothing above Master's level).
	w := analysis_report(&an, .World)
	testing.expect(t, abs(w.integrated - r.integrated) < 0.5)
}

// A tone between two samples is found by the true-peak measure.
@(test)
test_true_peak_between_samples :: proc(t: ^testing.T) {
	// fs/4 with a 45 degree phase: every sample is 0.707, the waveform peaks at 1.
	x := make([]f32, 2 * 400)
	defer delete(x)
	for i in 0 ..< 400 {
		v := f32(math.sin(2 * math.PI * 0.25 * f64(i) + math.PI / 4))
		x[2 * i], x[2 * i + 1] = v, v
	}
	tp := true_peak(x)
	testing.expect(t, tp > 0.97 && tp < 1.03, "the filter finds the peak between samples")
}

@(test)
test_baseline_roundtrip_and_compare :: proc(t: ^testing.T) {
	make_baseline :: proc(gain: f32) -> Baseline {
		m := new(Mixer)
		defer free(m)
		mixer_init(m, 48000)
		x := tone_sound(1, 700, 0.3)
		defer delete(x)
		id := add_sound(m, {samples = x, rate = 48000})
		an: Analysis
		defer analysis_destroy(&an)
		analysis_attach(m, &an, BASELINE_BUSES)
		play(m, {sound = id, gain = {gain, gain}})
		out := make([]f32, 2 * 480)
		defer delete(out)
		for _ in 0 ..< 120 {mix(m, out)}
		return baseline_measure("unit", &an, {{"tone", 0, 48000}})
	}
	a := make_baseline(0.5)
	b := make_baseline(0.5)
	loud := make_baseline(0.7)
	defer {baseline_destroy(&a); baseline_destroy(&b); baseline_destroy(&loud)}
	testing.expect_value(t, len(baseline_compare(a, b)), 0)
	// A gain 3 dB up fails it, and says which numbers moved.
	problems := baseline_compare(a, loud)
	testing.expect(t, len(problems) > 0)
	// The file round-trips (to the precision it keeps) and still matches.
	text := baseline_format(a)
	parsed, ok := baseline_parse(text)
	testing.expect(t, ok)
	defer baseline_destroy(&parsed)
	testing.expect_value(t, len(baseline_compare(parsed, b)), 0)
	testing.expect(t, len(baseline_compare(parsed, loud)) > 0)
	// Accepting is writing the changed one: then it passes.
	accepted, ok2 := baseline_parse(baseline_format(loud, parsed))
	testing.expect(t, ok2)
	defer baseline_destroy(&accepted)
	testing.expect_value(t, len(baseline_compare(accepted, loud)), 0)
	// Another OS's checksum is kept while this OS's is unchanged, and dropped
	// when the sound changed (it would be stale).
	same := b
	same.checksums = make([dynamic]Checksum, context.temp_allocator)
	append(&same.checksums, Checksum{"Nowhere.None", 7})
	append(&same.checksums, b.checksums[0])
	kept, _ := baseline_parse(baseline_format(b, same))
	defer baseline_destroy(&kept)
	testing.expect_value(t, len(kept.checksums), 2)
	dropped, _ := baseline_parse(baseline_format(loud, same))
	defer baseline_destroy(&dropped)
	testing.expect_value(t, len(dropped.checksums), 1)
	// A wrong checksum for this OS and level fails, one for another does not.
	bad := b
	bad.checksums = make([dynamic]Checksum, context.temp_allocator)
	append(&bad.checksums, Checksum{checksum_key(), 1})
	testing.expect(t, len(baseline_compare(bad, a)) > 0)
	bad.checksums[0].key = "Nowhere.None"
	testing.expect_value(t, len(baseline_compare(bad, a)), 0)
	// Garbage is refused.
	_, junk := baseline_parse(
		"scenario x\nrate 48000\nbus Nope integrated 1 true_peak 2 range 3\n",
	)
	testing.expect(t, !junk)
}

// A sweep draws a rising line in the spectrogram, a silent bus a dark image:
// the brightest row of each column climbs with time and sits at the sweep's
// frequency.
@(test)
test_spectrogram_follows_a_sweep :: proc(t: ^testing.T) {
	rate := u32(48000)
	frames := 48000 * 3
	x := make([]f32, 2 * frames)
	defer delete(x)
	phase := 0.0
	for i in 0 ..< frames {
		hz := 200.0 * math.pow(40.0, f64(i) / f64(frames)) // 200 Hz to 8 kHz
		phase += 2 * math.PI * hz / 48000
		v := 0.5 * f32(math.sin(phase))
		x[2 * i], x[2 * i + 1] = v, v
	}
	pixels, w, h := spectrogram_rgba(x, rate, 300)
	defer delete(pixels)
	testing.expect(t, w > 50 && w <= 301 && h == SPEC_HEIGHT, "size")
	row_of :: proc(pixels: []u8, w, h, col: int) -> (best: int) {
		most := -1
		for row in 0 ..< h {
			p := (row * w + col) * 4
			lum := int(pixels[p]) + int(pixels[p + 1]) + int(pixels[p + 2])
			if lum > most {most, best = lum, row}
		}
		return
	}
	early, late := row_of(pixels, w, h, w / 10), row_of(pixels, w, h, 9 * w / 10)
	testing.expectf(t, late < early - 40, "the line climbs (rows %d, %d)", early, late)
	// At 10% of 3 s the sweep is at 200 * 40^0.1 = 290 Hz: where the log axis puts it.
	top := 20000.0
	want := f64(h) * math.ln(290.0 / SPEC_LOW_HZ) / math.ln(top / SPEC_LOW_HZ)
	got := f64(h - 1 - early)
	testing.expectf(t, abs(got - want) < 14, "row %.0f, wanted %.0f", got, want)
	silent := make([]f32, 2 * 20000)
	defer delete(silent)
	dark, _, _ := spectrogram_rgba(silent, rate, 100)
	defer delete(dark)
	for v, i in dark {if i % 4 != 3 && v > 3 {testing.fail_now(t, "silence is not dark")}}
}
