package server

import "core:math"
import "core:strings"
import "core:testing"

import "../common/game"

@(private = "file")
said :: proc(c: ^Net_Client, what: string) -> bool {
	for n in c.notices {if strings.contains(n, what) {return true}}
	return false
}

@(private = "file")
cmd :: proc(c: ^Net_Client, text: string) {
	net_send(c, game.Command{text})
}

@(private = "file")
pump :: proc(t: ^testing.T, clients: []^Net_Client, seconds := 0.4) {
	net_wait(t, clients, proc(cs: []^Net_Client) -> bool {return false}, seconds)
}

// The slash commands about the world and players: selectors, relative
// coordinates, /tp with angles, /setblock, /time, /rule, /summon and /kill,
// /seed, /give to everyone, /wear, /help, /locate.
@(test)
test_world_commands :: proc(t: ^testing.T) {
	srv: Server
	config := Config {
		seed            = 27,
		generator       = .Earth,
		rules           = quiet_rules(),
		view_radius     = 3,
		view_height     = 2,
		workers         = 2,
		max_players     = 4,
		listen          = true,
		everyone_cheats = true,
		no_sheep        = true,
	}
	if !testing.expect(t, start(&srv, config, {})) {return}
	defer stop(&srv)
	a, b: Net_Client
	net_connect(&a, srv.host.socket.port, "a")
	net_connect(&b, srv.host.socket.port, "b")
	defer net_close(&a)
	defer net_close(&b)
	both := []^Net_Client{&a, &b}
	ok := net_wait(
		t,
		both,
		proc(cs: []^Net_Client) -> bool {return landed(cs[0]) && landed(cs[1])},
	)
	if !testing.expect(t, ok, "never landed") {return}

	// /setblock at a relative place; read on the server.
	p := a.update.state.position
	target := game.Block_Pos {
		i32(math.floor(p.x)) + 2,
		i32(math.floor(p.y)) + 3,
		i32(math.floor(p.z)),
	}
	cmd(&a, "setblock ~2 ~3 ~ glass")
	pump(t, both)
	testing.expect_value(t, block_on_server(&srv, target), game.Block.Glass)

	// /time and /rule.
	cmd(&a, "time set midnight")
	pump(t, both, 0.3)
	testing.expect(
		t,
		abs(clock_fraction(&srv)) < 0.02 || clock_fraction(&srv) > 0.98,
		"time set midnight",
	)
	cmd(&a, "time add 6")
	pump(t, both, 0.3)
	testing.expectf(
		t,
		abs(clock_fraction(&srv) - 0.25) < 0.02,
		"time add 6 gave %.3f",
		clock_fraction(&srv),
	)
	cmd(&a, "time query")
	cmd(&a, "rule drops false")
	cmd(&a, "rule drops")
	cmd(&a, "rule")
	cmd(&a, "seed")
	cmd(&a, "help tp")
	cmd(&a, "help")
	pump(t, both)
	testing.expect(t, said(&a, "It is 0.25"), "time query")
	testing.expect(t, said(&a, "drops = false"), "rule drops")
	testing.expect(t, said(&a, "random_tick_speed"), "rule lists the rules")
	testing.expect(t, said(&a, "Seed: 27"), "seed")
	testing.expect(t, said(&a, "teleport.tp"), "help tp")
	testing.expect(
		t,
		said(&a, "Commands:") && said(&a, "locate") && said(&a, "setblock"),
		"help lists the commands",
	)

	// /summon with a count, /kill.
	cmd(&a, "summon sheep 3")
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {return len(cs[0].entities) == 3})
	testing.expect(t, ok, "summon sheep 3")
	cmd(&a, "kill sheep")
	pump(t, both)
	testing.expect(t, said(&a, "Killed 3"), "kill sheep")

	// /tp x y z with angles, and ~ relative; the other to us by selector.
	cmd(&a, "tp 100 150 100 90 -30")
	ok = net_wait(
		t,
		both,
		proc(cs: []^Net_Client) -> bool {return abs(cs[0].update.state.position.x - 100) < 1},
	)
	testing.expect(t, ok, "tp x y z did not move a")
	at := a.update.state.position
	cmd(&a, "tp ~5 ~ ~-5")
	ok = net_wait(
		t,
		both,
		proc(cs: []^Net_Client) -> bool {return abs(cs[0].update.state.position.x - 105) < 2},
	)
	testing.expectf(t, ok, "tp ~5 ~ ~-5 left a at %v (was %v)", a.update.state.position, at)
	cmd(&a, "tp b @s")
	ok = net_wait(
		t,
		both,
		proc(cs: []^Net_Client) -> bool {return(
				abs(cs[1].update.state.position.x - cs[0].update.state.position.x) <
				3 \
			)},
	)
	testing.expect(t, ok, "tp b @s did not bring b")
	pump(t, both)

	// /give to everyone; /wear.
	stone := game.item_of_block(test_reg(), .Stone)
	before_a, before_b :=
		game.inventory_count(&a.inventory, stone), game.inventory_count(&b.inventory, stone)
	cmd(&a, "give @a stone 10")
	cmd(&a, "give @s cap")
	cmd(&a, "wear")
	pump(t, both, 0.6)
	testing.expect_value(t, game.inventory_count(&a.inventory, stone), before_a + 10)
	testing.expect_value(t, game.inventory_count(&b.inventory, stone), before_b + 10)
	testing.expect_value(t, a.inventory.equipment[.Head].item, game.item_of_armor(.Cap))

	// /locate, with or without the kind of thing, and a refusal for a nonsense name.
	cmd(&a, "locate gate")
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {
		for n in cs[0].notices {if strings.has_prefix(n, "gate at ") {return true}}
		return false
	})
	testing.expect(t, ok, "locate gate")
	cmd(&a, "locate structure dungeon")
	cmd(&a, "locate nowhere")
	pump(t, both, 0.6)
	testing.expect(
		t,
		said(&a, "dungeon at ") || said(&a, "No dungeon"),
		"locate structure dungeon",
	)
	testing.expect(t, said(&a, "Usage: locate") || said(&a, "nowhere"), "locate nowhere")
}

@(private = "file")
block_on_server :: proc(srv: ^Server, p: game.Block_Pos) -> game.Block {
	Data :: struct {
		p: game.Block_Pos,
		b: game.Block,
	}
	d := Data{p, .Air}
	call(srv, proc(s: ^Server, data: rawptr) {
			d := (^Data)(data)
			b, _ := chunks_block(&s.home.chunks, d.p)
			d.b = b
		}, &d)
	return d.b
}

@(private = "file")
clock_fraction :: proc(srv: ^Server) -> f64 {
	f := 0.0
	call(srv, proc(s: ^Server, data: rawptr) {(^f64)(data)^ = game.time_of_day(s.home.clock)}, &f)
	return f
}
