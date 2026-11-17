package update

import "core:log"
import "core:os"
import "core:slice"
import "core:strings"

// Putting a checked package in place of the installed one, by renames inside one folder
// (one filesystem): each of the package's entries in the install folder is renamed aside
// (<name>.voxiverse-old), then the new one renamed in. Windows cannot delete or overwrite
// a running executable but can rename it, so this works while the game runs there too.
// A failure part way renames everything back. What was renamed aside is deleted at the
// next start (cleanup), when nothing runs from it. Files in the install folder that are
// not the package's are never touched; the player's saves and settings are elsewhere
// (the user's data and config folders).

OLD_SUFFIX :: ".voxiverse-old"
STAGING_NAME :: ".voxiverse-update" // the staging folder, inside the install folder

// Install: where the running game was installed from a package.
Install :: struct {
	dir:   string, // the folder holding the package's files
	alone: bool, // macOS: the app bundle without the package's other files: only it is swapped
}

// install_find: the install the game running from exe_dir belongs to, if it is laid out as
// an unpacked package of layout (a developer's build/ is not).
install_find :: proc(exe_dir: string, layout: Layout) -> (install: Install, ok: bool) {
	// The executable's folder inside the package: none, or Voxiverse.app/Contents/MacOS.
	dir := strings.trim_right(exe_dir, "/\\")
	if slash := strings.last_index_byte(layout.game, '/'); slash >= 0 {
		inner := layout.game[:slash]
		slashed, _ := strings.replace_all(dir, "\\", "/", context.temp_allocator)
		if !strings.has_suffix(
			slashed,
			strings.concatenate({"/", inner}, context.temp_allocator),
		) {
			return
		}
		dir = dir[:len(dir) - len(inner) - 1]
	}
	if dir == "" {return}
	if all_files(dir, layout.required) {return {dir = dir}, true}
	if layout.app != "" && all_files(dir, layout.app_only) {return {dir = dir, alone = true}, true}
	return
}

@(private = "file")
all_files :: proc(dir: string, files: []string) -> bool {
	for f in files {
		info, err := os.lstat(join(dir, f), context.temp_allocator)
		if err != nil || info.type != .Regular {return false}
	}
	return true
}

// Step: one rename of a swap.
Step :: struct {
	from, to: string,
}

// swap_plan: the renames that put the package unpacked at staged (its folder) in place of
// install's files: for each of its entries (only the app, for an app alone), the one there
// renamed aside if there is one, then the new one in. In the temp allocator.
swap_plan :: proc(install: Install, staged: string, layout: Layout) -> (steps: []Step, ok: bool) {
	names := make([dynamic]string, context.temp_allocator)
	if install.alone {
		append(&names, layout.app)
	} else {
		entries, err := os.read_all_directory_by_path(staged, context.temp_allocator)
		if err != nil {return}
		for e in entries {append(&names, e.name)}
		slice.sort(names[:])
	}
	plan := make([dynamic]Step, context.temp_allocator)
	for name in names {
		target := join(install.dir, name)
		if os.exists(target) {
			append(
				&plan,
				Step{target, strings.concatenate({target, OLD_SUFFIX}, context.temp_allocator)},
			)
		}
		append(&plan, Step{join(staged, name), target})
	}
	return plan[:], len(plan) > 0
}

Rename :: #type proc(from, to: string) -> bool

rename_file :: proc(from, to: string) -> bool {
	err := os.rename(from, to)
	if err != nil {log.warnf("update cannot rename from=%s to=%s error=%v", from, to, err)}
	return err == nil
}

// swap_run takes the steps in order; when one fails, those done are undone in reverse
// (restored: true when every undo worked, so the install is as it was). Before it, what
// an earlier update renamed aside and did not clean up is removed, so no rename lands on
// it; that failing is a failure before anything moved.
swap_run :: proc(steps: []Step, rename: Rename = rename_file) -> (ok: bool, restored: bool) {
	for s in steps {
		if strings.has_suffix(s.to, OLD_SUFFIX) && os.exists(s.to) {
			if err := os.remove_all(s.to); err != nil {
				log.warnf("update cannot remove path=%s error=%v", s.to, err)
				return false, true
			}
		}
	}
	for s, i in steps {
		if rename(s.from, s.to) {continue}
		restored = true
		for j := i - 1; j >= 0; j -= 1 {
			if !rename(steps[j].to, steps[j].from) {
				log.errorf(
					"update could not put back path=%s (it is at %s)",
					steps[j].from,
					steps[j].to,
				)
				restored = false
			}
		}
		return false, restored
	}
	return true, true
}

// cleanup removes what an update left in the install folder: the files it renamed aside
// (in use until the restart) and a staging folder an interrupted update left.
cleanup :: proc(dir: string) {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {return}
	for e in entries {
		if !strings.has_suffix(e.name, OLD_SUFFIX) && e.name != STAGING_NAME {continue}
		if rerr := os.remove_all(e.fullpath); rerr != nil {
			log.warnf(
				"update cannot remove path=%s error=%v (the next start tries again)",
				e.fullpath,
				rerr,
			)
		} else {
			log.infof("update removed path=%s", e.fullpath)
		}
	}
}
