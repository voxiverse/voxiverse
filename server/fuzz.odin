package server

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:sync"

import "common:base"
import "common:base/fuzz"
import "common:game"

// The fuzz targets of what a save or a universe's files bring (Q1, docs/fuzzing.md): save
// transactions, player records, an export file, the universe's config files. tools/fuzz lists
// server_fuzz_targets; the suite replays their regression files.

FUZZ_SEEDS :: "testdata/fuzz/"
FUZZ_TMP :: "build/tmp/fuzz/"

server_fuzz_targets :: proc() -> []fuzz.Target {
	@(static) targets := [?]fuzz.Target {
		{
			name = "text.parsers",
			run = fuzz_text_parsers,
			seeds = FUZZ_SEEDS + "text.parsers",
			dictionary = {
				"&",
				"&#",
				"&l",
				"&#ff00ff",
				"[",
				"]",
				"=",
				",",
				":",
				"-",
				"voxiverse:",
				"midnight",
				"fly",
				"1e999",
				"NaN",
			},
			max_len = 1 << 12,
			generate = fuzz_text_generate,
		},
		{
			name = "net.server_session",
			run = fuzz_server_session,
			seeds = FUZZ_SEEDS + "net.server_session",
			dictionary = {"\x00", "\xff", "\x7f", "\x80"},
			max_len = 1 << 14,
			generate = fuzz_generate_session,
			alloc_cap = 1 << 20,
		},
		{
			name = "commands.player",
			run = fuzz_commands_player,
			seeds = FUZZ_SEEDS + "commands.player",
			dictionary = {
				" ~",
				" @s",
				" @a",
				" 1e999",
				" nan",
				" -1",
				" 2147483647",
				" stone",
				" &",
			},
			max_len = 1 << 12,
			generate = fuzz_generate_commands,
			alloc_cap = 1 << 20,
		},
		{
			name = "save.tx",
			run = fuzz_save_tx,
			seeds = FUZZ_SEEDS + "save.tx",
			dictionary = {TX_MAGIC, "..", "/", "\\", ":"},
			max_len = 1 << 16,
			generate = fuzz_generate_tx,
			fixup = fuzz_fixup_tx,
		},
		{
			name = "save.player",
			run = fuzz_save_player,
			seeds = FUZZ_SEEDS + "save.player",
			dictionary = {"\"stats\"", "{", "}", "NaN", "1e999", "voxiverse:stone", ","},
			max_len = 1 << 16,
			generate = fuzz_generate_player,
			alloc_cap = 64 << 20,
		},
		{
			name = "save.import",
			run = fuzz_save_import,
			seeds = FUZZ_SEEDS + "save.import",
			dictionary = {EXPORT_MAGIC, EXPORT_END, "..", "/"},
			max_len = 1 << 18,
			generate = fuzz_generate_import,
			alloc_cap = 64 << 20,
		},
		{
			name = "save.config",
			run = fuzz_save_config,
			seeds = FUZZ_SEEDS + "save.config",
			dictionary = {
				"role ",
				"player ",
				"grant ",
				"inherit ",
				"meta ",
				"account ",
				"\n",
				"-",
				"*",
				",",
			},
			max_len = 1 << 16,
			generate = fuzz_generate_config,
		},
	}
	return targets[:]
}

fuzz_registry :: proc() -> ^game.Registry {
	@(static) once: sync.Once
	@(static) reg: ^game.Registry
	sync.once_do(&once, proc() {reg = game.registry_base(runtime.heap_allocator())})
	return reg
}

// ---- save.tx

fuzz_save_tx :: proc(data: []u8, allocator: runtime.Allocator) -> u64 {
	context.allocator = allocator
	ops, generation, age, ok := tx_decode(data)
	if !ok {return 1}
	for op in ops {
		if !tx_path_safe(op.path) {fuzz.fail("an unsafe path %q was accepted", op.path)}
	}
	return fuzz.sig_mix(
		2,
		fuzz.sig_bucket(len(ops)),
		fuzz.sig_bucket(int(generation)),
		fuzz.sig_bucket(int(age)),
	)
}

fuzz_generate_tx :: proc(rng: ^base.Rng, out: ^[dynamic]u8) {
	b := Save_Batch {
		generation = u64(base.rng_int_max(rng, 100)),
		age        = u64(base.rng_int_max(rng, 100_000)),
	}
	b.files = make([dynamic]Prepared, context.temp_allocator)
	b.deletes = make([dynamic]string, context.temp_allocator)
	append(&b.files, Prepared{path = "regions/r.0.0.vxr", bytes = {1, 2, 3}})
	append(&b.files, Prepared{path = "chunks.idx", bytes = {4, 5}})
	append(&b.files, Prepared{path = "world.cfg", bytes = {6}})
	append(&b.deletes, "old/segment.0")
	append(out, ..tx_encode(&b))
}

// fuzz_fixup_tx: the trailing checksum rewritten, so a damaged body is read.
fuzz_fixup_tx :: proc(data: ^[dynamic]u8) {
	if len(data) < 12 {return}
	c := hash.crc32(data[:len(data) - 4])
	for i in 0 ..< 4 {data[len(data) - 4 + i] = u8(c >> uint(8 * i))}
}

// ---- save.player (player_parse and kit_parse on the same bytes)

fuzz_save_player :: proc(data: []u8, allocator: runtime.Allocator) -> u64 {
	context.allocator = allocator
	reg := fuzz_registry()
	r, ok := player_parse(reg, data)
	sig := u64(1)
	if ok {
		sig = fuzz.sig_mix(2, fuzz.sig_bucket(len(r.stats)))
		counters_free(&r.stats)
	}
	stacks, kit_ok := kit_parse(reg, string(data))
	if kit_ok {sig = fuzz.sig_mix(sig, 3, fuzz.sig_bucket(len(stacks)))}
	free_all(context.temp_allocator)
	return sig
}

fuzz_generate_player :: proc(rng: ^base.Rng, out: ^[dynamic]u8) {
	reg := fuzz_registry()
	r: Player_Record
	r.state.position = {f64(base.rng_int_max(rng, 100)), 70, -3}
	r.look = {1, 0.2}
	r.inventory.slots[0] = game.Stack{game.item_by_name(reg, "voxiverse:stone") or_else {}, 12, 0}
	counter_set(&r.stats, "blocks.mined", 5)
	counter_set(&r.stats, "blocks.mined.stone", 3)
	defer counters_free(&r.stats)
	append(out, ..player_json(reg, &r))
}

// ---- save.import

fuzz_save_import :: proc(data: []u8, allocator: runtime.Allocator) -> u64 {
	context.allocator = allocator
	dir := FUZZ_TMP + "save.import"
	file := fmt.tprintf("%s/in.vxu", dir)
	dest := fmt.tprintf("%s/dest", dir)
	staging := fmt.tprintf("%s.import", dest)
	os.remove_all(dest)
	os.remove_all(staging)
	os.make_directory_all(dir)
	_ = os.write_entire_file_from_bytes(file, data)
	disk := base.Disk{}
	problem := universe_import(file, dest, &disk)
	left := os.exists(dest) || os.exists(staging)
	if problem != "" && left {fuzz.fail("a refused import left files behind: %s", problem)}
	sig := fuzz.sig_mix(1, fuzz.sig_text(problem))
	os.remove_all(dest)
	os.remove_all(staging)
	os.remove(file)
	free_all(context.temp_allocator)
	return sig
}

fuzz_generate_import :: proc(rng: ^base.Rng, out: ^[dynamic]u8) {
	Part :: struct {
		path, data: string,
	}
	files := []Part {
		{"universe.cfg", "name Fuzz\n"},
		{"worlds/overworld/world.cfg", "seed 1\n"},
		{"worlds/overworld/regions/r.0.0.vxr", "abc"},
		{"worlds/nether/world.cfg", "seed 2\n"},
		{"worlds/nether/regions/r.0.0.vxr", "defg"},
	}
	w: game.Writer
	game.writer_init(&w, context.temp_allocator)
	put_u64 :: proc(w: ^game.Writer, v: u64) {
		game.write_u32(w, u32(v))
		game.write_u32(w, u32(v >> 32))
	}
	for c in EXPORT_MAGIC {game.write_u8(&w, u8(c))}
	game.write_u32(&w, EXPORT_FORMAT)
	game.write_u32(&w, u32(SAVE_FORMAT))
	put_u64(&w, u64(base.rng_int_max(rng, 50)))
	put_u64(&w, 0)
	game.write_varint(&w, 0)
	game.write_varint(&w, u32(len(files)))
	seal := u32(0)
	for f in files {
		crc := hash.crc32(transmute([]u8)f.data)
		game.write_string(&w, f.path)
		put_u64(&w, u64(len(f.data)))
		game.write_u32(&w, crc)
		append(&w.buf, f.data)
		seal = hash.crc32(transmute([]u8)f.path, seal)
		crc_bytes := [4]u8{u8(crc), u8(crc >> 8), u8(crc >> 16), u8(crc >> 24)}
		seal = hash.crc32(crc_bytes[:], seal)
	}
	for c in EXPORT_END {game.write_u8(&w, u8(c))}
	game.write_u32(&w, seal)
	append(out, ..w.buf[:])
}

// ---- save.config: permissions.cfg, a grants list, universe.cfg's packs line, a counters
// object: the first byte says which.

fuzz_save_config :: proc(data: []u8, allocator: runtime.Allocator) -> u64 {
	if len(data) == 0 {return 0}
	context.allocator = allocator
	text := string(data[1:])
	defer free_all(context.temp_allocator)
	switch data[0] % 4 {
	case 0:
		p: Permissions
		permissions_parse(&p, text)
		defer permissions_destroy(&p)
		return fuzz.sig_mix(1, fuzz.sig_bucket(len(p.roles)), fuzz.sig_bucket(len(p.players)))
	case 1:
		grants := make([dynamic]game.Grant, allocator)
		defer {
			for g in grants {delete(g.pattern, allocator)}
			delete(grants)
		}
		ok := game.grants_parse(text, &grants, allocator)
		return fuzz.sig_mix(2, u64(ok), fuzz.sig_bucket(len(grants)))
	case 2:
		names := packs_parse(text, allocator)
		defer {
			for n in names {delete(n, allocator)}
			delete(names, allocator)
		}
		return fuzz.sig_mix(3, fuzz.sig_bucket(len(names)))
	case:
		t := json.make_tokenizer(text, parse_integers = true)
		m, _, ok := counters_read(&t)
		if ok {counters_free(&m)}
		return fuzz.sig_mix(4, u64(ok), fuzz.sig_bucket(len(m)))
	}
}

fuzz_generate_config :: proc(rng: ^base.Rng, out: ^[dynamic]u8) {
	kind := base.rng_int_max(rng, 4)
	append(out, u8(kind))
	switch kind {
	case 0:
		append(out, ..transmute([]u8)string(DEFAULT_PERMISSIONS))
		append(
			out,
			..transmute([]u8)string(
				"player alice\nrole mod\ngrant teleport.tp\nmeta prefix x\naccount 12\n",
			),
		)
	case 1:
		grants := []game.Grant{{"chat.*", true, 1}, {"teleport.tp", false, 2}, {"*", true, 3}}
		append(out, ..transmute([]u8)game.grants_text(grants))
	case 2:
		append(out, ..transmute([]u8)string("alpha, beta,  gamma"))
	case 3:
		append(
			out,
			..transmute([]u8)string("{\n  \"blocks.mined\": 5,\n  \"blocks.placed\": 12\n}"),
		)
	}
}
