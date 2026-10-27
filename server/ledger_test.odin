package server

import "core:math/rand"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"

import "../common/game"
import "../common/telemetry"

// M31: the item ledger and its audit.

@(private = "file")
config :: proc(dir: string, death_drops := false) -> Config {
	rules := quiet_rules()
	rules.death_drops = death_drops
	return {
		seed = 31,
		generator = .Classic,
		rules = rules,
		view_radius = 3,
		view_height = 2,
		workers = 1,
		max_players = 4,
		listen = true,
		everyone_cheats = true,
		save_dir = dir,
		no_sheep = true,
		world_idle = 0.5,
	}
}

@(private = "file")
test_dir :: proc(name: string) -> string {
	dir := filepath.join({"build", "test", name}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	return dir
}

// Report: what the audit said and the entries asked about, read out on the
// server's thread.
@(private = "file")
Report :: struct {
	name:   string, // whose client
	step:   int,
	lines:  [8]Audit_Line,
	count:  int, // unbalanced items
	rows:   [4][game.Reason]i64, // entries for the first four of `items`
	items:  [4]game.Item,
	flag:   bool,
	addr:   game.Address,
	detail: int,
}

@(private = "file")
read_audit :: proc(s: ^Server, r: ^Report) {
	lines := audit(s)
	r.count = len(lines)
	for l, i in lines[:min(len(lines), len(r.lines))] {r.lines[i] = l}
	for item, i in r.items {
		if row, ok := s.ledger.entries[item]; ok {r.rows[i] = row}
	}
}

@(private = "file")
audit_now :: proc(srv: ^Server, items: [4]game.Item = {}) -> Report {
	r := Report {
		items = items,
	}
	call(srv, proc(s: ^Server, data: rawptr) {read_audit(s, (^Report)(data))}, &r)
	return r
}

@(private = "file")
expect_balanced :: proc(t: ^testing.T, r: Report, what: string, loc := #caller_location) {
	r := r
	testing.expectf(
		t,
		r.count == 0,
		"%s: unbalanced items: %v",
		what,
		r.lines[:r.count],
		loc = loc,
	)
}

@(private = "file")
join_one :: proc(t: ^testing.T, a: ^Net_Client, port: int, name: string) -> bool {
	net_connect(a, port, name)
	return net_wait(t, {a}, proc(cs: []^Net_Client) -> bool {return landed(cs[0])}, 30)
}

// The session: every faucet and every sink of the lists, one by one, on the
// server's thread, each with the numbers it should leave.
@(private = "file")
script :: proc(s: ^Server, data: rawptr) {
	r := (^Report)(data)
	c := client_by_name(s, r.name)
	if c == nil {return}
	w := c.world
	stone, dirt := game.item_of_block(.Stone), game.item_of_block(.Dirt)
	wool, wheat := game.item_of_block(.Wool), game.item_of_material(.Wheat)
	r.items = {stone, dirt, wool, wheat}
	switch r.step {
	case 0:
		// What the join made (the kit) is in the ledger already.
		read_audit(s, r)
		r.detail = int(s.ledger.entries[stone][.Kit])
		audit_baseline(s)
	case 1:
		// Faucets and sinks of the lists.
		admin_give(s, c, {r.name, "dirt", "100"})
		admin_give(s, c, {r.name, "wheat", "10"})
		// The catalog makes a stack of stone; the next Take replaces it.
		inventory_request(s, c, {1, {.Take, 0, int(stone)}})
		inventory_request(s, c, {2, {.Take, 0, int(dirt)}})
		inventory_request(s, c, {3, {.Close, game.CURSOR_SLOT, 0}})
		// Placing uses one up.
		for st, i in c.inventory.slots {
			if st.item == stone {
				used_to_place(s, c, i)
				break
			}
		}
		// Breaking leaves one.
		block_drop(w, {0, 100, 0}, .Stone)
		// Clearing takes the dirt back.
		admin_clear(s, c, {"dirt"})
		// An old stack on the ground expires.
		for i in 0 ..< len(w.entities.list) {
			e := &w.entities.list[i]
			if e.kind != .Item {continue}
			e.age = int(game.ITEM_LIFE * game.TICK_RATE) + 10
			if item_tick(w, i) {entity_gone(w, i)}
			break
		}
		// A sheep: wheat fed to it, then it is shorn (by someone who must
		// use up what they feed).
		for g in c.grants {delete(g.pattern)}
		clear(&c.grants)
		summon(s, c, .Sheep)
		for &e in w.entities.list {
			if e.kind != .Sheep {continue}
			for st, i in c.inventory.slots {
				if st.item == wheat { 	// (to the hand: a move)
					c.inventory.slots[i], c.inventory.slots[0] =
						c.inventory.slots[0], c.inventory.slots[i]
					break
				}
			}
			c.inventory.selected = 0
			sheep_use(s, c, &e)
			for i in 0 ..< game.HOTBAR_SLOTS {
				if c.inventory.slots[i].item != wheat {c.inventory.selected = i}
			}
			sheep_use(s, c, &e)
		}
		// A world with no room for what is dropped: it is void.
		ledger(s, w, .Give, stone, 5)
		for len(w.entities.list) < MAX_ENTITIES {entity_spawn(w, .Sheep, {0, 100, 0}, false)}
		spawn_item(w, {0, 100, 0}, {stone, 5}, {}, -1)
		for len(w.entities.list) > 0 && w.entities.list[len(w.entities.list) - 1].kind == .Sheep {
			entity_gone(w, len(w.entities.list) - 1)
		}
		read_audit(s, r)
	case 2:
		// A stack duplicated: the audit says which item and how much.
		for &st in c.inventory.slots {
			if game.stack_empty(st) {
				st = {stone, 7}
				read_audit(s, r)
				st = {}
				break
			}
		}
	case 3:
		// A stack deleted.
		for &st in c.inventory.slots {
			if st.item == stone {
				st.count -= 3
				break
			}
		}
		read_audit(s, r)
		for &st in c.inventory.slots {
			if st.item == stone {
				st.count += 3
				break
			}
		}
	case 4:
		read_audit(s, r)
	}
}

@(private = "file")
step :: proc(srv: ^Server, name: string, n: int) -> Report {
	r := Report {
		name = name,
		step = n,
	}
	call(srv, script, &r)
	return r
}

// A scripted session through every faucet and sink ends balanced with the
// expected counts; a duplicated stack and a deleted one are reported by
// item and amount.
@(test)
test_ledger_session :: proc(t: ^testing.T) {
	dir := test_dir("ledger_session")
	defer os.remove_all(dir)
	srv: Server
	if !testing.expect(t, start(&srv, config(dir), {})) {return}
	defer stop(&srv)
	for !srv.listening {}
	a: Net_Client
	defer net_close(&a)
	if !testing.expect(t, join_one(t, &a, srv.host.socket.port, "a"), "never landed") {return}

	r := step(&srv, "a", 0)
	expect_balanced(t, r, "after joining (the kit)")
	testing.expect(t, r.detail > 0, "the kit was not in the ledger")

	r = step(&srv, "a", 1)
	expect_balanced(t, r, "after the session")
	stone, dirt, wool, wheat := r.rows[0], r.rows[1], r.rows[2], r.rows[3]
	testing.expect_value(t, dirt[.Give], 100)
	testing.expect_value(t, dirt[.Catalog], 64)
	testing.expect_value(t, stone[.Catalog], 64)
	testing.expect_value(t, stone[.Catalog_Return], -64)
	testing.expect_value(t, stone[.Place], -1)
	testing.expect_value(t, stone[.Drop_Block], 1)
	testing.expect_value(t, stone[.Void], -5)
	testing.expect_value(t, dirt[.Clear], -228) // (the kit's and what was given and taken)
	testing.expect_value(t, wheat[.Give], 10)
	testing.expect_value(t, wheat[.Use], -1)
	testing.expect(t, wool[.Drop_Mob] >= 1 && wool[.Drop_Mob] <= 3, "no wool from the sheep")
	expired: i64
	for row in r.rows {expired += row[.Expire]}
	testing.expect(t, expired < 0, "nothing expired")

	r = step(&srv, "a", 2)
	testing.expect_value(t, r.count, 1)
	testing.expect_value(t, r.lines[0].item, game.item_of_block(.Stone))
	testing.expect_value(t, r.lines[0].held - r.lines[0].expected, 7)
	r = step(&srv, "a", 3)
	testing.expect_value(t, r.count, 1)
	testing.expect_value(t, r.lines[0].held - r.lines[0].expected, -3)
	expect_balanced(t, step(&srv, "a", 4), "put back")
}

@(private = "file")
Scenario :: struct {
	name:  string,
	step:  int,
	count: int,
	addr:  game.Address,
	slot:  int,
	pos:   game.Block_Pos,
	ok:    bool,
}

@(private = "file")
scenario_proc :: proc(s: ^Server, data: rawptr) {
	d := (^Scenario)(data)
	c := client_by_name(s, d.name)
	if d.step == 9 {
		d.count = len(audit(s))
		return
	}
	if c == nil && d.step != 3 {return}
	switch d.step {
	case 0:
		d.ok = travel(s, c, d.addr) == ""
	case 1:
		damage_player(s, c, 1000, "test")
	case 2:
		// A chest placed and filled by hand through the requests.
		set_block(c.world, d.pos, .Chest)
		use_block(s, c, d.pos)
	case 3:
		// A saved character with more than it can hold.
		if rec, ok := &s.store.players[d.name]; ok {
			rec.overflow[0] = {game.item_of_block(.Dirt), 9}
			d.ok = true
		}
	case 4:
		d.count = len(s.worlds)
	}
	d.count = len(audit(s))
}

@(private = "file")
scenario :: proc(
	srv: ^Server,
	name: string,
	n: int,
	addr := game.Address{},
	pos := game.Block_Pos{},
) -> Scenario {
	d := Scenario {
		name = name,
		step = n,
		addr = addr,
		pos  = pos,
	}
	call(srv, scenario_proc, &d)
	return d
}

@(private = "file")
settle :: proc(t: ^testing.T, a: ^Net_Client, seconds: f64) {
	net_wait(t, {a}, proc(cs: []^Net_Client) -> bool {return false}, seconds)
}

// Travel, a chest, death with drops, disconnecting with a full inventory
// and reconnecting, and a world unloaded and loaded again leave the audit
// balanced.
@(test)
test_ledger_scenarios :: proc(t: ^testing.T) {
	dir := test_dir("ledger_scenarios")
	defer os.remove_all(dir)
	srv: Server
	if !testing.expect(t, start(&srv, config(dir, death_drops = true), {})) {return}
	stopped := false
	defer if !stopped {stop(&srv)}
	for !srv.listening {}
	port := srv.host.socket.port
	a: Net_Client
	defer net_close(&a)
	if !testing.expect(t, join_one(t, &a, port, "a"), "never landed") {return}

	// A chest, filled and emptied through requests.
	pos := beside_of(&srv, "a")
	d := scenario(&srv, "a", 2, pos = pos)
	testing.expect_value(t, d.count, 0)
	n: u32
	for slot in 0 ..< 3 {
		n += 1
		net_send(&a, game.Inventory_Request{n, {.Quick_Move, slot, 0}})
	}
	settle(t, &a, 0.4)
	expect_balanced(t, audit_now(&srv), "stacks in a chest")
	// Broken, it spills.
	put_block_at(&srv, pos, .Air)
	settle(t, &a, 0.4)
	expect_balanced(t, audit_now(&srv), "a chest broken")

	// Travel away and back.
	away := game.address_derive(31)
	d = scenario(&srv, "a", 0, away)
	testing.expect(t, d.ok, "no travel")
	testing.expect_value(t, d.count, 0)
	settle(t, &a, 0.6)

	// Death drops everything where they fell (in the other world).
	d = scenario(&srv, "a", 1)
	testing.expect_value(t, d.count, 0)
	settle(t, &a, 0.4)

	// Home: the other world goes once nobody is in it, with its dropped
	// stacks; going there again loads them from its save.
	d = scenario(&srv, "a", 0, srv.home.address)
	testing.expect_value(t, d.count, 0)
	for _ in 0 ..< 40 {
		settle(t, &a, 0.1)
		if scenario(&srv, "a", 4).count == 0 && stats(&srv).worlds == 1 {break}
	}
	testing.expect_value(t, stats(&srv).worlds, 1)
	expect_balanced(t, audit_now(&srv), "a world unloaded")
	d = scenario(&srv, "a", 0, away)
	testing.expect_value(t, d.count, 0)
	settle(t, &a, 0.6)
	expect_balanced(t, audit_now(&srv), "a world loaded again")

	// Gone with what they carry, back with a saved character that had
	// more than it could hold.
	net_close(&a)
	for _ in 0 ..< 100 {
		r := Report {
			name = "a",
		}
		call(&srv, proc(s: ^Server, data: rawptr) {
				r := (^Report)(data)
				r.flag = client_by_name(s, r.name) != nil
			}, &r)
		if !r.flag {break}
		time.sleep(20 * time.Millisecond)
	}
	expect_balanced(t, audit_now(&srv), "a player gone")
	d = scenario(&srv, "a", 3)
	testing.expect(t, d.ok, "no saved character")
	a = {}
	if !testing.expect(t, join_one(t, &a, port, "a"), "never came back") {return}
	expect_balanced(t, audit_now(&srv), "a player back")
	r := audit_now(&srv, {game.item_of_block(.Dirt), 0, 0, 0})
	testing.expect(t, r.rows[0][.Spill_Old] == 9, "the old stack was not in the ledger")
}

@(private = "file")
beside_of :: proc(srv: ^Server, name: string) -> game.Block_Pos {
	d := Scenario {
		name = name,
		step = 5,
	}
	call(srv, proc(s: ^Server, data: rawptr) {
			d := (^Scenario)(data)
			if c := client_by_name(s, d.name); c != nil {
				p := c.player.position
				d.pos = {i32(p.x) + 2, i32(p.y), i32(p.z)}
			}
		}, &d)
	return d.pos
}

@(private = "file")
put_block_at :: proc(srv: ^Server, pos: game.Block_Pos, block: game.Block) {
	d := Scenario {
		pos  = pos,
		slot = int(block),
	}
	call(srv, proc(s: ^Server, data: rawptr) {
			d := (^Scenario)(data)
			set_block(s.worlds[0], d.pos, game.Block(d.slot))
		}, &d)
}

// --- The fuzz ---

// random_inventory: stacks of random items (kept valid).
@(private = "file")
random_inventory :: proc(r: rand.Generator) -> (inv: game.Inventory) {
	items := game.every_item(context.temp_allocator)
	pick :: proc(r: rand.Generator, items: []game.Item) -> game.Stack {
		if rand.int_max(3, r) == 0 {return {}}
		item := rand.choice(items, r)
		return {item, rand.int_range(1, game.item_stack_size(item) + 1, r)}
	}
	for &st in inv.slots {st = pick(r, items)}
	for &st, e in inv.equipment {
		st = pick(r, items)
		if !game.item_fits(st, e) {st = {}}
	}
	for &st in inv.chest {st = pick(r, items)}
	inv.cursor = pick(r, items)
	inv.chest_open = rand.int_max(2, r) == 0
	if !inv.chest_open {inv.chest = {}}
	return
}

@(private = "file")
totals :: proc(inv: ^game.Inventory) -> map[game.Item]int {
	m := make(map[game.Item]int, context.temp_allocator)
	add :: proc(m: ^map[game.Item]int, st: game.Stack) {
		if !game.stack_empty(st) {m[st.item] += st.count}
	}
	for st in inv.slots {add(&m, st)}
	for st in inv.equipment {add(&m, st)}
	for st in inv.chest {add(&m, st)}
	add(&m, inv.cursor)
	return m
}

// The game level: 20000 random actions (every kind; slots and arguments in
// and out of range) on random inventories, without the catalog: items are
// conserved (what is dropped counts), a refused action changes nothing, and
// the inventory stays valid.
@(test)
test_inventory_fuzz :: proc(t: ^testing.T) {
	state := rand.create(31)
	r := rand.default_random_generator(&state)
	for round in 0 ..< 400 {
		inv := random_inventory(r)
		for _ in 0 ..< 50 {
			before := inv
			a := game.Inventory_Action {
				kind = rand.choice_enum(game.Inventory_Action_Kind, r),
				slot = rand.int_range(-3, game.ALL_SLOTS + 3, r),
				arg  = rand.choice([]int{-1, 0, 1, 2, 4, 5, 64, 65535, 65536, 1 << 40}, r),
			}
			// (The chest is the server's record's copy: closing it forgets the copy.)
			counted := inv
			if a.kind == .Close {counted.chest = {}}
			sum := totals(&counted)
			dropped, ok := game.inventory_apply(&inv, a, false)
			if !ok {
				if !testing.expectf(
					t,
					inv == before && game.stack_empty(dropped),
					"refused %v changed things",
					a,
				) {return}
				continue
			}
			if !testing.expectf(
				t,
				game.inventory_valid(&inv),
				"%v left an invalid inventory",
				a,
			) {return}
			after := totals(&inv)
			if !game.stack_empty(dropped) {after[dropped.item] += dropped.count}
			same := len(sum) == len(after)
			for item, n in sum {same &&= after[item] == n}
			for item, n in after {same &&= sum[item] == n}
			if !testing.expectf(
				t,
				same,
				"%v changed the number of items (round %d)",
				a,
				round,
			) {return}
		}
	}
}

// Two clients over UDP send 2000 random requests each (the catalog allowed,
// a chest both look at, dying and travelling in between): the audit ends
// balanced.
@(test)
test_ledger_fuzz_over_udp :: proc(t: ^testing.T) {
	dir := test_dir("ledger_fuzz")
	defer os.remove_all(dir)
	srv: Server
	if !testing.expect(t, start(&srv, config(dir, death_drops = true), {})) {return}
	defer stop(&srv)
	for !srv.listening {}
	port := srv.host.socket.port
	a, b: Net_Client
	defer net_close(&a)
	defer net_close(&b)
	net_connect(&a, port, "a")
	net_connect(&b, port, "b")
	both := []^Net_Client{&a, &b}
	ok := net_wait(
		t,
		both,
		proc(cs: []^Net_Client) -> bool {return landed(cs[0]) && landed(cs[1])},
		30,
	)
	if !testing.expect(t, ok, "never landed") {return}
	pos := beside_of(&srv, "a")
	put_block_at(&srv, pos, .Chest)
	state := rand.create(32)
	r := rand.default_random_generator(&state)
	for i in 0 ..< 2000 {
		for c in both {
			c.seq += 1
			switch rand.int_max(60, r) {
			case 0:
				net_send(c, game.Use_Block{pos, 0})
			case 1:
				net_send(c, game.Command{"kill all"})
			case:
				request := game.Inventory_Request {
					sequence = c.seq,
					action   = {
						rand.choice_enum(game.Inventory_Action_Kind, r),
						rand.int_range(-1, game.ALL_SLOTS, r),
						rand.choice([]int{0, 0, 1, 1, 2, 4, 5, 64, 255, 65535}, r),
					},
				}
				net_send(c, request)
			}
		}
		if i % 100 == 99 {
			net_wait(t, both, proc(cs: []^Net_Client) -> bool {return false}, 0.05)
			if i == 999 {
				d := scenario(&srv, "a", 1) // dies mid-way
				testing.expect_value(t, d.count, 0)
			}
		}
	}
	net_wait(t, both, proc(cs: []^Net_Client) -> bool {return false}, 1.0)
	expect_balanced(t, audit_now(&srv), "after 4000 random requests")
}

@(private = "file")
given :: proc(s: ^Server, st: game.Stack) {
	row := s.ledger.entries[st.item]
	row[.Give] += i64(st.count)
	s.ledger.entries[st.item] = row
}

// The audit's cost: 200 players and 3000 item entities.
@(test)
test_audit_budget :: proc(t: ^testing.T) {
	s := new(Server)
	defer free(s)
	s.clients = make([]Client, 200)
	defer delete(s.clients)
	w := new(World)
	defer free(w)
	defer delete(w.entities.list)
	w.server = s
	append(&s.worlds, w)
	defer delete(s.worlds)
	defer ledger_destroy(&s.ledger)
	items := game.every_item(context.temp_allocator)
	for &c, i in s.clients {
		c.state = .Playing
		for &st, k in c.inventory.slots {
			st = {items[(i + k) % len(items)], 1 + k % 5}
			given(s, st)
		}
	}
	for i in 0 ..< 3000 {
		st := game.Stack{items[i % len(items)], 1 + i % 7}
		append(&w.entities.list, Entity{kind = .Item, stack = st})
		given(s, st)
	}
	start := time.tick_now()
	lines := audit(s)
	took := time.tick_since(start)
	testing.expect_value(t, len(lines), 0)
	testing.expectf(t, took < 10 * time.Millisecond, "the audit took %v", took)
	free_all(context.temp_allocator)
}

@(test)
test_ledger_kinds :: proc(t: ^testing.T) {
	for name in ([]string{"item_created", "item_destroyed", "audit_failed"}) {
		_, ok := telemetry.kind_by_name(name)
		testing.expectf(t, ok, "no kind %s", name)
	}
}

// expect_items_balanced: the end of every test that touches items.
@(private)
expect_items_balanced :: proc(t: ^testing.T, srv: ^Server, loc := #caller_location) {
	expect_balanced(t, audit_now(srv), "at the end", loc)
}
