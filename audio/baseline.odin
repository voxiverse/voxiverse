package audio

import "core:fmt"
import "core:hash"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"

// Baselines: what a scripted scenario sounded like, as numbers, kept in the
// repository (assets/baselines/audio/<scenario>.txt) so quality cannot drift
// unseen. A baseline holds, for the buses that carried sound, the integrated
// loudness, the true peak, the loudness range and the energy in third-octave
// bands; the decay time of the sounds the scenario marks; and the checksum of
// the master's samples per OS and optimization level (floating point may
// differ in the last bit between them: the numbers are what holds across, the
// checksum what holds on one machine).
//
// baseline_compare says what moved beyond what is tolerated; accepting a
// change is rewriting the file on purpose, and the diff is reviewed like code.

BASELINE_LUFS :: 0.5 // loudness may move this much (LU)
BASELINE_DB :: 1.0 // peaks and bands this much (dB)
BASELINE_RANGE :: 1.0 // loudness range (LU)
BASELINE_DECAY :: 0.25 // decay time, relative
BASELINE_FLOOR :: -60.0 // bands this far under the bus's loudest are not compared

Bus_Numbers :: struct {
	integrated: f32,
	true_peak:  f32,
	range:      f32,
	bands:      [BANDS]f64,
}

Mark :: struct {
	name:     string,
	from, to: int, // frames: a sound's span, its tail included
}

Decay :: struct {
	name: string,
	ms:   f64,
}

Checksum :: struct {
	key:   string, // "Linux.None": the OS and the optimization level
	value: u64,
}

Baseline :: struct {
	scenario:  string,
	rate:      u32,
	frames:    int,
	present:   bit_set[Bus],
	buses:     [Bus]Bus_Numbers,
	decays:    [dynamic]Decay,
	checksums: [dynamic]Checksum,
}

BASELINE_BUSES :: bit_set[Bus]{.Effects, .Ambience, .Music, .Master}

// checksum_key: this build's key in a baseline.
checksum_key :: proc() -> string {
	return fmt.tprintf("%v.%v", ODIN_OS, ODIN_OPTIMIZATION_MODE)
}

// baseline_measure: the numbers of an analysis that kept the audio of
// BASELINE_BUSES.
baseline_measure :: proc(
	name: string,
	a: ^Analysis,
	marks: []Mark,
	allocator := context.allocator,
) -> (
	b: Baseline,
) {
	b.scenario = strings.clone(name, allocator)
	b.rate = a.rate
	b.frames = a.frames
	b.decays = make([dynamic]Decay, allocator)
	b.checksums = make([dynamic]Checksum, allocator)
	for bus in BASELINE_BUSES {
		if a.peak[bus] == 0 {continue}
		r := analysis_report(a, bus)
		b.present += {bus}
		b.buses[bus] = {
			integrated = r.integrated,
			true_peak  = r.true_peak,
			range      = r.range,
			bands      = third_octaves(a.audio[bus][:], a.rate),
		}
	}
	for mk in marks {
		append(
			&b.decays,
			Decay {
				strings.clone(mk.name, allocator),
				decay_time(a.audio[.Master][:], a.rate, mk.from, mk.to),
			},
		)
	}
	append(
		&b.checksums,
		Checksum {
			strings.clone(checksum_key(), allocator),
			hash.fnv64a(slice.to_bytes(a.audio[.Master][:])),
		},
	)
	return
}

baseline_destroy :: proc(b: ^Baseline, allocator := context.allocator) {
	delete(b.scenario, allocator)
	for d in b.decays {delete(d.name, allocator)}
	for c in b.checksums {delete(c.key, allocator)}
	delete(b.decays)
	delete(b.checksums)
	b^ = {}
}

// baseline_format: the file's text. `old` (if any) lends the checksums of the
// other OSes, which this machine cannot recompute.
baseline_format :: proc(b: Baseline, old: Maybe(Baseline) = nil) -> string {
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&sb, "# audio baseline: rewritten by `build audio --accept %s`", b.scenario)
	fmt.sbprintfln(&sb, "scenario %s", b.scenario)
	fmt.sbprintfln(&sb, "rate %d", b.rate)
	fmt.sbprintfln(&sb, "frames %d", b.frames)
	for bus in Bus {
		if bus not_in b.present {continue}
		n := b.buses[bus]
		fmt.sbprintfln(
			&sb,
			"bus %v integrated %s true_peak %s range %.1f",
			bus,
			num(n.integrated),
			num(n.true_peak),
			n.range,
		)
		fmt.sbprintf(&sb, "bands %v", bus)
		for v in n.bands {fmt.sbprintf(&sb, " %.2f", v)}
		fmt.sbprintln(&sb)
	}
	for d in b.decays {fmt.sbprintfln(&sb, "decay %s %.0f", d.name, d.ms)}
	sums := make([dynamic]Checksum, context.temp_allocator)
	append(&sums, ..b.checksums[:])
	if o, ok := old.?; ok {
		for c in o.checksums {
			found := false
			for s in sums {if s.key == c.key {found = true}}
			if !found {append(&sums, c)}
		}
	}
	slice.sort_by(sums[:], proc(a, b: Checksum) -> bool {return a.key < b.key})
	for c in sums {fmt.sbprintfln(&sb, "checksum %s %016x", c.key, c.value)}
	return strings.to_string(sb)
}

@(private = "file")
num :: proc(x: f32) -> string {
	if math.is_inf(x) {return "-inf"}
	return fmt.tprintf("%.1f", x)
}

// baseline_parse reads a file's text.
baseline_parse :: proc(text: string, allocator := context.allocator) -> (b: Baseline, ok: bool) {
	b.decays = make([dynamic]Decay, allocator)
	b.checksums = make([dynamic]Checksum, allocator)
	defer if !ok {baseline_destroy(&b, allocator)}
	text := text
	for line in strings.split_lines_iterator(&text) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) == 0 || f[0][0] == '#' {continue}
		switch f[0] {
		case "scenario":
			if len(f) != 2 {return}
			b.scenario = strings.clone(f[1], allocator)
		case "rate":
			if len(f) != 2 {return}
			b.rate = u32(strconv.parse_uint(f[1]) or_return)
		case "frames":
			if len(f) != 2 {return}
			b.frames = strconv.parse_int(f[1]) or_return
		case "bus":
			if len(f) != 8 ||
			   f[2] != "integrated" ||
			   f[4] != "true_peak" ||
			   f[6] != "range" {return}
			bus := parse_bus(f[1]) or_return
			b.present += {bus}
			b.buses[bus].integrated = parse_num(f[3]) or_return
			b.buses[bus].true_peak = parse_num(f[5]) or_return
			b.buses[bus].range = parse_num(f[7]) or_return
		case "bands":
			if len(f) != 2 + BANDS {return}
			bus := parse_bus(f[1]) or_return
			for i in 0 ..< BANDS {b.buses[bus].bands[i] = f64(parse_num(f[2 + i]) or_return)}
		case "decay":
			if len(f) != 3 {return}
			ms := strconv.parse_f64(f[2]) or_return
			append(&b.decays, Decay{strings.clone(f[1], allocator), ms})
		case "checksum":
			if len(f) != 3 {return}
			v := strconv.parse_u64_of_base(f[2], 16) or_return
			append(&b.checksums, Checksum{strings.clone(f[1], allocator), v})
		case:
			return
		}
	}
	return b, b.scenario != "" && b.rate != 0
}

@(private = "file")
parse_bus :: proc(s: string) -> (b: Bus, ok: bool) {
	for x in Bus {
		if fmt.tprintf("%v", x) == s {return x, true}
	}
	return
}

@(private = "file")
parse_num :: proc(s: string) -> (x: f32, ok: bool) {
	if s == "-inf" {return -math.INF_F32, true}
	v := strconv.parse_f64(s) or_return
	return f32(v), true
}

// baseline_compare lists, in `problems` (temp allocator), what of `got`
// differs from `want` beyond the tolerances. A checksum is compared only if
// the baseline has one for this OS and optimization level.
baseline_compare :: proc(want, got: Baseline) -> (problems: []string) {
	out := make([dynamic]string, context.temp_allocator)
	if want.rate != got.rate {
		append(&out, fmt.tprintf("rate %d, baseline %d", got.rate, want.rate))
	}
	if want.present != got.present {
		append(&out, fmt.tprintf("buses with sound %v, baseline %v", got.present, want.present))
	}
	for bus in want.present & got.present {
		w, g := want.buses[bus], got.buses[bus]
		if !within_lufs(w.integrated, g.integrated, BASELINE_LUFS) {
			append(
				&out,
				fmt.tprintf(
					"%v integrated loudness %s LUFS, baseline %s",
					bus,
					num(g.integrated),
					num(w.integrated),
				),
			)
		}
		if !within_lufs(w.true_peak, g.true_peak, BASELINE_DB) {
			append(
				&out,
				fmt.tprintf(
					"%v true peak %s dBTP, baseline %s",
					bus,
					num(g.true_peak),
					num(w.true_peak),
				),
			)
		}
		if abs(w.range - g.range) > BASELINE_RANGE {
			append(
				&out,
				fmt.tprintf("%v loudness range %.1f LU, baseline %.1f", bus, g.range, w.range),
			)
		}
		loudest := slice.max(w.bands[:])
		for i in 0 ..< BANDS {
			if w.bands[i] < loudest + BASELINE_FLOOR {continue}
			if abs(w.bands[i] - g.bands[i]) > BASELINE_DB {
				centre := 50 * math.pow(2, f64(i) / 3)
				append(
					&out,
					fmt.tprintf(
						"%v band %d (%.0f Hz) %.1f dB, baseline %.1f",
						bus,
						i,
						centre,
						g.bands[i],
						w.bands[i],
					),
				)
			}
		}
	}
	for d in want.decays {
		found := false
		for e in got.decays {
			if e.name != d.name {continue}
			found = true
			if abs(e.ms - d.ms) > max(BASELINE_DECAY * d.ms, 20) {
				append(&out, fmt.tprintf("decay of %s %.0f ms, baseline %.0f", d.name, e.ms, d.ms))
			}
		}
		if !found {append(&out, fmt.tprintf("decay of %s not measured", d.name))}
	}
	key := checksum_key()
	for c in want.checksums {
		if c.key != key {continue}
		for e in got.checksums {
			if e.key == key && e.value != c.value {
				append(
					&out,
					fmt.tprintf("samples %016x, baseline %016x (%s)", e.value, c.value, key),
				)
			}
		}
	}
	return out[:]
}

@(private = "file")
within_lufs :: proc(a, b: f32, tol: f32) -> bool {
	if math.is_inf(a) || math.is_inf(b) {return math.is_inf(a) && math.is_inf(b)}
	return abs(a - b) <= tol
}
