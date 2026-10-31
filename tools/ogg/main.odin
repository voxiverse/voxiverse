package ogg_tool

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

import "common:ogg"

// The Ogg decoder's maintenance commands (docs/debugging.md):
//
//	build ogg digests     rewrite common/ogg/testdata/digests.txt and print what changed
//	build ogg reference   rewrite common/ogg/testdata/reference/ from the reference decoder (ffmpeg)
//	(the decoder is fuzzed by `build fuzz`, target pack.ogg)
MUSIC_DIR :: "assets/music/"
TESTDATA :: "common/ogg/testdata/"
WINDOW_FRAMES :: 24000 // half a second at 48 kHz

MUSIC :: [7]string{"death", "deep", "discovery", "far", "meadow", "night", "title"}

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: build ogg digests | reference | make-test-files")
		os.exit(1)
	}
	ok := false
	switch os.args[1] {
	case "digests":
		ok = digests()
	case "reference":
		ok = reference()
	case "make-test-files":
		ok = make_test_files()
	case:
		fmt.eprintfln("ogg: unknown command %q", os.args[1])
	}
	os.exit(0 if ok else 1)
}

// golden_files: every file with a golden digest, as paths.
golden_files :: proc() -> []string {
	out := make([dynamic]string)
	for n in MUSIC {append(&out, fmt.aprintf("%s%s.ogg", MUSIC_DIR, n))}
	append(&out, "client/audio/testdata/tone.ogg", "common/game/testdata/click.ogg")
	if files, err := os.read_all_directory_by_path(TESTDATA + "edge", context.allocator);
	   err == nil {
		for f in files {
			if strings.has_suffix(
				f.name,
				".ogg",
			) {append(&out, fmt.aprintf("%sedge/%s", TESTDATA, f.name))}
		}
	}
	return out[:]
}

digests :: proc() -> bool {
	path := TESTDATA + "digests.txt"
	old, _ := os.read_entire_file(path, context.allocator)
	lines := make([dynamic]string)
	for f in golden_files() {
		data, err := os.read_entire_file(f, context.allocator)
		if err != nil {
			fmt.eprintfln("ogg: %s: %v", f, err)
			return false
		}
		d, oerr := ogg.open(data)
		if oerr != .None {
			fmt.eprintfln("ogg: %s: %v", f, oerr)
			return false
		}
		pcm := make([dynamic]f32)
		block: [4096]f32
		inf := ogg.info(d)
		for {
			n, e := ogg.read(d, block[:])
			if e != .None {
				fmt.eprintfln("ogg: %s: read: %v", f, e)
				return false
			}
			if n == 0 {break}
			append(&pcm, ..block[:n * int(ogg.info(d).channels)])
		}
		ogg.close(d)
		append(
			&lines,
			fmt.aprintf(
				"%s %d %d %d %016x",
				f,
				inf.rate,
				inf.channels,
				inf.frames,
				ogg.digest_samples(pcm[:]),
			),
		)
	}
	text := strings.concatenate({strings.join(lines[:], "\n"), "\n"})
	if string(old) == text {
		fmt.println("digests unchanged")
		return true
	}
	before := strings.split_lines(string(old))
	for l in lines {
		if !slice.contains(before, l) {fmt.printfln("+ %s", l)}
	}
	for l in before {
		if l != "" && !slice.contains(lines[:], l) {fmt.printfln("- %s", l)}
	}
	return os.write_entire_file(path, text) == nil
}

// reference decodes each music file with ffmpeg (the reference decoder),
// takes half a second at the start, the middle and the end, rounds it to 16
// bits the way the test does and writes it.
reference :: proc() -> bool {
	os.make_directory_all(TESTDATA + "reference")
	os.make_directory_all("build/tmp")
	for name in MUSIC {
		src := fmt.aprintf("%s%s.ogg", MUSIC_DIR, name)
		tmp := fmt.aprintf("build/tmp/ref_%s.f32", name)
		state, _, errout, err := os.process_exec(
			{
				command = {
					"ffmpeg",
					"-v",
					"error",
					"-y",
					"-i",
					src,
					"-f",
					"f32le",
					"-acodec",
					"pcm_f32le",
					"-ac",
					"2",
					tmp,
				},
			},
			context.allocator,
		)
		if err != nil || !state.success {
			fmt.eprintfln("ogg: ffmpeg failed on %s: %v %s", src, err, string(errout))
			return false
		}
		raw, rerr := os.read_entire_file(tmp, context.allocator)
		if rerr != nil {return false}
		os.remove(tmp)
		samples := slice.reinterpret([]f32, raw)
		frames := len(samples) / 2
		for place, start in ([3]string{"start", "middle", "end"}) {
			at := [3]int{0, frames / 2, frames - WINDOW_FRAMES}[start]
			out := make([]byte, WINDOW_FRAMES * 4)
			for i in 0 ..< WINDOW_FRAMES * 2 {
				endian.put_i16(out[2 * i:], .Little, ogg.to_s16(samples[at * 2 + i]))
			}
			p := fmt.aprintf("%sreference/%s.%s.s16", TESTDATA, name, place)
			if werr := os.write_entire_file(p, out); werr != nil {return false}
		}
	}
	if !reference_edge() {return false}
	fmt.println("reference windows written")
	return true
}

// reference_edge: each edge-case file the reference decoder can decode, whole.
reference_edge :: proc() -> bool {
	files, err := os.read_all_directory_by_path(TESTDATA + "edge", context.allocator)
	if err != nil {return false}
	for f in files {
		if !strings.has_suffix(f.name, ".ogg") {continue}
		name := f.name[:len(f.name) - 4]
		if reason := ogg.reference_skipped(name); reason != "" {
			fmt.printfln("no reference for %s: %s", name, reason)
			continue
		}
		src := fmt.aprintf("%sedge/%s", TESTDATA, f.name)
		tmp := fmt.aprintf("build/tmp/ref_edge_%s.f32", name)
		state, _, errout, perr := os.process_exec(
			{
				command = {
					"ffmpeg",
					"-v",
					"error",
					"-y",
					"-i",
					src,
					"-f",
					"f32le",
					"-acodec",
					"pcm_f32le",
					tmp,
				},
			},
			context.allocator,
		)
		if perr != nil || !state.success {
			fmt.eprintfln("ogg: ffmpeg failed on %s: %v %s", src, perr, string(errout))
			return false
		}
		raw, rerr := os.read_entire_file(tmp, context.allocator)
		if rerr != nil {return false}
		os.remove(tmp)
		samples := slice.reinterpret([]f32, raw)
		info, _, serr := ogg.scan(transmute([]byte)read_file(src))
		if serr != .None {return false}
		channels := int(info.channels)
		out := make([]byte, 2 * len(samples))
		// Reference decoders write the channels in WAVE order; Vorbis's order for six is
		// front left, centre, front right, back left, back right, LFE.
		wave_to_vorbis := [6]int{0, 2, 1, 5, 3, 4}
		for i in 0 ..< len(samples) {
			c := i % channels
			j := i - c + (wave_to_vorbis[c] if channels == 6 else c)
			endian.put_i16(out[2 * j:], .Little, ogg.to_s16(samples[i]))
		}
		p := fmt.aprintf("%sreference/edge_%s.s16", TESTDATA, name)
		if werr := os.write_entire_file(p, out); werr != nil {return false}
	}
	return true
}

read_file :: proc(path: string) -> string {
	data, _ := os.read_entire_file(path, context.allocator)
	return string(data)
}
