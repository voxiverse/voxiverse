package server

import "core:fmt"
import "core:hash"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

import "../base"
import "../common/game"

// Export and import (M46b): one universe as one file, to move it between
// machines or keep it. A .vxu file is
//
//	"VXUX" u32 format (2)  u32 save_format  u64 generation  u64 age
//	varint pack count, per pack: string namespace, string hash (64 hex digits: the
//	pack's .vxpack SHA-256, game.pack_hash_hex; a reader sees them without unpacking)
//	varint file count
//	per file: varint len, path, u64 size, u32 crc32, the bytes
//	"VXUE" u32 crc32 over every path and file CRC, in order
//
// Files are stored, not compressed (regions are already palette and runs). The
// set is a backup's (docs/saves.md), plus journal segments up to the end their
// world.cfg records (without journal: left out, since the journal names
// characters). Importing never trusts the file: its limits and paths are
// checked before anything is written, and the universe appears whole or not at
// all.

EXPORT_MAGIC :: "VXUX"
EXPORT_END :: "VXUE"
EXPORT_FORMAT :: 2 // 2: the header lists the universe's packs and their hashes
EXPORTS_DIR :: "exports"

IMPORT_MAX_TOTAL :: u64(16) << 30
IMPORT_MAX_FILES :: 100_000
IMPORT_MAX_FILE :: u64(1) << 30

// Import_Limits: what an import accepts (the constants; tests pass lower ones,
// since a file of the real size is too big to make).
Import_Limits :: struct {
	total: u64,
	files: u64,
	file:  u64,
}

IMPORT_LIMITS :: Import_Limits{IMPORT_MAX_TOTAL, IMPORT_MAX_FILES, IMPORT_MAX_FILE}
IMPORT_MAX_PARTS :: 8
IMPORT_MAX_PART :: 64
IMPORT_MAX_PATH :: IMPORT_MAX_PARTS * (IMPORT_MAX_PART + 1)

// export_path_ok: a relative path with '/' that stays inside the universe, made
// of plain names; "" if so, else what is wrong with it.
export_path_ok :: proc(p: string) -> string {
	if p == "" {return "it is empty"}
	if p[0] == '/' {return "it is absolute"}
	if strings.contains(p, "\\") {return "it has a backslash"}
	if strings.contains(p, ":") {return "it has a colon"}
	parts := strings.split(p, "/", context.temp_allocator)
	if len(parts) > IMPORT_MAX_PARTS {return "it is too deep"}
	for part in parts {
		switch {
		case part == "":
			return "it has an empty part"
		case part == ".":
			return "it has a '.'"
		case part == "..":
			return "it has a '..'"
		case len(part) > IMPORT_MAX_PART:
			return "a part of it is too long"
		}
		for c in transmute([]u8)part {
			switch c {
			case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '.', '_', '-':
			case:
				return "it has a character a save never has"
			}
		}
	}
	return ""
}

@(private = "file")
write_u64 :: proc(w: ^game.Writer, v: u64) {
	game.write_u32(w, u32(v))
	game.write_u32(w, u32(v >> 32))
}

@(private = "file")
Export_Entry :: struct {
	path: string,
	cut:  int, // keep this many bytes (-1: all)
}

// export_packs: the universe's packs as the header lists them: "namespace" and
// the hash of the pack as it would be sent to a player (its archive without
// server/ files), in universe.cfg's order. A pack that cannot be read is
// listed with the hash "unreadable".
Export_Pack :: struct {
	namespace, hash: string,
}

@(private = "file")
export_packs :: proc(dir: string, cfg: string) -> []Export_Pack {
	value, _ := text_value(cfg, "packs")
	out := make([dynamic]Export_Pack, context.temp_allocator)
	for name in packs_parse(value, context.temp_allocator) {
		src, errs := pack_read_dir(
			full_path(dir, fmt.tprintf("%s/%s", PACKS_DIR, name)),
			context.temp_allocator,
		)
		hash_text := "unreadable"
		if len(errs) == 0 {
			hash_text = game.pack_hash_hex(
				game.pack_hash(game.pack_archive_make(src, context.temp_allocator)),
			)
		}
		append(&out, Export_Pack{name, hash_text})
	}
	return out[:]
}

// export_entries: the files of dir's committed generation, in path order.
@(private = "file")
export_entries :: proc(dir: string, journal: bool) -> []Export_Entry {
	files := make([dynamic]string, context.temp_allocator)
	walk_files(dir, "", &files)
	slice.sort(files[:])
	out := make([dynamic]Export_Entry, context.temp_allocator)
	for rel in files {
		if strings.has_suffix(rel, ".new") || strings.has_suffix(rel, ".tmp") || rel == TX_FILE {
			continue
		}
		cut := -1
		if i := strings.index(rel, "/journal/"); i > 0 && strings.has_suffix(rel, ".vxj") {
			if !journal {continue}
			// Up to the end the world.cfg records (a later segment is not the save's).
			cfg, _ := os.read_entire_file_from_path(
				full_path(dir, fmt.tprintf("%s/%s", rel[:i], WORLD_FILE)),
				context.temp_allocator,
			)
			seq, _ := strconv.parse_int(rel[i + len("/journal/"):][:8])
			seg_text, _ := text_value(string(cfg), "journal.segment")
			off_text, _ := text_value(string(cfg), "journal.offset")
			recorded, _ := strconv.parse_int(seg_text)
			offset, _ := strconv.parse_int(off_text)
			if seq > recorded {continue}
			if seq == recorded {cut = offset}
		}
		append(&out, Export_Entry{rel, cut})
	}
	return out[:]
}

// universe_export writes the closed universe dir's committed generation to out
// ("" or what failed). A universe another process has open is refused.
universe_export :: proc(dir, out: string, d: ^base.Disk, journal := true) -> string {
	lock, holder, ok := base.file_lock(full_path(dir, UNIVERSE_LOCK), "")
	defer delete(holder)
	if !ok {
		return fmt.tprintf(
			"the universe is open in another process (%s)",
			full_path(dir, UNIVERSE_LOCK),
		)
	}
	defer base.file_unlock(&lock)
	if problem := store_recover(dir, d); problem != "" {return problem}
	return export_write(dir, out, d, journal)
}

// export_write writes dir's files as out. dir may be open (the save worker
// writes an export after a commit): the files of the committed generation do not
// change, and a journal segment is cut where its world.cfg says it ended.
export_write :: proc(dir, out: string, d: ^base.Disk, journal := true) -> string {
	cfg, err := os.read_entire_file_from_path(
		full_path(dir, UNIVERSE_FILE),
		context.temp_allocator,
	)
	if err != nil {return fmt.tprintf("%s is not a universe (no %s)", dir, UNIVERSE_FILE)}
	format_text, _ := text_value(string(cfg), "format")
	generation_text, _ := text_value(string(cfg), "generation")
	age_text, _ := text_value(string(cfg), "age")
	format, _ := strconv.parse_int(format_text)
	generation, _ := strconv.parse_u64(generation_text, 10)
	age, _ := strconv.parse_u64(age_text, 10)
	entries := export_entries(dir, journal)
	tmp := strings.concatenate({out, ".tmp"}, context.temp_allocator)
	os.remove(tmp)
	if merr := os.make_directory_all(filepath.dir(out)); merr != nil && merr != .Exist {
		return fmt.tprintf("cannot make %s (%v)", filepath.dir(out), merr)
	}
	w: game.Writer
	game.writer_init(&w, context.temp_allocator)
	for c in EXPORT_MAGIC {game.write_u8(&w, u8(c))}
	game.write_u32(&w, EXPORT_FORMAT)
	game.write_u32(&w, u32(format))
	write_u64(&w, generation)
	write_u64(&w, age)
	packs := export_packs(dir, string(cfg))
	game.write_varint(&w, u32(len(packs)))
	for p in packs {
		game.write_string(&w, p.namespace)
		game.write_string(&w, p.hash)
	}
	game.write_varint(&w, u32(len(entries)))
	if e := base.disk_write(d, tmp, w.buf[:]); e != .None {
		return fmt.tprintf("cannot write %s (%v)", tmp, e)
	}
	seal := u32(0)
	for entry in entries {
		data, rerr := os.read_entire_file_from_path(full_path(dir, entry.path), context.allocator)
		if rerr != nil {
			os.remove(tmp)
			return fmt.tprintf("cannot read %s (%v)", entry.path, rerr)
		}
		defer delete(data)
		body := data if entry.cut < 0 || entry.cut > len(data) else data[:entry.cut]
		crc := hash.crc32(body)
		clear(&w.buf)
		game.write_string(&w, entry.path)
		write_u64(&w, u64(len(body)))
		game.write_u32(&w, crc)
		if e := base.disk_append(d, tmp, w.buf[:]); e != .None {
			return fmt.tprintf("cannot write %s (%v)", tmp, e)
		}
		if e := base.disk_append(d, tmp, body); e != .None {
			return fmt.tprintf("cannot write %s (%v)", tmp, e)
		}
		seal = hash.crc32(transmute([]u8)entry.path, seal)
		crc_bytes := [4]u8{u8(crc), u8(crc >> 8), u8(crc >> 16), u8(crc >> 24)}
		seal = hash.crc32(crc_bytes[:], seal)
	}
	clear(&w.buf)
	for c in EXPORT_END {game.write_u8(&w, u8(c))}
	game.write_u32(&w, seal)
	if e := base.disk_append(d, tmp, w.buf[:], sync = true); e != .None {
		return fmt.tprintf("cannot write %s (%v)", tmp, e)
	}
	if e := base.disk_rename(d, tmp, out); e != .None {
		return fmt.tprintf("cannot finish %s (%v)", out, e)
	}
	base.disk_sync_dir(d, filepath.dir(out))
	log.infof(
		"server exported dir=%s file=%s files=%d generation=%d",
		dir,
		out,
		len(entries),
		generation,
	)
	return ""
}

// Export_Reader: a .vxu file read in pieces (it may be larger than memory).
@(private = "file")
Export_Reader :: struct {
	file:    ^os.File,
	size:    u64, // of the file
	at:      u64,
	ok:      bool,
	scratch: [IMPORT_MAX_PATH + 16]u8,
}

@(private = "file")
er_take :: proc(r: ^Export_Reader, into: []u8) -> bool {
	if !r.ok || u64(len(into)) > r.size - r.at {r.ok = false; return false}
	n, err := os.read(r.file, into)
	if err != nil || n != len(into) {r.ok = false; return false}
	r.at += u64(len(into))
	return true
}

@(private = "file")
er_u32 :: proc(r: ^Export_Reader) -> u32 {
	b: [4]u8
	er_take(r, b[:])
	return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
}

@(private = "file")
er_u64 :: proc(r: ^Export_Reader) -> u64 {
	lo := u64(er_u32(r))
	return lo | u64(er_u32(r)) << 32
}

@(private = "file")
er_varint :: proc(r: ^Export_Reader) -> u64 {
	v: u64
	for shift: uint = 0; shift < 35; shift += 7 {
		b: [1]u8
		if !er_take(r, b[:]) {return 0}
		v |= u64(b[0] & 0x7f) << shift
		if b[0] & 0x80 == 0 {return v}
	}
	r.ok = false
	return 0
}

// universe_import makes the universe dest from an export file ("" or what is
// wrong, naming the path that is). dest must not exist. Nothing of dest appears
// unless the whole file reads and every checksum holds.
universe_import :: proc(file, dest: string, d: ^base.Disk, limits := IMPORT_LIMITS) -> string {
	if os.exists(dest) {return fmt.tprintf("%s exists already", dest)}
	f, oerr := os.open(file)
	if oerr != nil {return fmt.tprintf("cannot open %s (%v)", file, oerr)}
	defer os.close(f)
	info, serr := os.fstat(f, context.temp_allocator)
	if serr != nil {return fmt.tprintf("cannot read %s (%v)", file, serr)}
	r := Export_Reader {
		file = f,
		size = u64(info.size),
		ok   = true,
	}
	magic: [4]u8
	er_take(&r, magic[:])
	if !r.ok ||
	   string(magic[:]) != EXPORT_MAGIC {return fmt.tprintf("%s is not a universe file", file)}
	format := er_u32(&r)
	if format > EXPORT_FORMAT {return "this file was made by a newer game"}
	if format <
	   EXPORT_FORMAT {return "this file was made by an older game; export the universe again"}
	if int(er_u32(&r)) > SAVE_FORMAT {return "this universe was made by a newer game"}
	er_u64(&r) // generation
	er_u64(&r) // age
	header_packs := make([dynamic]Export_Pack, context.temp_allocator)
	pack_count := er_varint(&r)
	if pack_count > game.MAX_PACKS {return fmt.tprintf("%s is damaged (too many packs)", file)}
	for _ in 0 ..< pack_count {
		ns: [IMPORT_MAX_PART + 1]u8
		hash_text: [65]u8
		n := er_varint(&r)
		if !r.ok || n > 32 {return fmt.tprintf("%s is damaged (a pack name is too long)", file)}
		er_take(&r, ns[:n])
		m := er_varint(&r)
		if !r.ok || m > 64 {return fmt.tprintf("%s is damaged (a pack hash is too long)", file)}
		er_take(&r, hash_text[:m])
		append(
			&header_packs,
			Export_Pack {
				strings.clone(string(ns[:n]), context.temp_allocator),
				strings.clone(string(hash_text[:m]), context.temp_allocator),
			},
		)
	}
	count := er_varint(&r)
	if !r.ok {return fmt.tprintf("%s is cut short", file)}
	if count >
	   limits.files {return fmt.tprintf("too many files (%d, at most %d)", count, limits.files)}
	staging := strings.concatenate({dest, ".import"}, context.temp_allocator)
	os.remove_all(staging)
	problem := ""
	seen := make(map[string]struct{}, context.temp_allocator)
	total := u64(0)
	seal := u32(0)
	for _ in 0 ..< count {
		n := er_varint(&r)
		if !r.ok || n > IMPORT_MAX_PATH {
			problem = fmt.tprintf("%s is damaged (a path is too long)", file)
			break
		}
		path_bytes := r.scratch[:n]
		if !er_take(&r, path_bytes) {break}
		path := strings.clone(string(path_bytes), context.temp_allocator)
		size := er_u64(&r)
		crc := er_u32(&r)
		if !r.ok {break}
		if why := export_path_ok(path); why != "" {
			problem = fmt.tprintf("%q is not a path a universe has: %s", path, why)
			break
		}
		if path in seen {
			problem = fmt.tprintf("%q is in the file twice", path)
			break
		}
		seen[path] = {}
		if size > limits.file {
			problem = fmt.tprintf(
				"%s is too large (%d bytes, at most %d)",
				path,
				size,
				limits.file,
			)
			break
		}
		total += size
		if total > limits.total {
			problem = fmt.tprintf("the universe is too large (over %d bytes)", limits.total)
			break
		}
		if size > r.size - r.at {
			r.ok = false
			break
		}
		data := make([]u8, size)
		defer delete(data)
		if !er_take(&r, data) {break}
		if hash.crc32(data) != crc {
			problem = fmt.tprintf("%s is damaged (its checksum does not hold)", path)
			break
		}
		to := full_path(staging, path)
		if e := base.disk_mkdir(d, filepath.dir(to)); e != .None {
			problem = fmt.tprintf("cannot make %s (%v)", filepath.dir(to), e)
			break
		}
		if e := base.disk_write(d, to, data); e != .None {
			problem = fmt.tprintf("cannot write %s (%v)", to, e)
			break
		}
		seal = hash.crc32(transmute([]u8)path, seal)
		crc_bytes := [4]u8{u8(crc), u8(crc >> 8), u8(crc >> 16), u8(crc >> 24)}
		seal = hash.crc32(crc_bytes[:], seal)
	}
	if problem == "" && r.ok {
		end: [4]u8
		er_take(&r, end[:])
		sum := er_u32(&r)
		if !r.ok || string(end[:]) != EXPORT_END || sum != seal || r.at != r.size {
			problem = fmt.tprintf("%s is damaged (its end does not hold)", file)
		}
	}
	if problem == "" && !r.ok {problem = fmt.tprintf("%s is cut short", file)}
	if problem == "" {problem = import_check_packs(staging, header_packs[:])}
	if problem != "" {
		os.remove_all(staging)
		return problem
	}
	if e := base.disk_rename(d, staging, dest); e != .None {
		os.remove_all(staging)
		return fmt.tprintf("cannot finish %s (%v)", dest, e)
	}
	base.disk_sync_dir(d, filepath.dir(dest))
	log.infof("server imported file=%s dir=%s files=%d", file, dest, count)
	return ""
}

// import_check_packs: the imported universe's packs must load (the registry
// is built from them before the universe is accepted: a pack error refuses
// the import with its lines), and match the hashes the header lists.
@(private = "file")
import_check_packs :: proc(staging: string, listed: []Export_Pack) -> string {
	cfg, _ := os.read_entire_file_from_path(
		full_path(staging, UNIVERSE_FILE),
		context.temp_allocator,
	)
	for p, i in export_packs(staging, string(cfg)) {
		if i >= len(listed) || listed[i] != p {
			return fmt.tprintf(
				"the pack %s in this file is not the one its header lists (hash %s)",
				p.namespace,
				p.hash,
			)
		}
	}
	value, _ := text_value(string(cfg), "packs")
	names := packs_parse(value, context.temp_allocator)
	if len(names) !=
	   len(listed) {return "the packs in this file are not the ones its header lists"}
	reg, _, problems := packs_registry(staging, names)
	if reg == nil {
		lines := strings.join(problems, "\n", context.temp_allocator)
		return fmt.tprintf("the packs of this universe do not load:\n%s", lines)
	}
	game.registry_destroy(reg)
	return ""
}
