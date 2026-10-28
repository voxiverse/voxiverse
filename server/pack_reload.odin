package server

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"

import "../base"
import "../common/game"

// Hot reload of the packs (development builds, `Config.pack_watch`; M47i): a
// pack author edits a file and sees it in the running game. It is a
// development tool, not a way to send packs into a running universe: the
// registry never grows, so a reload that would change the number of any
// block, item, texture or sound set is refused; a client that is not the
// player here (the in-process one, which has the same files) is sent away
// and gets the packs again as on any join.
//
// The watch looks every RELOAD_WATCH_TICKS at the files of the base pack's
// source directory (found next to the build: <repo>/assets/packs/voxiverse;
// without it the compiled-in pack is used and nothing of the base is watched)
// and of the universe's packs/. `pack reload` (the owner) reloads at once. A
// reload builds the new registry on the tick it is asked for; errors are
// logged and told to the owner (the first ten lines), and the old registry
// stays. Once built, the swap waits until no chunk job and no save is reading
// the registry (new chunk jobs are held meanwhile), then replaces the
// registry's contents in place (the address everyone holds stays good).

RELOAD_WATCH_TICKS :: 15 // half a second
RELOAD_NOTICE_LINES :: 10

Pack_Reload :: struct {
	base_dir: string, // the base pack's source directory ("": the compiled-in one)
	stamp:    u64, // what the watched files looked like last
	wanted:   bool, // `pack reload`, or the watch saw a change
	pending:  ^game.Registry, // built, waiting for the jobs that read the old one
	blobs:    [dynamic]Pack_Blob, // the packs as joining clients will be sent them
	swaps:    int, // reloads applied
}

// dev_base_dir: the base pack's source directory next to the build, "" in a
// build without it (a shipped game, or not run from the repository's build/).
dev_base_dir :: proc() -> string {
	when !base.DEV {return ""}
	exe_dir, err := os.get_executable_directory(context.temp_allocator)
	if err != nil {return ""}
	dir, _ := filepath.join(
		{filepath.dir(exe_dir), "assets", "packs", game.BASE_NAMESPACE},
		context.temp_allocator,
	)
	if !os.is_directory(dir) {return ""}
	return dir
}

// pack_stamp: a number that changes when any file under the watched
// directories is added, removed, resized or modified.
pack_stamp :: proc(dirs: []string) -> u64 {
	h: u64 = 1469598103934665603
	mix :: proc(h: ^u64, v: u64) {
		h^ = (h^ ~ v) * 1099511628211
	}
	walk :: proc(h: ^u64, dir: string, depth: int) {
		if depth > 8 {return}
		entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil {return}
		for e in entries {
			for c in transmute([]u8)e.name {mix(h, u64(c))}
			mix(h, u64(e.size))
			mix(h, u64(e.modification_time._nsec))
			if e.type == .Directory {walk(h, e.fullpath, depth + 1)}
		}
	}
	for d in dirs {walk(&h, d, 0)}
	return h
}

@(private = "file")
watched :: proc(s: ^Server) -> []string {
	dirs := make([dynamic]string, context.temp_allocator)
	if s.reload.base_dir != "" {append(&dirs, s.reload.base_dir)}
	for name in s.store.packs {
		append(&dirs, fmt.tprintf("%s/%s/%s", s.store.dir, PACKS_DIR, name))
	}
	return dirs[:]
}

// packs_reload_request: reload on this tick (the command, tests).
packs_reload_request :: proc(s: ^Server) {
	s.reload.wanted = true
}

// packs_reload_tick runs once a tick.
packs_reload_tick :: proc(s: ^Server) {
	if s.reload.pending == nil {
		if s.config.pack_watch && s.tick % RELOAD_WATCH_TICKS == 0 {
			if stamp := pack_stamp(watched(s)); stamp != s.reload.stamp {
				if s.reload.stamp != 0 {s.reload.wanted = true}
				s.reload.stamp = stamp
			}
		}
		if !s.reload.wanted {return}
		s.reload.wanted = false
		reload_build(s)
		if s.reload.pending == nil {return}
	}
	reload_apply(s)
}

// reload_tell logs and tells the owner (or the one who asked) why a reload
// did not happen: the first ten lines.
@(private = "file")
reload_tell :: proc(s: ^Server, lines: []string) {
	for l in lines {log.warnf("server packs reload %s", l)}
	shown := min(len(lines), RELOAD_NOTICE_LINES)
	for &c in s.clients {
		if c.state != .Playing || !is_owner(s, &c) {continue}
		for l in lines[:shown] {notice(s, &c, l)}
		if len(lines) > shown {
			notice(s, &c, fmt.tprintf("... and %d more (see the server log)", len(lines) - shown))
		}
	}
}

@(private = "file")
reload_build :: proc(s: ^Server) {
	reg, sources, problems := packs_registry(
		s.store.dir,
		s.store.packs,
		s.config.extra_packs,
		s.reload.base_dir,
	)
	if reg == nil {
		reload_tell(s, problems)
		return
	}
	if why := game.registry_id_changes(s.registry, reg); why != "" {
		game.registry_destroy(reg)
		reload_tell(s, {why})
		return
	}
	for b in s.reload.blobs {
		delete(b.namespace)
		delete(b.version)
		delete(b.data)
	}
	clear(&s.reload.blobs)
	pack_blobs_into(&s.reload.blobs, reg, sources)
	s.reload.pending = reg
	for w in s.worlds {w.chunks.hold = true}
}

@(private = "file")
reload_apply :: proc(s: ^Server) {
	for w in s.worlds {
		if w.chunks.in_flight > 0 {return} 	// (tries again next tick)
	}
	if s.store.job != nil || s.store.inflight != nil {return} 	// a save reads the registry
	game.registry_swap(s.registry, s.reload.pending)
	s.reload.pending = nil
	s.reload.swaps += 1
	pack_blobs_destroy(s)
	s.pack_blobs = s.reload.blobs
	s.reload.blobs = {}
	for w in s.worlds {w.chunks.hold = false}
	log.infof("server packs reloaded hash=%x", s.registry.hash)
	for &c in s.clients {
		if c.state == .Gone || c.state == .Free {continue}
		if _, local := c.link.(Local); local {
			if c.state == .Playing {send_message(s, &c, game.Packs_Changed{s.registry.hash})}
		} else {
			disconnect(s, &c, "the server reloaded its packs; join again")
		}
	}
}

// reload_destroy frees what a reload holds (the server stops).
reload_destroy :: proc(s: ^Server) {
	if s.reload.pending != nil {game.registry_destroy(s.reload.pending)}
	for b in s.reload.blobs {
		delete(b.namespace)
		delete(b.version)
		delete(b.data)
	}
	delete(s.reload.blobs)
	delete(s.reload.base_dir)
	s.reload = {}
}
