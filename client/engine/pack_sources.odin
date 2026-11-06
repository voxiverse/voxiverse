package engine

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"

import "client:steam"
import "common:base"
import "common:game"
import "server:core"
import "server:packs"

// Where a pack a universe lists is found when the universe's own packs/ folder does not
// hold it (docs/packs.md, "Where a listed pack is found"): the local packs folder, then the
// Workshop. Both are read here, once per session, and handed to the server and to
// core.registry_for_dir alike so the client builds the registry the server does.

LOCAL_PACKS_DIR :: "local_packs"

// local_packs_dir: <user data>/voxiverse/local_packs, one folder per pack, named by its
// namespace ("" when there is no user data directory).
local_packs_dir :: proc() -> string {
	dir := base.boot_info().dirs.data
	if dir == "" {return ""}
	return filepath.join({dir, "voxiverse", LOCAL_PACKS_DIR}, context.temp_allocator) or_else ""
}

// pack_candidates reads the local packs and the Workshop's (client nil or off: none).
// Nothing is checked here: a pack nobody lists is never loaded, and one that is listed
// fails in the registry build with its own errors.
pack_candidates :: proc(
	client: ^steam.Client,
	allocator := context.allocator,
) -> []core.Pack_Candidate {
	context.allocator = allocator
	out := make([dynamic]core.Pack_Candidate)
	if local := local_packs_dir(); local != "" {
		entries, _ := os.read_all_directory_by_path(local, context.temp_allocator)
		for e in entries {
			if e.type != .Directory {continue}
			path := filepath.join({local, e.name}) or_else ""
			src, errs := packs.pack_read_dir(path)
			append(&out, core.Pack_Candidate{src, "local pack", problem_texts(errs)})
		}
	}
	if client != nil {
		found, errs := steam.workshop_packs(client)
		for f in found {
			append(
				&out,
				core.Pack_Candidate{f.source, fmt.aprintf("Workshop item %d", f.item), nil},
			)
		}
		// A read error goes on the candidate of its pack, so a universe that lists the
		// pack does not open on it. One that names no pack (an item with no pack folder,
		// an unreadable one) can be listed by nobody: it is said, not refused.
		first := len(out) - len(found)
		for e in errs {
			text := game.pack_error_text(e)
			at := -1
			for f, i in found {
				if e.pack == f.source.namespace {at = first + i}
			}
			if at >= 0 {
				out[at].problems = append_problem(out[at].problems, text)
			} else {
				log.warnf("workshop %s", text)
			}
		}
	}
	return out[:]
}

@(private = "file")
problem_texts :: proc(errs: []game.Pack_Error) -> []string {
	out := make([]string, len(errs))
	for e, i in errs {out[i] = game.pack_error_text(e)}
	return out
}

@(private = "file")
append_problem :: proc(have: []string, text: string) -> []string {
	out := make([]string, len(have) + 1)
	copy(out, have)
	out[len(have)] = text
	return out
}
