package server

import "core:fmt"
import "core:os"
import "core:slice"
import "core:testing"

import "../common/game"
import "../common/netcode"

// M47b: a universe's packs go to a joining client, over a simulated network with
// loss; the client keeps them by hash and a second join needs no parts.

@(private = "file")
transfer_pack :: proc() -> game.Pack_Source {
	// marble, with a PNG texture and Ogg sounds (M47i: they cross the join too)
	files := make([dynamic]game.Pack_File, context.temp_allocator)
	append(&files, ..game.test_asset_pack().files)
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
	h: Harness
	srv := &h.srv
	if !testing.expect(
		t,
		harness_start(
			&h,
			{
				rules = quiet_rules(),
				seed = 31,
				view_radius = 2,
				view_height = 2,
				max_players = 4,
				listen = true,
				no_sheep = true,
				extra_packs = extra,
			},
			conditions = bad,
		),
	) {return}
	defer harness_stop(&h)
	testing.expect_value(t, len(srv.pack_blobs), 1)

	join :: proc(h: ^Harness, name: string, cache: string) -> Net_Client {
		c: Net_Client
		net_connect(&c, 0, name, h = h)
		c.pack_cache = cache
		return c
	}

	a := join(&h, "alpha", cache)
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
	marble, has_marble := game.registry_block(a.reg, "testpack:marble")
	testing.expect(t, has_marble, "the pack's block is not in the client's registry")
	// The PNG's pixels and the Ogg arrived whole: the client decoded the server's own.
	testing.expect_value(t, len(a.reg.images), 1)
	if len(a.reg.images) == 1 {
		testing.expect(t, a.reg.images[0] == srv.registry.images[0], "the decoded pixels differ")
		testing.expect(
			t,
			a.reg.images[0] == game.test_marble_pixels(),
			"the pixels are not the PNG's",
		)
	}
	if has_marble {
		client_set := a.reg.sounds[a.reg.blocks.defs[marble].sound]
		server_set := srv.registry.sounds[srv.registry.blocks.defs[marble].sound]
		testing.expect(t, len(client_set.clips[.Break]) == 1 && len(server_set.clips[.Break]) == 1)
		if len(client_set.clips[.Break]) == 1 {
			testing.expect(
				t,
				slice.equal(client_set.clips[.Break][0], server_set.clips[.Break][0]),
				"the Ogg differs",
			)
		}
	}
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
	b := join(&h, "beta", cache)
	defer net_close(&b)
	ok = net_wait(t, {&b}, proc(cs: []^Net_Client) -> bool {
			return cs[0].welcomed || cs[0].packs_error != ""
		}, 60)
	testing.expect(t, ok, "the second client was not welcomed")
	testing.expect_value(t, b.pack_parts, 0)
	testing.expect_value(t, b.packs_error, "")
}
