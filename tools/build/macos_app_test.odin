package build

import "core:strings"
import "core:testing"

@(test)
test_info_plist :: proc(t: ^testing.T) {
	text := info_plist("1.0&<2>", "42")
	for want in ([]string{"<key>CFBundleIdentifier</key>\n\t<string>net.voxiverse.game</string>", "<key>CFBundleName</key>\n\t<string>Voxiverse</string>", "<key>CFBundleExecutable</key>\n\t<string>voxiverse</string>", "<key>CFBundlePackageType</key>\n\t<string>APPL</string>", "<key>CFBundleShortVersionString</key>\n\t<string>1.0&amp;&lt;2&gt;</string>", "<key>CFBundleVersion</key>\n\t<string>42</string>", "<key>CFBundleIconFile</key>\n\t<string>Voxiverse</string>", "<key>LSMinimumSystemVersion</key>\n\t<string>" + MACOS_MINIMUM + "</string>", "public.app-category.games", "<key>NSHighResolutionCapable</key>\n\t<true/>", "<key>NSSupportsAutomaticGraphicsSwitching</key>\n\t<true/>"}) {
		testing.expectf(t, strings.contains(text, want), "Info.plist lacks %q", want)
	}
	testing.expect(t, !strings.contains(text, "1.0&<2>"), "a version is escaped")
}

@(test)
test_icns_layout :: proc(t: ^testing.T) {
	a := []u8{1, 2, 3}
	b := []u8{4, 5, 6, 7, 8}
	file := icns_file({"ic11", "ic12"}, {a, b})
	testing.expect_value(t, string(file[:4]), "icns")
	be :: proc(f: []u8) -> int {return(
			int(f[0]) << 24 |
			int(f[1]) << 16 |
			int(f[2]) << 8 |
			int(f[3]) \
		)}
	testing.expect_value(t, len(file), 8 + 8 + 3 + 8 + 5)
	testing.expect_value(t, be(file[4:]), len(file))
	testing.expect_value(t, string(file[8:12]), "ic11")
	testing.expect_value(t, be(file[12:]), 8 + 3)
	testing.expect_value(t, string(file[19:23]), "ic12")
	testing.expect_value(t, be(file[23:]), 8 + 5)
}

@(test)
test_otool_foreign :: proc(t: ^testing.T) {
	ok := "build/voxiverse:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\n\t/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit (x)\n\t@executable_path/../Frameworks/libMoltenVK.dylib (x)\n"
	testing.expect_value(t, otool_foreign(ok), "")
	bad := strings.concatenate(
		{ok, "\t/opt/homebrew/lib/libfoo.dylib (x)\n"},
		context.temp_allocator,
	)
	testing.expect_value(t, otool_foreign(bad), "/opt/homebrew/lib/libfoo.dylib")
}
