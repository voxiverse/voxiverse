package build

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

// Versions, Windows resources and release packages (docs/plan.md, M21).

// Version: what a build is, from git (base/version.odin says how players
// see it).
Version :: struct {
	version: string, // "0.21.0" on a version tag, "0.21.0+5" after it
	name:    string, // a release's name, from its tag's message; or empty
	commit:  string, // short hash, "-dirty" with uncommitted changes
}

// version_of: on a commit tagged v<major>.<minor>.<patch> with nothing
// uncommitted, that version, and the tag's message (an annotated tag:
// `git tag -a v0.21.0 -m "Pre-Alpha 1"`) as its name. Elsewhere the last
// such tag's version plus the commits since ("0.21.0+5": semver's build
// metadata, after 0.21.0, where "-dev" would mean before it); "0.0.0-dev"
// before any tag.
version_of :: proc() -> (v: Version) {
	v.version = "0.0.0-dev"
	v.commit = "unknown"
	hash, in_git := capture({"git", "rev-parse", "--short=12", "HEAD"})
	if !in_git {return}
	v.commit = strings.trim_space(hash)
	dirty := false
	if status, _ := capture({"git", "status", "--porcelain", "--untracked-files=no"});
	   strings.trim_space(status) != "" {
		v.commit = strings.concatenate({v.commit, "-dirty"})
		dirty = true
	}
	if tag, ok := capture({"git", "describe", "--tags", "--exact-match", "--match", "v[0-9]*"});
	   ok && !dirty {
		tag = strings.trim_space(tag)
		v.version = tag[1:]
		// A lightweight tag's "contents" are its commit's message: only an
		// annotated tag (objecttype "tag") names the release.
		info, _ := capture(
			{
				"git",
				"for-each-ref",
				"--format=%(objecttype) %(contents:subject)",
				strings.concatenate({"refs/tags/", tag}),
			},
		)
		kind, _, subject := strings.partition(strings.trim_space(info), " ")
		if kind == "tag" && subject != tag && subject != v.version {
			// (No quotes or backslashes: it goes into -define and .rc strings.)
			v.name, _ = strings.remove_all(subject, "\"")
			v.name, _ = strings.remove_all(v.name, "\\")
		}
		return
	}
	// v0.21.0-5-g1a2b3c4: the tag, the commits since, the commit.
	if d, ok := capture({"git", "describe", "--tags", "--long", "--match", "v[0-9]*"}); ok {
		d = strings.trim_space(d)
		rest := d[:strings.last_index_byte(d, '-')]
		i := strings.last_index_byte(rest, '-')
		v.version = fmt.tprintf("%s+%s", rest[1:i], rest[i + 1:])
	}
	return
}

// version_defines stamps v into a build (base.VERSION, RELEASE_NAME, COMMIT).
version_defines :: proc(v: Version) -> []string {
	defines := make([dynamic]string)
	append(
		&defines,
		strings.concatenate({"-define:VX_VERSION=", v.version}),
		strings.concatenate({"-define:VX_COMMIT=", v.commit}),
	)
	if v.name != "" {append(&defines, strings.concatenate({"-define:VX_RELEASE_NAME=", v.name}))}
	return defines[:]
}

// version_is_dev: not a release (as base.version_is_dev).
version_is_dev :: proc(v: Version) -> bool {
	return strings.contains_any(v.version, "-+")
}

// version_text as base.version_text has it.
version_text :: proc(v: Version) -> string {
	if v.name != "" {return fmt.tprintf("%s (%s)", v.name, v.version)}
	if !version_is_dev(v) {return v.version}
	return fmt.tprintf("%s (%s)", v.version, v.commit)
}

// windows_resource writes build/<exe name>.rc: the icon and the version
// information (the file's Details tab), for Odin's -resource (which
// compiles it with the Windows SDK's rc.exe).
windows_resource :: proc(v: Version, exe_name, description: string) -> (path: string, ok: bool) {
	write_icon() or_return
	// FILEVERSION wants four numbers: major, minor, patch, 0.
	numbers: [3]int
	head := v.version
	if i := strings.index_any(head, "-+"); i >= 0 {head = head[:i]}
	for part, i in strings.split(head, ".") {
		if i < 3 {numbers[i], _ = strconv.parse_int(part)}
	}
	icon, _ := filepath.abs("build/voxiverse.ico")
	icon, _ = strings.replace_all(icon, "\\", "/")
	text := fmt.tprintf(
		`1 ICON "%s"
1 VERSIONINFO
FILEVERSION %d,%d,%d,0
PRODUCTVERSION %d,%d,%d,0
FILEOS 0x40004
FILETYPE 0x1
BEGIN
	BLOCK "StringFileInfo"
	BEGIN
		BLOCK "040904B0"
		BEGIN
			VALUE "FileDescription", "%s"
			VALUE "FileVersion", "%s"
			VALUE "InternalName", "%s"
			VALUE "OriginalFilename", "%s.exe"
			VALUE "ProductName", "Voxiverse"
			VALUE "ProductVersion", "%s"
			VALUE "Comments", "commit %s"
		END
	END
	BLOCK "VarFileInfo"
	BEGIN
		VALUE "Translation", 0x409, 1200
	END
END
`,
		icon,
		numbers[0],
		numbers[1],
		numbers[2],
		numbers[0],
		numbers[1],
		numbers[2],
		description,
		v.version,
		exe_name,
		exe_name,
		version_text(v),
		v.commit,
	)
	path = path_join({"build", strings.concatenate({exe_name, ".rc"})})
	if os.write_entire_file(path, transmute([]u8)text) != nil {
		fmt.eprintfln("build: cannot write %s", path)
		return "", false
	}
	return path, true
}

PACKAGE_README :: #load("package_readme.txt", string)

// package_game makes the release package for this platform in build/dist/:
// a release build (shaders carried inside; on Windows a windowed program,
// no console), the server, README.txt and the licences, in a folder of the
// package's name (unpacking never scatters files), archived as
// voxiverse-<version>-<os>-<arch>.zip on Windows or .tar.gz elsewhere (tar
// keeps the executable bit). A development build's name carries its commit
// too: builds between releases are told apart by name.
package_game :: proc() -> bool {
	when ODIN_OS == .Darwin {
		fmt.eprintln("build: no macOS package until the macOS backend (docs/plan.md, M1b)")
		return false
	}
	v := version_of()
	build_game({"--release"}, windowed = true) or_return
	os_name := "windows" when ODIN_OS == .Windows else "linux"
	arch := "arm64" when ODIN_ARCH == .arm64 else "x64"
	label := v.version
	if version_is_dev(v) {label = fmt.tprintf("%s-%s", v.version, v.commit)}
	name := fmt.tprintf("voxiverse-%s-%s-%s", label, os_name, arch)
	dist := path_join({"build", "dist"})
	stage := path_join({dist, name})
	os.remove_all(stage)
	os.make_directory_all(path_join({stage, "licenses"}))

	for exe in ([]string{GAME_NAME, SERVER_NAME}) {
		file := strings.concatenate({exe, exe_suffix()})
		if err := os.copy_file(path_join({stage, file}), path_join({"build", file})); err != nil {
			fmt.eprintfln("build: cannot copy %s: %v", file, err)
			return false
		}
	}
	when ODIN_OS != .Windows {
		// The picture for a launcher or desktop entry (Windows has it in the .exe).
		write_icon() or_return
		if err := os.copy_file(
			path_join({stage, "voxiverse.png"}),
			path_join({"build", "icon.png"}),
		); err != nil {
			fmt.eprintfln("build: cannot copy the icon: %v", err)
			return false
		}
	}
	readme, _ := strings.replace_all(PACKAGE_README, "{version}", version_text(v))
	when ODIN_OS == .Windows {readme, _ = strings.replace_all(readme, "\n", "\r\n")}
	copies := [][2]string {
		{"LICENSE", "LICENSE"},
		{"assets/fonts/JetBrainsMono-OFL.txt", "licenses/JetBrainsMono-OFL.txt"},
		{"assets/fonts/NotoSansOldTurkic-OFL.txt", "licenses/NotoSansOldTurkic-OFL.txt"},
	}
	for c in copies {
		if err := os.copy_file(path_join({stage, c[1]}), c[0]); err != nil {
			fmt.eprintfln("build: cannot copy %s: %v", c[0], err)
			return false
		}
	}
	if os.write_entire_file(path_join({stage, "README.txt"}), transmute([]u8)readme) != nil {
		fmt.eprintln("build: cannot write README.txt")
		return false
	}

	archive: string
	when ODIN_OS == .Windows {
		// Windows' own bsdtar (not another tar earlier in PATH), which
		// writes zips (-a: by the name's extension).
		root, _ := os.lookup_env("SystemRoot", context.allocator)
		tar := path_join({root, "System32", "tar.exe"})
		archive = path_join({dist, strings.concatenate({name, ".zip"})})
		os.remove(archive)
		abs_archive, _ := filepath.abs(archive)
		// The folder by name: archiving "." would store "./" paths, which
		// Explorer shows as an empty zip that will not extract.
		run({tar, "-a", "-c", "-f", abs_archive, "-C", dist, name}) or_return
	} else {
		archive = path_join({dist, strings.concatenate({name, ".tar.gz"})})
		// (Owned by nobody in particular: not the builder's account.)
		run(
			{
				"tar",
				"--owner=0",
				"--group=0",
				"--numeric-owner",
				"-czf",
				archive,
				"-C",
				dist,
				name,
			},
		) or_return
	}
	fmt.printfln("package %s (%s)", archive, version_text(v))
	return true
}
