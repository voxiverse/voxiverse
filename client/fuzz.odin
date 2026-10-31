package client

import "base:runtime"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sync"

import "common:base"
import "common:base/fuzz"
import "common:game"
import "server:."

// net.client_session (Q2b, docs/fuzzing.md): a headless session (no window, no GPU, no server)
// fed what a server sends, in order, through the receive path: the handshake, the pack phase,
// the welcome, the world and its state. The case is frames, a two-byte little-endian length and
// that many bytes of one server message. The session either fails with a reason shown to the
// player or keeps running; the world's chunk pool stays within its capacity.

FUZZ_PACKS_DIR :: "build/tmp/fuzz/client_packs"
FUZZ_HEARD_TICKS :: 200

client_fuzz_targets :: proc() -> []fuzz.Target {
	@(static) targets := [?]fuzz.Target {
		{
			name = "net.client_session",
			run = fuzz_client_session,
			seeds = "testdata/fuzz/net.client_session",
			dictionary = {"\x00", "\xff", "\x7f", "\x80"},
			max_len = 1 << 20,
			generate = fuzz_generate_client,
			alloc_cap = 256 << 20,
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

// fuzz_session_start: a session as session_start leaves one joining a remote server whose link
// is not up: what the receive path reads and writes, nothing else.
fuzz_session_start :: proc(s: ^Session) {
	s^ = {
		last_jump = -1e9,
		remote    = true,
	}
	seed: [32]u8
	game.account_key_set(&s.config.key, seed[:])
	s.config.name = "fuzz"
	loading_begin(s, false)
	_ = virtual.arena_init_growing(&s.arena)
	arena := virtual.arena_allocator(&s.arena)
	s.scratch = new(game.Block_Array, arena)
	game.writer_init(&s.writer, arena, game.MAX_MESSAGE_SIZE)
	s.schema = game.game_schema()
	s.reg = fuzz_registry()
	game.receiver_init(&s.rx, &s.schema, s.reg)
	s.received = make([dynamic]game.Packet, 0, 256)
	s.edits = make([dynamic]game.Edit, 0, MAX_PENDING_EDITS, arena)
	s.sounds = make([dynamic]Sound_Event, 0, 64, arena)
	s.notices = make([dynamic]string, 0, 16)
	s.others = make(map[u16]Other_Player)
	s.entities = make(map[u32]Other_Entity, 64)
	s.puffs = make([dynamic]Puff, 0, MAX_PUFFS, arena)
}

fuzz_client_session :: proc(data: []u8, allocator: runtime.Allocator) -> u64 {
	context.allocator = runtime.heap_allocator()
	defer free_all(context.temp_allocator)
	os.set_env("VX_PACKS", FUZZ_PACKS_DIR)
	s := new(Session)
	defer free(s)
	fuzz_session_start(s)
	rest := data
	frames := 0
	for len(rest) >= 2 {
		n := min(int(rest[0]) | int(rest[1]) << 8, len(rest) - 2)
		packet := rest[2:][:n]
		rest = rest[2 + n:]
		if n == 0 {continue}
		frames += 1
		handle_packets(s, {packet})
		free_all(context.temp_allocator)
		if s.state == .Failed {break}
	}
	state := s.state
	if state == .Failed && s.failure == "" {fuzz.fail("the session failed without a reason")}
	if s.world_init && s.world.chunks.high > u32(len(s.world.chunks.items)) {
		fuzz.fail("the world's chunk pool passed its capacity")
	}
	chunks := int(s.world.chunks.high) if s.world_init else 0
	fetched := s.fetched
	session_free(s)
	return fuzz.sig_mix(
		5,
		u64(state),
		u64(fetched),
		fuzz.sig_bucket(frames),
		fuzz.sig_bucket(chunks),
	)
}

// The generator's raw material: what a stepped server sends a client in its first ticks.
@(thread_local)
fuzz_heard_packets: [][]u8

// fuzz_generate_client: the packets a server sent one client, whole or from a cut, with one to
// three bytes of some changed; sometimes a pack phase (Packs, then Pack_Parts, the archive's
// hash right for what is sent, or not) after the Challenge.
fuzz_generate_client :: proc(rng: ^base.Rng, out: ^[dynamic]u8) {
	if fuzz_heard_packets == nil {fuzz_heard_packets = server.fuzz_heard(FUZZ_HEARD_TICKS)}
	heard := fuzz_heard_packets
	if len(heard) == 0 {return}
	put :: proc(out: ^[dynamic]u8, msg: []u8) {
		n := len(msg)
		append(out, u8(n), u8(n >> 8))
		append(out, ..msg)
	}
	mutate :: proc(rng: ^base.Rng, msg: []u8) -> []u8 {
		m := make([]u8, len(msg), context.temp_allocator)
		copy(m, msg)
		interesting := [?]u8{0, 1, 2, 0x7f, 0x80, 0xfe, 0xff}
		for _ in 0 ..< 1 + base.rng_int_max(rng, 3) {
			if len(m) == 0 {break}
			at := base.rng_int_max(rng, len(m))
			m[at] =
				interesting[base.rng_int_max(rng, len(interesting))] if base.rng_int_max(rng, 2) == 0 else u8(base.rng_u32(rng))
		}
		return m
	}
	start := 0
	if base.rng_int_max(rng, 4) == 0 {start = base.rng_int_max(rng, len(heard))}
	limit := 1 + base.rng_int_max(rng, 400)
	for i in start ..< min(len(heard), start + limit) {
		msg := heard[i]
		if i == start + 1 &&
		   start == 0 &&
		   base.rng_int_max(rng, 3) == 0 {fuzz_pack_phase(rng, out)}
		switch base.rng_int_max(rng, 80) {
		case 0:
			raw := make([]u8, 1 + base.rng_int_max(rng, 60), context.temp_allocator)
			for &b in raw {b = u8(base.rng_u32(rng))}
			msg = raw
		case 1, 2, 3:
			msg = mutate(rng, msg)
		}
		if len(msg) <= 0xffff {put(out, msg)}
	}
}

// fuzz_pack_phase: a Packs message and the parts of an archive (a small pack's, a few bytes
// of it changed or cut), in order, or not.
fuzz_pack_phase :: proc(rng: ^base.Rng, out: ^[dynamic]u8) {
	base_src := game.base_pack_source(context.temp_allocator)
	files := make([dynamic]game.Pack_File, context.temp_allocator)
	for f in base_src.files {
		if f.path == "pack.json" || (strings.has_prefix(f.path, "data/blocks") && len(files) < 3) {
			append(&files, f)
		}
	}
	archive := game.pack_archive_make({"fuzzpack", files[:]}, context.temp_allocator)
	for _ in 0 ..< base.rng_int_max(rng, 4) {
		archive[base.rng_int_max(rng, len(archive))] = u8(base.rng_u32(rng))
	}
	if base.rng_int_max(rng, 4) == 0 {archive = archive[:base.rng_int_max(rng, len(archive))]}
	announced := len(archive)
	switch base.rng_int_max(rng, 8) {
	case 0:
		announced = base.rng_int_max(rng, 1 << 30)
	case 1:
		announced += 1
	}
	packs := game.Packs {
		content = base.rng_u64(rng),
		count   = 1,
	}
	packs.entries[0] = {
		namespace = "fuzzpack",
		version   = "1.0",
		size      = u32(announced),
		sha256    = game.pack_hash(archive) if base.rng_int_max(rng, 4) != 0 else {},
	}
	w: game.Writer
	game.writer_init(&w, context.temp_allocator)
	put :: proc(out: ^[dynamic]u8, w: ^game.Writer, m: game.Server_Message) {
		clear(&w.buf)
		game.encode_server(w, m)
		n := len(w.buf)
		append(out, u8(n), u8(n >> 8))
		append(out, ..w.buf[:])
	}
	put(out, &w, packs)
	offset := 0
	for offset < len(archive) {
		n := min(game.MAX_PACK_PART, len(archive) - offset)
		at := u32(offset)
		if base.rng_int_max(rng, 16) == 0 {at = u32(base.rng_u32(rng))} 	// (out of order)
		put(out, &w, game.Pack_Part{0, at, archive[offset:][:n]})
		offset += n
	}
}
