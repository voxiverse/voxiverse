package server

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "../game"
import "../worldgen"

// Nobody arrives inside blocks: spawn lands on the top of what stands at
// the spawn, a teleport into blocks comes out above them; setworldspawn
// is kept with the world.
@(test)
test_spawn_and_landings :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "spawn"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	config := Config {
		seed         = 4,
		view_radius  = 2,
		view_height  = 1,
		workers      = 1,
		allow_cheats = true,
		save_dir     = dir,
		generator    = .Classic,
	}
	@(static) want: f64
	top: i32
	{
		pipe: game.Pipe
		game.pipe_init(&pipe)
		defer game.pipe_destroy(&pipe)
		srv: Server
		if !testing.expect(t, start(&srv, config, {&pipe, .Server})) {return}
		c := Fake_Client {
			endpoint = {&pipe, .Client},
			scratch  = new(game.Block_Array),
		}
		defer free(c.scratch)
		defer delete(c.has)
		defer delete(c.columns)
		fake_hello(t, &c, "lander")
		testing.expect(
			t,
			wait_until(t, &c, proc(c: ^Fake_Client) -> bool {return c.welcomed && c.chunks > 10}),
		)
		top = i32(c.welcome.spawn.y) - 1 // (the generator's: on the ground)
		testing.expect_value(t, top, worldgen.column_top(&srv.world.gen, 0, 0))

		// A pillar where the spawn is: spawn lands on it.
		fake_send(&c, game.Command{fmt.tprintf("fill 0 %d 0 0 %d 0 stone", top + 1, top + 6)})
		fake_send(&c, game.Command{"spawn"})
		want = f64(top + 7)
		testing.expect(t, wait_until(t, &c, proc(c: ^Fake_Client) -> bool {
				return c.player.state.position.y == want
			}), "spawn did not land on the pillar")

		// Into the pillar: out on top of it.
		fake_send(&c, game.Teleport{{0.5, f64(top + 3), 0.5}, 0, 0})
		want = f64(top + 3)
		testing.expect(t, wait_until(t, &c, proc(c: ^Fake_Client) -> bool {
				return c.player.state.position.y != want
			}))
		testing.expect_value(t, c.player.state.position.y, f64(top + 7))

		fake_send(&c, game.Command{fmt.tprintf("setworldspawn 5.5 %d 5.5", top + 20)})
		testing.expect(t, wait_until(t, &c, proc(c: ^Fake_Client) -> bool {
				for n in c.notices {if strings.has_prefix(n, "World spawn set") {return true}}
				return false
			}))
		testing.expect(t, stop(&srv))
	}
	// Kept: a newcomer arrives there (exactly: in the air).
	{
		pipe: game.Pipe
		game.pipe_init(&pipe)
		defer game.pipe_destroy(&pipe)
		srv: Server
		if !testing.expect(t, start(&srv, config, {&pipe, .Server})) {return}
		c := Fake_Client {
			endpoint = {&pipe, .Client},
			scratch  = new(game.Block_Array),
		}
		defer free(c.scratch)
		defer delete(c.has)
		defer delete(c.columns)
		fake_hello(t, &c, "newcomer")
		testing.expect(t, wait_until(t, &c, proc(c: ^Fake_Client) -> bool {return c.welcomed}))
		testing.expect_value(t, c.welcome.spawn, [3]f64{5.5, f64(top + 20), 5.5})
		testing.expect(t, stop(&srv))
	}
}
