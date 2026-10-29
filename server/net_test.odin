package server

import "core:math"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "../common/game"
import "../common/netcode"

// Players over the network: remote clients (netcode links on loopback) on a
// server without a local player, as a dedicated server runs.

@(private)
Net_Client :: struct {
	link:                        netcode.Link,
	buttons:                     bit_set[game.Button;u8], // what its Inputs hold down
	stepper:                     ^Harness, // net_wait steps this harness's ticks
	name:                        string,
	scratch:                     ^game.Block_Array,
	arrays:                      game.Block_Arrays,
	chunks:                      map[game.Chunk_Pos]game.Chunk_Blocks,
	welcome:                     game.Welcome,
	welcomed:                    bool,
	rejected:                    string,
	update:                      game.Own_Player,
	schema:                      game.Schema,
	rx:                          game.Receiver,
	teleports:                   int, // Own_Player.teleports changes seen
	others:                      map[u16]string, // joined, by player id
	seen:                        map[u16][3]f64, // last Players position, by player id
	counts:                      map[u16][2]u32, // the others' kills and deaths (Player records)
	worn:                        map[u16][game.WORN_SLOTS]game.Item, // last Player_Worn, by player id
	changed:                     [dynamic]Net_Block,
	entities:                    map[u32][3]f64, // known entities, where last seen
	shorn:                       map[u32]bool, // sheep as last told shorn or not
	sheep:                       map[u32]game.Sheep_Flags, // and what else about their looks
	stats_text:                  string, // the last Stats_Page's lines (heap)
	stats_pages:                 int,
	health:                      game.Health, // the last Health message
	mode:                        string, // the last Mode record's id (heap)
	hurt:                        int, // Entity_Hurt messages
	bulk_begins:                 int,
	explosions:                  int,
	place:                       game.Place, // the last Place record
	tally:                       game.Tally, // the last Tally record
	places:                      int, // Place records received
	deaths:                      int, // Player_Died events
	died:                        int, // Entity_Despawn with died
	hits:                        int, // Damage_Hit events
	shots_seen:                  int, // Shot events (another player's)
	confirms:                    [dynamic]game.Hit_Confirm, // Hit_Confirm events (heap)
	death_cause, death_attacker: string, // the last Player_Died
	results:                     map[u32]game.Edit_Result,
	seq:                         u32,
	messages:                    [dynamic][]u8,
	notices:                     [dynamic]string, // (heap)
	grants:                      [dynamic]game.Grant, // (heap)
	chat:                        [dynamic]Net_Chat, // lines heard (heap)
	deleted:                     [dynamic]u32, // lines taken back
	inventory:                   game.Inventory, // the server's last word
	rest_last:                   [3]f64, // at_rest: where it was last update, and for how many
	rest_still:                  int,
	inv_acked:                   u32,
	inv_updates:                 int,
	look:                        [2]f32, // yaw, pitch of its idle inputs
	move:                        [2]f32, // and their move (right, forward)
	key_name:                    string, // whose test_key it says it is (default: name)
	sign_name:                   string, // whose test_key it signs with (default: key_name: an impostor if not)
	ask:                         bool, // Hello without a character: Characters, then Choose name
	characters:                  string, // the last Characters (temp: compared at once)
	address:                     game.Address, // the world it is in (Welcome, World_Changed)
	travels:                     int, // World_Changed messages
	capture:                     netcode.Capture, // (net_capture: every packet it sends and receives)
	pack_cache:                  string, // where it keeps the packs it was sent ("": nowhere)
	fetch:                       ^game.Pack_Fetch, // the Packs it was told of
	reg:                         ^game.Registry, // built from them (client side: no server/ files); nil: the base pack's
	pack_parts:                  int, // Pack_Part messages received
	received:                    int, // bytes of server messages taken (party_test's bandwidth)
	packs_error:                 string, // why the packs could not be taken (temp)
}

@(private)
Net_Block :: struct {
	pos:   game.Block_Pos,
	block: game.Block,
	heard: bool,
}

@(private)
Net_Chat :: struct {
	id:     u32,
	sender: u16,
	text:   string, // (heap)
}

@(private)
net_connect :: proc(
	c: ^Net_Client,
	port: int,
	name: string,
	password := "",
	capture := "",
	sim: ^netcode.Simnet = nil,
	h: ^Harness = nil,
) {
	sim, port := sim, port
	if h != nil {
		// (on the harness's network, at the server's address, stepped by net_wait)
		sim, port, c.stepper = &h.net, h.srv.host.socket.port, h
	}
	c.name = name
	assert(sim != nil, "net_connect needs a harness (h) or a simulated network (sim)")
	now := sim.now
	c.scratch = new(game.Block_Array)
	game.block_arrays_init(&c.arrays, 4096)
	c.schema = game.game_schema()
	game.receiver_init(&c.rx, &c.schema, test_reg())
	netcode.link_connect(&c.link, {net.IP4_Loopback, port}, password, now, sim = sim)
	if capture != "" {net_capture(c, capture)}
}

// net_capture records c's packets to a pcap file (tools/wireshark/check.lua reads it).
@(private)
net_capture :: proc(c: ^Net_Client, path: string) {
	if netcode.capture_open(&c.capture, path) {c.link.socket.capture = &c.capture}
}

@(private)
net_close :: proc(c: ^Net_Client) {
	netcode.link_close(&c.link, "test over")
	netcode.capture_close(&c.capture)
	free(c.scratch)
	game.receiver_destroy(&c.rx)
	game.schema_destroy(&c.schema)
	for _, &b in c.chunks {game.chunk_release(&b, &c.arrays)}
	game.block_arrays_destroy(&c.arrays)
	delete(c.chunks)
	for _, n in c.others {delete(n)}
	delete(c.others)
	delete(c.mode)
	delete(c.death_cause)
	delete(c.death_attacker)
	delete(c.seen)
	delete(c.worn)
	delete(c.counts)
	delete(c.changed)
	for n in c.notices {delete(n)}
	delete(c.notices)
	for g in c.grants {delete(g.pattern)}
	delete(c.grants)
	for l in c.chat {delete(l.text)}
	delete(c.chat)
	delete(c.confirms)
	delete(c.deleted)
	delete(c.entities)
	delete(c.shorn)
	delete(c.sheep)
	delete(c.stats_text)
	delete(c.results)
	delete(c.messages)
	delete(c.rejected)
	if c.fetch != nil {
		game.pack_fetch_destroy(c.fetch)
		free(c.fetch)
	}
	if c.reg != nil {game.registry_destroy(c.reg)}
}

// net_packs_built: with every pack held, the registry they make, and Packs_Ready.
@(private)
net_packs_built :: proc(c: ^Net_Client) {
	if c.reg != nil || c.packs_error != "" || !game.pack_fetch_complete(c.fetch) {return}
	sources, _ := game.pack_fetch_sources(c.fetch)
	all := make([dynamic]game.Pack_Source, context.temp_allocator)
	append(&all, game.pack_source_sent(game.base_pack_source(context.temp_allocator)))
	append(&all, ..sources)
	reg, problems := game.registry_build(all[:], .Client)
	if reg == nil {
		c.packs_error =
			"the packs do not build" if len(problems) == 0 else game.pack_error_text(problems[0])
		return
	}
	c.reg = reg
	game.receiver_destroy(&c.rx)
	game.receiver_init(&c.rx, &c.schema, reg)
	net_send(c, game.Packs_Ready{reg.hash})
}

@(private)
net_send :: proc(c: ^Net_Client, m: game.Client_Message) {
	w: game.Writer
	game.writer_init(&w, context.temp_allocator)
	game.encode_client(&w, m)
	netcode.link_send(&c.link, w.buf[:], game.message_reliable(.Client, w.buf[0]))
}

// net_apply keeps what the receiver yielded as the client's fields.
@(private)
net_apply :: proc(c: ^Net_Client, got: []game.Received) {
	for g in got {
		switch game.State_Kind(g.kind) {
		case .Own_Player:
			if v := (^game.Own_Player)(g.value)^; v.teleports != u8(c.teleports) {
				c.teleports = int(v.teleports)
			}
			c.update = (^game.Own_Player)(g.value)^
		case .Health:
			c.health = (^game.Health)(g.value)^
		case .Inventory:
			v := (^game.Inventory_State)(g.value)
			c.inventory, c.inv_acked = v.inventory, v.acked
			c.inv_updates += 1
		case .Mode:
			delete(c.mode)
			c.mode = strings.clone((^game.Mode_Record)(g.value).mode)
		case .Rules, .Clock, .Variables, .Selection:
		case .Tally:
			c.tally = (^game.Tally)(g.value)^
		case .Place:
			c.place = (^game.Place)(g.value)^
			c.places += 1
		case .Grants:
			v := (^game.Grants)(g.value)
			for gr in c.grants {delete(gr.pattern)}
			clear(&c.grants)
			game.grants_parse(v.text, &c.grants)
		case .Player:
			id := u16(g.key.a)
			if g.op == .Remove {
				if n, had := c.others[id]; had {delete(n)}
				delete_key(&c.others, id)
				delete_key(&c.worn, id)
			} else {
				v := (^game.Player_Record)(g.value)
				if n, had := c.others[id]; had {delete(n)}
				c.others[id] = strings.clone(v.name)
				c.worn[id] = v.worn
				c.counts[id] = {v.kills, v.deaths}
			}
		case .Player_Motion:
			id := u16(g.key.a)
			if g.op == .Remove {
				delete_key(&c.seen, id)
			} else {
				c.seen[id] = (^game.Player_Motion)(g.value).position
			}
		case .Entity:
			// (an entity is known once it has a place too: Entity_Motion)
			if g.op == .Remove {
				id := u32(g.key.a)
				delete_key(&c.entities, id)
				delete_key(&c.shorn, id)
				delete_key(&c.sheep, id)
			}
		case .Entity_Motion:
			id := u32(g.key.a)
			if g.op == .Remove {continue}
			v := (^game.Entity_Motion)(g.value)
			if game.replica_get(&c.rx.live, int(game.State_Kind.Entity), g.key) != nil {
				c.entities[id] = v.position
				c.shorn[id] = .Shorn in v.flags
				c.sheep[id] = v.flags
			}
		case .Block:
			v := (^game.Block_Record)(g.value)
			p := game.key_block(g.key)
			append(&c.changed, Net_Block{p, game.Block(v.block), v.heard})
			if blocks, have := &c.chunks[game.chunk_of(p)]; have {
				game.chunk_set(blocks, &c.arrays, game.local_of(p), game.Block(v.block))
			}
		}
		if g.op != .Event {continue}
		switch game.Event_Kind(g.kind - len(game.State_Kind)) {
		case .Notice:
			append(&c.notices, strings.clone((^game.Notice)(g.value).text))
		case .Chat_Line:
			v := (^game.Chat_Line)(g.value)
			append(&c.chat, Net_Chat{v.id, v.sender, strings.clone(v.text)})
		case .Chat_Delete:
			append(&c.deleted, (^game.Chat_Delete)(g.value).id)
		case .Entity_Hurt:
			c.hurt += 1
		case .Entity_Died:
			c.died += 1
		case .Explosion:
			c.explosions += 1
		case .Player_Died:
			c.deaths += 1
			v := (^game.Player_Died)(g.value)
			delete(c.death_cause)
			delete(c.death_attacker)
			c.death_cause, c.death_attacker = strings.clone(v.cause), strings.clone(v.attacker)
		case .Damage_Hit:
			c.hits += 1
		case .Shot:
			c.shots_seen += 1
		case .Hit_Confirm:
			append(&c.confirms, (^game.Hit_Confirm)(g.value)^)
		}
	}
}

@(private)
net_set_block :: proc(c: ^Net_Client, p: game.Block_Pos, b: game.Block) {
	if blocks, have := &c.chunks[game.chunk_of(p)]; have {
		game.chunk_set(blocks, &c.arrays, game.local_of(p), b)
	}
}

// net_pump: network in, messages handled, an idle input sent (once
// welcomed, as a real client sends one every tick), network out.
@(private)
net_pump :: proc(t: ^testing.T, c: ^Net_Client) {
	now := netcode.link_now(&c.link)
	was := c.link.state
	netcode.link_update(&c.link, now)
	if was != .Connected && c.link.state == .Connected {
		k := test_key(c.key_name if c.key_name != "" else c.name)
		net_send(
			c,
			game.Hello{game.PROTOCOL_VERSION, k.account, "" if c.ask else c.name, c.schema.hash},
		)
	}
	netcode.link_receive(&c.link, &c.messages)
	for p in c.messages {
		defer netcode.link_free(&c.link, p)
		c.received += len(p)
		m, ok := game.decode_server(p, c.scratch, c.reg if c.reg != nil else test_reg())
		if !testing.expect(t, ok, "invalid message from the server") {continue}
		#partial switch v in m {
		case game.Packs:
			c.fetch = new(game.Pack_Fetch)
			want, err := game.pack_fetch_begin(c.fetch, v, c.pack_cache)
			c.packs_error = err
			net_send(c, want)
			net_packs_built(c)
		case game.Pack_Part:
			c.pack_parts += 1
			c.packs_error = game.pack_fetch_part(c.fetch, v)
			net_packs_built(c)
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
			c.address = v.address
			rules := v.rules
			game.receiver_seed(&c.rx, int(game.State_Kind.Rules), &rules)
		case game.World_Changed:
			// Nothing of the last world stays.
			c.address = v.address
			game.receiver_reset(&c.rx)
			c.travels += 1
			for _, &b in c.chunks {game.chunk_release(&b, &c.arrays)}
			clear(&c.chunks)
			clear(&c.entities)
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
		case game.State_Message:
			got := make([dynamic]game.Received, context.temp_allocator)
			testing.expect(t, game.receive_state(&c.rx, v.data, &got), "invalid State message")
			net_apply(c, got[:])
		case game.Snapshot_Message:
			got := make([dynamic]game.Received, context.temp_allocator)
			testing.expect(
				t,
				game.receive_snapshot(&c.rx, v.data, &got),
				"invalid Snapshot message",
			)
			net_apply(c, got[:])
		case game.Stats_Page:
			delete(c.stats_text)
			c.stats_text = strings.clone(v.text)
			c.stats_pages = int(v.pages)
		case game.Edit_Result:
			c.results[v.id] = v
			// (as a client does: the result is what the server holds, for the sender alone)
			net_set_block(c, v.pos, v.block)
			if two, has := v.companion.?; has {net_set_block(c, two.pos, two.block)}
		case game.Bulk_Begin:
			c.bulk_begins += 1
		}
	}
	clear(&c.messages)
	if c.welcomed {
		c.seq += 1
		net_send(
			c,
			game.Input {
				c.seq,
				{move = c.move, yaw = c.look[0], pitch = c.look[1], buttons = c.buttons},
				c.rx.ack,
			},
		)
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
	h := clients[0].stepper
	assert(h != nil, "net_wait steps a harness: connect with net_connect(h = ...)")
	// (ticks, not time: what a test waits for is the same on every machine)
	for _ in 0 ..< int(seconds * game.TICK_RATE) {
		if done(clients) {return true}
		for c in clients {net_pump(t, c)}
		harness_step(h)
	}
	return done(clients)
}

// net_for: the clients play on for `seconds` of the harness's ticks, whatever
// happens (for what must not happen, or what needs a moment to settle).
@(private)
net_for :: proc(t: ^testing.T, clients: []^Net_Client, seconds: f64) {
	net_ticks(t, clients, int(seconds * game.TICK_RATE + 0.5))
}

// net_ticks: n ticks of the harness, every client pumped before each.
@(private)
net_ticks :: proc(t: ^testing.T, clients: []^Net_Client, n: int) {
	for _ in 0 ..< n {
		for c in clients {net_pump(t, c)}
		harness_step(clients[0].stepper)
	}
}

// at_rest: on the ground and still, as of the server's last word.
@(private)
at_rest :: proc(c: ^Net_Client) -> bool {
	// (Counted per client: tests run side by side on threads; a count kept
	// in statics was one test's and another's at once.)
	s := c.update.state
	if s.on_ground && s.position == c.rest_last {c.rest_still += 1} else {c.rest_still = 0}
	c.rest_last = s.position
	return c.rest_still >= 5
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
		rules       = quiet_rules(),
		seed        = 21,
		view_radius = 3,
		view_height = 2,
		save_dir    = dir,
		max_players = 4,
		listen      = true,
		name        = "net test",
	}
	h: Harness
	// No local player; listen on a free port.
	if !testing.expect(t, harness_start(&h, config)) {return}
	stopped := false
	defer if !stopped {harness_stop(&h)}

	alice, bob, impostor: Net_Client
	net_connect(&alice, 0, "alice", h = &h)
	net_connect(&bob, 0, "bob", h = &h)
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
	net_connect(&impostor, 0, "alice", h = &h)
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
	net_send(&alice, game.edit_plain(1, alice.seq, below, .Air))
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
	netcode.link_close(&alice.link, "bye")
	harness_step(&h, 4)
	testing.expect(t, harness_stop(&h))
	stopped = true
	if !testing.expect(t, harness_start(&h, config)) {return}
	stopped = false
	again: Net_Client
	net_connect(&again, 0, "bob", h = &h)
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
}

// The seed of the loss, duplication and jitter draws of the test below: the
// same seed, the same drops. A failure prints it; run again with
// `./build.sh test -define:VX_LOSS_SEED=<n>` (try others to hunt).
LOSS_SEED :: u64(#config(VX_LOSS_SEED, 7))

// M7's exit check (the half a machine can do alone): two players over a
// simulated network with 10% loss, 10% duplication and jitter, both
// ways: the whole interest area arrives; they see each other; an edit by
// one reaches the other. (That every chunk arrives whole under loss is the
// agreement invariant of test_scenario_chunk_streaming_under_loss.)
@(test)
test_players_through_ten_percent_loss :: proc(t: ^testing.T) {
	bad := netcode.Conditions {
		loss       = 0.1,
		duplicate  = 0.1,
		latency_ms = 15,
		jitter_ms  = 25,
		seed       = LOSS_SEED,
	}
	config := Config {
		rules           = quiet_rules(),
		seed            = 31,
		view_radius     = 3,
		view_height     = 2,
		max_players     = 4,
		listen          = true,
		everyone_cheats = true,
		no_sheep        = true, // (the summoned one is the only one: natural ones spawn by day, when the timing lets them)
	}
	h: Harness
	srv := &h.srv
	if !testing.expect(t, harness_start(&h, config, conditions = bad)) {return}
	defer harness_stop(&h)

	a, b: Net_Client
	net_connect(&a, 0, "alpha", h = &h)
	net_connect(&b, 0, "beta", h = &h)
	defer net_close(&a)
	defer net_close(&b)
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

	ok = net_wait(t, {&a, &b}, proc(cs: []^Net_Client) -> bool {
			return len(cs[0].seen) == 1 && len(cs[1].seen) == 1
		}, 30)
	testing.expect(t, ok, "the players do not see each other")

	feet := a.update.state.position
	@(static) below: game.Block_Pos
	below = {i32(math.floor(feet.x)), i32(math.floor(feet.y)) - 1, i32(math.floor(feet.z))}
	net_send(&a, game.edit_plain(1, a.seq, below, .Air))
	ok = net_wait(t, {&a, &b}, proc(cs: []^Net_Client) -> bool {
			for ch in cs[1].changed {
				if ch.pos == below && ch.block == .Air && 1 in cs[0].results {return true}
			}
			return false
		}, 30)
	testing.expect(t, ok, "beta never heard of alpha's edit (or alpha of its result)")
	testing.expect(t, a.results[1].accepted, "alpha's edit was refused")

	// The state model through the loss: once the loss stops, within 30 ticks
	// each client holds exactly the server's values of the other player and of
	// a summoned sheep (snapshots that were lost are sent again against the
	// newest the client acknowledged).
	net_send(&a, game.Command{"summon sheep"})
	ok = net_wait(t, {&a, &b}, proc(cs: []^Net_Client) -> bool {
			return len(cs[0].entities) == 1 && len(cs[1].entities) == 1
		}, 30)
	if !testing.expect(t, ok, "the summoned sheep never reached both clients") {return}
	netcode.simnet_set_conditions(&h.net, {})
	// Converged: a client's newest complete snapshot is recent, and what it
	// holds is exactly what the server's sender recorded for that tick (the
	// sender's ring is what the receiver holds if every part arrived), and what
	// the client shows of the other player and the sheep is that. (Not the
	// server's values of the moment: the sheep wanders, and the server ticks
	// between a client's last packet and the test's look.)
	Look :: struct {
		cs:     [2]^Net_Client,
		ids:    [2]u16,
		recent: [2]bool, // the ack is within 10 ticks of the server's
		same:   [2]bool, // the sender's and the receiver's snapshot at the ack are one
		shown:  [2]bool, // and the client shows the other player and the sheep as it has them
	}
	look: Look
	look.cs = {&a, &b}
	look.ids = {a.welcome.player, b.welcome.player}
	converged := false
	for _ in 0 ..< 30 + 5 * game.TICK_RATE {
		if converged {break}
		net_pump(t, &a)
		net_pump(t, &b)
		harness_step(&h)
		call(
			srv,
			proc(s: ^Server, data: rawptr) {
				look := (^Look)(data)
				for c, i in look.cs {
					look.recent[i], look.same[i], look.shown[i] = false, false, false
					ack := c.rx.ack
					sent := game.ring_find(&s.clients[look.ids[i]].tx.ring, ack)
					held := game.ring_find(&c.rx.ring, ack)
					if ack == 0 || sent == nil || held == nil {continue}
					look.recent[i] = s.tick - u64(ack) <= 10
					look.same[i] = replicas_match(&c.schema, &sent.data, &held.data)
					if c.rx.gather.active || c.rx.newest != ack {
						look.shown[i] = true // (a newer snapshot is half applied: look again)
						continue
					}
					other := look.ids[1 - i]
					motion := (^game.Player_Motion)(
						game.replica_get(
							&sent.data,
							int(game.State_Kind.Player_Motion),
							{a = i32(other)},
						),
					)
					sheep: ^game.Entity_Motion
					for rec in sent.data.tables[game.State_Kind.Entity_Motion].records {
						sheep = (^game.Entity_Motion)(rec.value)
					}
					look.shown[i] =
						motion != nil &&
						sheep != nil &&
						c.seen[other] == motion.position &&
						len(c.entities) == 1
					for _, p in c.entities {look.shown[i] &&= p == sheep.position}
				}
			},
			&look,
		)
		converged =
			look.recent == {true, true} && look.same == {true, true} && look.shown == {true, true}
	}
	testing.expectf(
		t,
		converged,
		"the clients never held what the server sent them (acks %d and %d; recent %v, same %v, shown %v; loss seed %d)",
		a.rx.ack,
		b.rx.ack,
		look.recent,
		look.same,
		look.shown,
		LOSS_SEED,
	)
}

// replicas_match: two replicas hold the same records of every snapshot-lane kind.
@(private = "file")
replicas_match :: proc(schema: ^game.Schema, x, y: ^game.Replica) -> bool {
	for kind in 0 ..< schema.n_states {
		k := &schema.kinds[kind]
		if k.lane != .Snapshot {continue}
		xs, ys := x.tables[kind].records, y.tables[kind].records
		if len(xs) != len(ys) {return false}
		for rec, i in xs {
			if rec.key != ys[i].key ||
			   game.value_diff(k, rec.value, ys[i].value) != 0 {return false}
		}
	}
	return true
}

// A client that knows another set of state kinds is refused, with both hashes
// in the reason.
@(test)
test_schema_mismatch_refused :: proc(t: ^testing.T) {
	config := Config {
		rules       = quiet_rules(),
		seed        = 32,
		view_radius = 2,
		view_height = 1,
		max_players = 2,
		listen      = true,
	}
	h: Harness
	if !testing.expect(t, harness_start(&h, config)) {return}
	defer harness_stop(&h)
	c: Net_Client
	net_connect(&c, 0, "stranger", h = &h)
	defer net_close(&c)
	c.schema.hash += 1
	ok := net_wait(t, {&c}, proc(cs: []^Net_Client) -> bool {return cs[0].rejected != ""})
	testing.expect(t, ok, "a client with another schema was not refused")
	testing.expect(
		t,
		strings.has_prefix(
			c.rejected,
			"this server runs a different version of the game (state schema ",
		),
		c.rejected,
	)
}

// quiet_rules: nothing changing by itself, for tests that compare what clients
// hold with the world's blocks.
@(private)
quiet_rules :: proc() -> game.Rules {
	return game.rules_still()
}
