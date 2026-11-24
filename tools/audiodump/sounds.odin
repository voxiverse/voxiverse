package audiodump

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "client:audio"
import "client:audio/synth"
import "client:engine"

// sounds_report: every sound the game synthesizes (engine.sounds_init: the blocks'
// breaking, placing and steps, the player's, the creatures', the weapons', the gate's,
// the ambience's beds and thunder), as the mixer holds it, measured: an agent cannot
// listen, so this is what says a sound is harsh (an instant attack, a high crest, much
// energy up high) or quiet. Each row: the sound's name and
//
//	peak    sample peak, dBFS
//	rms     RMS over the sound's length, dBFS
//	crest   peak over RMS, dB (a click is high, a soft hush low)
//	loud    the loudest 400 ms momentary loudness, LUFS (one ear, synth.measure)
//	rise    ms from the onset (-40 dB re peak) to the 1 ms envelope's first half of its top
//	        (a click rises in a millisecond or less, a soft footfall in several)
//	length  s to the end of the last 5 ms frame above -60 dB re peak
//	decay   s from the peak to the first 5 ms frame under -30 dB re peak
//	centroid Hz, of the whole sound
//	>4k     the energy above 4 kHz, dB re the total
//
// With wav, each sound is also written there as <name>.wav (stereo float, both ears alike).
sounds_report :: proc(filter, wav: string) {
	m := new(audio.Mixer)
	audio.mixer_init(m, synth.RATE)
	bank := new(engine.Sound_Bank)
	engine.sounds_init(bank, m)
	if wav != "" {
		if err := os.make_directory_all(wav); err != nil && err != .Exist {
			fmt.eprintfln("audiodump: cannot make %s: %v", wav, err)
			os.exit(1)
		}
	}
	fmt.printfln(
		"%-28s %7s %7s %6s %7s %7s %6s %6s %8s %6s",
		"sound",
		"peak",
		"rms",
		"crest",
		"loud",
		"rise",
		"length",
		"decay",
		"centroid",
		">4k",
	)
	for i in 0 ..< m.count {
		buf: [audio.SOUND_NAME_LEN + 8]u8
		name := audio.sound_name(&m.names[i], i, buf[:])
		if filter != "" && !strings.contains(name, filter) {continue}
		x := m.sounds[i].samples
		s := sound_measures(x)
		fmt.printfln(
			"%-28s %7.1f %7.1f %6.1f %7.1f %7.1f %6.3f %6.3f %8.0f %6.1f",
			name,
			s.peak,
			s.rms,
			s.crest,
			s.loud,
			s.rise_ms,
			s.length,
			s.decay,
			s.centroid,
			s.high_4k,
		)
		if wav != "" {
			st := make([]f32, 2 * len(x), context.temp_allocator)
			for y, k in x {st[2 * k], st[2 * k + 1] = y, y}
			path, _ := filepath.join({wav, fmt.tprintf("%s.wav", name)}, context.temp_allocator)
			if !audio.wav_write(path, st, synth.RATE) {os.exit(1)}
		}
		free_all(context.temp_allocator)
	}
}

Sound_Measures :: struct {
	using measures: synth.Measures,
	rms:            f64, // dBFS, over the length
	crest:          f64, // dB
	rise_ms:        f64, // the onset to the 1 ms envelope's first half of its top
	high_4k:        f64, // dB re the total
}

// sound_measures: synth.measure's, and the ones it has not (x at synth.RATE).
sound_measures :: proc(x: []f32) -> (s: Sound_Measures) {
	s.measures = synth.measure(x)
	peak: f32
	for y in x {peak = max(peak, abs(y))}
	if peak == 0 || len(x) == 0 {return}
	n := clamp(int(s.length * synth.RATE), 1, len(x))
	sum: f64
	for y in x[:n] {sum += f64(y) * f64(y)}
	s.rms = db(math.sqrt(sum / f64(n)))
	s.crest = s.peak - s.rms

	// The rise: the onset, then the 1 ms RMS envelope (every quarter millisecond).
	onset := 0
	for y, i in x {
		if abs(y) >= peak * 0.01 {
			onset = i
			break
		}
	}
	WINDOW :: synth.RATE / 1000
	HOP :: WINDOW / 4
	env := make([dynamic]f64, context.temp_allocator)
	for at := onset; at + WINDOW <= len(x); at += HOP {
		e: f64
		for y in x[at:at + WINDOW] {e += f64(y) * f64(y)}
		append(&env, math.sqrt(e / WINDOW))
	}
	top: f64
	for e in env {top = max(top, e)}
	for e, k in env {
		if e >= 0.5 * top {
			s.rise_ms = f64(k * HOP + WINDOW / 2) * 1000 / synth.RATE
			break
		}
	}

	// The energy above 4 kHz.
	size := 1
	for size < len(x) {size <<= 1}
	re := make([]f64, size, context.temp_allocator)
	im := make([]f64, size, context.temp_allocator)
	for y, i in x {re[i] = f64(y)}
	audio.fft(re, im)
	total, high: f64
	for k in 1 ..< size / 2 {
		p := re[k] * re[k] + im[k] * im[k]
		total += p
		if f64(k) * synth.RATE / f64(size) >= 4000 {high += p}
	}
	s.high_4k = 10 * math.log10(max(high / max(total, 1e-30), 1e-20))
	return
}

db :: proc(x: f64) -> f64 {return 20 * math.log10(max(x, 1e-10))}
