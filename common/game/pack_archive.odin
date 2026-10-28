package game

import "core:crypto/hash"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"

// The pack archive: one pack as one canonical file, what a server sends a
// joining client. "VXPK", u32 version, varint file count, then per file in
// byte order of paths: the path (a string), varint size, the bytes. The same
// files always give the same bytes. It holds pack.json, assets/ and data/
// only: server/ stays on the server.

PACK_ARCHIVE_MAGIC :: "VXPK"
PACK_ARCHIVE_VERSION :: 1

// pack_archive_sent: whether a pack file travels to a client.
pack_archive_sent :: proc(path: string) -> bool {
	return(
		path == "pack.json" ||
		strings.has_prefix(path, "assets/") ||
		strings.has_prefix(path, "data/") \
	)
}

// pack_source_sent: source without its server/ files (what a client builds from).
pack_source_sent :: proc(source: Pack_Source, allocator := context.temp_allocator) -> Pack_Source {
	files := make([dynamic]Pack_File, allocator)
	for f in source.files {
		if pack_archive_sent(f.path) {append(&files, f)}
	}
	return {source.namespace, files[:]}
}

// pack_archive_make: the archive of source's files that are sent (the files
// of server/ are left out).
pack_archive_make :: proc(source: Pack_Source, allocator := context.allocator) -> []u8 {
	files := make([dynamic]Pack_File, context.temp_allocator)
	for f in source.files {
		if pack_archive_sent(f.path) {append(&files, f)}
	}
	slice.sort_by(files[:], proc(a, b: Pack_File) -> bool {return a.path < b.path})
	w: Writer
	writer_init(&w, allocator, 1024)
	append(&w.buf, PACK_ARCHIVE_MAGIC)
	write_u32(&w, PACK_ARCHIVE_VERSION)
	write_varint(&w, u32(len(files)))
	for f in files {
		write_string(&w, f.path)
		write_varint(&w, u32(len(f.data)))
		append(&w.buf, ..f.data)
	}
	return w.buf[:]
}

// pack_archive_read: the files of an archive, as the pack namespace. Every
// way it can be wrong is refused with a message (nothing is trusted: it came
// over the network).
pack_archive_read :: proc(
	namespace: string,
	data: []u8,
	allocator := context.allocator,
) -> (
	src: Pack_Source,
	errs: []Pack_Error,
) {
	bad :: proc(ns, file, why: string, allocator: mem.Allocator) -> []Pack_Error {
		out := make([]Pack_Error, 1, allocator)
		out[0] = {
			pack    = strings.clone(ns, allocator),
			file    = strings.clone(file, allocator),
			message = strings.clone(why, allocator),
		}
		return out
	}
	r := reader_make(data)
	magic: [4]u8
	for &b in magic {b = read_u8(&r)}
	if !r.ok || string(magic[:]) != PACK_ARCHIVE_MAGIC {
		return {}, bad(namespace, "", "not a pack archive; it does not begin with VXPK", allocator)
	}
	if v := read_u32(&r); !r.ok || v != PACK_ARCHIVE_VERSION {
		return {}, bad(namespace, "", fmt.tprintf("pack archive version %d; this game reads %d", v, PACK_ARCHIVE_VERSION), allocator)
	}
	count := read_varint(&r)
	if !r.ok || int(count) > MAX_PACK_FILES {
		return {}, bad(namespace, "", fmt.tprintf("the archive lists %d files; the limit is %d", count, MAX_PACK_FILES), allocator)
	}
	files := make([]Pack_File, int(count), allocator)
	total := 0
	last := ""
	for i in 0 ..< int(count) {
		path := read_string(&r, MAX_PACK_PATH)
		if !r.ok {
			return {}, bad(namespace, "", fmt.tprintf("the archive ends or goes wrong in file %d (its path)", i + 1), allocator)
		}
		if !valid_path(path) {
			return {}, bad(namespace, path, "path has a character outside a-z, 0-9 and _./-", allocator)
		}
		if !pack_archive_sent(path) {
			return {}, bad(namespace, path, "a sent pack has no server/ files; the server keeps them", allocator)
		}
		if i > 0 && path <= last {
			return {}, bad(namespace, path, "paths are not in order, or one is repeated", allocator)
		}
		size := read_varint(&r)
		if !r.ok || int(size) > JSON_MAX_FILE || total + int(size) > MAX_PACK_BYTES {
			return {}, bad(namespace, path, fmt.tprintf("file is over the limits (%d for a file, %d for a pack)", JSON_MAX_FILE, MAX_PACK_BYTES), allocator)
		}
		if len(data) - r.pos < int(size) {
			return {}, bad(namespace, path, "the archive ends inside this file", allocator)
		}
		body := make([]u8, int(size), allocator)
		copy(body, data[r.pos:][:int(size)])
		r.pos += int(size)
		total += int(size)
		files[i] = {strings.clone(path, allocator), body}
		last = files[i].path
	}
	if r.pos != len(data) {
		return {}, bad(namespace, "", "the archive has bytes after its last file", allocator)
	}
	return {strings.clone(namespace, allocator), files}, nil
}

// pack_hash: SHA-256 of a pack's archive.
pack_hash :: proc(archive: []u8) -> [32]u8 {
	out: [32]u8
	digest := hash.hash_bytes(.SHA256, archive, context.temp_allocator)
	copy(out[:], digest)
	return out
}

// pack_hash_text: the first 16 hex digits of a pack's hash, as people see it.
pack_hash_text :: proc(h: [32]u8, allocator := context.temp_allocator) -> string {
	return fmt.aprintf(
		"%02x%02x%02x%02x%02x%02x%02x%02x",
		h[0],
		h[1],
		h[2],
		h[3],
		h[4],
		h[5],
		h[6],
		h[7],
		allocator = allocator,
	)
}

// pack_hash_hex: all 64 digits (a cache file's name).
pack_hash_hex :: proc(h: [32]u8, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for x in h {fmt.sbprintf(&b, "%02x", x)}
	return strings.to_string(b)
}
