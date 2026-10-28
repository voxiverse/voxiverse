package build

import "core:fmt"
import "core:os"
import "core:strings"

// MoltenVK, the Vulkan driver on macOS, is pinned and provisioned like the
// shader compiler (glslang.odin): `build` on a Mac downloads the official
// release once, checks it against the hash below and keeps only the
// universal libMoltenVK.dylib in build/tools/moltenvk/. The game finds it
// there (or, packaged, in the .app); nothing else is installed.
//
// To update: bump MOLTENVK_VERSION and replace the SHA-256 of
// MoltenVK-macos.tar (sha256sum of the release asset). The newest release is
// the pin.

MOLTENVK_VERSION :: "v1.4.2"
MOLTENVK_SHA256 :: "f95765a6229cb7b915990a2890ce12ebe36a730b021545d3d52ae69ce4c4024e"
MOLTENVK_ASSET :: "MoltenVK-macos.tar"
MOLTENVK_URL ::
	"https://github.com/KhronosGroup/MoltenVK/releases/download/" +
	MOLTENVK_VERSION +
	"/" +
	MOLTENVK_ASSET

// Where the dylib sits inside the release archive.
MOLTENVK_MEMBER :: "MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib"

// moltenvk_path returns the library (build/tools/moltenvk/libMoltenVK.dylib),
// fetching it on first use.
moltenvk_path :: proc() -> (path: string, ok: bool) {
	dir := path_join({"build", "tools", "moltenvk"})
	dylib := path_join({dir, "libMoltenVK.dylib"})
	// The version that was unpacked, so a bumped pin fetches again.
	stamp := path_join({dir, "version.txt"})
	want := strings.concatenate({MOLTENVK_VERSION, " ", MOLTENVK_SHA256})
	if have, err := os.read_entire_file(stamp, context.allocator);
	   err == nil && string(have) == want && os.exists(dylib) {
		return dylib, true
	}

	os.make_directory_all(dir)
	archive := path_join({dir, MOLTENVK_ASSET})
	defer os.remove(archive)
	fmt.printfln("moltenvk: fetching MoltenVK %s (one time)", MOLTENVK_VERSION)
	if !run({system_tool("curl"), "-fsSL", "--retry", "3", "-o", archive, MOLTENVK_URL}) {
		fmt.eprintfln("moltenvk: download failed: %s", MOLTENVK_URL)
		return "", false
	}
	if !sha256_matches(archive, MOLTENVK_SHA256) {
		fmt.eprintfln(
			"moltenvk: %s does not match its pinned SHA-256 - refusing to use it",
			MOLTENVK_ASSET,
		)
		return "", false
	}
	// --strip-components: the dylib lands in dir itself.
	if !run(
		   {
			   system_tool("tar"),
			   "-xf",
			   archive,
			   "-C",
			   dir,
			   "--strip-components=5",
			   MOLTENVK_MEMBER,
		   },
	   ) ||
	   !os.exists(dylib) {
		fmt.eprintfln("moltenvk: could not unpack %s", MOLTENVK_MEMBER)
		return "", false
	}
	if os.write_entire_file(stamp, transmute([]u8)want) != nil {
		fmt.eprintln("moltenvk: cannot write the version stamp")
		return "", false
	}
	return dylib, true
}

// moltenvk_pin_valid: the pin is a 64-digit lower-case hex SHA-256 and the
// URL names the version (what the test checks; no network).
moltenvk_pin_valid :: proc(version, sha256, url: string) -> bool {
	if len(sha256) != 64 {return false}
	for c in sha256 {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {return false}
	}
	return strings.contains(url, strings.concatenate({"/", version, "/"}, context.temp_allocator))
}
