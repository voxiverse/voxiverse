package music_tool

import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

// SFZ, the subset the CC0 libraries use (VSCO 2 Community Edition, read in
// place and not converted): `<control>` (default_path), `<global>`, `<master>`,
// `<group>` and `<region>` headers, each inheriting the one above, and the
// opcodes sample, lokey, hikey, key, pitch_keycenter, lovel, hivel, offset,
// end, loop_mode, loop_start, loop_end, ampeg_attack, ampeg_hold, ampeg_decay,
// ampeg_sustain, ampeg_release, volume, pan, tune and transpose. Anything else
// is ignored; an `#include` is not followed. The result is a Soundfont whose
// presets are the files (named without .sfz) and whose zones are the regions,
// so the renderer has one path for both formats. Samples are PCM WAV files
// (16, 24 or 32 bit, or 32-bit float; a stereo file is mixed to mono).

Sfz_Opcodes :: map[string]string

// sfz_read_dir reads every .sfz file under dir into one Soundfont.
sfz_read_dir :: proc(dir: string) -> (sf: Soundfont, err: string, ok: bool) {
	files: [dynamic]string
	sfz_collect(dir, &files)
	slice.sort(files[:])
	if len(files) == 0 {return {}, "no .sfz file", false}
	pool: [dynamic]f32
	samples: [dynamic]Sf_Sample
	insts: [dynamic]Sf_Instrument
	presets: [dynamic]Sf_Preset
	loaded: map[string]int // sample key -> index
	for f in files {
		text, rerr := os.read_entire_file_from_path(f, context.allocator)
		if rerr != nil {return {}, strings.concatenate({"cannot read ", f}), false}
		stem := filepath.stem(f)
		inst, msg, iok := sfz_instrument(
			string(text),
			filepath.dir(f),
			stem,
			&pool,
			&samples,
			&loaded,
		)
		if !iok {return {}, strings.concatenate({f, ": ", msg}), false}
		append(&insts, inst)
		zones := make([]Sf_Zone, 1)
		zones[0] = Sf_Zone {
			gens = slice.clone([]Sf_Gen{{GEN_INSTRUMENT, i16(len(insts) - 1)}}),
		}
		append(&presets, Sf_Preset{name = stem, zones = zones})
	}
	sf.name = "sfz"
	sf.data, sf.samples, sf.instruments, sf.presets = pool[:], samples[:], insts[:], presets[:]
	return sf, "", true
}

@(private = "file")
sfz_collect :: proc(dir: string, out: ^[dynamic]string) {
	files, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil {return}
	for f in files {
		if f.type == .Directory {
			sfz_collect(f.fullpath, out)
		} else if strings.has_suffix(f.name, ".sfz") {
			append(out, f.fullpath)
		}
	}
}

// sfz_parse splits a file into headers and their opcodes, in file order.
Sfz_Section :: struct {
	header:  string,
	opcodes: Sfz_Opcodes,
}

sfz_sections :: proc(text: string) -> []Sfz_Section {
	out: [dynamic]Sfz_Section
	// Comments run to the end of the line; opcodes are name=value, a value
	// running to the next name= (a sample's path may hold spaces).
	clean: strings.Builder
	rest := text
	for len(rest) > 0 {
		line: string
		if nl := strings.index_byte(rest, '\n'); nl >= 0 {
			line, rest = rest[:nl], rest[nl + 1:]
		} else {
			line, rest = rest, ""
		}
		if c := strings.index(line, "//"); c >= 0 {line = line[:c]}
		strings.write_string(&clean, line)
		strings.write_byte(&clean, ' ')
	}
	s := strings.to_string(clean)
	i := 0
	for i < len(s) {
		switch {
		case s[i] == '<':
			end := strings.index_byte(s[i:], '>')
			if end < 0 {return out[:]}
			append(&out, Sfz_Section{header = s[i + 1:i + end], opcodes = make(Sfz_Opcodes)})
			i += end + 1
		case s[i] == ' ' || s[i] == '\t' || s[i] == '\r':
			i += 1
		case:
			eq := strings.index_byte(s[i:], '=')
			if eq < 0 {return out[:]}
			name := strings.trim_space(s[i:i + eq])
			vstart := i + eq + 1
			// The value ends before the next " name=" or "<".
			vend := len(s)
			j := vstart
			for j < len(s) {
				if s[j] == '<' {vend = j; break}
				if s[j] == ' ' {
					k := j + 1
					for k < len(s) &&
					    (s[k] == '_' ||
							    s[k] >= 'a' && s[k] <= 'z' ||
							    s[k] >= '0' && s[k] <= '9') {k += 1}
					if k < len(s) && s[k] == '=' && k > j + 1 {vend = j; break}
				}
				j += 1
			}
			if len(out) > 0 {out[len(out) - 1].opcodes[name] = strings.trim_space(s[vstart:vend])}
			i = vend
		}
	}
	return out[:]
}

// sfz_key reads a note number or a name (c4 is 60, c#4 and db4 are 61).
sfz_key :: proc(s: string) -> (key: int, ok: bool) {
	if v, vok := strconv.parse_int(s, 10); vok {return v, v >= 0 && v <= 127}
	if len(s) < 2 {return}
	n := -1
	switch s[0] | 0x20 {
	case 'c':
		n = 0
	case 'd':
		n = 2
	case 'e':
		n = 4
	case 'f':
		n = 5
	case 'g':
		n = 7
	case 'a':
		n = 9
	case 'b':
		n = 11
	}
	if n < 0 {return}
	i := 1
	if s[i] == '#' {n += 1; i += 1} else if s[i] == 'b' && len(s) > 2 {n -= 1; i += 1}
	oct, ook := strconv.parse_int(s[i:], 10)
	if !ook {return}
	key = (oct + 1) * 12 + n
	return key, key >= 0 && key <= 127
}

@(private = "file")
num :: proc(o: Sfz_Opcodes, name: string, default: f64) -> f64 {
	if v, ok := o[name]; ok {
		if f, fok := strconv.parse_f64(v); fok {return f}
	}
	return default
}

@(private = "file")
tc :: proc(seconds: f64) -> i16 {
	if seconds <= 0.001 {return -12000}
	return i16(clamp(math.round(1200 * math.log2(seconds)), -12000, 8000))
}

@(private = "file")
sfz_instrument :: proc(
	text, dir, name: string,
	pool: ^[dynamic]f32,
	samples: ^[dynamic]Sf_Sample,
	loaded: ^map[string]int,
) -> (
	inst: Sf_Instrument,
	err: string,
	ok: bool,
) {
	zones: [dynamic]Sf_Zone
	control, global, master, group: Sfz_Opcodes
	merged :: proc(layers: ..Sfz_Opcodes) -> Sfz_Opcodes {
		out := make(Sfz_Opcodes)
		for l in layers {
			for k, v in l {out[k] = v}
		}
		return out
	}
	default_path := ""
	for sec in sfz_sections(text) {
		switch sec.header {
		case "control":
			control = sec.opcodes
			default_path = control["default_path"] or_else ""
		case "global":
			global, master, group = sec.opcodes, nil, nil
		case "master":
			master, group = sec.opcodes, nil
		case "group":
			group = sec.opcodes
		case "region":
			o := merged(global, master, group, sec.opcodes)
			file, has := o["sample"]
			if !has {continue}
			if strings.has_prefix(file, "*") {continue} 	// a generator, not a sample
			file, _ = strings.replace_all(file, "\\", "/")
			path := strings.concatenate({dir, "/", default_path, file})
			offset, end := int(num(o, "offset", 0)), int(num(o, "end", -1))
			skey := strings.concatenate(
				{path, "|", o["offset"] or_else "", "|", o["end"] or_else ""},
			)
			sid, seen := loaded[skey]
			if !seen {
				data, rate, wok := wav_read_mono(path)
				if !wok {return {}, strings.concatenate({"cannot read the sample ", path}), false}
				start := len(pool)
				append(pool, ..data)
				n := len(data)
				e := n if end < 0 || end >= n else end + 1
				loop_start := int(num(o, "loop_start", 0))
				loop_end := int(num(o, "loop_end", f64(e - 1))) + 1
				append(
					samples,
					Sf_Sample {
						name = file,
						start = u32(start + min(offset, e)),
						end = u32(start + e),
						loop_start = u32(start + min(loop_start, e)),
						loop_end = u32(start + min(loop_end, e)),
						rate = u32(rate),
						pitch = 60,
					},
				)
				sid = len(samples) - 1
				loaded[skey] = sid
			}
			lokey, hikey := 0, 127
			root := 60
			if k, kok := o["key"]; kok {
				kk, _ := sfz_key(k)
				lokey, hikey, root = kk, kk, kk
			}
			if k, kok := o["lokey"]; kok {lokey, _ = sfz_key(k)}
			if k, kok := o["hikey"]; kok {hikey, _ = sfz_key(k)}
			if k, kok := o["pitch_keycenter"]; kok {root, _ = sfz_key(k)}
			lovel, hivel := int(num(o, "lovel", 0)), int(num(o, "hivel", 127))
			gens: [dynamic]Sf_Gen
			append(&gens, Sf_Gen{GEN_KEY_RANGE, i16(u16(lokey) | u16(hikey) << 8)})
			append(&gens, Sf_Gen{GEN_VEL_RANGE, i16(u16(lovel) | u16(hivel) << 8)})
			append(&gens, Sf_Gen{GEN_ROOT, i16(root)})
			cents := num(o, "tune", 0) + 100 * num(o, "transpose", 0)
			append(&gens, Sf_Gen{GEN_COARSE, i16(math.trunc(cents / 100))})
			append(&gens, Sf_Gen{GEN_FINE, i16(math.round(cents - 100 * math.trunc(cents / 100)))})
			mode := o["loop_mode"] or_else ""
			switch mode {
			case "loop_continuous":
				append(&gens, Sf_Gen{GEN_SAMPLE_MODES, 1})
			case "loop_sustain":
				append(&gens, Sf_Gen{GEN_SAMPLE_MODES, 3})
			case "one_shot", "no_loop":
				append(&gens, Sf_Gen{GEN_SAMPLE_MODES, 0})
			case:
				// Without a mode a region loops when it gives its loop points.
				if "loop_start" in o &&
				   "loop_end" in o {append(&gens, Sf_Gen{GEN_SAMPLE_MODES, 1})}
			}
			append(&gens, Sf_Gen{GEN_ATTACK, tc(num(o, "ampeg_attack", 0))})
			append(&gens, Sf_Gen{GEN_HOLD, tc(num(o, "ampeg_hold", 0))})
			append(&gens, Sf_Gen{GEN_DECAY, tc(num(o, "ampeg_decay", 0))})
			sus := clamp(num(o, "ampeg_sustain", 100), 0.001, 100)
			append(&gens, Sf_Gen{GEN_SUSTAIN, i16(clamp(-200 * math.log10(sus / 100), 0, 1440))})
			append(&gens, Sf_Gen{GEN_RELEASE, tc(num(o, "ampeg_release", 0.001))})
			vol := num(o, "volume", 0)
			append(&gens, Sf_Gen{GEN_ATTENUATION, i16(clamp(-vol * 10, 0, 1440))})
			append(&gens, Sf_Gen{GEN_PAN, i16(clamp(num(o, "pan", 0) * 5, -500, 500))})
			append(&gens, Sf_Gen{GEN_SAMPLE_ID, i16(sid)})
			append(&zones, Sf_Zone{gens[:]})
		}
	}
	if len(zones) == 0 {return {}, "no region", false}
	return Sf_Instrument{name, zones[:]}, "", true
}

// sf_find_named: the preset with this name, or -1.
sf_find_named :: proc(sf: ^Soundfont, name: string) -> int {
	for p, i in sf.presets {
		if p.name == name {return i}
	}
	return -1
}

// wav_read_mono reads a PCM or float WAV file into mono floats.
wav_read_mono :: proc(path: string) -> (out: []f32, rate: int, ok: bool) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {return}
	return wav_decode_mono(data)
}

wav_decode_mono :: proc(b: []u8) -> (out: []f32, rate: int, ok: bool) {
	u16at :: proc(b: []u8, i: int) -> int {return int(b[i]) | int(b[i + 1]) << 8}
	u32at :: proc(b: []u8, i: int) -> int {return u16at(b, i) | u16at(b, i + 2) << 16}
	if len(b) < 12 || string(b[:4]) != "RIFF" || string(b[8:12]) != "WAVE" {return}
	format, channels, bits := 0, 0, 0
	at := 12
	pcm: []u8
	for at + 8 <= len(b) {
		size := u32at(b, at + 4)
		body := b[at + 8:min(at + 8 + size, len(b))]
		switch string(b[at:at + 4]) {
		case "fmt ":
			if len(body) < 16 {return}
			format, channels, rate, bits =
				u16at(body, 0), u16at(body, 2), u32at(body, 4), u16at(body, 14)
			if format == 0xFFFE && len(body) >= 26 {format = u16at(body, 24)}
		case "data":
			pcm = body
		}
		at += 8 + size + (size & 1)
	}
	if channels < 1 || channels > 2 || rate <= 0 || len(pcm) == 0 {return}
	width := bits / 8
	if !(format == 1 && (width == 2 || width == 3 || width == 4)) &&
	   !(format == 3 && width == 4) {return}
	frames := len(pcm) / (width * channels)
	out = make([]f32, frames)
	for f in 0 ..< frames {
		sum: f32
		for c in 0 ..< channels {
			i := (f * channels + c) * width
			v: f32
			switch {
			case format == 3:
				v = transmute(f32)u32(u32at(pcm, i))
			case width == 2:
				v = f32(i16(u16at(pcm, i))) / 32768
			case width == 3:
				v =
					f32(i32(u32(pcm[i]) << 8 | u32(pcm[i + 1]) << 16 | u32(pcm[i + 2]) << 24)) /
					2147483648
			case:
				v = f32(i32(u32at(pcm, i))) / 2147483648
			}
			sum += v
		}
		out[f] = sum / f32(channels)
	}
	return out, rate, true
}
