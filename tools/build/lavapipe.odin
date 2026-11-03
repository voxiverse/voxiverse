package build

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Software Vulkan for Windows CI, pinned and provisioned like the shader
// compiler (glslang.odin): `build lavapipe` downloads Mesa's lavapipe driver
// and LunarG's Vulkan runtime (the loader, vulkan-1.dll), checks both
// against the hashes below and keeps them in build/tools/. CI uses them to
// run the packaged game on runners without a GPU; neither is shipped.
//
// Mesa publishes no Windows builds of its own: the driver comes from
// pal1000/mesa-dist-win's release (the MSVC build; only vulkan_lvp.dll and
// its manifest are kept). Unpacking needs 7-Zip (`7z` on PATH), which the
// runner image has; the system's bsdtar does not read .7z.
//
// To update: bump LAVAPIPE_VERSION and LAVAPIPE_SHA256 (sha256sum of the
// release asset), or the runtime's pair (the file name carries its version).

LAVAPIPE_VERSION :: "26.2.6"
LAVAPIPE_ASSET :: "mesa3d-" + LAVAPIPE_VERSION + "-release-msvc.7z"
LAVAPIPE_SHA256 :: "b2e00615feaba45942343c265cc8c5f576142ca682c1ac6661922d4b72492877"
LAVAPIPE_URL ::
	"https://github.com/pal1000/mesa-dist-win/releases/download/" +
	LAVAPIPE_VERSION +
	"/" +
	LAVAPIPE_ASSET
LAVAPIPE_MEMBERS :: [2]string{"x64/vulkan_lvp.dll", "x64/lvp_icd.x86_64.json"}

VULKAN_RUNTIME_VERSION :: "1.3.296.0"
VULKAN_RUNTIME_ASSET :: "VulkanRT-" + VULKAN_RUNTIME_VERSION + "-Installer.exe"
VULKAN_RUNTIME_SHA256 :: "93a14d17f70bde4e5e2a4daf0af0e72b0fcb9693d84757ffd08255e5828d28ca"
VULKAN_RUNTIME_URL ::
	"https://sdk.lunarg.com/sdk/download/" +
	VULKAN_RUNTIME_VERSION +
	"/windows/" +
	VULKAN_RUNTIME_ASSET

// lavapipe fetches both on first use and prints where they are: the
// driver's manifest (for VK_DRIVER_FILES) and the runtime's installer
// (run with /S).
lavapipe :: proc() -> bool {
	when ODIN_OS != .Windows {
		fmt.eprintln("lavapipe: only provisioned for Windows (other hosts install Mesa)")
		return false
	}
	icd := lavapipe_windows_icd() or_return
	installer := vulkan_runtime_installer() or_return
	fmt.printfln("icd=%s", icd)
	fmt.printfln("runtime=%s", installer)
	return true
}

lavapipe_windows_icd :: proc() -> (path: string, ok: bool) {
	dir := path_join({"build", "tools", strings.concatenate({"lavapipe-", LAVAPIPE_VERSION})})
	icd := path_join({dir, "lvp_icd.x86_64.json"})
	if os.exists(icd) && os.exists(path_join({dir, "vulkan_lvp.dll"})) {
		return absolute_path(icd), true
	}
	os.make_directory_all(dir)
	archive := path_join({"build", "tools", LAVAPIPE_ASSET})
	defer os.remove(archive)
	fmt.printfln("lavapipe: fetching Mesa %s (one time)", LAVAPIPE_VERSION)
	if !fetch_pinned(LAVAPIPE_URL, LAVAPIPE_SHA256, archive) {return "", false}
	// "e": the members land in dir itself, without their x64/ folder.
	cmd := []string{"7z", "e", "-y", strings.concatenate({"-o", dir}), archive}
	members := LAVAPIPE_MEMBERS
	if !run({cmd[0], cmd[1], cmd[2], cmd[3], cmd[4], members[0], members[1]}) || !os.exists(icd) {
		fmt.eprintln("lavapipe: could not unpack the driver (is 7z on PATH?)")
		return "", false
	}
	return absolute_path(icd), true
}

vulkan_runtime_installer :: proc() -> (path: string, ok: bool) {
	dir := path_join(
		{"build", "tools", strings.concatenate({"vulkan-runtime-", VULKAN_RUNTIME_VERSION})},
	)
	file := path_join({dir, VULKAN_RUNTIME_ASSET})
	// Kept only after its hash was checked, so its presence is the cache.
	if os.exists(file) {return absolute_path(file), true}
	os.make_directory_all(dir)
	partial := strings.concatenate({file, ".part"})
	defer os.remove(partial)
	fmt.printfln("lavapipe: fetching the Vulkan runtime %s (one time)", VULKAN_RUNTIME_VERSION)
	if !fetch_pinned(VULKAN_RUNTIME_URL, VULKAN_RUNTIME_SHA256, partial) {return "", false}
	if os.rename(partial, file) != nil {
		fmt.eprintln("lavapipe: cannot keep the Vulkan runtime installer")
		return "", false
	}
	return absolute_path(file), true
}

// fetch_pinned downloads url to dest and refuses it unless its SHA-256 is the pinned one.
fetch_pinned :: proc(url, sha256, dest: string) -> bool {
	if !run({system_tool("curl"), "-fsSL", "--retry", "3", "-o", dest, url}) {
		fmt.eprintfln("lavapipe: download failed: %s", url)
		return false
	}
	if !sha256_matches(dest, sha256) {
		fmt.eprintfln("lavapipe: %s does not match its pinned SHA-256 - refusing to use it", url)
		os.remove(dest)
		return false
	}
	return true
}

absolute_path :: proc(p: string) -> string {
	abs, err := filepath.abs(p, context.allocator)
	return abs if err == nil else p
}

// lavapipe_pin_valid: both pins are 64-digit lower-case hex SHA-256 and
// each URL names its version (what the test checks; no network).
lavapipe_pin_valid :: proc() -> bool {
	return(
		moltenvk_pin_valid(LAVAPIPE_VERSION, LAVAPIPE_SHA256, LAVAPIPE_URL) &&
		moltenvk_pin_valid(VULKAN_RUNTIME_VERSION, VULKAN_RUNTIME_SHA256, VULKAN_RUNTIME_URL) \
	)
}
