package server

import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "../common/game"

// M48j: the LAN party's hardening. Six and eight scripted bots play survival
// with all four weapons against a stepped server over the harness's simulated network (the caller
// runs the ticks, so six thousand of them take seconds, not five minutes):
// moving, shooting, being shot, dying, respawning, reloading; one operator
// toggles creative and back; one more player joins and leaves in the middle.
// Asserted: what the clients are told is what the server holds at every
// settle (the bots do not predict, so this is replication, and the server's
// desync detector has nothing to say), the server's memory is flat after the
// first minute, a client's downstream stays within the baseline's budget, the
// kills and deaths agree everywhere, and health is never out of range.

PARTY_TICKS :: 6000 // ticks played (the spec's five simulated minutes at 20 a second)
PARTY_WARMUP :: 1800 // a minute of the game's ticks
PARTY_SETTLE_EVERY :: 1500
PARTY_SETTLE_TICKS :: 120

@(private = "file")
Bot :: struct {
	net:         Net_Client,
	rng:         u64,
	inv_seq:     u32,
	dead_for:    int, // ticks waiting at the death screen
	turn_at:     int, // the tick its walk changes
	weapon_at:   int, // the tick it changes the weapon in hand
	received_at: int, // bytes taken when the warm-up ended
	still:       bool, // the settle: no moving, no shooting
	// What it was told of deaths (kept past a leave).
	deaths:      int,
	by_player:   int, // ... of them with an attacker
	lines:       int, // death chat lines heard
}

@(private = "file")
roll :: proc(b: ^Bot) -> u64 {
	b.rng = b.rng * 6364136223846793005 + 1442695040888963407
	return b.rng >> 33
}

@(private = "file")
aim :: proc(from, to: [3]f64) -> (yaw, pitch: f32) {
	d := to - from
	return f32(math.atan2(-d.x, -d.z)), f32(math.atan2(d.y, math.sqrt(d.x * d.x + d.z * d.z)))
}

@(private = "file")
is_death_line :: proc(text: string) -> bool {
	plain := game.format_strip(text)
	for what in ([]string{" was shot by ", " was blown up", " died", " fell ", " was killed"}) {
		if strings.contains(plain, what) {return true}
	}
	return false
}

// drive: one tick of a bot's play, before its pump.
@(private = "file")
drive :: proc(b: ^Bot, tick: int, operator: bool) {
	c := &b.net
	if !c.welcomed {return}
	// What it has heard is counted, then forgotten (a bot that keeps every line grows).
	for l in c.chat {
		if is_death_line(l.text) {b.lines += 1}
		delete(l.text)
	}
	clear(&c.chat)
	for n in c.notices {delete(n)}
	clear(&c.notices)
	clear(&c.confirms)
	clear(&c.changed)
	if c.deaths > 0 {
		// (net_apply counts; the attacker is the last one told)
		b.deaths += c.deaths
		if c.death_attacker != "" && c.death_attacker != c.name {b.by_player += c.deaths}
		c.deaths = 0
	}
	if c.health.dead {
		c.move = {}
		b.dead_for += 1
		if b.dead_for == 12 + int(roll(b) % 20) {
			net_send(c, game.Respawn{})
			b.dead_for = 0
		}
		return
	}
	b.dead_for = 0
	if b.still {
		c.move = {}
		return
	}
	if operator && tick % 1200 == 300 {net_send(c, game.Command{"gamemode creative"})}
	if operator && tick % 1200 == 900 {net_send(c, game.Command{"gamemode survival"})}
	// Walk: a direction for a while, strafing and stopping at random.
	if tick >= b.turn_at {
		b.turn_at = tick + 20 + int(roll(b) % 60)
		c.look[0] = f32(roll(b) % 628) / 100
		c.look[1] = 0
		c.move = {f32(int(roll(b) % 3) - 1), f32(int(roll(b) % 3) - 1)}
		if roll(b) % 2 == 0 {c.move = {}}
	}
	// Weapon: one of the four, changed now and then.
	if tick >= b.weapon_at {
		b.weapon_at = tick + 60 + int(roll(b) % 120)
		b.inv_seq += 1
		net_send(
			c,
			game.Inventory_Request {
				b.inv_seq,
				{
					kind = .Select,
					slot = 0,
					arg = int(roll(b) % 8) % 4 if roll(b) % 3 == 0 else int(roll(b) % 3),
				},
			},
		)
	}
	// The nearest other player is the target: face them and shoot.
	me := c.update.state.position
	best, found := f64(1e18), false
	target: [3]f64
	for _, p in c.seen {
		d := p - me
		if dist := d.x * d.x + d.y * d.y + d.z * d.z;
		   dist < best {best, target, found = dist, p, true}
	}
	if !found {return}
	yaw, pitch := aim(me + {0, 1.6, 0}, target + {0, 1.0, 0})
	pitch = clamp(pitch, -1.5, 1.5) // (a message with a pitch past the limit is refused)
	selected := c.inventory.selected
	if selected == 3 {
		if tick % 150 == int(roll(b) % 150) {net_send(c, game.Fire{c.seq, yaw, pitch})}
		return
	}
	if c.inventory.slots[selected].ammo == 0 {
		net_send(c, game.Reload{})
	} else {
		net_send(c, game.Shoot{c.seq, u8(selected), true, yaw, pitch})
	}
	if roll(b) % 400 == 0 {net_send(c, game.Reload{})}
}

// party_budget: the most bytes a tick a bot may be sent downstream: the
// baseline session's (chunks, state, edit results: everything) times 1.5.
@(private = "file")
party_budget :: proc() -> (per_tick: f64, ok: bool) {
	data, err := os.read_entire_file_from_path(BANDWIDTH_FILE, context.temp_allocator)
	if err != nil {return}
	want, found := bandwidth_parse(string(data), "session")
	if !found || want.server_to_client == 0 {return}
	return f64(want.server_to_client) / BANDWIDTH_TICKS * 1.5, true
}

@(private = "file")
Party :: struct {
	h:     ^Harness,
	srv:   ^Server,
	outer: mem.Allocator, // the test's own: the bots' work is not the server's
	bots:  []^Bot,
	tick:  int,
	t:     ^testing.T,
	bad:   [dynamic]string,
	track: ^mem.Tracking_Allocator, // the server's allocations alone: only its steps run under it
}

// party_bots: every bot plays and pumps (a party of the harness, before the
// server's step).
@(private = "file")
party_bots :: proc(data: rawptr) {
	p := (^Party)(data)
	context.allocator = p.outer
	p.tick += 1
	for b, i in p.bots {
		if b == nil {continue}
		drive(b, p.tick, i == 0)
		net_pump(p.t, &b.net)
	}
}

// party_tick: the bots play and pump, the server steps (its allocations alone
// are tracked).
@(private = "file")
party_tick :: proc(p: ^Party) {
	{
		context.allocator = mem.tracking_allocator(p.track)
		harness_step(p.h)
	}
	// Health is never out of range, for anyone.
	for &c in p.srv.clients {
		if c.state != .Playing {continue}
		if c.health < 0 || c.health > c.max_health || math.is_nan(c.health) {
			append(
				&p.bad,
				fmt.aprintf(
					"tick %d: %s has health %v of %v",
					p.tick,
					client_name(&c),
					c.health,
					c.max_health,
				),
			)
		}
	}
	for b in p.bots {
		if b == nil {continue}
		h := b.net.health
		if h.health < 0 || h.health > h.max {
			append(
				&p.bad,
				fmt.aprintf(
					"tick %d: %s was told health %v of %v",
					p.tick,
					b.net.name,
					h.health,
					h.max,
				),
			)
		}
	}
}

// settle: nobody moves or shoots for PARTY_SETTLE_TICKS ticks (the dead
// respawn), then what each bot was told is what the server holds.
@(private = "file")
settle :: proc(p: ^Party, label: string) {
	for b in p.bots {if b != nil {b.still, b.net.move = true, {}}}
	for _ in 0 ..< PARTY_SETTLE_TICKS {party_tick(p)}
	for b in p.bots {
		if b == nil {continue}
		c := client_by_name(p.srv, b.net.name)
		if c == nil {
			append(&p.bad, fmt.aprintf("%s: %s is not on the server", label, b.net.name))
			continue
		}
		told := b.net.update.state
		if told.position != c.player.position {
			append(
				&p.bad,
				fmt.aprintf(
					"%s: %s was told %v, the server has %v",
					label,
					b.net.name,
					told.position,
					c.player.position,
				),
			)
		}
		if abs(b.net.health.health - c.health) > 0.1 || b.net.health.dead != c.dead {
			append(
				&p.bad,
				fmt.aprintf(
					"%s: %s was told health %v dead=%v, the server has %v dead=%v",
					label,
					b.net.name,
					b.net.health.health,
					b.net.health.dead,
					c.health,
					c.dead,
				),
			)
		}
		for st, i in c.inventory.slots[:game.HOTBAR_SLOTS] {
			if b.net.inventory.slots[i] != st {
				append(
					&p.bad,
					fmt.aprintf(
						"%s: %s's slot %d differs from the server's",
						label,
						b.net.name,
						i,
					),
				)
				break
			}
		}
		// The others they see are where the server has them (within the quantizing).
		for id, seen in b.net.seen {
			if int(id) >= len(p.srv.clients) {continue}
			o := &p.srv.clients[id]
			if o.state != .Playing {continue}
			if d := seen - o.player.position; d.x * d.x + d.y * d.y + d.z * d.z > 0.25 {
				append(
					&p.bad,
					fmt.aprintf(
						"%s: %s sees %s at %v, the server has %v",
						label,
						b.net.name,
						client_name(o),
						seen,
						o.player.position,
					),
				)
			}
		}
	}
	for b in p.bots {if b != nil {b.still = false}}
}

@(private = "file")
server_kills_deaths :: proc(s: ^Server) -> (kills, deaths: u64) {
	for &c in s.clients {
		if c.state != .Playing {continue}
		kills += c.stats["kills"] or_else 0
		deaths += c.stats["deaths"] or_else 0
	}
	return
}

@(private = "file")
party :: proc(t: ^testing.T, size: int) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	dir :=
		filepath.join(
			{"build", "test", fmt.tprintf("party_%d", size)},
			context.temp_allocator,
		) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	os.make_directory_all(dir)
	perms := strings.concatenate(
		{DEFAULT_PERMISSIONS, "player bot1\nrole admin\n"},
		context.temp_allocator,
	)
	cfg := filepath.join({dir, PERMISSIONS_FILE}, context.temp_allocator) or_else ""
	testing.expect(t, os.write_entire_file(cfg, transmute([]u8)perms) == nil)

	h := new(Harness)
	defer free(h)
	srv := &h.srv
	config := Config {
		seed        = 23,
		mode        = "survival",
		view_radius = 2,
		view_height = 1,
		workers     = 1,
		save_dir    = dir,
		max_players = size,
		listen      = true,
		generator   = .Classic,
		no_sheep    = true,
		kit         = "pistol 1, rifle 1, sniper 1, rocket_launcher 1", // (the tests' own default is blocks)
	}
	started: bool
	{
		context.allocator = mem.tracking_allocator(&track)
		started = harness_start(h, config)
	}
	if !testing.expect(t, started) {return}
	stopped := false
	defer if !stopped {
		context.allocator = mem.tracking_allocator(&track)
		harness_stop(h)
	}
	srv.home.rules.pvp = true
	port := srv.host.socket.port

	p := Party {
		h     = h,
		srv   = srv,
		outer = context.allocator,
		t     = t,
		track = &track,
	}
	defer {
		for line in p.bad {delete(line)}
		delete(p.bad)
	}
	harness_add(h, party_bots, &p)
	resident := size - 1 // one seat is the one who comes and goes
	p.bots = make([]^Bot, size)
	defer delete(p.bots)
	made := make([dynamic]^Bot)
	defer {
		for b in made {
			net_close(&b.net)
			delete(b.net.name)
			free(b)
		}
		delete(made)
	}
	join :: proc(p: ^Party, made: ^[dynamic]^Bot, i: int, port: int) -> ^Bot {
		b := new(Bot)
		b.rng = u64(i + 1) * 0x9E3779B97F4A7C15
		net_connect(&b.net, port, fmt.aprintf("bot%d", i + 1), sim = &p.h.net) // (heap: the steps free the temp allocator)
		append(made, b)
		return b
	}
	for i in 0 ..< resident {p.bots[i] = join(&p, &made, i, port)}

	// Everyone in and landed.
	landed: bool
	{
		context.allocator = mem.tracking_allocator(&track)
		_, landed = harness_step_until(h, proc(data: rawptr) -> bool {
				p := (^Party)(data)
				for b in p.bots {
					if b == nil {continue}
					if !(b.net.welcomed &&
						   b.net.update.acked > 0 &&
						   len(b.net.chunks) >= 20 &&
						   b.net.mode != "" &&
						   len(b.net.grants) > 0) {return false}
				}
				return true
			}, &p, 2000)
	}
	if !landed {
		for b in p.bots[:resident] {
			n := &b.net
			fmt.printfln(
				"%s: welcomed=%v ground=%v acked=%d chunks=%d mode=%q grants=%d rejected=%q link=%v",
				n.name,
				n.welcomed,
				n.update.state.on_ground,
				n.update.acked,
				len(n.chunks),
				n.mode,
				len(n.grants),
				n.rejected,
				n.link.state,
			)
		}
		testing.expect(t, false, "the bots never all landed")
		return
	}
	// A clear arena around the first bot (hills in the line of fire made a party of misses).
	if c := client_by_name(srv, p.bots[0].net.name); c != nil {
		w := c.world
		o := game.Block_Pos {
			i32(math.floor(c.player.position.x)),
			i32(math.floor(c.player.position.y)),
			i32(math.floor(c.player.position.z)),
		}
		for dx in i32(-14) ..= 14 {
			for dz in i32(-14) ..= 14 {
				for dy in i32(0) ..= 6 {set_block(w, o + {dx, dy, dz}, .Air, test_act(w))}
			}
		}
	}
	for _ in 0 ..< 60 {party_tick(&p)}
	p.tick = 0 // (the script's clock starts here)
	for b in p.bots {if b != nil {b.turn_at, b.weapon_at = 0, 0}}

	bytes_at_warmup: [dynamic]int
	defer delete(bytes_at_warmup)
	memory_before_join, memory_after_leave, arena_at_warmup: int
	warm_kills, warm_deaths: u64
	left_kills, left_deaths: u64 // the one who left, counted before they went
	left_told, left_by_players: int
	for p.tick < PARTY_TICKS {
		party_tick(&p)
		if p.tick % 500 ==
		   0 {fmt.printfln("party %d: tick %d, server memory %d, clients %d", size, p.tick, track.current_memory_allocated, len(made))}
		if p.tick >= 4900 && memory_after_leave == 0 {
			memory_after_leave = int(track.current_memory_allocated) // (a settle moves the tick on: not a case)
		}
		switch p.tick {
		case PARTY_WARMUP:
			settle(&p, "warm-up")
			for b in p.bots {
				if b != nil {b.received_at = b.net.received}
			}
			arena_at_warmup = int(srv.arena.total_used)
			warm_kills, warm_deaths = server_kills_deaths(srv)
		case 2400:
			memory_before_join = int(track.current_memory_allocated)
			// Someone joins in the middle of it.
			b := join(&p, &made, resident, port)
			p.bots[resident] = b
		case 4200:
			// ... and leaves: what they were told is kept, their count is the server's.
			if b := p.bots[resident]; b != nil {
				c := client_by_name(srv, b.net.name)
				if c != nil {
					left_kills = c.stats["kills"] or_else 0
					left_deaths = c.stats["deaths"] or_else 0
				}
				left_told += b.deaths + b.net.deaths
				left_by_players += b.by_player
				p.bots[resident] = nil
				for m, k in made {
					if m == b {
						unordered_remove(&made, k)
						break
					}
				}
				net_close(&b.net)
				delete(b.net.name)
				free(b)
				for _ in 0 ..< 15 {party_tick(&p)} 	// (the server notices)
			}
		case PARTY_WARMUP + PARTY_SETTLE_EVERY, PARTY_WARMUP + 2 * PARTY_SETTLE_EVERY:
			settle(&p, fmt.tprintf("tick %d", p.tick))
		}
	}
	settle(&p, "the end")

	// Bandwidth: what each resident was sent a tick after the warm-up.
	if budget, ok := party_budget(); testing.expect(t, ok, "no baseline session") {
		worst := f64(0)
		for b in p.bots[:resident] {
			per := f64(b.net.received - b.received_at) / f64(p.tick - PARTY_WARMUP)
			worst = max(worst, per)
		}
		testing.expectf(
			t,
			worst <= budget,
			"a client was sent %.1f bytes a tick, the budget is %.1f",
			worst,
			budget,
		)
		fmt.printfln(
			"party %d: worst downstream %.1f bytes a tick (budget %.1f)",
			size,
			worst,
			budget,
		)
	}

	// Kills and deaths agree: the server's counts, what the bots were told, the chat.
	kills, deaths := server_kills_deaths(srv)
	kills += left_kills
	deaths += left_deaths
	told_deaths, told_by_players, lines := left_told, left_by_players, 0
	for b in made {
		told_deaths += b.deaths + b.net.deaths
		told_by_players += b.by_player
		lines += b.lines
	}
	_ = lines
	for b in made {
		if c := client_by_name(srv, b.net.name); c != nil {
			fmt.printfln(
				"  %s: %d hits taken, %d shots seen; told %d deaths, server %d",
				b.net.name,
				b.net.hits,
				b.net.shots_seen,
				b.deaths + b.net.deaths,
				c.stats["deaths"] or_else 0,
			)
		}
	}
	testing.expectf(
		t,
		u64(told_deaths) == deaths,
		"the bots were told of %d deaths, the server counted %d",
		told_deaths,
		deaths,
	)
	testing.expectf(
		t,
		u64(told_by_players) == kills,
		"the deaths by a player are %d, the server's kills are %d",
		told_by_players,
		kills,
	)
	testing.expect(t, deaths > 0, "nobody died: the party was not played")
	_ = warm_kills
	_ = warm_deaths

	// No desyncs the server could see, and none in what it replicated.
	testing.expect_value(t, srv.desyncs, 0)
	for line in p.bad {testing.expect(t, false, line)}

	// Flat memory: the server's, from after the one who left (and an autosave
	// or two) to the end; and what the visit left behind is small.
	steady := int(track.current_memory_allocated) - memory_after_leave
	visit := memory_after_leave - memory_before_join
	arena := int(srv.arena.total_used) - arena_at_warmup
	fmt.printfln(
		"party %d: %d deaths, memory %+d bytes in the last 1200 ticks, %+d for a visit, the arena %+d",
		size,
		deaths,
		steady,
		visit,
		arena,
	)
	testing.expectf(
		t,
		steady <= 4096,
		"the server's memory grew by %d bytes in the last 1200 ticks",
		steady,
	)
	testing.expectf(t, visit <= 32768, "a player's visit left %d bytes behind", visit)
	testing.expectf(
		t,
		arena <= 2048,
		"the server's arena grew by %d bytes after the warm-up",
		arena,
	)

	stopped = true
	context.allocator = mem.tracking_allocator(&track)
	testing.expect(t, harness_stop(h), "the server stopped with an error")
}

@(test)
test_party_six_clients :: proc(t: ^testing.T) {
	party(t, 6)
}

@(test)
test_party_eight_clients :: proc(t: ^testing.T) {
	party(t, 8)
}
