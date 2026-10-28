package game

import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

// What a joining client does with the Packs message: it takes the packs it
// has in its cache (<cache>/<sha256 hex>.vxpack, least recently used dropped
// first past PACK_CACHE_LIMIT), asks for the rest (a Pack_Want), checks each
// pack's size and hash as its last Pack_Part arrives, and builds the packs'
// sources (the files of assets/ and data/) in load order.

PACK_CACHE_LIMIT :: 256 << 20
PACK_SEND_PER_TICK :: 32 * 1024 // bytes of Pack_Part to one client in one tick
PACK_JOIN_SECONDS :: 120 // a client may spend this long in the Packs phase

Fetch_Entry :: struct {
	namespace: string,
	version:   string,
	size:      u32,
	sha256:    [32]u8,
	data:      []u8, // the archive: whole once the pack is held
	received:  u32,
	wanted:    bool, // asked for from the server (not in the cache)
}

Pack_Fetch :: struct {
	allocator: mem.Allocator,
	cache_dir: string, // "": no cache
	content:   u64, // the server's
	count:     int,
	entries:   [MAX_PACKS]Fetch_Entry,
}

// pack_fetch_begin: takes the cache's packs and says which are still wanted.
// A pack whose announced size is absurd is refused (err).
pack_fetch_begin :: proc(
	f: ^Pack_Fetch,
	p: Packs,
	cache_dir: string,
	allocator := context.allocator,
) -> (
	want: Pack_Want,
	err: string,
) {
	f^ = {
		allocator = allocator,
		cache_dir = strings.clone(cache_dir, allocator),
		content   = p.content,
		count     = int(p.count),
	}
	total := 0
	for i in 0 ..< f.count {
		e := p.entries[i]
		total += int(e.size)
		if e.size < 9 ||
		   int(e.size) > MAX_PACK_BYTES + 64 * 1024 ||
		   total > MAX_PACKS * MAX_PACK_BYTES {
			return {}, fmt.aprintf("pack %s is announced at %d bytes; the limit is %d", e.namespace, e.size, MAX_PACK_BYTES, allocator = context.temp_allocator)
		}
		f.entries[i] = {
			namespace = strings.clone(e.namespace, allocator),
			version   = strings.clone(e.version, allocator),
			size      = e.size,
			sha256    = e.sha256,
		}
		if data, ok := pack_cache_take(cache_dir, e.sha256, e.size, allocator); ok {
			f.entries[i].data = data
			f.entries[i].received = e.size
		} else {
			f.entries[i].wanted = true
			f.entries[i].data = make([]u8, int(e.size), allocator)
			want.indices[want.count] = u8(i)
			want.count += 1
		}
	}
	return want, ""
}

pack_fetch_destroy :: proc(f: ^Pack_Fetch) {
	for i in 0 ..< f.count {
		e := f.entries[i]
		delete(e.namespace, f.allocator)
		delete(e.version, f.allocator)
		delete(e.data, f.allocator)
	}
	delete(f.cache_dir, f.allocator)
	f^ = {}
}

// pack_fetch_part: takes a Pack_Part. err is why the server must be left
// (a part out of order, for a pack not asked for, past its size, or a pack
// that arrived damaged).
pack_fetch_part :: proc(f: ^Pack_Fetch, part: Pack_Part) -> (err: string) {
	if int(part.index) >= f.count {return "the server sent a part of a pack it did not announce"}
	e := &f.entries[part.index]
	if !e.wanted {return fmt.tprintf("the server sent a part of pack %s, which we did not ask for", e.namespace)}
	if part.offset != e.received || int(part.offset) + len(part.data) > int(e.size) {
		return fmt.tprintf("the server sent pack %s out of order or past its size", e.namespace)
	}
	copy(e.data[part.offset:], part.data)
	e.received += u32(len(part.data))
	if e.received == e.size {
		got := pack_hash(e.data)
		if got != e.sha256 {
			return fmt.tprintf(
				"pack %s arrived damaged (hash %s vs %s)",
				e.namespace,
				pack_hash_text(got),
				pack_hash_text(e.sha256),
			)
		}
		e.wanted = false
		pack_cache_store(f.cache_dir, e.sha256, e.data)
	}
	return ""
}

// pack_fetch_complete: every announced pack is held.
pack_fetch_complete :: proc(f: ^Pack_Fetch) -> bool {
	for i in 0 ..< f.count {
		if f.entries[i].received != f.entries[i].size || f.entries[i].wanted {return false}
	}
	return true
}

// pack_fetch_sources: the packs' files, in load order (the client's registry
// is built from the base pack and these, with .Client).
pack_fetch_sources :: proc(
	f: ^Pack_Fetch,
	allocator := context.temp_allocator,
) -> (
	sources: []Pack_Source,
	errs: []Pack_Error,
) {
	list := make([dynamic]Pack_Source, allocator)
	problems := make([dynamic]Pack_Error, allocator)
	for i in 0 ..< f.count {
		src, e := pack_archive_read(f.entries[i].namespace, f.entries[i].data, allocator)
		if len(e) > 0 {append(&problems, ..e)} else {append(&list, src)}
	}
	return list[:], problems[:]
}

@(private = "file")
pack_cache_path :: proc(dir: string, sha: [32]u8) -> string {
	return fmt.tprintf("%s/%s.vxpack", dir, pack_hash_hex(sha))
}

// pack_cache_take: a cached pack whose size and hash are right (it is
// marked as used now); a damaged file is not used.
pack_cache_take :: proc(
	dir: string,
	sha: [32]u8,
	size: u32,
	allocator := context.allocator,
) -> (
	data: []u8,
	ok: bool,
) {
	if dir == "" {return}
	path := pack_cache_path(dir, sha)
	bytes, err := os.read_entire_file_from_path(path, allocator)
	if err != nil {return}
	if u32(len(bytes)) != size || pack_hash(bytes) != sha {
		delete(bytes, allocator)
		return
	}
	now := time.now()
	os.change_times(path, now, now)
	return bytes, true
}

// pack_cache_store: writes a pack to the cache, then drops the least
// recently used files while the cache is over PACK_CACHE_LIMIT.
pack_cache_store :: proc(dir: string, sha: [32]u8, data: []u8) {
	if dir == "" {return}
	os.make_directory_all(dir)
	path := pack_cache_path(dir, sha)
	tmp := fmt.tprintf("%s.tmp", path)
	if os.write_entire_file(tmp, data) != nil {return}
	if os.rename(tmp, path) != nil {os.remove(tmp)}
	pack_cache_prune(dir, PACK_CACHE_LIMIT)
}

pack_cache_prune :: proc(dir: string, limit: int) {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {return}
	files := make([dynamic]os.File_Info, context.temp_allocator)
	total := 0
	for e in entries {
		if e.type == .Regular && strings.has_suffix(e.name, ".vxpack") {
			append(&files, e)
			total += int(e.size)
		}
	}
	slice.sort_by(files[:], proc(a, b: os.File_Info) -> bool {
		return time.diff(b.modification_time, a.modification_time) < 0
	})
	for e in files {
		if total <= limit {break}
		os.remove(e.fullpath)
		total -= int(e.size)
	}
}
