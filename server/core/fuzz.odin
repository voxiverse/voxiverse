package core

import "base:runtime"
import "core:encoding/json"
import "core:sync"

import "common:access"
import "common:base"
import "common:base/fuzz"
import "common:game"
import "server:store"

// The fuzz targets of what a save or a universe's files bring (docs/fuzzing.md): player
// records and the universe's config files (save transactions and export files are
// server/store's). tools/fuzz lists
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
			name = "save.player",
			run = fuzz_save_player,
			seeds = FUZZ_SEEDS + "save.player",
			dictionary = {"\"stats\"", "{", "}", "NaN", "1e999", "voxiverse:stone", ","},
			max_len = 1 << 16,
			generate = fuzz_generate_player,
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

// ---- save.player (player_parse and kit_parse on the same bytes)

fuzz_save_player :: proc(data: []u8, allocator: runtime.Allocator) -> u64 {
	context.allocator = allocator
	reg := fuzz_registry()
	r, ok := player_parse(reg, data, nil)
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
	r.inventory.slots[0] = game.Stack {
		game.item_by_name(reg, "voxiverse:stone") or_else {},
		12,
		0,
		0,
	}
	counter_set(&r.stats, "blocks.mined", 5)
	counter_set(&r.stats, "blocks.mined.stone", 3)
	defer counters_free(&r.stats)
	append(out, ..player_json(reg, &r, nil))
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
		grants := make([dynamic]access.Grant, allocator)
		defer {
			for g in grants {delete(g.pattern, allocator)}
			delete(grants)
		}
		ok := access.grants_parse(text, &grants, allocator)
		return fuzz.sig_mix(2, u64(ok), fuzz.sig_bucket(len(grants)))
	case 2:
		names := store.packs_parse(text, allocator)
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
		grants := []access.Grant{{"chat.*", true, 1}, {"teleport.tp", false, 2}, {"*", true, 3}}
		append(out, ..transmute([]u8)access.grants_text(grants))
	case 2:
		append(out, ..transmute([]u8)string("alpha, beta,  gamma"))
	case 3:
		append(
			out,
			..transmute([]u8)string("{\n  \"blocks.mined\": 5,\n  \"blocks.placed\": 12\n}"),
		)
	}
}
