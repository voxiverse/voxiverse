package core

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "common:game"
import "common:island"

@(private = "file")
home: ^World

@(private = "file")
island_count :: proc() -> int {return len(island.island_ids(&home.islands))}

// Players in a world have islands: two together are one, one who flies far is a second
// island, and flying back merges them again; /islands lists them.
@(test)
test_players_islands_follow_them :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "islands"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	os.make_directory_all(dir)
	perms := strings.concatenate(
		{DEFAULT_PERMISSIONS, "player alice\nrole admin\n"},
		context.temp_allocator,
	)
	cfg := filepath.join({dir, PERMISSIONS_FILE}, context.temp_allocator) or_else ""
	testing.expect(t, os.write_entire_file(cfg, transmute([]u8)perms) == nil)
	config := Config {
		seed        = 22,
		view_radius = 2,
		view_height = 1,
		save_dir    = dir,
		max_players = 4,
		listen      = true,
		generator   = .Classic,
	}
	h := new(Harness)
	defer free(h)
	if !testing.expect(t, harness_start(h, config)) {return}
	defer harness_stop(h)
	home = h.srv.home
	testing.expect_value(t, island_radius_of(home), i32(4)) // the view distance plus 2

	alice := new(Net_Client)
	defer free(alice)
	bob := new(Net_Client)
	defer free(bob)
	net_connect(alice, 0, "alice", h = h)
	net_connect(bob, 0, "bob", h = h)
	defer net_close(alice)
	defer net_close(bob)
	both := []^Net_Client{alice, bob}
	ok := net_wait(t, both, proc(cs: []^Net_Client) -> bool {
		return(
			cs[0].welcomed &&
			cs[1].welcomed &&
			cs[0].update.acked > 0 &&
			cs[1].update.acked > 0 &&
			island_count() > 0 \
		)
	})
	if !testing.expect(t, ok, "the players never landed") {return}
	testing.expect_value(t, island_count(), 1)

	// Alice flies far away: two islands.
	net_send(alice, game.Command{"tp 4000.5 80 4000.5"})
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {return island_count() == 2})
	testing.expect(t, ok, "far apart they are not two islands")
	net_send(alice, game.Command{"islands"})
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {
		for n in cs[0].notices {
			if strings.has_prefix(game.format_strip(n), "2 islands") {return true}
		}
		return false
	})
	testing.expect(t, ok, "/islands did not list two")

	// And back to bob: one.
	net_send(alice, game.Command{"tp bob"})
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {return island_count() == 1})
	testing.expect(t, ok, "together they are not one island")
}

// The scene the bench runs does its work.
@(test)
test_budget_islands_scene :: proc(t: ^testing.T) {
	r := budget_islands()
	testing.expect_value(t, r.done, r.want)
}
