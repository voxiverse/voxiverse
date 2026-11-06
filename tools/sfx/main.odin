package sfx_tool

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import "client:audio/synth"

SOUNDS :: "assets/sounds"

// Writes every variant of every recipe in the base pack to
// build/sounds/<name>.<v>.wav (24-bit mono at 48 kHz) and build/sounds/report.txt:
// each measure against the target range of the sound's class, `ok` or `OUT`.
// Exits 1 if any is out.
//
//	build sfx
main :: proc() {
	dir := filepath.join({"build", "sounds"}) or_else "sounds"
	os.remove_all(dir) // no leftovers of sounds that are gone
	os.make_directory_all(dir)

	ttext, terr := os.read_entire_file(
		filepath.join({SOUNDS, "targets.txt"}) or_else "",
		context.allocator,
	)
	if terr != nil {
		fmt.eprintfln("sfx: cannot read targets.txt: %v", terr)
		os.exit(1)
	}
	targets, err := synth.parse_targets(string(ttext), "targets.txt")
	if err != "" {
		fmt.eprintln(err)
		os.exit(1)
	}

	infos, derr := os.read_all_directory_by_path(SOUNDS, context.allocator)
	if derr != nil {
		fmt.eprintfln("sfx: cannot read %s: %v", SOUNDS, derr)
		os.exit(1)
	}
	slice.sort_by(infos, proc(a, b: os.File_Info) -> bool {return a.name < b.name})

	report := strings.builder_make()
	count, out := 0, 0
	for fi in infos {
		if !strings.has_suffix(fi.name, ".recipe") {continue}
		text, rerr := os.read_entire_file(fi.fullpath, context.allocator)
		if rerr != nil {
			fmt.eprintfln("sfx: cannot read %s: %v", fi.fullpath, rerr)
			os.exit(1)
		}
		set, ok := synth.parse(string(text), fi.name)
		if !ok {
			fmt.eprintln(synth.error_string(set.error))
			os.exit(1)
		}
		for &s in set.sounds {
			for v in 0 ..< s.variants {
				x := synth.generate(&s, v)
				m := synth.measure(x)
				bad := synth.check_targets(&targets, &s, m)
				name := fmt.tprintf("%s.%d", s.name, v)
				fmt.sbprintf(
					&report,
					"%-18s peak %6.1f dB  loud %6.1f LUFS  length %5.3f s  decay %5.3f s  centroid %6.0f Hz  low %6.1f  mid %6.1f  high %6.1f  %s\n",
					name,
					m.peak,
					m.loud,
					m.length,
					m.decay,
					m.centroid,
					m.low,
					m.mid,
					m.high,
					"ok" if len(bad) == 0 else "OUT",
				)
				for b in bad {fmt.sbprintfln(&report, "    %s", b)}
				if len(bad) > 0 {out += 1}
				path := filepath.join({dir, fmt.tprintf("%s.wav", name)}) or_else name
				write_wav(path, x) or_continue
				count += 1
				delete(x)
			}
		}
	}
	rpath := filepath.join({dir, "report.txt"}) or_else "report.txt"
	_ = os.write_entire_file(rpath, transmute([]u8)strings.to_string(report))
	fmt.printfln(
		"sfx: wrote %d sounds to %s, %d out of their targets (report.txt)",
		count,
		dir,
		out,
	)
	if out > 0 {
		os.exit(1)
	}
}

// write_wav: 24-bit PCM, mono, 48 kHz.
write_wav :: proc(path: string, samples: []f32) -> bool {
	n := 3 * len(samples)
	data := make([]u8, 44 + n)
	defer delete(data)
	copy(data[0:], "RIFF")
	endian.put_u32(data[4:], .Little, u32(36 + n))
	copy(data[8:], "WAVEfmt ")
	endian.put_u32(data[16:], .Little, 16)
	endian.put_u16(data[20:], .Little, 1) // PCM
	endian.put_u16(data[22:], .Little, 1) // mono
	endian.put_u32(data[24:], .Little, synth.RATE)
	endian.put_u32(data[28:], .Little, synth.RATE * 3)
	endian.put_u16(data[32:], .Little, 3)
	endian.put_u16(data[34:], .Little, 24)
	copy(data[36:], "data")
	endian.put_u32(data[40:], .Little, u32(n))
	for x, i in samples {
		v := i32(clamp(x, -1, 1) * 8388607)
		data[44 + 3 * i] = u8(v)
		data[45 + 3 * i] = u8(v >> 8)
		data[46 + 3 * i] = u8(v >> 16)
	}
	if err := os.write_entire_file(path, data); err != nil {
		fmt.eprintfln("sfx: cannot write %s: %v", path, err)
		return false
	}
	return true
}
