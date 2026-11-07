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
	name:    string,
	kind:    Font_Kind,
	base:    string, // a font made from another: the felt piano is the upright
	felt:    bool, // the soft hammer (felt_zone)
	url:     string,
	archive: string,
	sha256:  string, // of the archive
}

FONTS :: [?]Font_Def {
	{
		name = "piano",
		url = "https://freepats.zenvoid.org/Piano/UprightPianoKW/UprightPianoKW-small-SF2-20190703.7z",
		archive = "UprightPianoKW-small-SF2-20190703.7z",
		sha256 = "3bd025e7c2ffa9e6f3f99215ce383c9cebbac991cfbf9be1453cdb4328ec3492",
	},
	{name = "felt", base = "piano", felt = true},
	{
		name = "freepats_harp",
		url = "https://freepats.zenvoid.org/OrchestralStrings/ConcertHarp/ConcertHarp-small-SF2-20200702.tar.xz",
		archive = "ConcertHarp-small-SF2-20200702.tar.xz",
		sha256 = "04d149bd7446e24ce30874de34077aa81a21a1b8d228e5fa81611fc883b18f71",
	},
	{
		name = "freepats_bells",
		url = "https://github.com/freepats/tubular-bells1/releases/download/2024-11-30/TubularBells-small-SF2-20241130.7z",
		archive = "TubularBells-small-SF2-20241130.7z",
		sha256 = "2ebd88d83f67a7a0174b61ca09f28d10355e49c2214b1c769b3cf11e84815c90",
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
	if strings.has_suffix(archive, ".tar.xz") || strings.has_suffix(archive, ".tar.gz") {
		for tool in ([]string{"bsdtar", "tar"}) {
			exe := find_on_path(tool) or_continue
			if run_command({exe, "-xf", archive, "-C", dir}) {return true}
		}
		return false
	}
	for tool in ([]string{"7zz", "7z", "7za", "bsdtar"}) {
		exe := find_on_path(tool) or_continue
		cmd := []string{exe, "x", "-y", strings.concatenate({"-o", dir}), archive}
		if tool == "bsdtar" {cmd = {exe, "-xf", archive, "-C", dir}}
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
