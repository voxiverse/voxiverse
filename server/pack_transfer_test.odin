package server

import "core:fmt"
import "core:os"
import "core:testing"

import "../common/game"
import "../common/netcode"

// M47b: a universe's packs go to a joining client, over real sockets with
// loss; the client keeps them by hash and a second join needs no parts.

@(private = "file")
transfer_pack :: proc() -> game.Pack_Source {
	files := make([dynamic]game.Pack_File, context.temp_allocator)
	append(&files, game.Pack_File{"pack.json", transmute([]u8)string(MANIFEST)})
	append(&files, game.Pack_File{"data/blocks/marble.json", transmute([]u8)string(MARBLE)})
	// A server-only file: a structure of the base pack (valid, and not sent).
	for f in game.base_pack_source(context.temp_allocator).files {
		if len(f.path) > 18 && f.path[:18] == "server/structures/" {
			append(&files, game.Pack_File{f.path, f.data})
			break
		}
	}
	return {"testpack", files[:]}
}

@(test)
test_pack_transfer :: proc(t: ^testing.T) {
	cache := "build/test_pack_cache"
	os.remove_all(cache)
	defer os.remove_all(cache)
	bad := netcode.Conditions {
		loss       = 0.1,
		duplicate  = 0.1,
		latency_ms = 10,
		jitter_ms  = 10,
		seed       = LOSS_SEED,
	}
	extra := []game.Pack_Source{transfer_pack()}
	srv: Server
	if !testing.expect(
		t,
		start(
			&srv,
			{
				rules = quiet_rules(),
				seed = 31,
				view_radius = 2,
				view_height = 2,
				workers = 2,
				max_players = 4,
				listen = true,
				conditions = bad,
				no_sheep = true,
				extra_packs = extra,
			},
			{},
		),
	) {return}
	defer stop(&srv)
	port := srv.host.socket.port
	testing.expect_value(t, len(srv.pack_blobs), 1)

	join :: proc(t: ^testing.T, port: int, name: string, cache: string, seed: u64) -> Net_Client {
		c: Net_Client
		net_connect(&c, port, name)
		c.pack_cache = cache
		c.link.socket.conditions = {
			loss       = 0.1,
			duplicate  = 0.1,
			latency_ms = 10,
			jitter_ms  = 10,
			seed       = seed,
		}
		return c
	}

	a := join(t, port, "alpha", cache, LOSS_SEED + 1)
	defer net_close(&a)
	ok := net_wait(t, {&a}, proc(cs: []^Net_Client) -> bool {
			return cs[0].welcomed || cs[0].packs_error != ""
		}, 60)
	testing.expect(t, ok, "the client was not welcomed")
	testing.expect_value(t, a.packs_error, "")
	testing.expect(t, a.pack_parts > 0, "no Pack_Part arrived")
	testing.expect(t, a.reg != nil, "the client built no registry")
	if a.reg == nil {return}
	testing.expect_value(t, a.reg.hash, srv.registry.hash)
	testing.expect_value(t, len(a.reg.structures), 0) // (server/ was not sent)
	testing.expect_value(t, len(srv.registry.structures) > 2, true)
	_, has_marble := game.registry_block(a.reg, "testpack:marble")
	testing.expect(t, has_marble, "the pack's block is not in the client's registry")
	files, _ := os.read_all_directory_by_path(cache, context.temp_allocator)
	testing.expect_value(t, len(files), 1)
	for f in files {
		testing.expect_value(
			t,
			f.name,
			fmt.tprintf("%s.vxpack", game.pack_hash_hex(srv.pack_blobs[0].sha256)),
		)
	}
	// A pack arrives whole the first time only.
	b := join(t, port, "beta", cache, LOSS_SEED + 2)
	defer net_close(&b)
	ok = net_wait(t, {&b}, proc(cs: []^Net_Client) -> bool {
			return cs[0].welcomed || cs[0].packs_error != ""
		}, 60)
	testing.expect(t, ok, "the second client was not welcomed")
	testing.expect_value(t, b.pack_parts, 0)
	testing.expect_value(t, b.packs_error, "")
}
