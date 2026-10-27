package music_tool

import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"

// The soundfont is downloaded, not committed (docs/plan.md, Assets): the
// FreePats Upright Piano KW, CC0 by the page's word. The hash is pinned (M43b),
// after the license was read on the download page itself: CC0 1.0.
SOUNDFONT_URL :: "https://freepats.zenvoid.org/Piano/UprightPianoKW/UprightPianoKW-small-SF2-20190703.7z"
SOUNDFONT_FILE :: "UprightPianoKW-small-SF2-20190703.7z"
SOUNDFONT_SHA256 :: "3bd025e7c2ffa9e6f3f99215ce383c9cebbac991cfbf9be1453cdb4328ec3492"
SOUNDFONT_DIR :: "build/tools/soundfont"

// soundfont_path returns the SF2 to render with: $VX_SOUNDFONT, else the
// fetched Upright Piano KW.
soundfont_path :: proc() -> (path: string, ok: bool) {
	if p, found := os.lookup_env("VX_SOUNDFONT", context.allocator); found && len(p) > 0 {
		return p, true
	}
	if SOUNDFONT_SHA256 == "" {
		fmt.eprintln(
			"music: soundfont hash not pinned (set VX_SOUNDFONT=/path/file.sf2 to use any SF2)",
		)
		return
	}
	dir := SOUNDFONT_DIR
	if sf, found := find_sf2(dir); found {return sf, true}
	os.make_directory_all(dir)
	archive := strings.concatenate({dir, "/", SOUNDFONT_FILE})
	fmt.printfln("music: fetching the soundfont (one time)")
	if !run_command({"curl", "-fsSL", "--retry", "3", "-o", archive, SOUNDFONT_URL}) {return}
	data, err := os.read_entire_file_from_path(archive, context.allocator)
	if err != nil || string(hex.encode(hash.hash_bytes(.SHA256, data))) != SOUNDFONT_SHA256 {
		fmt.eprintfln(
			"music: %s does not match its pinned SHA-256: refusing to use it",
			SOUNDFONT_FILE,
		)
		os.remove(archive)
		return
	}
	for tool in ([]string{"7zz", "7z", "7za", "bsdtar"}) {
		exe := find_on_path(tool) or_continue
		cmd := []string{exe, "x", "-y", strings.concatenate({"-o", dir}), archive}
		if tool == "bsdtar" {cmd = {exe, "-xf", archive, "-C", dir}}
		if run_command(cmd) {
			if sf, got := find_sf2(dir); got {return sf, true}
		}
	}
	fmt.eprintln("music: cannot unpack the .7z: install one of 7zz, 7z, 7za or bsdtar")
	return
}

@(private = "file")
find_sf2 :: proc(dir: string) -> (path: string, ok: bool) {
	files, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil {return}
	for f in files {
		if strings.has_suffix(f.name, ".sf2") {return f.fullpath, true}
		if f.type == .Directory {
			if p, found := find_sf2(f.fullpath); found {return p, true}
		}
	}
	return
}
