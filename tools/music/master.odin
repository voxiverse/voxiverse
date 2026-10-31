package music_tool

import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"

import "client:audio"

MUSIC_LUFS :: -20.0
TRUE_PEAK_CEILING_DB :: -1.0
TRIM_FLOOR :: 0.000316 // -70 dBFS
TRIM_TAIL_SECONDS :: 0.05

Mastered :: struct {
	stereo:       []f32,
	frames:       int,
	loop_end:     int, // frames; 0 unless the piece loops
	lufs:         f32,
	true_peak_db: f32,
	shortfall_db: f32, // LU under the target to keep the peaks under the ceiling
}

// master turns a render into the file's content: the loop's tail folded onto
// its start (or a one-shot trimmed to its end), then the gain to the music's
// loudness, held back where the true peak would pass the ceiling. Never a
// limiter.
master :: proc(p: ^Piece, render: []f32, rate := RATE) -> (m: Mastered, ok: bool) {
	frames := len(render) / 2
	x: []f32
	if p.loop {
		end := int(frame_of(p, f64(p.end), f64(rate)) + 0.5)
		if end < 1 || end > frames {return}
		x = make([]f32, 2 * end)
		for i in 0 ..< frames {
			at := i % end
			x[2 * at] += render[2 * i]
			x[2 * at + 1] += render[2 * i + 1]
		}
		m.loop_end = end
	} else {
		last := 0
		for i in 0 ..< frames {
			if abs(render[2 * i]) > TRIM_FLOOR || abs(render[2 * i + 1]) > TRIM_FLOOR {last = i}
		}
		n := min(last + 1 + int(TRIM_TAIL_SECONDS * f64(rate)), frames)
		x = make([]f32, 2 * n)
		copy(x, render[:2 * n])
	}
	meter := new(audio.Meter)
	audio.meter_init(meter, f64(rate))
	audio.meter_push(meter, x)
	loud := audio.meter_integrated(meter)
	if math.is_inf(loud) {return}
	gain_db := f64(MUSIC_LUFS) - f64(loud)
	peak := f64(audio.true_peak(x))
	peak_db := 20 * math.log10(max(peak, 1e-12)) + gain_db
	if peak_db > TRUE_PEAK_CEILING_DB {
		m.shortfall_db = f32(peak_db - TRUE_PEAK_CEILING_DB)
		gain_db -= f64(m.shortfall_db)
		peak_db = TRUE_PEAK_CEILING_DB
	}
	g := f32(math.pow(10, gain_db / 20))
	for &v in x {v *= g}
	audio.meter_init(meter, f64(rate))
	audio.meter_push(meter, x)
	m.lufs = audio.meter_integrated(meter)
	m.true_peak_db = f32(peak_db)
	m.stereo, m.frames = x, len(x) / 2
	return m, true
}

// wav24_encode: interleaved stereo as a 24-bit PCM WAV.
wav24_encode :: proc(x: []f32, rate: int) -> []u8 {
	bytes := len(x) * 3
	out := make([dynamic]u8, 0, 44 + bytes)
	u32le :: proc(out: ^[dynamic]u8, v: u32) {
		for i in 0 ..< 4 {append(out, u8(v >> (8 * u32(i))))}
	}
	u16le :: proc(out: ^[dynamic]u8, v: u16) {append(out, u8(v), u8(v >> 8))}
	append(&out, "RIFF")
	u32le(&out, u32(36 + bytes))
	append(&out, "WAVEfmt ")
	u32le(&out, 16)
	u16le(&out, 1)
	u16le(&out, 2)
	u32le(&out, u32(rate))
	u32le(&out, u32(rate * 6))
	u16le(&out, 6)
	u16le(&out, 24)
	append(&out, "data")
	u32le(&out, u32(bytes))
	for v in x {
		q := i32(math.round(clamp(f64(v), -1, 1) * 8388607))
		append(&out, u8(q), u8(q >> 8), u8(q >> 16))
	}
	return out[:]
}

// find_on_path: the first directory of PATH that has the program.
find_on_path :: proc(name: string) -> (path: string, ok: bool) {
	paths := os.get_env("PATH", context.allocator)
	sep := ";" when ODIN_OS == .Windows else ":"
	suffix := ".exe" when ODIN_OS == .Windows else ""
	for dir in strings.split(paths, sep) {
		if dir == "" {continue}
		candidate := strings.concatenate({dir, "/", name, suffix})
		if os.is_file(candidate) {return candidate, true}
	}
	return
}

run_command :: proc(cmd: []string) -> bool {
	state, _, stderr, err := os.process_exec(os.Process_Desc{command = cmd}, context.allocator)
	if err != nil || !state.success {
		fmt.eprintfln("music: %s failed: %s", cmd[0], string(stderr))
		return false
	}
	return true
}

// encode writes the Ogg Vorbis file: oggenc if there is one, else ffmpeg.
encode :: proc(wav, ogg: string) -> bool {
	if exe, ok := find_on_path("oggenc"); ok {
		return run_command({exe, "-Q", "-q", "5", "-o", ogg, wav})
	}
	if exe, ok := find_on_path("ffmpeg"); ok {
		return run_command(
			{exe, "-v", "error", "-y", "-i", wav, "-c:a", "libvorbis", "-q:a", "5", ogg},
		)
	}
	fmt.eprintln("music: no encoder: install oggenc (vorbis-tools) or ffmpeg with libvorbis")
	return false
}

sha256_hex :: proc(data: []u8) -> string {
	return string(hex.encode(hash.hash_bytes(.SHA256, data)))
}

// num formats a number with at most 3 decimals and at least one, as the
// metadata writes them (a whole value as an integer when `whole`).
num :: proc(v: f64, whole := false) -> string {
	if whole && v == math.floor(v) {return fmt.aprintf("%d", int(v))}
	buf: [64]byte
	s := strconv.write_float(buf[:], v, 'f', 3, 64)
	s = strings.trim_left(s, "+")
	s = strings.trim_right(s, "0")
	if strings.has_suffix(s, ".") {s = strings.concatenate({s, "0"})}
	if s == "-0.0" {s = "0.0"}
	return strings.clone(s)
}

ANY := [1]string{"any"}

Meta :: struct {
	source:           string,
	source_sha256:    string,
	soundfont_sha256: string,
	rate:             int,
}

// metadata_json is the `.json` beside an Ogg, keys in this order.
metadata_json :: proc(p: ^Piece, m: Mastered, meta: Meta) -> string {
	b: strings.Builder
	list :: proc(b: ^strings.Builder, name: string, items: []string, last := false) {
		fmt.sbprintf(b, "  \"%s\": [", name)
		for it, i in items {
			if i > 0 {strings.write_string(b, ", ")}
			fmt.sbprintf(b, "\"%s\"", escape(it))
		}
		strings.write_string(b, "]," if !last else "]")
		strings.write_string(b, "\n")
	}
	any_of :: proc(l: [dynamic]string) -> []string {
		if len(l) > 0 {return l[:]}
		return ANY[:]
	}
	strings.write_string(&b, "{\n")
	fmt.sbprintf(&b, "  \"title\": \"%s\",\n", escape(p.title))
	fmt.sbprintf(&b, "  \"source\": \"%s\",\n", escape(meta.source))
	fmt.sbprintf(&b, "  \"source_sha256\": \"%s\",\n", meta.source_sha256)
	fmt.sbprintf(&b, "  \"soundfont_sha256\": \"%s\",\n", meta.soundfont_sha256)
	fmt.sbprintf(&b, "  \"rate\": %d,\n", meta.rate)
	fmt.sbprintf(&b, "  \"channels\": 2,\n")
	fmt.sbprintf(&b, "  \"frames\": %d,\n", m.frames)
	fmt.sbprintf(&b, "  \"seconds\": %s,\n", num(f64(m.frames) / f64(meta.rate)))
	fmt.sbprintf(&b, "  \"loop\": %v,\n", p.loop)
	fmt.sbprintf(&b, "  \"loop_start\": 0,\n")
	fmt.sbprintf(&b, "  \"loop_end\": %d,\n", m.loop_end)
	fmt.sbprintf(&b, "  \"lufs\": %s,\n", num(f64(m.lufs)))
	fmt.sbprintf(&b, "  \"true_peak_db\": %s,\n", num(f64(m.true_peak_db)))
	key := strings.concatenate({p.key, " ", p.mode}) if p.key != "" else ""
	fmt.sbprintf(&b, "  \"key\": \"%s\",\n", escape(key))
	fmt.sbprintf(&b, "  \"tempo\": %s,\n", num(p.tempos[0].bpm, true))
	list(&b, "mood", p.moods[:])
	list(&b, "place", any_of(p.place))
	list(&b, "time", any_of(p.time))
	list(&b, "depth", any_of(p.depth))
	list(&b, "worlds", any_of(p.worlds), true)
	strings.write_string(&b, "}\n")
	return strings.to_string(b)
}

@(private = "file")
escape :: proc(s: string) -> string {
	r, _ := strings.replace_all(s, "\\", "\\\\")
	r, _ = strings.replace_all(r, "\"", "\\\"")
	return r
}
