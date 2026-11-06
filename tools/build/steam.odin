package build

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// The Steam depot build: `build steam` lays out one depot per operating system
// from the release packages and writes the SteamPipe scripts that upload them
// (docs/platforms.md, "How a build reaches Steam").

// STEAM_BRANCH: the beta branch an upload goes live on. Never the default branch:
// a build reaches players there only when the owner sets it live by hand.
STEAM_BRANCH :: "playtest"

// STEAM_OUT: where the layout is written.
STEAM_OUT :: "build/steam"

// Steam_Depot: one depot, which is one operating system's package.
Steam_Depot :: struct {
	name:        string, // the folder and script name, and the package's "<os>-<arch>"
	env:         string, // the repository variable holding its depot ID
	placeholder: string, // the ID used while that variable is unset
	library:     string, // the Steamworks library the game loads, which Steam's redistributable supplies
	slot:        string, // the folder of the package the game loads it from (beside the executable)
	zipped:      bool, // the package is a .zip, else a .tar.gz
}

STEAM_DEPOTS :: [?]Steam_Depot {
	{
		name = "windows-x64",
		env = "STEAM_DEPOT_WINDOWS",
		placeholder = "1",
		library = "steam_api64.dll",
		slot = ".",
		zipped = true,
	},
	{
		name = "linux-x64",
		env = "STEAM_DEPOT_LINUX",
		placeholder = "2",
		library = "libsteam_api.so",
		slot = ".",
	},
	{
		name = "macos-arm64",
		env = "STEAM_DEPOT_MACOS",
		placeholder = "3",
		library = "libsteam_api.dylib",
		slot = "Voxiverse.app/Contents/MacOS",
		zipped = true,
	},
}

// STEAM_APP_PLACEHOLDER: the App ID while STEAM_APP_ID is unset. Steam knows no
// App 0, so an upload with placeholders fails loudly instead of landing anywhere.
STEAM_APP_PLACEHOLDER :: "0"

// Steam_Ids: the App ID and the depot IDs of a build.
Steam_Ids :: struct {
	app:          string,
	depots:       [len(STEAM_DEPOTS)]string,
	placeholders: bool, // some ID is a placeholder
}

// steam_ids reads the IDs from the environment's repository variables (lookup is
// os.lookup_env, or a fake in a test). An unset or empty variable is a
// placeholder.
steam_ids :: proc(lookup: proc(name: string) -> (string, bool)) -> (ids: Steam_Ids) {
	pick :: proc(
		lookup: proc(name: string) -> (string, bool),
		name, placeholder: string,
		ids: ^Steam_Ids,
	) -> string {
		value, found := lookup(name)
		value = strings.trim_space(value)
		if found && value != "" {return value}
		ids.placeholders = true
		return placeholder
	}
	ids.app = pick(lookup, "STEAM_APP_ID", STEAM_APP_PLACEHOLDER, &ids)
	for d, i in STEAM_DEPOTS {
		ids.depots[i] = pick(lookup, d.env, d.placeholder, &ids)
	}
	return
}

// vdf_quote writes s as a VDF string. VDF has no line breaks inside a string
// here, and quotes and backslashes are escaped.
vdf_quote :: proc(s: string) -> string {
	b := strings.builder_make()
	strings.write_byte(&b, '"')
	for c in transmute([]u8)s {
		switch c {
		case '"':
			strings.write_string(&b, `\"`)
		case '\\':
			strings.write_string(&b, `\\`)
		case '\n', '\r':
			strings.write_byte(&b, ' ')
		case:
			strings.write_byte(&b, c)
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

// app_build_vdf: the script `steamcmd +run_app_build` takes. Paths are relative to
// the script's own folder (build/steam/scripts).
app_build_vdf :: proc(ids: Steam_Ids, description: string) -> string {
	b := strings.builder_make()
	fmt.sbprintfln(&b, "\"appbuild\"\n{{")
	fmt.sbprintfln(&b, "\t\"appid\" %s", vdf_quote(ids.app))
	fmt.sbprintfln(&b, "\t\"desc\" %s", vdf_quote(description))
	fmt.sbprintfln(&b, "\t\"buildoutput\" \"../output\"")
	fmt.sbprintfln(&b, "\t\"contentroot\" \"../depots\"")
	fmt.sbprintfln(&b, "\t\"setlive\" %s", vdf_quote(STEAM_BRANCH))
	fmt.sbprintfln(&b, "\t\"preview\" \"0\"")
	fmt.sbprintfln(&b, "\t\"depots\"\n\t{{")
	for d, i in STEAM_DEPOTS {
		fmt.sbprintfln(
			&b,
			"\t\t%s %s",
			vdf_quote(ids.depots[i]),
			vdf_quote(fmt.tprintf("depot_build_%s.vdf", d.name)),
		)
	}
	fmt.sbprintfln(&b, "\t}}\n}}")
	return strings.to_string(b)
}

// depot_build_vdf: one depot's script: everything under its folder, recursively,
// except steam_appid.txt (which is for running outside Steam and never ships).
depot_build_vdf :: proc(depot_id: string, d: Steam_Depot) -> string {
	b := strings.builder_make()
	fmt.sbprintfln(&b, "\"DepotBuildConfig\"\n{{")
	fmt.sbprintfln(&b, "\t\"DepotID\" %s", vdf_quote(depot_id))
	fmt.sbprintfln(&b, "\t\"contentroot\" %s", vdf_quote(d.name))
	fmt.sbprintfln(&b, "\t\"FileMapping\"\n\t{{")
	fmt.sbprintfln(&b, "\t\t\"LocalPath\" \"*\"")
	fmt.sbprintfln(&b, "\t\t\"DepotPath\" \".\"")
	fmt.sbprintfln(&b, "\t\t\"recursive\" \"1\"")
	fmt.sbprintfln(&b, "\t}}")
	fmt.sbprintfln(&b, "\t\"FileExclusion\" \"steam_appid.txt\"")
	fmt.sbprintfln(&b, "\t\"FileExclusion\" \"*/steam_appid.txt\"")
	fmt.sbprintfln(&b, "}}")
	return strings.to_string(b)
}

// find_package: the package of depot d in dir: voxiverse-<version>-<os>-<arch>.<ext>.
find_package :: proc(dir: string, d: Steam_Depot) -> (path: string, ok: bool) {
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {return "", false}
	suffix := strings.concatenate({"-", d.name, ".zip" if d.zipped else ".tar.gz"})
	for info in infos {
		if strings.has_prefix(info.name, "voxiverse-") && strings.has_suffix(info.name, suffix) {
			return info.fullpath, true
		}
	}
	return "", false
}

// unpack_package extracts a package into dest (which must not exist).
unpack_package :: proc(archive, dest: string) -> bool {
	os.make_directory_all(dest)
	if strings.has_suffix(archive, ".zip") && ODIN_OS == .Linux {
		return run({"unzip", "-q", archive, "-d", dest})
	}
	// bsdtar (macOS, Windows) reads zips too; GNU tar reads the .tar.gz.
	return run({system_tool("tar"), "-xf", archive, "-C", dest})
}

// remove_steam_appid deletes every steam_appid.txt under dir; it is never in a depot.
remove_steam_appid :: proc(dir: string) {
	found := make([dynamic]string, context.temp_allocator)
	w := os.walker_create(dir)
	for info in os.walker_walk(&w) {
		if info.type == .Regular && strings.equal_fold(info.name, "steam_appid.txt") {
			append(&found, strings.clone(info.fullpath, context.temp_allocator))
		}
	}
	os.walker_destroy(&w)
	for path in found {os.remove(path)}
}

// steam lays out the depots from the packages in dir (default build/dist) in
// build/steam/: depots/<os>/ with each package's contents, and scripts/ with the
// VDF files. The upload is a separate step (steamcmd, in CI).
steam :: proc(args: []string) -> bool {
	packages := args[0] if len(args) > 0 else path_join({"build", "dist"})
	ids := steam_ids(proc(name: string) -> (string, bool) {
		return os.lookup_env(name, context.temp_allocator)
	})
	if ids.placeholders {
		fmt.println(
			"steam: STEAM_APP_ID or a STEAM_DEPOT_* variable is unset: the layout uses placeholder IDs and cannot be uploaded",
		)
	}
	// The library comes from Steam's redistributable; where it is kept is up to
	// whoever uploads (STEAM_REDIST_DIR holds the three files). Without it the
	// slot is empty and the game plays without Steam (docs/platforms.md).
	redist, _ := os.lookup_env("STEAM_REDIST_DIR", context.temp_allocator)

	root := path_join({STEAM_OUT})
	os.remove_all(root)
	unpack_dir := path_join({root, "unpack"})
	scripts := path_join({root, "scripts"})
	os.make_directory_all(scripts)
	os.make_directory_all(path_join({root, "depots"}))

	for d, i in STEAM_DEPOTS {
		archive, found := find_package(packages, d)
		if !found {
			fmt.eprintfln("build: steam: no %s package in %s", d.name, packages)
			return false
		}
		from := path_join({unpack_dir, d.name})
		unpack_package(archive, from) or_return
		// The package's one folder is the depot's content (the folder's name carries
		// the version, which Steam does not want in a path).
		infos, err := os.read_all_directory_by_path(from, context.temp_allocator)
		if err != nil || len(infos) != 1 || infos[0].type != .Directory {
			fmt.eprintfln("build: steam: %s should hold one folder", archive)
			return false
		}
		depot := path_join({root, "depots", d.name})
		if rerr := os.rename(infos[0].fullpath, depot); rerr != nil {
			fmt.eprintfln("build: steam: cannot move %s: %v", infos[0].fullpath, rerr)
			return false
		}
		remove_steam_appid(depot)
		slot := path_join({depot, d.slot})
		if redist != "" {
			lib := path_join({redist, d.library})
			if cerr := os.copy_file(path_join({slot, d.library}), lib); cerr != nil {
				fmt.eprintfln("build: steam: cannot copy %s: %v", lib, cerr)
				return false
			}
		} else {
			fmt.printfln("steam: %s: %s not in the depot (slot: %s)", d.name, d.library, d.slot)
		}
		script := path_join({scripts, fmt.tprintf("depot_build_%s.vdf", d.name)})
		if os.write_entire_file(script, transmute([]u8)depot_build_vdf(ids.depots[i], d)) != nil {
			fmt.eprintfln("build: steam: cannot write %s", script)
			return false
		}
	}
	os.remove_all(unpack_dir)

	v := version_of()
	desc := fmt.tprintf("Voxiverse %s", version_text(v))
	script := path_join({scripts, "app_build.vdf"})
	if os.write_entire_file(script, transmute([]u8)app_build_vdf(ids, desc)) != nil {
		fmt.eprintfln("build: steam: cannot write %s", script)
		return false
	}
	abs, _ := filepath.abs(root)
	fmt.printfln("steam: layout in %s (%s)", abs, desc)
	return true
}
