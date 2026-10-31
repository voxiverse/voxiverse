package game

import "base:runtime"
import "core:hash"
import "core:mem"
import "core:strings"
import "core:sync"

import "common:base"
import "common:base/fuzz"

// The fuzz targets of what a pack or a save brings (Q1, docs/fuzzing.md). Each `fuzz_*` runs
// the decoder through its public entry and returns an outcome signature; the harness's
// table (tools/fuzz) lists game_fuzz_targets, and the suite replays their regression files.

SEEDS :: "testdata/fuzz/"

game_fuzz_targets :: proc() -> []fuzz.Target {
	@(static) targets := [?]fuzz.Target {
		{
			name = "pack.json",
			run = fuzz_pack_json,
			seeds = SEEDS + "pack.json",
			dictionary = {
				"{",
				"}",
				"[",
				"]",
				":",
				",",
				"\"",
				"\\u0000",
				"\\ud800",
				"1e999",
				"-0",
				"true",
				"null",
			},
			max_len = JSON_MAX_FILE + 1024,
			generate = fuzz_generate_json,
		},
		{
			name = "pack.registry",
			run = fuzz_pack_registry,
			seeds = SEEDS + "pack.registry",
			dictionary = {"\"", "null", "[]", "{}", "99999999999", "-1", "\"unknown:thing\""},
			max_len = 64 << 10,
			generate = fuzz_generate_registry,
			alloc_cap = 64 << 20,
		},
		{
			name = "pack.png",
			run = fuzz_pack_png,
			seeds = SEEDS + "pack.png",
			dictionary = {"IHDR", "IDAT", "IEND", "PLTE", "tRNS"},
			max_len = MAX_PNG_BYTES + 1024,
			generate = fuzz_generate_png,
			fixup = fuzz_fixup_png,
			alloc_cap = 64 << 20,
		},
		{
			name = "pack.archive",
			run = fuzz_pack_archive,
			seeds = SEEDS + "pack.archive",
			dictionary = {"VXPK", "..", "/", "\x00", "server/", "pack.json"},
			max_len = 1 << 20,
			generate = fuzz_generate_archive,
			alloc_cap = 64 << 20,
		},
		{
			name = "save.region",
			run = fuzz_save_region,
			seeds = SEEDS + "save.region",
			dictionary = {"VXRG", "voxiverse:stone", "voxiverse:air"},
			max_len = 256 << 10,
			generate = fuzz_generate_region,
			fixup = fuzz_fixup_region,
			alloc_cap = 256 << 20,
		},
		{
			name = "save.journal",
			run = fuzz_save_journal,
			seeds = SEEDS + "save.journal",
			dictionary = {JOURNAL_MAGIC},
			max_len = 64 << 10,
			generate = fuzz_generate_journal,
			fixup = fuzz_fixup_journal,
		},
		{
			name = "save.structure",
			run = fuzz_save_structure,
			seeds = SEEDS + "save.structure",
			dictionary = {"void", "voxiverse:stone", "voxiverse:air"},
			max_len = 64 << 10,
			generate = fuzz_generate_structure,
			alloc_cap = 64 << 20,
		},
	}
	return targets[:]
}

// fuzz_registry: the base registry the save targets decode against, made once and never freed.
fuzz_registry :: proc() -> ^Registry {
	@(static) once: sync.Once
	@(static) reg: ^Registry
	sync.once_do(&once, proc() {reg = registry_base(runtime.heap_allocator())})
	return reg
}

// ---- pack.json

fuzz_pack_json :: proc(data: []u8, allocator: runtime.Allocator) -> u64 {
	arena: mem.Dynamic_Arena // the values are many small allocations: one arena frees them
	mem.dynamic_arena_init(&arena, allocator, allocator)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	value, err, ok := json_parse(string(data))
	if !ok {
		if err.line < 1 ||
		   err.column < 1 {fuzz.fail("error at line %d column %d", err.line, err.column)}
		return fuzz.sig_mix(1, fuzz.sig_text(err.message))
	}
	return fuzz.sig_mix(2, u64(value.kind), fuzz.sig_bucket(len(data)))
}

fuzz_generate_json :: proc(rng: ^base.Rng, out: ^[dynamic]u8) {
	b := strings.builder_make(context.temp_allocator)
	json_gen(&b, rng, 0, 1 + base.rng_int_max(rng, 45))
	append(out, ..transmute([]u8)strings.to_string(b))
}

@(private = "file")
json_gen :: proc(b: ^strings.Builder, rng: ^base.Rng, depth, max_depth: int) {
	kind := base.rng_int_max(rng, 7 if depth < max_depth else 5)
	switch kind {
	case 0:
		strings.write_string(b, "null")
	case 1:
		strings.write_string(b, "true" if base.rng_int_max(rng, 2) == 0 else "false")
	case 2:
		nums := [?]string {
			"0",
			"-0",
			"1",
			"-1",
			"3.5",
			"1e999",
			"-1e999",
			"123456789012345678901234567890",
			"0.000001",
			"1E5",
			"2147483648",
			"-2147483649",
		}
		strings.write_string(b, nums[base.rng_int_max(rng, len(nums))])
	case 3, 4:
		strings.write_byte(b, '"')
		n :=
			base.rng_int_max(rng, 8) *
			(base.rng_int_max(rng, 600) if base.rng_int_max(rng, 8) == 0 else 3)
		esc := [?]string {
			"\\n",
			"\\\"",
			"\\\\",
			"\\u0041",
			"\\u00e9",
			"\\ud83d\\ude00",
			"\\ud800",
			"\\u0000",
			"é",
			"x",
		}
		for _ in 0 ..< n {strings.write_string(b, esc[base.rng_int_max(rng, len(esc))])}
		strings.write_byte(b, '"')
	case 5:
		strings.write_byte(b, '[')
		for i in 0 ..< base.rng_int_max(rng, 5) {
			if i > 0 {strings.write_byte(b, ',')}
			json_gen(b, rng, depth + 1, max_depth)
		}
		strings.write_byte(b, ']')
	case:
		strings.write_byte(b, '{')
		for i in 0 ..< base.rng_int_max(rng, 5) {
			if i > 0 {strings.write_byte(b, ',')}
			strings.write_string(b, "\"k")
			strings.write_int(b, base.rng_int_max(rng, 6))
			strings.write_string(b, "\":")
			json_gen(b, rng, depth + 1, max_depth)
		}
		strings.write_byte(b, '}')
	}
}

// ---- pack.registry
//
// The input is one file of the base pack: the first byte picks which (modulo the count), the
// rest is its new content; registry_build runs over the base pack with that file replaced.

fuzz_pack_registry :: proc(data: []u8, allocator: runtime.Allocator) -> u64 {
	if len(data) == 0 {return 0}
	context.allocator = allocator
	source := base_pack_source(context.temp_allocator)
	idx := int(data[0]) % len(source.files)
	files := make([]Pack_File, len(source.files), context.temp_allocator)
	copy(files, source.files)
	files[idx].data = data[1:]
	sources := []Pack_Source{{source.namespace, files}}
	reg, errs := registry_build(sources, .Server, allocator)
	defer registry_destroy(reg)
	defer pack_errors_destroy(errs, allocator)
	for e in errs {
		if e.line < 0 || e.column < 0 {fuzz.fail("error with line %d column %d", e.line, e.column)}
		if e.file != "" && e.line > 0 && e.file == files[idx].path {
			lines := strings.count(string(data[1:]), "\n") + 1
			if int(e.line) >
			   lines {fuzz.fail("error at line %d of a file of %d lines", e.line, lines)}
		}
	}
	if len(errs) >
	   0 {return fuzz.sig_mix(1, fuzz.sig_text(errs[0].message), fuzz.sig_bucket(len(errs)))}
	return fuzz.sig_mix(2, fuzz.sig_bucket(reg.blocks.count))
}

fuzz_generate_registry :: proc(rng: ^base.Rng, out: ^[dynamic]u8) {
	source := base_pack_source(context.temp_allocator)
	// Only the JSON files: a number replaced by a string, an array by a long one, and so on.
	candidates := make([dynamic]int, context.temp_allocator)
	for f, i in source.files {
		if strings.has_suffix(f.path, ".json") {append(&candidates, i)}
	}
	idx := candidates[base.rng_int_max(rng, len(candidates))]
	text := string(source.files[idx].data)
	b := strings.builder_make(context.temp_allocator)
	changes := 1 + base.rng_int_max(rng, 4)
	cursor := 0
	replacements := [?]string {
		"\"x\"",
		"\"unknown:thing\"",
		"null",
		"[]",
		"{}",
		"-1",
		"99999999999",
		"true",
		"0.5",
	}
	for _ in 0 ..< changes {
		// Find a value start: a digit, a quote or a bracket after the cursor.
		at := cursor + base.rng_int_max(rng, max(len(text) - cursor, 1))
		for at < len(text) && !strings.contains_rune(":,[", rune(text[at])) {at += 1}
		if at >= len(text) {break}
		at += 1
		end := at
		for end < len(text) && !strings.contains_rune(",]}\n", rune(text[end])) {end += 1}
		strings.write_string(&b, text[cursor:at])
		if base.rng_int_max(rng, 6) == 0 {
			strings.write_byte(&b, '[')
			for k in 0 ..< 10_000 {
				if k > 0 {strings.write_byte(&b, ',')}
				strings.write_byte(&b, '1')
			}
			strings.write_byte(&b, ']')
		} else {
			strings.write_string(&b, replacements[base.rng_int_max(rng, len(replacements))])
		}
		cursor = end
	}
	strings.write_string(&b, text[cursor:])
	append(out, u8(idx))
	append(out, ..transmute([]u8)strings.to_string(b))
}

// ---- pack.png

fuzz_pack_png :: proc(data: []u8, allocator: runtime.Allocator) -> u64 {
	arena: mem.Dynamic_Arena // (png_texture's messages are built, not static)
	mem.dynamic_arena_init(&arena, allocator, allocator)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	_, message, ok := png_texture(data, "assets/textures/fuzz.png")
	if !ok {return fuzz.sig_mix(1, fuzz.sig_text(message))}
	return 2
}

fuzz_generate_png :: proc(rng: ^base.Rng, out: ^[dynamic]u8) {
	pixels := test_marble_pixels()
	png, _ := base.png_encode(
		TEXTURE_SIZE,
		TEXTURE_SIZE,
		([^]u8)(&pixels[0])[:len(pixels) * 4],
		context.temp_allocator,
	)
	append(out, ..png)
	// IHDR sizes at the edges, with the CRC repaired.
	if base.rng_int_max(rng, 2) == 0 && len(out) >= 33 {
		for k in 0 ..< 8 {out[16 + k] = u8(fuzz.interesting_u64(rng) >> uint(8 * (k % 4)))}
		fuzz_fixup_png(out)
	}
}

// fuzz_fixup_png: every whole chunk's CRC rewritten, so a mutated chunk reaches the decoder.
fuzz_fixup_png :: proc(data: ^[dynamic]u8) {
	at := 8
	for at + 12 <= len(data) {
		n :=
			int(data[at]) << 24 |
			int(data[at + 1]) << 16 |
			int(data[at + 2]) << 8 |
			int(data[at + 3])
		if n < 0 || at + 12 + n > len(data) {return}
		c := hash.crc32(data[at + 4:at + 8 + n])
		data[at + 8 + n] = u8(c >> 24)
		data[at + 9 + n] = u8(c >> 16)
		data[at + 10 + n] = u8(c >> 8)
		data[at + 11 + n] = u8(c)
		at += 12 + n
	}
}

// ---- pack.archive

fuzz_pack_archive :: proc(data: []u8, allocator: runtime.Allocator) -> u64 {
	context.allocator = allocator
	src, errs := pack_archive_read("fuzz", data, allocator)
	if len(errs) > 0 {
		sig := fuzz.sig_mix(1, fuzz.sig_text(errs[0].message))
		pack_errors_destroy(errs, allocator)
		return sig
	}
	n := len(src.files)
	for f in src.files {
		if !valid_path(f.path) ||
		   !pack_archive_sent(
				   f.path,
			   ) {fuzz.fail("a file the archive should have refused: %q", f.path)}
		delete(f.path, allocator)
		delete(f.data, allocator)
	}
	delete(src.files, allocator)
	delete(src.namespace, allocator)
	return fuzz.sig_mix(2, fuzz.sig_bucket(n))
}

fuzz_generate_archive :: proc(rng: ^base.Rng, out: ^[dynamic]u8) {
	files := []Pack_File {
		{
			"pack.json",
			transmute([]u8)string(
				`{"format": 1, "namespace": "fuzz", "version": "1.0.0", "title": "T", "requires": []}`,
			),
		},
		{"data/blocks/a.json", transmute([]u8)string(`{"a": {}}`)},
		{"assets/textures/b.png", transmute([]u8)string("not really a png")},
	}
	archive := pack_archive_make({"fuzz", files}, context.temp_allocator)
	append(out, ..archive)
}

// ---- save.region

fuzz_save_region :: proc(data: []u8, allocator: runtime.Allocator) -> u64 {
	context.allocator = allocator
	reg := fuzz_registry()
	r, err := region_open(reg, data, {0, 0}, unknown_air = len(data) & 1 == 1)
	defer free_all(context.temp_allocator)
	if err != .None {return fuzz.sig_mix(1, u64(err))}
	dst := new(Block_Array, allocator)
	defer free(dst, allocator)
	entities := make([dynamic]Block_Entity, allocator)
	defer delete(entities)
	chunks := 0
	for {
		_, _, _, got := region_next_chunk(&r, dst, &entities)
		if !got {break}
		chunks += 1
	}
	tops := make([dynamic]Saved_Top, allocator)
	defer delete(tops)
	region_tops(&r, &tops)
	return fuzz.sig_mix(
		2,
		fuzz.sig_bucket(len(r.index)),
		fuzz.sig_bucket(chunks),
		fuzz.sig_bucket(len(r.dropped)),
		fuzz.sig_bucket(len(tops)),
	)
}

fuzz_generate_region :: proc(rng: ^base.Rng, out: ^[dynamic]u8) {
	reg := fuzz_registry()
	context.allocator = context.temp_allocator
	blocks: [4]Chunk_Blocks
	saved: [4]Saved_Chunk
	for i in 0 ..< 4 {
		if base.rng_int_max(rng, 3) == 0 {
			blocks[i] = {
				uniform = Block(base.rng_int_max(rng, reg.blocks.count)),
			}
		} else {
			arr := new(Block_Array)
			for &b in arr {b = Block(base.rng_int_max(rng, min(reg.blocks.count, 6)))}
			blocks[i] = {
				array = arr,
			}
		}
		saved[i] = {
			pos    = {i32(i), 0, 0},
			blocks = &blocks[i],
		}
	}
	tops := []Saved_Top{{0, 0, 10}, {1, 2, 11}}
	w: Writer
	writer_init(&w, context.temp_allocator)
	region_encode(reg, &w, {0, 0}, saved[:], tops, u64(base.rng_int_max(rng, 1000)))
	append(out, ..w.buf[:])
}

// fuzz_fixup_region: the header's checksum rewritten, so a damaged table or index reaches the
// code that trusts it.
fuzz_fixup_region :: proc(data: ^[dynamic]u8) {
	r := reader_make(data[:])
	if len(data) < 8 {return}
	r.pos = 4
	read_u32(&r)
	read_i32(&r)
	read_i32(&r)
	read_varint64(&r)
	names := read_varint(&r)
	if !r.ok || names > MAX_BLOCK_STATES {return}
	for _ in 0 ..< names {
		read_string(&r, MAX_SAVED_BLOCK_NAME)
		if !r.ok {return}
	}
	items := read_varint(&r)
	if !r.ok || items > 0x10000 {return}
	for _ in 0 ..< items {
		read_varint(&r)
		read_string(&r, MAX_SAVED_BLOCK_NAME)
		if !r.ok {return}
	}
	n := read_varint(&r)
	if !r.ok || n > 1 << 20 {return}
	r.pos += int(n) * 24
	tops := read_varint(&r)
	if !r.ok || tops > 1 << 20 {return}
	r.pos += int(tops) * 12
	if !r.ok || r.pos + 4 > len(data) {return}
	c := hash.crc32(data[:r.pos])
	data[r.pos] = u8(c)
	data[r.pos + 1] = u8(c >> 8)
	data[r.pos + 2] = u8(c >> 16)
	data[r.pos + 3] = u8(c >> 24)
}

// ---- save.journal

@(private = "file")
journal_visit :: proc(user: rawptr, rec: Journal_Record) {
	(^int)(user)^ += 1
	#partial switch v in rec {
	case Journal_Changes:
		if len(v.changes) == 0 ||
		   len(v.changes) >
			   MAX_CHANGES_PER_RECORD {fuzz.fail("a Changes record of %d changes", len(v.changes))}
	}
}

fuzz_save_journal :: proc(data: []u8, allocator: runtime.Allocator) -> u64 {
	context.allocator = allocator
	seen := 0
	res := journal_read_segment(fuzz_registry(), data, journal_visit, &seen)
	free_all(context.temp_allocator)
	if res.valid_bytes > len(data) {fuzz.fail("valid_bytes %d past the data", res.valid_bytes)}
	return fuzz.sig_mix(
		u64(res.status),
		fuzz.sig_bucket(res.records),
		fuzz.sig_bucket(res.valid_bytes),
		fuzz.sig_bucket(len(data) - res.valid_bytes),
	)
}

fuzz_generate_journal :: proc(rng: ^base.Rng, out: ^[dynamic]u8) {
	w: Writer
	writer_init(&w, context.temp_allocator)
	journal_write_header(&w, {seq = u32(base.rng_int_max(rng, 100)), first_age = 1000})
	for i in 0 ..< 64 {
		switch i % 7 {
		case 0:
			journal_write_record(&w, Journal_Tick{age = u64(i), unix_ms = 1_700_000_000_000})
		case 1:
			journal_write_record(
				&w,
				Journal_Actor{index = u32(i), kind = .Character, name = "player"},
			)
		case 2:
			journal_write_record(
				&w,
				Journal_Action {
					id = u32(i),
					actor = 1,
					system = .Command,
					age = u64(i),
					command = "fill 1 2 3 4 5 6 stone",
				},
			)
		case 3:
			changes := []Journal_Change {
				{0, .Air, .Stone, 5, .Command},
				{u16(base.rng_int_max(rng, 4096)), .Stone, .Air, 5, .Liquid},
			}
			journal_write_record(&w, Journal_Changes{chunk = {-3, 2, 40}, changes = changes})
		case 4:
			journal_write_record(&w, Journal_Save{age = u64(i)})
		case 5:
			journal_write_record(&w, Journal_Params{age = u64(i)})
		case 6:
			journal_write_record(&w, Journal_Entity{{-3, 2, 40}, 9, u64(i), 5, {1, 2, 3}})
		}
	}
	append(out, ..w.buf[:])
}

// fuzz_fixup_journal: the header's checksum, then every record's, rewritten.
fuzz_fixup_journal :: proc(data: ^[dynamic]u8) {
	if len(data) < JOURNAL_HEADER_SIZE {return}
	c := hash.crc32(data[:JOURNAL_HEADER_SIZE - 4])
	for i in 0 ..< 4 {data[JOURNAL_HEADER_SIZE - 4 + i] = u8(c >> uint(8 * i))}
	at := JOURNAL_HEADER_SIZE
	for at < len(data) {
		rest := Reader {
			data = data[at:],
			ok   = true,
		}
		read_u8(&rest)
		length := read_varint(&rest)
		if !rest.ok {return}
		total := rest.pos + int(length) + 4
		if total > len(data) - at {return}
		rc := hash.crc32(data[at:at + total - 4])
		for i in 0 ..< 4 {data[at + total - 4 + i] = u8(rc >> uint(8 * i))}
		at += total
	}
}

// ---- save.structure

fuzz_save_structure :: proc(data: []u8, allocator: runtime.Allocator) -> u64 {
	context.allocator = allocator
	t, ok := template_decode(fuzz_registry(), data, allocator)
	if !ok {return 1}
	defer delete(t.cells, allocator)
	for s in t.size {
		if s < 0 || s > MAX_TEMPLATE_SIZE {fuzz.fail("template size %v", t.size)}
	}
	if len(t.cells) !=
	   int(t.size.x) *
		   int(t.size.y) *
		   int(t.size.z) {fuzz.fail("%d cells in a box of %v", len(t.cells), t.size)}
	return fuzz.sig_mix(2, fuzz.sig_bucket(len(t.cells)))
}

fuzz_generate_structure :: proc(rng: ^base.Rng, out: ^[dynamic]u8) {
	reg := fuzz_registry()
	size := [3]i32{4, 3, 4}
	cells := make([]u16, int(size.x * size.y * size.z), context.temp_allocator)
	for &c in cells {c = u16(base.rng_int_max(rng, 5)) if base.rng_int_max(rng, 6) != 0 else VOID}
	t := Template{size, cells}
	w: Writer
	writer_init(&w, context.temp_allocator)
	template_encode(&w, &t, reg)
	append(out, ..w.buf[:])
}
