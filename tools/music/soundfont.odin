package music_tool

import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"

// The fonts are downloaded, not committed, each pinned by the SHA-256 of its
// archive after the license was read on the download page itself (all CC0 1.0;
// the credit lines are in assets/music/CREDITS.txt). A score names a font
// (`instrument harp font freepats_harp preset 0:0`); `piano` is the default.
FONT_DIR :: "build/tools/soundfont"

Font_Kind :: enum {
	Sf2, // an SF2 file: presets by bank:program
	Sfz, // a directory of .sfz files: a preset is a file's name without .sfz
}

Font_Def :: struct {
	name:        string,
	kind:        Font_Kind,
	base:        string, // a font made from another: the felt piano is the upright
	felt:        bool, // the soft hammer (felt_zone)
	url:         string,
	archive:     string,
	sha256:      string, // of the archive
	font_sha256: string, // of the unpacked font (.sf2 or .sfz dir)
}

FONTS :: [?]Font_Def {
	{
		name = "piano",
		url = "https://freepats.zenvoid.org/Piano/UprightPianoKW/UprightPianoKW-small-SF2-20190703.7z",
		archive = "UprightPianoKW-small-SF2-20190703.7z",
		sha256 = "3bd025e7c2ffa9e6f3f99215ce383c9cebbac991cfbf9be1453cdb4328ec3492",
		font_sha256 = "cf2a98eb38a32c4954b4b6e2caae4112d62dd8e892eceefdd7942b0e7d01ac2f",
	},
	{name = "felt", base = "piano", felt = true},
	{
		name = "freepats_harp",
		url = "https://freepats.zenvoid.org/OrchestralStrings/ConcertHarp/ConcertHarp-small-SF2-20200702.tar.xz",
		archive = "ConcertHarp-small-SF2-20200702.tar.xz",
		sha256 = "04d149bd7446e24ce30874de34077aa81a21a1b8d228e5fa81611fc883b18f71",
		font_sha256 = "1796607b3c7dc9ce0d98473c33068ea4c20ab3dfda38a44f157ee10bfed6ccb4",
	},
	{
		name = "freepats_bells",
		url = "https://github.com/freepats/tubular-bells1/releases/download/2024-11-30/TubularBells-small-SF2-20241130.7z",
		archive = "TubularBells-small-SF2-20241130.7z",
		sha256 = "2ebd88d83f67a7a0174b61ca09f28d10355e49c2214b1c769b3cf11e84815c90",
		font_sha256 = "c65f95fa73d881aaaf317029b749abb8b99efb1c1838fb0f34855c5a7188a9eb",
	},
	{
		name = "freepats_timpani",
		url = "https://github.com/freepats/timpani/releases/download/2024-08-10/Timpani-SF2-20240810.7z",
		archive = "Timpani-SF2-20240810.7z",
		sha256 = "6a8dff96d9ad109c7ba6155b11f2c2dcc635850cdd43fc1db460f80c45a8e066",
		font_sha256 = "f4f133d63bca297c98143e95c1f3fe5418a2a51d7b1f4d5470971eec7885d87b",
	},
	{
		name = "freepats_choir",
		url = "https://github.com/freepats/synth-pad-choir/releases/download/2020-05-16/SynthPadChoir-SF2-20200516.7z",
		archive = "SynthPadChoir-SF2-20200516.7z",
		sha256 = "4a6024721615d15bedff030a7e8259d380fdcef51f2a223961c69dfbbbdb39f1",
		font_sha256 = "8688e074a15a40f2d9a251f9a642f67f91b1667ba6f4a1e765b9ee7347260c2d",
	},
	{
		name = "freepats_sweep",
		url = "https://github.com/freepats/sweep-pad/releases/download/2019-08-13/SweepPad-SF2-20190813.7z",
		archive = "SweepPad-SF2-20190813.7z",
		sha256 = "2a2eb595b47e780fc633391f756e972e87512d61adcb9564c3c27b9ffca3fb63",
		font_sha256 = "5a09a1d8ab60d236907572a46af8b4211881e2f8c7325e75f782ad5d7acce433",
	},
	{
		name = "freepats_bowed",
		url = "https://github.com/freepats/synth-pad-bowed/releases/download/2019-07-19/SynthPadBowed-SF2-20190719.7z",
		archive = "SynthPadBowed-SF2-20190719.7z",
		sha256 = "70a1db4b7bd33caf1f37187e29ff367d8c78d7043a6e36cf1b5e99f72412bb56",
		font_sha256 = "d20b2c26757c58665f83850515d68a7ecee11a87103f849be2406f026f9cf52a",
	},
	{
		name = "freepats_synthstrings",
		url = "https://github.com/freepats/synth-strings-1/releases/download/2020-05-28/SynthStrings1-SF2-20200528.7z",
		archive = "SynthStrings1-SF2-20200528.7z",
		sha256 = "1fed457941efbd6e1deca6937d1859db7920946709732265426785e9e11bcf55",
		font_sha256 = "7df5074a9ca497adfc3b63a3501a9244495dbb3334b05bba00789bf83cfe6cd4",
	},
	{
		name = "freepats_recorder",
		url = "https://freepats.zenvoid.org/Wind/Recorder1/Recorder-SF2-20201205.7z",
		archive = "Recorder-SF2-20201205.7z",
		sha256 = "60258c60fcef9e398aca22749cdbeaba792b8fa7c9115e63ceef3aff5d4bd1c0",
		font_sha256 = "fb89e90e6b8b40e6463c7edab8cbf4583abbd8fa2d3e32a9250ce7b91d480722",
	},
	{
		name = "freepats_ocarina",
		url = "https://github.com/freepats/ocarina1/releases/download/2024-10-02/Ocarina-SF2-20241002.7z",
		archive = "Ocarina-SF2-20241002.7z",
		sha256 = "1d48403208a38555503bbd9f65d09815ee4edb10ba01e9a345935ae44c38179c",
		font_sha256 = "e92c42a68cb738663748ce512dfbc7f18c3c3ea38d12df9ce165b249e6da6bc6",
	},
	{
		name = "freepats_glass",
		url = "https://freepats.zenvoid.org/ChromaticPercussion/Glass/Glass-SF2-20191227.7z",
		archive = "Glass-SF2-20191227.7z",
		sha256 = "e73912077f2cf4c16a6861ba0752c864ce78c1b5f609b890dfcbdb312a8bfb15",
		font_sha256 = "c86204d29aa2cb660b00d074468dbfc642cd9b93bdfe639555ba008a6c283968",
	},
}

// extra_fonts: fonts a test registers (an SFZ font made of synthetic files).
extra_fonts: [dynamic]Font_Def

// font_def finds a font by name ("" is the piano).
font_def :: proc(name: string) -> (def: Font_Def, ok: bool) {
	n := name if name != "" else "piano"
	for d in extra_fonts {
		if d.name == n {return d, true}
	}
	for d in FONTS {
		if d.name == n {return d, true}
	}
	return
}

font_names :: proc() -> string {
	b: strings.Builder
	for d, i in FONTS {
		if i > 0 {strings.write_string(&b, ", ")}
		strings.write_string(&b, d.name)
	}
	return strings.to_string(b)
}

// font_source is the font whose files a font reads: itself, or its base.
font_source :: proc(def: Font_Def) -> Font_Def {
	if def.base == "" {return def}
	d, _ := font_def(def.base)
	return d
}

// font_path returns where a font's files are: the SF2 file, or for SFZ the
// directory. $VX_SOUNDFONT=<file.sf2> replaces the piano.
font_path :: proc(font: Font_Def) -> (path: string, ok: bool) {
	def := font_source(font)
	if def.name == "piano" {
		if p, found := os.lookup_env("VX_SOUNDFONT", context.allocator); found && len(p) > 0 {
			return p, true
		}
	}
	dir := strings.concatenate({FONT_DIR, "/", def.name})
	if def.kind == .Sf2 {
		if sf, found := find_ext(dir, ".sf2"); found {return sf, true}
	} else if _, found := find_ext(dir, ".sfz"); found {
		return dir, true
	}
	os.make_directory_all(dir)
	archive := strings.concatenate({dir, "/", def.archive})
	fmt.printfln("music: fetching the font %s (one time)", def.name)
	if !run_command({"curl", "-fsSL", "--retry", "3", "-o", archive, def.url}) {return}
	data, err := os.read_entire_file_from_path(archive, context.allocator)
	if err != nil || string(hex.encode(hash.hash_bytes(.SHA256, data))) != def.sha256 {
		fmt.eprintfln(
			"music: %s does not match its pinned SHA-256: refusing to use it",
			def.archive,
		)
		os.remove(archive)
		return
	}
	if !unpack(archive, dir) {
		fmt.eprintfln(
			"music: cannot unpack %s: install one of 7zz, 7z, 7za, bsdtar or tar",
			def.archive,
		)
		return
	}
	if def.kind == .Sf2 {
		path, ok = find_ext(dir, ".sf2")
		return
	}
	return dir, true
}

@(private = "file")
unpack :: proc(archive, dir: string) -> bool {
	// Windows 10 and later carry tar.exe in System32: it is bsdtar (libarchive),
	// which reads .7z and .tar.xz, so a stock Windows needs no 7-Zip. (A GNU tar
	// from Git for Windows earlier on PATH would not read .7z: System32's is named.)
	when ODIN_OS == .Windows {
		root, found := os.lookup_env("SystemRoot", context.allocator)
		if !found {root = "C:\\Windows"}
		exe := strings.concatenate({root, "\\System32\\tar.exe"})
		if os.exists(exe) && run_command({exe, "-xf", archive, "-C", dir}) {return true}
		// 7-Zip's installer does not put 7z.exe on PATH: look where it installs.
		for var in ([]string{"ProgramFiles", "ProgramFiles(x86)"}) {
			pf := os.lookup_env(var, context.allocator) or_continue
			seven := strings.concatenate({pf, "\\7-Zip\\7z.exe"})
			if os.exists(seven) &&
			   run_command(
				   {seven, "x", "-y", strings.concatenate({"-o", dir}), archive},
			   ) {return true}
		}
	}
	if strings.has_suffix(archive, ".tar.xz") || strings.has_suffix(archive, ".tar.gz") {
		for tool in ([]string{"bsdtar", "tar"}) {
			exe := find_on_path(tool) or_continue
			if run_command({exe, "-xf", archive, "-C", dir}) {return true}
		}
		return false
	}
	for tool in ([]string{"7zz", "7z", "7za", "bsdtar", "tar"}) {
		exe := find_on_path(tool) or_continue
		cmd := []string{exe, "x", "-y", strings.concatenate({"-o", dir}), archive}
		if tool == "bsdtar" || tool == "tar" {cmd = {exe, "-xf", archive, "-C", dir}}
		if run_command(cmd) {return true}
	}
	return false
}

// find_ext finds the first file with a suffix under dir (sorted, so the same
// on every machine).
find_ext :: proc(dir, suffix: string) -> (path: string, ok: bool) {
	files, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil {return}
	for f in files {
		if f.type == .Directory {
			if p, found := find_ext(f.fullpath, suffix); found {return p, true}
		} else if strings.has_suffix(f.name, suffix) {
			return f.fullpath, true
		}
	}
	return
}

// Loaded_Font: a font's samples and presets, and the hash that says when it changed.
Loaded_Font :: struct {
	sf:     Soundfont,
	sha256: string,
}

// fonts_load reads every font the piece names (the fonts a felt piano or any
// other made-from font stands on included), by name.
fonts_load :: proc(
	p: ^Piece,
	cache: ^map[string]^Loaded_Font,
) -> (
	fonts: map[string]^Soundfont,
	ok: bool,
) {
	for part in p.parts {
		def, known := font_def(part.font)
		if !known {
			fmt.eprintfln("music: unknown font '%s'", part.font)
			return
		}
		if def.name in fonts {continue}
		src := font_source(def)
		lf, have := cache[src.name]
		if !have {
			path := font_path(src) or_return
			lf = new(Loaded_Font)
			if src.kind == .Sf2 {
				data, rerr := os.read_entire_file_from_path(path, context.allocator)
				if rerr != nil {
					fmt.eprintfln("music: cannot read %s", path)
					return
				}
				lf.sha256 = sha256_hex(data)
				msg: string
				sok: bool
				lf.sf, msg, sok = sf2_read(data)
				if !sok {
					fmt.eprintfln("music: %s: %s", path, msg)
					return
				}
			} else {
				lf.sha256 = src.sha256
				msg: string
				sok: bool
				lf.sf, msg, sok = sfz_read_dir(path)
				if !sok {
					fmt.eprintfln("music: %s: %s", path, msg)
					return
				}
			}
			cache[src.name] = lf
		}
		fonts[def.name] = &lf.sf
		if part.preset != "" && sf_find_named(&lf.sf, part.preset) < 0 {
			fmt.eprintfln("music: font %s has no preset '%s'", def.name, part.preset)
			return
		}
	}
	return fonts, true
}

// fonts_sha256 is the hash recorded in a piece's metadata: the piano's own
// hash for a piece that plays only the upright (as before there were
// instruments), else one over every font used, by name.
fonts_sha256 :: proc(p: ^Piece, cache: map[string]^Loaded_Font) -> string {
	used: [dynamic]string
	for part in p.parts {
		def, _ := font_def(part.font)
		if !contains(used[:], def.name) {append(&used, def.name)}
	}
	if len(used) == 1 && used[0] == "piano" {return cache["piano"].sha256}
	for i in 1 ..< len(used) { 	// insertion sort: the names are few
		for j := i;
		    j > 0 && used[j] < used[j - 1];
		    j -= 1 {used[j], used[j - 1] = used[j - 1], used[j]}
	}
	b: strings.Builder
	for name in used {
		def, _ := font_def(name)
		fmt.sbprintf(&b, "%s=%s\n", name, cache[font_source(def).name].sha256)
		if def.felt {strings.write_string(&b, "felt=1\n")}
	}
	return sha256_hex(transmute([]u8)strings.to_string(b))
}

// fonts_expected_sha256 computes the expected soundfont_sha256 for a piece from
// the pinned font definitions, without requiring the fonts to be downloaded.
fonts_expected_sha256 :: proc(p: ^Piece) -> string {
	used: [dynamic]string
	for part in p.parts {
		def, _ := font_def(part.font)
		if !contains(used[:], def.name) {append(&used, def.name)}
	}
	piano_def, _ := font_def("piano")
	if len(used) == 1 && used[0] == "piano" {return piano_def.font_sha256}
	for i in 1 ..< len(used) { 	// insertion sort: the names are few
		for j := i;
		    j > 0 && used[j] < used[j - 1];
		    j -= 1 {used[j], used[j - 1] = used[j - 1], used[j]}
	}
	b: strings.Builder
	for name in used {
		def, _ := font_def(name)
		fmt.sbprintf(&b, "%s=%s\n", name, font_source(def).font_sha256)
		if def.felt {strings.write_string(&b, "felt=1\n")}
	}
	return sha256_hex(transmute([]u8)strings.to_string(b))
}
