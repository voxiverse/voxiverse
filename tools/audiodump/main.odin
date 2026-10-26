package audiodump

import "core:flags"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"

import "../../audio"
import "../../base"
import "../../client"

// audiodump prints what a capture file holds (the game's audio recorder, see
// audio/capture.odin) and what the engine did with it, by replaying it
// through the same mixer: the audio's `netdump`.
//
//	build audiodump <capture>                     timeline, decisions, summaries
//	build audiodump <capture> -report             loudness, peaks, correlation per bus
//	build audiodump <capture> -bus:Music -wav:out.wav     one bus (or Master) as a WAV
//	build audiodump <capture> -bus:Music -spectrogram:out.png     ... or as a spectrogram
//	build audiodump <capture> -from:2 -to:5 -sound:Stone  a part, one sound
//
// The replay needs the game's own sounds (client.sounds_init) to match the
// capture's table; when they do not (a capture of another build) the timeline
// still prints, and what needs the audio says why it cannot.

Options :: struct {
	file:        string `args:"pos=0" usage:"capture file"`,
	report:      bool `usage:"per-bus loudness (BS.1770), true peak, range, correlation, real-time counters"`,
	bus:         string `usage:"the bus a -wav takes, or the only one the decisions and report cover (default Master)"`,
	wav:         string `usage:"write the bus's audio to this 32-bit float WAV"`,
	spectrogram: string `usage:"write the bus's spectrogram (log frequency, time across) to this PNG"`,
	from:        f64 `usage:"only from this many seconds into the capture"`,
	to:          f64 `usage:"only up to this many seconds into the capture"`,
	sound:       string `usage:"only sounds whose name contains this"`,
	quiet:       bool `usage:"no timeline: the decisions and summaries only"`,
}

main :: proc() {
	opts: Options
	flags.parse_or_exit(&opts, os.args, .Odin)
	if opts.file == "" {
		fmt.eprintln("audiodump: which capture? (build audiodump <file>)")
		os.exit(1)
	}
	data, err := os.read_entire_file_from_path(opts.file, context.allocator)
	if err != nil {
		fmt.eprintfln("audiodump: cannot read %s: %v", opts.file, err)
		os.exit(1)
	}
	f, ok := audio.capture_parse(data)
	if !ok {
		fmt.eprintfln("audiodump: %s is not a capture this build can read", opts.file)
		os.exit(1)
	}
	bus := audio.Bus.Master
	if opts.bus != "" {
		found := false
		for b in audio.Bus {
			if strings.equal_fold(fmt.tprintf("%v", b), opts.bus) {bus, found = b, true}
		}
		if !found {
			fmt.eprintfln(
				"audiodump: no bus %q (World Player UI Effects Ambience Music Master)",
				opts.bus,
			)
			os.exit(1)
		}
	}
	h := f.header
	rate := f64(h.rate)
	frames := audio.capture_frames(&f)
	fmt.printfln(
		"capture %s: %d Hz, %.2f s, %d sounds, %d commands, from frame %d",
		opts.file,
		h.rate,
		f64(frames) / rate,
		h.sound_count,
		int(h.record_count) - mix_calls(&f),
		h.start_clock,
	)
	if h.overflow > 0 {
		fmt.printfln("  the recorder was full: %d records were lost", h.overflow)
	}
	if h.dropped > 0 {
		fmt.printfln(
			"  the live mixer dropped %d commands (ring full, no free handle, busy stream)",
			h.dropped,
		)
	}
	if f.state != nil {
		fmt.printfln(
			"  (a rolling capture: begins from the mixer's state at frame %d%s)",
			h.start_clock,
			", stream voices replayed without" if h.streams > 0 else "",
		)
	} else if h.start_clock != 0 {
		fmt.println(
			"  (begun mid-session without a state: the audio cannot be remade, only the timeline read)",
		)
	}

	rows := audio.capture_rows(&f)
	sound_ok :: proc(f: ^audio.Capture_File, r: audio.Row, name: string) -> bool {
		if name == "" {return true}
		if r.sound < 0 {return false}
		buf: [audio.SOUND_NAME_LEN + 8]u8
		return strings.contains(audio.sound_name(&f.sounds[r.sound].name, r.sound, buf[:]), name)
	}
	in_time :: proc(frame: u64, rate: f64, o: Options) -> bool {
		t := f64(frame) / rate
		return t >= o.from && (o.to <= 0 || t <= o.to)
	}
	if !opts.quiet {
		fmt.println("\ntimeline")
		shown := 0
		for r in rows {
			if !in_time(r.frame, rate, opts) || !sound_ok(&f, r, opts.sound) {continue}
			fmt.printfln("  %-10s f%-9d  %s", secs(r.frame, rate), r.frame, r.text)
			shown += 1
		}
		fmt.printfln("  (%d of %d commands)", shown, len(rows))
	}

	// What each sound did, from the commands.
	plays := make([]int, h.sound_count)
	by_bus: [audio.Bus]int
	for r in rows {
		if r.is_play {
			plays[r.sound] += 1
			by_bus[r.bus] += 1
		}
	}
	fmt.println("\nsounds")
	for n, i in plays {
		if n == 0 {continue}
		buf: [audio.SOUND_NAME_LEN + 8]u8
		name := audio.sound_name(&f.sounds[i].name, i, buf[:])
		if opts.sound != "" && !strings.contains(name, opts.sound) {continue}
		fmt.printfln("  %-24s %-5d plays", name, n)
	}
	fmt.println("\nbuses")
	for b in audio.Bus {
		if by_bus[b] > 0 {fmt.printfln("  %-8v %-5d plays", b, by_bus[b])}
	}

	// The audio: the game's sounds in a fresh mixer.
	m := new(audio.Mixer)
	audio.mixer_init(m, h.rate)
	bank := new(client.Sound_Bank)
	client.sounds_init(bank, m)
	an: audio.Analysis
	if (h.start_clock != 0 && f.state == nil) ||
	   !audio.analyze_replay(m, &f, {.Master} | {bus}, &an) {
		fmt.println(
			"\nno replay: the capture's sounds are not this build's (or it began mid-session);",
			"decisions, reports and WAVs need the same sounds",
		)
		return
	}
	fmt.println("\ndecisions")
	counts: [audio.Decision_Kind]int
	for d in an.decisions {
		counts[d.kind] += 1
		if d.kind == .Started || d.kind == .Ended || d.kind == .Stopped {continue}
		if !in_time(d.frame, rate, opts) {continue}
		buf: [audio.SOUND_NAME_LEN + 8]u8
		name := audio.sound_name(&f.sounds[d.sound].name, int(d.sound), buf[:])
		if opts.sound != "" && !strings.contains(name, opts.sound) {continue}
		note := ""
		switch d.kind {
		case .Virtualized:
			note =
				"by rank: more audible voices of higher priority than real ones" if d.why == .Priority else "inaudible: nothing to hear"
		case .Restored:
			note = "mixed again"
		case .Dropped:
			note = "did nothing: a stream already playing, or no samples"
		case .Started, .Ended, .Stopped:
		}
		fmt.printfln(
			"  %-10s %-11v %-18s %s  bus %v  priority %d  (%d voices playing)  %s",
			secs(d.frame, rate),
			d.kind,
			name,
			audio.voice_label(d.voice),
			d.bus,
			d.priority,
			d.voices,
			note,
		)
	}
	fmt.printfln(
		"  started %d, ended %d, stopped %d, virtualized %d, restored %d, dropped %d; at most %d voices at once, %d mixed",
		counts[.Started],
		counts[.Ended],
		counts[.Stopped],
		counts[.Virtualized],
		counts[.Restored],
		counts[.Dropped],
		an.voices_peak,
		an.real_peak,
	)

	if opts.report {
		fmt.println("\nreport")
		fmt.println("  bus       integrated   momentary    range   true peak   correlation")
		for b in audio.Bus {
			if an.peak[b] == 0 {continue}
			r := audio.analysis_report(&an, b)
			fmt.printfln(
				"  %-8v %-7s LUFS %-7s LUFS %-5.1f LU %-7s dBTP   %-6.2f   (%d plays, at most %d voices)",
				b,
				lu(r.integrated),
				lu(r.momentary),
				r.range,
				lu(r.true_peak),
				r.correlation,
				an.plays[b],
				an.peak_voices[b],
			)
		}
		fmt.printfln(
			"  limiter: reduced in %d blocks, down to %.1f dB; guarded samples: %d",
			an.limiter_blocks,
			20 * math.log10(an.limiter_low),
			an.guarded,
		)
		fmt.println(
			"  (the real-time counters - underruns, late, callback time - live in the running game's audio overlay and log, not in a capture)",
		)
	}
	if opts.spectrogram != "" {
		pixels, w, h := audio.spectrogram_rgba(an.audio[bus][:], h.rate, 4096)
		defer delete(pixels)
		png, perr := base.png_encode(w, h, pixels)
		if perr != nil || os.write_entire_file(opts.spectrogram, png) != nil {
			fmt.eprintfln("audiodump: cannot write %s", opts.spectrogram)
			os.exit(1)
		}
		fmt.printfln("\nwrote %s: %v, %d x %d", opts.spectrogram, bus, w, h)
	}
	if opts.wav != "" {
		if !audio.wav_write(opts.wav, an.audio[bus][:], h.rate) {os.exit(1)}
		fmt.printfln("\nwrote %s: %v, %.2f s", opts.wav, bus, f64(len(an.audio[bus])) / 2 / rate)
	}
}

secs :: proc(frame: u64, rate: f64) -> string {
	return fmt.tprintf("%.4fs", f64(frame) / rate)
}

mix_calls :: proc(f: ^audio.Capture_File) -> (n: int) {
	for r in f.records {if r.frames > 0 || r.drops > 0 {n += 1}}
	return
}

lu :: proc(x: f32) -> string {
	if math.is_inf(x) {return "-inf"}
	return fmt.tprintf("%.1f", x)
}
