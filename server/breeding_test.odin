package server

import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"

import "../game"

@(private = "file")
Sheep_Info :: struct {
	id:     u32,
	genes:  game.Genes,
	growth: int,
	love:   int,
	wait:   int,
	shorn:  bool,
}

// sheep_list: every sheep in client a's world (read on the server's thread).
@(private = "file")
sheep_list :: proc(srv: ^Server) -> []Sheep_Info {
	out := make([dynamic]Sheep_Info, context.temp_allocator)
	call(srv, proc(s: ^Server, data: rawptr) {
			out := (^[dynamic]Sheep_Info)(data)
			w := client_by_name(s, "a").world
			for e in w.entities.list {
				if e.kind ==
				   .Sheep {append(out, Sheep_Info{e.id, e.genes, e.growth, e.love, e.wait, e.shorn})}
			}
		}, &out)
	return out[:]
}

// sheep_set: change sheep id (on the server's thread).
@(private = "file")
sheep_set :: proc(srv: ^Server, info: Sheep_Info) {
	info := info
	call(srv, proc(s: ^Server, data: rawptr) {
			i := (^Sheep_Info)(data)
			w := client_by_name(s, "a").world
			if e, _ := entity_find(w, i.id); e != nil {
				e.genes, e.growth, e.love, e.wait, e.shorn =
					i.genes, i.growth, i.love, i.wait, i.shorn
			}
		}, &info)
}

// bring puts sheep id four blocks ahead of client a (out of pickup range) (they wander off).
@(private = "file")
bring :: proc(srv: ^Server, id: u32) {
	id := id
	call(srv, proc(s: ^Server, data: rawptr) {
			c := client_by_name(s, "a")
			if e, _ := entity_find(c.world, (^u32)(data)^); e != nil {
				e.body.position = c.player.position + {0, 0, -4}
				e.body.velocity = {}
			}
		}, &id)
}

@(private = "file")
config :: proc(dir: string) -> Config {
	return {
		seed = 25,
		generator = .Classic,
		rules = quiet_rules(),
		view_radius = 3,
		view_height = 2,
		workers = 2,
		max_players = 4,
		listen = true,
		everyone_cheats = true,
		save_dir = dir,
		no_sheep = true,
	}
}

@(private = "file")
wait_for :: proc(
	t: ^testing.T,
	clients: []^Net_Client,
	done: proc(cs: []^Net_Client) -> bool,
) -> bool {
	return net_wait(t, clients, done, 12)
}

// M25's exit check, over UDP and the save: two sheep fed wheat make a lamb of
// their genes; fed wheat uses it up (not while one waits); a lamb is small,
// not shorn, grows up on time and sooner with wheat; a second player sees
// the lamb and the black sheep; genes, age and waits are kept.
@(test)
test_breeding_lamb_to_adult :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "breeding"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	srv: Server
	if !testing.expect(t, start(&srv, config(dir), {})) {return}
	stopped := false
	defer if !stopped {stop(&srv)}
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
	net_send(&a, game.Command{"time midnight"})
	net_send(&a, game.Command{"summon sheep"})
	net_send(&a, game.Command{"summon sheep"})
	ok = wait_for(
		t,
		both,
		proc(cs: []^Net_Client) -> bool {return(
				len(cs[0].entities) == 2 &&
				len(cs[1].entities) == 2 \
			)},
	)
	if !testing.expect(t, ok, "the sheep never showed up") {return}

	// A black sheep and a plain one (no recessive copies); wheat in hand (slot 3).
	list := sheep_list(&srv)
	black, plain := list[0], list[1]
	black.genes, plain.genes = game.WOOL_BLACK, {}
	sheep_set(&srv, black)
	sheep_set(&srv, plain)
	wheat := game.item_of_material(.Wheat)
	seq := u32(0)
	req :: proc(a: ^Net_Client, seq: ^u32, kind: game.Inventory_Action_Kind, slot: int, arg := 0) {
		seq^ += 1
		net_send(a, game.Inventory_Request{seq^, {kind, slot, arg}})
	}
	req(&a, &seq, .Take, game.CURSOR_SLOT, int(wheat))
	req(&a, &seq, .Click, 3)
	req(&a, &seq, .Select, 0, 3)
	ok = wait_for(t, both, proc(cs: []^Net_Client) -> bool {return cs[0].inv_acked == 3})
	testing.expect(t, ok && a.inventory.slots[3] == {wheat, 64}, "no wheat in hand")

	// Feeding: both ready (hearts), two wheat used; feeding the same one again does nothing.
	net_send(&a, game.Use_Entity{black.id, a.seq})
	net_send(&a, game.Use_Entity{plain.id, a.seq})
	// The lamb: a third sheep.
	ok = wait_for(
		t,
		both,
		proc(cs: []^Net_Client) -> bool {return(
				len(cs[0].entities) == 3 &&
				len(cs[1].entities) == 3 \
			)},
	)
	if !testing.expect(t, ok, "no lamb") {return}
	list = sheep_list(&srv)
	testing.expect_value(t, len(list), 3)
	lamb: Sheep_Info
	for s in list {
		if s.id != black.id && s.id != plain.id {lamb = s}
	}
	testing.expect(t, lamb.growth < game.LAMB_TICKS / 100, "the lamb is not new")
	// Its genes: a black parent's copy and a plain parent's: one wool copy (bar a mutation).
	wool := 0
	for c in ([]game.Gene_Copy{.Wool_A, .Wool_B}) {if c in lamb.genes {wool += 1}}
	testing.expect(t, wool == 1, "the lamb's genes are not its parents'")
	// The parents waited and are no longer in love.
	for s in list {
		if s.id == black.id || s.id == plain.id {
			testing.expect(
				t,
				s.love == 0 && s.wait > game.BREED_WAIT_TICKS - 300,
				"a parent did not wait",
			)
		}
	}
	// Fed again while waiting: not used up. A lamb fed: grows a tenth sooner, wheat used.
	net_send(&a, game.Use_Entity{black.id, a.seq})
	net_wait(t, both, proc(cs: []^Net_Client) -> bool {return false}, 0.4)
	net_send(&a, game.Use_Entity{lamb.id, a.seq})
	net_wait(t, both, proc(cs: []^Net_Client) -> bool {return false}, 0.6)
	list = sheep_list(&srv)
	for s in list {
		if s.id == lamb.id {
			testing.expect(
				t,
				s.growth >= game.LAMB_TICKS / 10 && s.growth < game.LAMB_TICKS / 10 + 300,
				"the lamb did not grow a tenth",
			)
		}
	}
	// A second player sees a small lamb and a black sheep.
	lambs, blacks := 0, 0
	for _, f in b.sheep {
		if .Lamb in f {lambs += 1}
		if .Black in f {blacks += 1}
	}
	testing.expect_value(t, lambs, 1)
	testing.expect_value(t, blacks, 1)
	// A lamb cannot be shorn (nothing in hand but stone: slot 0), and cannot be fed to breed.
	req(&a, &seq, .Select, 0, 0)
	net_wait(t, both, proc(cs: []^Net_Client) -> bool {return false}, 0.3)
	bring(&srv, lamb.id)
	net_send(&a, game.Use_Entity{lamb.id, a.seq})
	net_wait(t, both, proc(cs: []^Net_Client) -> bool {return false}, 0.4)
	for s in sheep_list(&srv) {if s.id == lamb.id {testing.expect(t, !s.shorn, "a lamb was shorn")}}
	// The black sheep drops black wool (shorn on the server's thread, wool counted at once).
	n := 0
	Shear :: struct {
		id: u32,
		n:  int,
	}
	shear := Shear{black.id, 0}
	call(
		&srv,
		proc(s: ^Server, data: rawptr) {
			d := (^Shear)(data)
			c := client_by_name(s, "a")
			c.inventory.selected = 0 // (stone in hand)
			if e, _ := entity_find(c.world, d.id); e != nil {
				sheep_use(s, c, e)
				for it in c.world.entities.list {
					if it.kind == .Item && it.stack.item == game.item_of_block(.Wool_Black) {
						d.n += it.stack.count
					}
				}
			}
		},
		&shear,
	)
	n = shear.n
	testing.expectf(t, n >= 1 && n <= 3, "the black sheep dropped %d black wool", n)

	// It grows up on time: 30 ticks short of it, a second later an adult.
	lamb.growth = game.LAMB_TICKS - 30
	sheep_set(&srv, lamb)
	net_wait(t, both, proc(cs: []^Net_Client) -> bool {return false}, 2)
	for s in sheep_list(&srv) {if s.id == lamb.id {testing.expect(t, s.growth == game.LAMB_TICKS, "the lamb did not grow up")}}
	for _, f in b.sheep {testing.expect(t, .Lamb not_in f, "the lamb still looks small")}

	// Kept: genes, growth, love and wait through save and load.
	keep := Sheep_Info{plain.id, game.Genes{.Wool_A, .Coat_B}, 1234, 77, 4321, true}
	sheep_set(&srv, keep)
	net_close(&a)
	net_close(&b)
	a, b = {}, {}
	time.sleep(100 * time.Millisecond)
	testing.expect(t, stop(&srv))
	stopped = true
	if !testing.expect(t, start(&srv, config(dir), {})) {return}
	stopped = false
	again: Net_Client
	net_connect(&again, srv.host.socket.port, "a")
	defer net_close(&again)
	ok = net_wait(
		t,
		{&again},
		proc(cs: []^Net_Client) -> bool {return landed(cs[0]) && len(cs[0].entities) >= 3},
	)
	testing.expect(t, ok, "the sheep did not come back")
	found := false
	for s in sheep_list(&srv) {
		// (ids are new after loading: find it by what was set)
		if s.genes == keep.genes && s.growth >= 1234 && s.growth < 1234 + 300 && s.shorn {
			found = true
			testing.expect(
				t,
				s.love > 0 && s.love <= 77 && s.wait > 4000 && s.wait <= 4321,
				"love and wait were not kept",
			)
		}
	}
	testing.expect(t, found, "genes, growth and shorn were not kept")
}
