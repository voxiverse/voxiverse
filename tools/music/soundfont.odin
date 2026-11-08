package music_tool

import "core:fmt"
import "core:os"
import "core:strings"

SOUNDFONT_PATH :: "assets/music/voxiverse.sf2"
SOUNDFONT_SHA256 :: "e402377d330065a3c1db59d32ddc341184b7b0e8f990e08aa9f3db35e7ab8f78"

Font_Kind :: enum {
	Sf2, // an SF2 file: presets by bank:program
	Sfz, // a directory of .sfz files: a preset is a file's name without .sfz
}

Font_Def :: struct {
	name:        string,
	kind:        Font_Kind,
	base:        string, // a font made from another: the felt piano is the upright
	program:     u8,
	felt:        bool, // the soft hammer (felt_zone)
	font_sha256: string,
}

FONTS :: [?]Font_Def {
	{name = "piano", program = 0, font_sha256 = SOUNDFONT_SHA256},
	{name = "felt", base = "piano", program = 0, felt = true, font_sha256 = SOUNDFONT_SHA256},
	{name = "freepats_harp", program = 1, font_sha256 = SOUNDFONT_SHA256},
	{name = "freepats_timpani", program = 3, font_sha256 = SOUNDFONT_SHA256},
	{name = "freepats_synthstrings", program = 7, font_sha256 = SOUNDFONT_SHA256},
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

// font_path returns where a font's files are: the SF2 file, or for SFZ the directory.
// $VX_SOUNDFONT=<file.sf2> overrides the soundfont.
font_path :: proc(font: Font_Def) -> (path: string, ok: bool) {
	def := font_source(font)
	if p, found := os.lookup_env("VX_SOUNDFONT", context.allocator); found && len(p) > 0 {
		return p, true
	}
	if def.kind == .Sf2 {
		return SOUNDFONT_PATH, true
	}
	return def.name, true
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
				lf.sha256 = src.name
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

// fonts_sha256 is the hash recorded in a piece's metadata.
fonts_sha256 :: proc(p: ^Piece, cache: map[string]^Loaded_Font) -> string {
	return SOUNDFONT_SHA256
}

// fonts_expected_sha256 computes the expected soundfont_sha256 for a piece.
fonts_expected_sha256 :: proc(p: ^Piece) -> string {
	return SOUNDFONT_SHA256
}
