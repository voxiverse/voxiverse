package build

import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"

// The shader compiler is pinned and provisioned here, so a fresh machine
// needs nothing installed for it: the first `build shaders` downloads the
// official Khronos release for this host, checks it against the hashes
// below and keeps only the compiler binary in build/tools/.
//
// To update: bump GLSLANG_VERSION and replace the three SHA-256 hashes
// (sha256sum of each release asset).
//
// GLSLANG=/path/to/glslang overrides all of this (e.g. Linux arm64, which
// has no official build).

GLSLANG_VERSION :: "16.6.0"

Glslang_Asset :: struct {
	name:   string, // release asset suffix after "glslang-<version>-"
	sha256: string,
}

when ODIN_OS == .Windows && ODIN_ARCH == .amd64 {
	GLSLANG_ASSET :: Glslang_Asset {
		"windows-x86_64-release.zip",
		"82bf434e69b9bb4829de7e2b4bc2c5e7a7861e53d66cf75e5cc70f5f694a8d9b",
	}
} else when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
	GLSLANG_ASSET :: Glslang_Asset {
		"linux-x86_64-release.tar.gz",
		"2c34071f56ecf39d16233294d3739cf43f981fd39080f2fd9dccb782101191ce",
	}
} else when ODIN_OS == .Darwin {
	GLSLANG_ASSET :: Glslang_Asset {
		"macos-universal-release.tar.gz",
		"4f8c05f2888a73ed0b7b274bc524af9130e09ae94b43c0f3f9ed83cfae852834",
	}
} else {
	GLSLANG_ASSET :: Glslang_Asset{}
}

// glslang_path returns the compiler to use, fetching it on first use.
glslang_path :: proc() -> (path: string, ok: bool) {
	if override, found := os.lookup_env("GLSLANG", context.allocator); found && len(override) > 0 {
		return override, true
	}
	exe_rel := strings.concatenate({"bin/glslang", exe_suffix()})
	dir := path_join({"build", "tools", strings.concatenate({"glslang-", GLSLANG_VERSION})})
	exe := path_join({dir, exe_rel})
	if os.exists(exe) {return exe, true}

	if GLSLANG_ASSET.name == "" {
		fmt.eprintfln(
			"shaders: no official glslang %s build for %v/%v - install glslang and set GLSLANG=/path/to/glslang",
			GLSLANG_VERSION,
			ODIN_OS,
			ODIN_ARCH,
		)
		return "", false
	}

	file := strings.concatenate({"glslang-", GLSLANG_VERSION, "-", GLSLANG_ASSET.name})
	url := strings.concatenate(
		{"https://github.com/KhronosGroup/glslang/releases/download/", GLSLANG_VERSION, "/", file},
	)
	archive := path_join({"build", "tools", file})
	os.make_directory_all(dir)
	defer os.remove(archive)

	fmt.printfln("shaders: fetching glslang %s (one time)", GLSLANG_VERSION)
	if !run({system_tool("curl"), "-fsSL", "--retry", "3", "-o", archive, url}) {
		fmt.eprintfln("shaders: download failed: %s", url)
		return "", false
	}
	if !sha256_matches(archive, GLSLANG_ASSET.sha256) {
		fmt.eprintfln("shaders: %s does not match its pinned SHA-256 - refusing to use it", file)
		return "", false
	}
	if !run({system_tool("tar"), "-xf", archive, "-C", dir, exe_rel}) || !os.exists(exe) {
		fmt.eprintfln("shaders: could not unpack %s", exe_rel)
		return "", false
	}
	return exe, true
}

sha256_matches :: proc(path, expected: string) -> bool {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {return false}
	digest := hash.hash_bytes(.SHA256, data)
	return string(hex.encode(digest)) == expected
}

// system_tool names the OS's own curl/tar. On Windows that is System32's,
// which (unlike a Git-for-Windows GNU tar earlier on PATH) unpacks .zip.
system_tool :: proc(name: string) -> string {
	when ODIN_OS == .Windows {
		root, found := os.lookup_env("SystemRoot", context.allocator)
		if !found {root = "C:\\Windows"}
		return path_join({root, "System32", strings.concatenate({name, ".exe"})})
	} else {
		return name
	}
}
