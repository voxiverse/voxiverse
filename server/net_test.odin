package server

import "core:math"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

import "../game"
import "../netcode"
import "../worldgen"

// Players over the network: remote clients (netcode links on loopback) on a
// server without a local player, as a dedicated server runs.

@(private)
Net_Client :: struct {
	link:        netcode.Link,
	name:        string,
	scratch:     ^game.Block_Array,
	arrays:      game.Block_Arrays,
	chunks:      map[game.Chunk_Pos]game.Chunk_Blocks,
	welcome:     game.Welcome,
	welcomed:    bool,
	rejected:    string,
	update:      game.Player_Update,
	others:      map[u16]string, // joined, by player id
	seen:        map[u16][3]f64, // last Players position, by player id
	changed:     [dynamic]game.Block_Changed,
	entities:    map[u32][3]f64, // known entities, where last seen
	hurt:        int, // Entity_Hurt messages
	bulk_begins: int,
	explosions:  int,
	died:        int, // Entity_Despawn with died
	results:     map[u32]game.Edit_Result,
	seq:         u32,
	messages:    [dynamic][]u8,
	notices:     [dynamic]string, // (heap)
	grants:      [dynamic]game.Grant, // (heap)
	chat:        [dynamic]Net_Chat, // lines heard (heap)
	deleted:     [dynamic]u32, // lines taken back
	inventory:   game.Inventory, // the server's last word
	inv_acked:   u32,
	inv_updates: int,
	look:        [2]f32, // yaw, pitch of its idle inputs
	key_name:    string, // whose test_key it says it is (default: name)
	sign_name:   string, // whose test_key it signs with (default: key_name: an impostor if not)
	ask:         bool, // Hello without a character: Characters, then Choose name
	characters:  string, // the last Characters (temp: compared at once)
}

@(private)
Net_Chat :: struct {
	id:     u32,
	sender: u16,
	text:   string, // (heap)
}

@(private)
net_connect :: proc(c: ^Net_Client, port: int, name: string, password := "") {
	c.name = name
	c.scratch = new(game.Block_Array)
	game.block_arrays_init(&c.arrays, 4096)
	netcode.link_connect(&c.link, {net.IP4_Loopback, port}, password, time.tick_now())
}

@(private)
net_close :: proc(c: ^Net_Client) {
	netcode.link_close(&c.link, "test over")
	free(c.scratch)
	for _, &b in c.chunks {game.chunk_release(&b, &c.arrays)}
	game.block_arrays_destroy(&c.arrays)
	delete(c.chunks)
	for _, n in c.others {delete(n)}
	delete(c.others)
	delete(c.seen)
	delete(c.changed)
	for n in c.notices {delete(n)}
	delete(c.notices)
	for g in c.grants {delete(g.pattern)}
	delete(c.grants)
	for l in c.chat {delete(l.text)}
	delete(c.chat)
	delete(c.deleted)
	delete(c.entities)
	delete(c.results)
	delete(c.messages)
	delete(c.rejected)
}

@(private)
net_send :: proc(c: ^Net_Client, m: game.Client_Message) {
	w: game.Writer
	game.writer_init(&w, context.temp_allocator)
	game.encode_client(&w, m)
	netcode.link_send(&c.link, w.buf[:], game.message_reliable(.Client, w.buf[0]))
}

// net_pump: network in, messages handled, an idle input sent (once
// welcomed, as a real client sends one every tick), network out.
@(private)
net_pump :: proc(t: ^testing.T, c: ^Net_Client) {
	now := time.tick_now()
	was := c.link.state
	netcode.link_update(&c.link, now)
	if was != .Connected && c.link.state == .Connected {
		k := test_key(c.key_name if c.key_name != "" else c.name)
		net_send(c, game.Hello{game.PROTOCOL_VERSION, k.account, "" if c.ask else c.name})
	}
	netcode.link_receive(&c.link, &c.messages)
	for p in c.messages {
		defer netcode.link_free(&c.link, p)
		m, ok := game.decode_server(p, c.scratch)
		if !testing.expect(t, ok, "invalid message from the server") {continue}
		#partial switch v in m {
		case game.Challenge:
			signer := c.sign_name
			if signer == "" {signer = c.key_name if c.key_name != "" else c.name}
			k := test_key(signer)
			net_send(c, game.Proof{game.account_sign(&k, v.nonce)})
		case game.Characters:
			c.characters = strings.clone(v.names, context.temp_allocator)
			net_send(c, game.Choose{c.name})
		case game.Welcome:
			c.welcome, c.welcomed = v, true
		case game.Reject:
			delete(c.rejected)
			c.rejected = strings.clone(v.reason)
		case game.Chunk_Message:
			b := game.Chunk_Blocks {
				uniform = v.uniform,
			}
			if !v.is_uniform {
				b.array, _ = game.block_arrays_take(&c.arrays)
				b.array^ = c.scratch^
			}
			if old, had := &c.chunks[v.pos]; had {game.chunk_release(old, &c.arrays)}
			c.chunks[v.pos] = b
		case game.Unload_Chunk:
			if old, had := &c.chunks[v.pos]; had {
				game.chunk_release(old, &c.arrays)
				delete_key(&c.chunks, v.pos)
			}
		case game.Player_Update:
			c.update = v
		case game.Player_Joined:
			c.others[v.player] = strings.clone(v.name)
		case game.Player_Left:
			if n, had := c.others[v.player]; had {delete(n)}
			delete_key(&c.others, v.player)
			delete_key(&c.seen, v.player)
		case game.Players:
			for i in 0 ..< v.count {c.seen[v.entries[i].player] = v.entries[i].position}
		case game.Block_Changed:
			append(&c.changed, v)
			if blocks, have := &c.chunks[game.chunk_of(v.pos)]; have {
				game.chunk_set(blocks, &c.arrays, game.local_of(v.pos), v.block)
			}
		case game.Notice:
			append(&c.notices, strings.clone(v.text))
		case game.Chat_Line:
			append(&c.chat, Net_Chat{v.id, v.sender, strings.clone(v.text)})
		case game.Chat_Delete:
			append(&c.deleted, v.id)
		case game.Inventory_Update:
			c.inventory, c.inv_acked = v.inventory, v.acked
			c.inv_updates += 1
		case game.Grants:
			for g in c.grants {delete(g.pattern)}
			clear(&c.grants)
			game.grants_parse(v.text, &c.grants)
		case game.Blocks_Changed:
			if blocks, have := &c.chunks[v.chunk]; have {
				for i in 0 ..< v.count {
					e := v.entries[i]
					game.chunk_set(blocks, &c.arrays, game.local_from_index(int(e.index)), e.block)
				}
			}
		case game.Edit_Result:
			c.results[v.id] = v
		case game.Entity_Spawn:
			c.entities[v.entity] = v.position
		case game.Entities:
			for i in 0 ..< v.count {
				e := v.entries[i]
				if e.entity in c.entities {c.entities[e.entity] = e.position}
			}
		case game.Entity_Despawn:
			delete_key(&c.entities, v.entity)
			if v.died {c.died += 1}
		case game.Entity_Hurt:
			c.hurt += 1
		case game.Bulk_Begin:
			c.bulk_begins += 1
		case game.Explosion:
			c.explosions += 1
		}
	}
	clear(&c.messages)
	if c.welcomed {
		c.seq += 1
		net_send(c, game.Input{c.seq, {yaw = c.look[0], pitch = c.look[1]}})
	}
	netcode.link_flush(&c.link, now)
}

@(private)
net_wait :: proc(
	t: ^testing.T,
	clients: []^Net_Client,
	done: proc(clients: []^Net_Client) -> bool,
	seconds := 15.0,
) -> bool {
	deadline := time.tick_add(time.tick_now(), time.Duration(seconds * f64(time.Second)))
	for !done(clients) {
		if time.tick_diff(time.tick_now(), deadline) < 0 {return false}
		for c in clients {net_pump(t, c)}
		time.sleep(game.TICK_DURATION / 2)
	}
	return true
}

// at_rest: on the ground and still, as of the server's last word.
@(private)
at_rest :: proc(c: ^Net_Client) -> bool {
	@(static) last: [3]f64
	@(static) still: int
	s := c.update.state
	if s.on_ground && s.position == last {still += 1} else {still = 0}
	last = s.position
	return still >= 5
}

@(private)
landed :: proc(c: ^Net_Client) -> bool {
	return c.welcomed && c.update.state.on_ground && c.update.acked > 0 && len(c.chunks) > 50
}

@(test)
test_players_over_the_network :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "net_players"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	config := Config {
		seed        = 21,
		view_radius = 3,
		view_height = 2,
		workers     = 2,
		save_dir    = dir,
		max_players = 4,
		listen      = true,
		name        = "net test",
	}
	srv: Server
	// No local player; listen on a free port.
	if !testing.expect(t, start(&srv, config, {})) {return}
	stopped := false
	defer if !stopped {stop(&srv)}
	sync_listen(&srv)
	port := srv.host.socket.port

	alice, bob, impostor: Net_Client
	net_connect(&alice, port, "alice")
	net_connect(&bob, port, "bob")
	defer net_close(&alice)
	defer net_close(&bob)
	ok := net_wait(t, {&alice, &bob}, proc(cs: []^Net_Client) -> bool {
		return landed(cs[0]) && landed(cs[1])
	})
	if !testing.expect(t, ok, "the two players never landed") {return}
	testing.expect(t, alice.welcome.player != bob.welcome.player)
	// A remote player has the role default: they may build, not bulk edit.
	ok = net_wait(
		t,
		{&alice, &bob},
		proc(cs: []^Net_Client) -> bool {return len(cs[0].grants) > 0},
	)
	testing.expect(t, ok, "no grants")
	testing.expect(t, game.allowed(alice.grants[:], "world.edit"), "a player may not build")
	testing.expect(
		t,
		!game.allowed(alice.grants[:], "world.edit.bulk"),
		"a remote player may bulk edit",
	)

	// They know each other, and see each other (both spawn at the origin).
	ok = net_wait(t, {&alice, &bob}, proc(cs: []^Net_Client) -> bool {
			return len(cs[0].seen) == 1 && len(cs[1].seen) == 1
		})
	testing.expect(t, ok, "the players do not see each other")
	testing.expect_value(t, alice.others[bob.welcome.player], "bob")
	testing.expect_value(t, bob.others[alice.welcome.player], "alice")

	// The same name again is refused.
	net_connect(&impostor, port, "alice")
	defer net_close(&impostor)
	ok = net_wait(t, {&impostor, &alice, &bob}, proc(cs: []^Net_Client) -> bool {
		return cs[0].rejected != ""
	})
	testing.expect_value(t, impostor.rejected, "someone with that name is playing")

	// Alice breaks the block under her feet: Bob hears of it.
	feet := alice.update.state.position
	below := game.Block_Pos {
		i32(math.floor(feet.x)),
		i32(math.floor(feet.y)) - 1,
		i32(math.floor(feet.z)),
	}
	net_send(&alice, game.Edit{1, alice.seq, below, .Air})
	@(static) target: game.Block_Pos
	target = below
	ok = net_wait(t, {&alice, &bob}, proc(cs: []^Net_Client) -> bool {
		for ch in cs[1].changed {if ch.pos == target && ch.block == .Air {return true}}
		return false
	})
	testing.expect(t, ok, "bob never heard of alice's edit")
	testing.expect(t, alice.results[1].accepted, "alice's edit was refused")
	for ch in alice.changed {
		testing.expect(t, ch.pos != below, "alice was told of her own edit twice")
	}

	// Bob (standing where Alice dug: they spawn together) comes to rest,
	// then leaves: Alice is told.
	ok = net_wait(t, {&alice, &bob}, proc(cs: []^Net_Client) -> bool {return at_rest(cs[1])})
	testing.expect(t, ok, "bob never came to rest")
	bob_at := bob.update.state.position
	netcode.link_close(&bob.link, "bye")
	ok = net_wait(t, {&alice}, proc(cs: []^Net_Client) -> bool {return len(cs[0].others) == 0})
	testing.expect(t, ok, "alice was not told bob left")

	// Saved by name: after a restart, each comes back where they were.
	alice_at := alice.update.state.position
	netcode.link_close(&alice.link, "bye")
	time.sleep(100 * time.Millisecond)
	testing.expect(t, stop(&srv))
	stopped = true
	if !testing.expect(t, start(&srv, config, {})) {return}
	stopped = false
	sync_listen(&srv)
	again: Net_Client
	net_connect(&again, srv.host.socket.port, "bob")
	defer net_close(&again)
	ok = net_wait(t, {&again}, proc(cs: []^Net_Client) -> bool {return cs[0].welcomed})
	if testing.expect(t, ok) {
		d := again.welcome.spawn - bob_at
		testing.expectf(
			t,
			abs(d.x) + abs(d.y) + abs(d.z) < 0.01,
			"bob back at %v, left at %v",
			again.welcome.spawn,
			bob_at,
		)
	}
	_ = alice_at
}

// sync_listen waits for the server thread to be listening (start opens the
// socket before the thread starts, so this is immediate; kept explicit).
@(private = "file")
sync_listen :: proc(s: ^Server) {
	for !s.listening {time.sleep(time.Millisecond)}
}

// M7's exit check (the half a machine can do alone): two players over real
// sockets with 10% loss, 10% duplication and jitter on every socket, both
// ways. Every chunk each receives is exactly what the world generator
// makes there; they see each other; an edit by one reaches the other.
@(test)
test_players_through_ten_percent_loss :: proc(t: ^testing.T) {
	bad := netcode.Conditions {
		loss       = 0.1,
		duplicate  = 0.1,
		latency_ms = 15,
		jitter_ms  = 25,
	}
	config := Config {
		seed        = 31,
		view_radius = 3,
		view_height = 2,
		workers     = 2,
		max_players = 4,
		listen      = true,
		conditions  = bad,
	}
	srv: Server
	if !testing.expect(t, start(&srv, config, {})) {return}
	defer stop(&srv)
	port := srv.host.socket.port

	a, b: Net_Client
	net_connect(&a, port, "alpha")
	net_connect(&b, port, "beta")
	defer net_close(&a)
	defer net_close(&b)
	a.link.socket.conditions = bad
	b.link.socket.conditions = bad
	// The whole interest area, not just enough to land on.
	@(static) want: int
	want = game.interest_count(config.view_radius, config.view_height)
	ok := net_wait(t, {&a, &b}, proc(cs: []^Net_Client) -> bool {
			return(
				landed(cs[0]) &&
				landed(cs[1]) &&
				len(cs[0].chunks) >= want &&
				len(cs[1].chunks) >= want \
			)
		}, 60)
	if !testing.expectf(
		t,
		ok,
		"chunks: %d and %d of %d",
		len(a.chunks),
		len(b.chunks),
		want,
	) {return}

	expected := new(game.Block_Array)
	defer free(expected)
	for c in ([]^Net_Client{&a, &b}) {
		damaged := 0
		for pos, &blocks in c.chunks {
			gen := worldgen.generator_make(config.generator, config.seed)
			worldgen.generate(&gen, pos, expected)
			for i in 0 ..< len(expected) {
				got := blocks.uniform if blocks.array == nil else blocks.array[i]
				if got != expected[i] {
					damaged += 1
					break
				}
			}
		}
		testing.expectf(
			t,
			damaged == 0,
			"%s: %d of %d chunks differ from the world",
			c.name,
			damaged,
			len(c.chunks),
		)
	}

	ok = net_wait(t, {&a, &b}, proc(cs: []^Net_Client) -> bool {
			return len(cs[0].seen) == 1 && len(cs[1].seen) == 1
		}, 30)
	testing.expect(t, ok, "the players do not see each other")

	feet := a.update.state.position
	@(static) below: game.Block_Pos
	below = {i32(math.floor(feet.x)), i32(math.floor(feet.y)) - 1, i32(math.floor(feet.z))}
	net_send(&a, game.Edit{1, a.seq, below, .Air})
	ok = net_wait(t, {&a, &b}, proc(cs: []^Net_Client) -> bool {
			for ch in cs[1].changed {
				if ch.pos == below && ch.block == .Air && 1 in cs[0].results {return true}
			}
			return false
		}, 30)
	testing.expect(t, ok, "beta never heard of alpha's edit (or alpha of its result)")
	testing.expect(t, a.results[1].accepted, "alpha's edit was refused")
}
