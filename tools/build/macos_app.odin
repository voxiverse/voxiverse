package build

import "core:fmt"
import "core:os"
import "core:strings"

import "client:font"
import "client:ui"
import "common:base"

// The macOS .app: its Info.plist and icon file are made here from pure
// procedures (tested on any OS); package_game assembles and signs the bundle
// (package.odin).

// MACOS_MINIMUM: the lowest macOS asked for, passed to the linker
// (-minimum-os-version) and written to Info.plist. A tester's report on an
// older macOS is what moves it (docs/platforms.md).
MACOS_MINIMUM :: "13.0"

APP_IDENTIFIER :: "net.voxiverse.game"

// ICNS_ENTRIES: the sizes of Voxiverse.icns, each a PNG of that many pixels.
ICNS_ENTRIES :: [6]struct {
	kind: string,
	size: int,
}{{"ic11", 32}, {"ic12", 64}, {"ic07", 128}, {"ic08", 256}, {"ic09", 512}, {"ic10", 1024}}

xml_escape :: proc(s: string) -> string {
	out, _ := strings.replace_all(s, "&", "&amp;", context.temp_allocator)
	out, _ = strings.replace_all(out, "<", "&lt;", context.temp_allocator)
	out, _ = strings.replace_all(out, ">", "&gt;", context.temp_allocator)
	return out
}

// info_plist: the bundle's Info.plist for a version (short: "0.21.0", no commit;
// build: the commit count).
info_plist :: proc(short_version, build_number: string) -> string {
	return fmt.tprintf(
		`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>%s</string>
	<key>CFBundleName</key>
	<string>Voxiverse</string>
	<key>CFBundleDisplayName</key>
	<string>Voxiverse</string>
	<key>CFBundleExecutable</key>
	<string>voxiverse</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>%s</string>
	<key>CFBundleVersion</key>
	<string>%s</string>
	<key>CFBundleIconFile</key>
	<string>Voxiverse</string>
	<key>LSMinimumSystemVersion</key>
	<string>%s</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.games</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSSupportsAutomaticGraphicsSwitching</key>
	<true/>
</dict>
</plist>
`,
		APP_IDENTIFIER,
		xml_escape(short_version),
		xml_escape(build_number),
		MACOS_MINIMUM,
	)
}

// icns_file: an Apple icon file from (type, PNG) entries: "icns", the total
// length, then each entry's type, its length (with these 8 bytes) and the PNG,
// all big endian.
icns_file :: proc(kinds: []string, pngs: [][]u8) -> []u8 {
	out := make([dynamic]u8, context.temp_allocator)
	u32be :: proc(b: ^[dynamic]u8, v: int) {append(b, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))}
	total := 8
	for png in pngs {total += 8 + len(png)}
	append(&out, "icns")
	u32be(&out, total)
	for png, i in pngs {
		append(&out, kinds[i])
		u32be(&out, 8 + len(png))
		append(&out, ..png)
	}
	return out[:]
}

// write_icns makes build/Voxiverse.icns from the generated icon.
write_icns :: proc() -> (path: string, ok: bool) {
	f, font_ok := font.load(ICON_FONT)
	if !font_ok {
		fmt.eprintln("build: icon: cannot read the font")
		return "", false
	}
	entries := ICNS_ENTRIES
	kinds: [len(entries)]string
	pngs: [len(entries)][]u8
	for e, i in entries {
		png, err := base.png_encode(
			e.size,
			e.size,
			ui.app_icon(&f, e.size, context.temp_allocator),
		)
		if err != nil {
			fmt.eprintfln("build: icon: %v", err)
			return "", false
		}
		kinds[i], pngs[i] = e.kind, png
	}
	path = "build/Voxiverse.icns"
	if os.write_entire_file(path, icns_file(kinds[:], pngs[:])) != nil {
		fmt.eprintln("build: cannot write the icon")
		return "", false
	}
	return path, true
}

// otool_foreign returns the first library `otool -L` lists that is not the
// system's (/usr/lib, /System) or the bundle's own Frameworks folder, or "".
// The first line names the file itself.
otool_foreign :: proc(output: string) -> string {
	lines := strings.split_lines(output, context.temp_allocator)
	for line in lines[min(1, len(lines)):] {
		lib := strings.trim_space(line)
		if lib == "" {continue}
		lib = lib[:strings.index_byte(lib, ' ') if strings.index_byte(lib, ' ') >= 0 else len(lib)]
		if strings.has_prefix(lib, "/usr/lib/") ||
		   strings.has_prefix(lib, "/System/") ||
		   strings.has_prefix(lib, "@executable_path/../Frameworks/") {
			continue
		}
		return lib
	}
	return ""
}

// check_libraries fails on a program that needs a library the Mac may not have.
check_libraries :: proc(exe: string) -> bool {
	out, ok := capture({"otool", "-L", exe})
	if !ok {
		fmt.eprintfln("build: otool -L %s failed", exe)
		return false
	}
	if bad := otool_foreign(out); bad != "" {
		fmt.eprintfln("build: %s needs %s, which is not in the system or the bundle", exe, bad)
		return false
	}
	return true
}

// assemble_app builds stage/Voxiverse.app from build/voxiverse and the pinned
// MoltenVK, and signs it and the server ad hoc (not a Developer ID signature,
// not notarized).
assemble_app :: proc(stage: string, v: Version) -> bool {
	check_libraries(path_join({"build", GAME_NAME})) or_return
	check_libraries(path_join({"build", SERVER_NAME})) or_return
	app := path_join({stage, "Voxiverse.app", "Contents"})
	for d in ([]string{"MacOS", "Frameworks", "Resources"}) {
		os.make_directory_all(path_join({app, d}))
	}
	dylib := moltenvk_path() or_return
	icns := write_icns() or_return
	short := v.version
	if i := strings.index_any(short, "-+"); i >= 0 {short = short[:i]}
	count, _ := capture({"git", "rev-list", "--count", "HEAD"})
	count = strings.trim_space(count)
	if count == "" {count = "1"}
	files := [][2]string {
		{path_join({"build", GAME_NAME}), path_join({app, "MacOS", "voxiverse"})},
		{dylib, path_join({app, "Frameworks", "libMoltenVK.dylib"})},
		{icns, path_join({app, "Resources", "Voxiverse.icns"})},
	}
	for f in files {
		if err := os.copy_file(f[1], f[0]); err != nil {
			fmt.eprintfln("build: cannot copy %s: %v", f[0], err)
			return false
		}
	}
	if os.write_entire_file(
		   path_join({app, "Info.plist"}),
		   transmute([]u8)info_plist(short, count),
	   ) !=
	   nil {
		fmt.eprintln("build: cannot write Info.plist")
		return false
	}
	run(
		{"codesign", "--force", "--deep", "--sign", "-", path_join({stage, "Voxiverse.app"})},
	) or_return
	run({"codesign", "--force", "--sign", "-", path_join({stage, SERVER_NAME})}) or_return
	return true
}
