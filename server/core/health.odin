package core

import "core:fmt"
import "core:log"
import "core:math"
import "core:strings"
import "core:time"

import "common:base"
import "common:game"
import "common:telemetry"

// Health, damage, death and what a character grows by. A player has health
// points (BASE_HEALTH, plus what they wear: common/game/mods.odin); a fall of more
// than 3 blocks onto ground costs a point a block, an explosion costs by how
// near it was; at nought a player dies (a Death event, the inventory dropped
// where they fell if the character's mode drops them and keep_inventory is off);
// they wait at the death screen and the Respawn button wakes them at the world's
// spawn (damage.odin: the one pipeline). Every event that happens to
// a player may also earn experience (award_xp): the pipeline from something
// happening to the character growing, a table and a curve, kept as the counters
// `xp` and `level` (so saved with the character).

SAFE_FALL :: 3.0 // blocks

// health_tick: once a tick for each playing client, after its movement.
health_tick :: proc(s: ^Server, c: ^Client) {
	w := c.world
	mods := character_mods(s, c)
	if c.max_health == 0 {c.health = mods.max_health} 	// (just joined: full)
	if mods.max_health != c.max_health {
		c.max_health = mods.max_health
		c.health = min(c.health, c.max_health)
	}
	if c.dead {
		c.airborne = false
		health := game.Health{c.health, c.max_health, true}
		state_put(s, c, .Health, &health)
		return
	}
	regenerate(s, c)
	// A fall: from where the player left the ground to where they land.
	p := c.player
	query := game.Block_Query{&w.chunks, chunks_block, &w.server.registry.blocks, {}}
	safe :=
		p.on_ground ||
		p.flying ||
		game.in_water(query, p.position, 0.2) ||
		game.in_water(query, p.position, 1.2)
	if safe {
		if c.airborne &&
		   !p.flying &&
		   !game.in_water(query, p.position, 0.2) &&
		   !game.in_water(query, p.position, 1.2) {
			drop := c.fall_peak - p.position.y
			if drop > SAFE_FALL {damage(s, c, f32(drop - SAFE_FALL), {kind = .Fall})}
		}
		c.airborne, c.fall_peak = false, p.position.y
	} else if !c.airborne {
		c.airborne, c.fall_peak = true, p.position.y
	} else {
		c.fall_peak = max(c.fall_peak, p.position.y)
	}
	health := game.Health{c.health, c.max_health, false}
	state_put(s, c, .Health, &health) // (nothing is sent while it is unchanged)
}

// heal_player: c recovers amount health points.
heal_player :: proc(c: ^Client, amount: f32) {
	c.health = min(c.health + amount, c.max_health)
}

// --- Experience ----------------------------------------------------------

// xp_for: what an event of kind earns (0: nothing).
xp_for :: proc(kind: telemetry.Kind) -> u64 {
	#partial switch kind {
	case .Block_Mined, .Block_Placed, .Entity_Hit:
		return 1
	case .Item_Used, .Sheep_Fed:
		return 2
	case .Sheep_Sheared:
		return 5
	case .Entity_Killed:
		return 10
	case .Gate_Dial:
		return 25
	}
	return 0
}

// xp_needed: the total experience a level takes (level 1: none, 2: 100, 3: 300, 4: 600 ...).
xp_needed :: proc(level: u64) -> u64 {
	return 50 * level * (level - 1) if level > 1 else 0
}

// level_of: the level that total experience xp makes.
level_of :: proc(xp: u64) -> u64 {
	level := u64(1)
	for xp >= xp_needed(level + 1) {level += 1}
	return level
}

// award_xp: an event of kind happened to c: its experience, and a level if it is one.
award_xp :: proc(s: ^Server, c: ^Client, kind: telemetry.Kind) {
	gain := xp_for(kind)
	if gain == 0 {return}
	stat_add(c, "xp", gain)
	xp := c.stats["xp"]
	level := level_of(xp)
	if now := c.stats["level"] or_else 1; level > now {
		counter_set(&c.stats, "level", level)
		emit_event(
			s,
			event_for(s, c.world, .Level_Up, player_id(s, c), "", {i64(level), i64(xp), 0}),
		)
	}
}

// ---- proto/flood ----

// proto/flood: the Flood round. Throwaway prototype code (GAME.md §3): water
// rises in a walled 32x32 column, players climb to the goal platform at the
// top, and each round runs under one hidden rule (game.Flood_Rule). The whole
// round lives here; the hooks elsewhere are marked "proto/flood".
//
// Tuning: the FLOOD_* constants below.

FLOOD_SIZE :: 32 // the arena's inside, x and z: 0 ..< FLOOD_SIZE
FLOOD_H :: 96 // its height: y 0 ..< FLOOD_H (floor at 0)
FLOOD_GOAL_Y :: 88 // the goal platform's top block
FLOOD_WALL_TOP :: 111 // bedrock walls up to here (chunk 6's top: loaded with the arena)
FLOOD_WATER_MAX :: FLOOD_GOAL_Y // the water stops here (those on the goal stay dry)

FLOOD_COUNTDOWN :: 4.0 // seconds from the arena built to playing
FLOOD_REVEAL :: 5.0 // seconds the result and the rule are shown
FLOOD_GRACE :: 8.0 // seconds before the water starts
FLOOD_DROWN :: 2.0 // seconds with the head under water (or outside the walls) and you are out
FLOOD_ROUND_MAX :: 420.0 // seconds: the round ends anyway
FLOOD_BUILD_WAIT :: 5.0 // seconds the build waits for the arena's chunks before building what is there

// Seconds per layer of water, by rule.
FLOOD_RISE_BASELINE :: 2.4
FLOOD_RISE_TIDE :: 2.6 // the net rise; the surge goes on top
FLOOD_TIDE_AMPLITUDE :: 7.0 // layers
FLOOD_TIDE_PERIOD :: 30.0 // seconds
FLOOD_RISE_ROT :: 2.6
FLOOD_ROT_SPLASH :: 2 // layers above the water that count as wet
FLOOD_ROT_DELAY :: 2.5 // seconds from wet to the first block crumbling
FLOOD_ROT_SPREAD :: 5.0 // ... and over how long the layer's blocks go
FLOOD_RISE_HEAVY :: 2.0
FLOOD_HEAVY_RADIUS :: 1.75 // explosions' radius times this (rockets: 4 -> 7)
FLOOD_HEAVY_PUSH :: 2.0 // their throw times this

FLOOD_SPAWN :: [3]f64{16.5, 1, 16.5}
FLOOD_SPECTATE :: [3]f64{16.5, FLOOD_H + 4, 16.5}

Flood :: struct {
	on:         bool,
	phase:      game.Flood_Phase,
	rule:       game.Flood_Rule,
	forced:     Maybe(game.Flood_Rule), // the next round's (/flood rule)
	result:     game.Flood_Result,
	round:      u16,
	seed:       u32,
	rng:        u64,
	phase_tick: u64, // when the phase began
	built:      bool,
	level:      i32, // the water's top layer (0: the floor only)
	goal:       [2]i32, // the goal platform's corner (x, z)
	wet_at:     [FLOOD_H]f32, // Rot: seconds into play when each layer got wet (-1: dry)
	rot_last:   f32, // Rot: seconds into play of the last pass
	made_it:    int,
	rotted:     int, // Rot: blocks crumbled this round
}

// flood_init: the server is a Flood server (start).
flood_init :: proc(s: ^Server) {
	f := &s.flood
	f.on = true
	nanos := u64(time.now()._nsec)
	f.rng = nanos ~ u64(s.config.seed) ~ 0x9e3779b97f4a7c15
	r := &s.home.rules
	r.daylight_cycle = false
	r.drops = false // no pillaring up with what you break
	r.random_tick_speed = 0
	r.keep_inventory = true
	s.home.clock = 0.5 // noon
	log.info("flood on")
}

@(private = "file")
flood_rand :: proc(f: ^Flood) -> u64 {
	f.rng += 0x9e3779b97f4a7c15
	z := f.rng
	z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ~ (z >> 27)) * 0x94d049bb133111eb
	return z ~ (z >> 31)
}

// a seeded generator for the arena (the seed alone decides it).
@(private = "file")
Arena_Rng :: struct {
	state: u64,
}

@(private = "file")
arena_next :: proc(r: ^Arena_Rng) -> u64 {
	r.state += 0x9e3779b97f4a7c15
	z := r.state
	z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ~ (z >> 27)) * 0x94d049bb133111eb
	return z ~ (z >> 31)
}

// arena_int: lo..hi inclusive.
@(private = "file")
arena_int :: proc(r: ^Arena_Rng, lo, hi: i32) -> i32 {
	if hi <= lo {return lo}
	return lo + i32(arena_next(r) % u64(hi - lo + 1))
}

@(private = "file")
hash3 :: proc(x, y, z: i32, seed: u32) -> f32 {
	h := u32(x) * 73856093 ~ u32(y) * 19349663 ~ u32(z) * 83492791 ~ seed * 2654435761
	h ~= h >> 13
	h *= 0x5bd1e995
	h ~= h >> 15
	return f32(h & 0xffff) / 65535
}

@(private = "file")
seconds_in_phase :: proc(s: ^Server) -> f32 {
	return f32(s.tick - s.flood.phase_tick) / f32(game.TICK_RATE)
}

@(private = "file")
set_phase :: proc(s: ^Server, phase: game.Flood_Phase) {
	s.flood.phase = phase
	s.flood.phase_tick = s.tick
}

// flood_wants: the arena's chunks stay loaded whoever is near (anyone_wants).
flood_wants :: proc(w: ^World, pos: game.Chunk_Pos) -> bool {
	s := w.server
	if !s.flood.on || w != s.home {return false}
	return pos.x >= -1 && pos.x <= 2 && pos.z >= -1 && pos.z <= 2 && pos.y >= -1 && pos.y <= 6
}

// arena_template: the arena's blocks for a seed, FLOOD_SIZE x FLOOD_H x FLOOD_SIZE.
@(private = "file")
arena_template :: proc(seed: u32, goal: ^[2]i32) -> game.Template {
	t := game.Template {
		size  = {FLOOD_SIZE, FLOOD_H, FLOOD_SIZE},
		cells = make([]u16, FLOOD_SIZE * FLOOD_H * FLOOD_SIZE, context.temp_allocator),
	}
	set :: proc(t: ^game.Template, x, y, z: i32, b: game.Block) {
		if x < 0 || y < 0 || z < 0 || x >= FLOOD_SIZE || y >= FLOOD_H || z >= FLOOD_SIZE {return}
		t.cells[game.template_index(t, {x, y, z})] = u16(b)
	}
	box :: proc(t: ^game.Template, x0, y0, z0, x1, y1, z1: i32, b: game.Block) {
		for y in y0 ..= y1 {for z in z0 ..= z1 {for x in x0 ..= x1 {set(t, x, y, z, b)}}}
	}
	in_spawn :: proc(x, z: i32) -> bool {return x >= 12 && x <= 20 && z >= 12 && z <= 20}
	r := Arena_Rng{u64(seed) * 0x2545f4914f6cdd1d + 1}
	box(&t, 0, 0, 0, FLOOD_SIZE - 1, 0, FLOOD_SIZE - 1, .Stone)

	// Pillars from the floor: hook and climb targets.
	for _ in 0 ..< arena_int(&r, 4, 7) {
		w := arena_int(&r, 2, 3)
		x, z := arena_int(&r, 1, FLOOD_SIZE - 1 - w), arena_int(&r, 1, FLOOD_SIZE - 1 - w)
		if in_spawn(x, z) || in_spawn(x + w, z + w) {continue}
		top := arena_int(&r, 12, 64)
		box(
			&t,
			x,
			1,
			z,
			x + w - 1,
			top,
			z + w - 1,
			.Log if arena_next(&r) % 2 == 0 else .Stone_Bricks,
		)
	}
	// Overhangs: wide slabs with a hole or two (go round, or blast through).
	for y := i32(22); y < FLOOD_GOAL_Y - 10; y += arena_int(&r, 18, 24) {
		w, d := arena_int(&r, 14, 22), arena_int(&r, 14, 22)
		x, z := arena_int(&r, 0, FLOOD_SIZE - w), arena_int(&r, 0, FLOOD_SIZE - d)
		box(&t, x, y, z, x + w - 1, y, z + d - 1, .Cobblestone)
		for _ in 0 ..< arena_int(&r, 1, 2) {
			hx, hz := arena_int(&r, x + 1, x + w - 4), arena_int(&r, z + 1, z + d - 4)
			box(&t, hx, y, hz, hx + 2, y, hz + 2, .Air)
		}
	}
	// Staggered ledges: 2..4 blocks apart, so a plain jump (1.25) never
	// reaches the next; the boots (two jumps, ~2.5) sometimes do; the hook
	// and the rockets always.
	materials := [?]game.Block{.Dirt, .Planks, .Sandstone, .Clay, .Glass, .Stone, .Gravel}
	for y := i32(3); y < FLOOD_GOAL_Y - 2; y += arena_int(&r, 2, 4) {
		band := min(int(y) * len(materials) / FLOOD_GOAL_Y, len(materials) - 1)
		for _ in 0 ..< arena_int(&r, 2, 3) {
			w, d := arena_int(&r, 3, 7), arena_int(&r, 2, 5)
			x, z: i32
			switch arena_next(&r) % 3 {
			case 0:
				// against a wall
				if arena_next(&r) % 2 == 0 {
					x = 0 if arena_next(&r) % 2 == 0 else FLOOD_SIZE - w
					z = arena_int(&r, 0, FLOOD_SIZE - d)
				} else {
					z = 0 if arena_next(&r) % 2 == 0 else FLOOD_SIZE - d
					x = arena_int(&r, 0, FLOOD_SIZE - w)
				}
			case:
				x, z = arena_int(&r, 0, FLOOD_SIZE - w), arena_int(&r, 0, FLOOD_SIZE - d)
			}
			m := materials[band]
			if arena_next(&r) % 5 == 0 {m = materials[arena_next(&r) % len(materials)]}
			box(&t, x, y, z, x + w - 1, y, z + d - 1, m)
		}
	}
	// The spawn stays clear (and has a step up out of it).
	box(&t, 12, 1, 12, 20, 4, 20, .Air)
	// The goal: a lamp platform in a corner, nothing over it.
	corner := arena_next(&r) % 4
	goal^ = {
		2 if corner & 1 == 0 else FLOOD_SIZE - 2 - game.FLOOD_GOAL_SIZE,
		2 if corner & 2 == 0 else FLOOD_SIZE - 2 - game.FLOOD_GOAL_SIZE,
	}
	gx, gz := goal.x, goal.y
	box(
		&t,
		gx - 1,
		FLOOD_GOAL_Y - 1,
		gz - 1,
		gx + game.FLOOD_GOAL_SIZE,
		FLOOD_H - 1,
		gz + game.FLOOD_GOAL_SIZE,
		.Air,
	)
	box(
		&t,
		gx,
		FLOOD_GOAL_Y,
		gz,
		gx + game.FLOOD_GOAL_SIZE - 1,
		FLOOD_GOAL_Y,
		gz + game.FLOOD_GOAL_SIZE - 1,
		.Lamp,
	)
	// A lamp post at each corner of the goal, so it is seen from below.
	for c in ([4][2]i32{{0, 0}, {1, 0}, {0, 1}, {1, 1}}) {
		px := gx + c.x * (game.FLOOD_GOAL_SIZE - 1)
		pz := gz + c.y * (game.FLOOD_GOAL_SIZE - 1)
		box(&t, px, FLOOD_GOAL_Y + 1, pz, px, FLOOD_GOAL_Y + 2, pz, .Lamp)
	}
	return t
}

// flood_build: walls, the arena for the round's seed, no water. false: its
// chunks are not all loaded yet (and the wait is not over).
@(private = "file")
flood_build :: proc(s: ^Server, force: bool) -> bool {
	w := s.home
	f := &s.flood
	ready := true
	for cy in i32(-1) ..= 6 {
		for cz in i32(-1) ..= 2 {
			for cx in i32(-1) ..= 2 {
				pos := game.Chunk_Pos{cx, cy, cz}
				c := chunks_get(&w.chunks, pos)
				if c == nil {
					request_chunk(w, pos)
					ready = false
				} else if c.state != .Ready {
					ready = false
				}
			}
		}
	}
	if !ready && !force {return false}
	act := Act{0, .Structure}
	for wall in ([4]Box{{{-1, -3, -1}, {-1, FLOOD_WALL_TOP, FLOOD_SIZE}}, {{FLOOD_SIZE, -3, -1}, {FLOOD_SIZE, FLOOD_WALL_TOP, FLOOD_SIZE}}, {{0, -3, -1}, {FLOOD_SIZE - 1, FLOOD_WALL_TOP, -1}}, {{0, -3, FLOOD_SIZE}, {FLOOD_SIZE - 1, FLOOD_WALL_TOP, FLOOD_SIZE}}}) {
		bulk_edit(w, {shape = wall, op = .Set, block = .Bedrock, partial = true}, act)
	}
	// Under the floor: solid, so blasting through it finds stone, not the open flat world.
	bulk_edit(
		w,
		{
			shape = Box{{0, -3, 0}, {FLOOD_SIZE - 1, -1, FLOOD_SIZE - 1}},
			op = .Set,
			block = .Stone,
			partial = true,
		},
		act,
	)
	t := arena_template(f.seed, &f.goal)
	started := time.tick_now()
	n, _, _ := bulk_edit(
		w,
		{
			shape = Box{{0, 0, 0}, {FLOOD_SIZE - 1, FLOOD_H - 1, FLOOD_SIZE - 1}},
			op = .Paste,
			template = &t,
			partial = true,
		},
		act,
	)
	log.infof(
		"flood arena built round=%d seed=%d rule=%s goal=%v changed=%d ms=%.1f all_loaded=%v",
		f.round,
		f.seed,
		game.FLOOD_RULE_NAMES[f.rule],
		f.goal,
		n,
		time.duration_milliseconds(time.tick_since(started)),
		ready,
	)
	f.level = 0
	for &v in f.wet_at {v = -1}
	f.rot_last = 0
	f.rotted = 0
	f.built = true
	return true
}

// flood_new_round: a new seed and rule; the arena is built in the countdown.
@(private = "file")
flood_new_round :: proc(s: ^Server) {
	f := &s.flood
	f.round += 1
	f.seed = u32(flood_rand(f))
	if rule, forced := f.forced.?; forced {
		f.rule = rule
		f.forced = nil
	} else {
		f.rule = game.Flood_Rule(flood_rand(f) % len(game.Flood_Rule))
	}
	f.result = .None
	f.made_it = 0
	f.built = false
	set_phase(s, .Countdown)
	log.infof("flood round=%d seed=%d rule=%s", f.round, f.seed, game.FLOOD_RULE_NAMES[f.rule])
}

// enlist: c plays this round: survival, the kit, at the spawn.
@(private = "file")
enlist :: proc(s: ^Server, c: ^Client) {
	c.flood_round = s.flood.round
	c.flood_in, c.flood_out, c.flood_under = true, false, 0
	if mode, ok := game.mode_find(s.registry, "survival"); ok {
		set_game_mode(s, c, mode, {"flood", ""})
	}
	c.player.flying = false
	c.health = c.max_health
	kit_give(s, c)
	refill_weapons(s, c)
	// The rocket launcher in hand.
	for st, i in c.inventory.slots[:game.HOTBAR_SLOTS] {
		if game.item_name(s.registry, st.item) == "rocket_launcher" && !game.stack_empty(st) {
			c.inventory.selected = i
			c.inv_changed = true
		}
	}
	jitter := [3]f64{f64(player_id(s, c) % 3) - 1, 0, f64(player_id(s, c) / 3 % 3) - 1}
	land(s, c, FLOOD_SPAWN + jitter, {0, 0}, .Exact, remember = false)
}

// spectate: c watches (out, or arrived mid-round): flying, harmless, above.
@(private = "file")
spectate :: proc(s: ^Server, c: ^Client, teleport: bool) {
	c.flood_round = s.flood.round
	c.flood_out = true
	c.flood_under = 0
	if mode, ok := game.mode_find(s.registry, "flood_out"); ok {
		set_game_mode(s, c, mode, {"flood", ""})
	}
	c.player.flying = true
	if teleport {land(s, c, FLOOD_SPECTATE, {0, -1.2}, .Exact, remember = false)} 	// (looking down into it)
	disturb(s, c)
}

// water_target: the level the rule wants t seconds into play.
@(private = "file")
water_target :: proc(f: ^Flood, t: f32) -> i32 {
	if t < FLOOD_GRACE {return 0}
	r := t - FLOOD_GRACE
	level: f32
	switch f.rule {
	case .Baseline:
		level = r / FLOOD_RISE_BASELINE
	case .Tide:
		// Starts at the trough, so the first surge comes as a surprise.
		phase := 2 * math.PI * r / FLOOD_TIDE_PERIOD
		level = r / FLOOD_RISE_TIDE + FLOOD_TIDE_AMPLITUDE * (1 - base.cos(phase)) * 0.5
		level += FLOOD_TIDE_AMPLITUDE * 0.5 * base.sin(phase * 0.5) // (uneven surges)
	case .Rot:
		level = r / FLOOD_RISE_ROT
	case .Heavy:
		level = r / FLOOD_RISE_HEAVY
	}
	return clamp(i32(level), 0, FLOOD_WATER_MAX)
}

@(private = "file")
WATER_BLOCKS := [?]game.Block {
	.Water,
	.Water_1,
	.Water_2,
	.Water_3,
	.Water_4,
	.Water_5,
	.Water_6,
	.Water_7,
	.Water_Falling,
}

// layer_set: the arena's layer y filled with water (or drained).
@(private = "file")
layer_set :: proc(w: ^World, y: i32, water: bool) {
	layer := Box{{0, y, 0}, {FLOOD_SIZE - 1, y, FLOOD_SIZE - 1}}
	act := Act{0, .Liquid}
	if water {
		bulk_edit(
			w,
			{shape = layer, op = .Replace, from = .Air, block = .Water, partial = true},
			act,
		)
		return
	}
	for b in WATER_BLOCKS {
		bulk_edit(w, {shape = layer, op = .Replace, from = b, block = .Air, partial = true}, act)
	}
}

// rot_tick: Rot: blocks crumble a few seconds after the water (or its
// splash) first reached their layer, each at its own moment.
@(private = "file")
rot_tick :: proc(s: ^Server, t: f32) {
	f := &s.flood
	w := s.home
	top := min(f.level + FLOOD_ROT_SPLASH, FLOOD_H - 1)
	if f.level > 0 {
		for y in 0 ..= top {if f.wet_at[y] < 0 {f.wet_at[y] = t}}
	}
	act := Act{0, .Liquid}
	for y in i32(0) ..< FLOOD_H {
		at := f.wet_at[y]
		if at < 0 {break}
		if t < at + FLOOD_ROT_DELAY ||
		   f.rot_last > at + FLOOD_ROT_DELAY + FLOOD_ROT_SPREAD {continue}
		for z in i32(0) ..< FLOOD_SIZE {
			for x in i32(0) ..< FLOOD_SIZE {
				due := at + FLOOD_ROT_DELAY + hash3(x, y, z, f.seed) * FLOOD_ROT_SPREAD
				if due <= f.rot_last || due > t {continue}
				p := game.Block_Pos{x, y, z}
				b, loaded := chunks_block(&w.chunks, p)
				if !loaded || b == .Air || b == .Lamp || b == .Bedrock {continue}
				if _, wet := game.water_level(b); wet {continue}
				set_block(w, p, .Water if y <= f.level else .Air, act)
				f.rotted += 1
			}
		}
	}
	f.rot_last = t
}

@(private = "file")
on_goal :: proc(f: ^Flood, c: ^Client) -> bool {
	p := c.player.position
	return(
		p.x >= f64(f.goal.x) &&
		p.x < f64(f.goal.x + game.FLOOD_GOAL_SIZE) &&
		p.z >= f64(f.goal.y) &&
		p.z < f64(f.goal.y + game.FLOOD_GOAL_SIZE) &&
		p.y >= FLOOD_GOAL_Y + 0.9 &&
		p.y < FLOOD_GOAL_Y + 4 \
	)
}

@(private = "file")
in_round :: proc(s: ^Server, c: ^Client) -> bool {
	return c.state == .Playing && c.world == s.home && c.flood_round == s.flood.round
}

@(private = "file")
end_round :: proc(s: ^Server, result: game.Flood_Result, made_it: int) {
	f := &s.flood
	f.result = result
	f.made_it = made_it
	played := seconds_in_phase(s)
	set_phase(s, .Reveal)
	players := 0
	for &c in s.clients {if in_round(s, &c) && c.flood_in {players += 1}}
	head: string
	switch result {
	case .Won:
		head = "&aROUND WON"
	case .Lost:
		head = "&cEVERYONE DROWNED"
	case .Time_Up:
		head = "&eTIME UP"
	case .None:
	}
	chat_system(
		s,
		fmt.tprintf(
			"%s&r: %d of %d made it. The rule was &l%s",
			head,
			made_it,
			players,
			strings.to_upper(game.FLOOD_RULE_NAMES[f.rule], context.temp_allocator),
		),
	)
	log.infof(
		"flood round over round=%d result=%v made_it=%d players=%d rule=%s level=%d seconds=%.0f",
		f.round,
		result,
		made_it,
		players,
		game.FLOOD_RULE_NAMES[f.rule],
		f.level,
		played,
	)
}

// flood_tick: once a tick, after the players moved and the entities ran.
flood_tick :: proc(s: ^Server) {
	f := &s.flood
	if !f.on {return}
	w := s.home
	present := 0
	for &c in s.clients {if c.state == .Playing && c.world == w {present += 1}}
	t := seconds_in_phase(s)
	switch f.phase {
	case .Waiting:
		if present > 0 {flood_new_round(s)}
	case .Countdown:
		if !f.built {
			if !flood_build(s, t >= FLOOD_BUILD_WAIT) {break}
			set_phase(s, .Countdown) // (counted from the build)
			for &c in s.clients {
				if c.state == .Playing && c.world == w {enlist(s, &c)}
			}
			chat_system(
				s,
				fmt.tprintf(
					"&bRound %d&r: climb to the glowing platform. Something is different.",
					f.round,
				),
			)
			break
		}
		for &c in s.clients {
			if c.state == .Playing && c.world == w && c.flood_round != f.round {enlist(s, &c)}
		}
		if present == 0 {
			set_phase(s, .Waiting)
		} else if t >= FLOOD_COUNTDOWN {
			set_phase(s, .Playing)
		}
	case .Playing:
		for &c in s.clients {
			if c.state == .Playing &&
			   c.world == w &&
			   c.flood_round != f.round {spectate(s, &c, true)}
		}
		target := water_target(f, t)
		if target > f.level {
			f.level += 1
			layer_set(w, f.level, true)
		} else if target < f.level {
			layer_set(w, f.level, false)
			f.level -= 1
		}
		if f.rule == .Rot {rot_tick(s, t)}
		if s.tick % (5 * game.TICK_RATE) == 0 {
			log.infof(
				"flood status round=%d rule=%s t=%.0f level=%d target=%d rotted=%d",
				f.round,
				game.FLOOD_RULE_NAMES[f.rule],
				t,
				f.level,
				target,
				f.rotted,
			)
		}
		players, alive, goal := 0, 0, 0
		query := game.Block_Query{&w.chunks, chunks_block, &s.registry.blocks, {}}
		for &c in s.clients {
			if !in_round(s, &c) || !c.flood_in {continue}
			players += 1
			if c.flood_out {continue}
			eye := game.player_eye(c.player)
			p := c.player.position
			outside :=
				p.x < 0 ||
				p.z < 0 ||
				p.x >= FLOOD_SIZE ||
				p.z >= FLOOD_SIZE ||
				p.y > FLOOD_WALL_TOP
			if outside || game.in_water(query, eye, 0) {
				c.flood_under += 1
			} else {
				c.flood_under = 0
			}
			if c.flood_under >= int(FLOOD_DROWN * game.TICK_RATE) {
				chat_system(s, fmt.tprintf("&c%s is out", client_name(&c)))
				log.infof("flood out player=%d at=%v level=%d", player_id(s, &c), p, f.level)
				spectate(s, &c, true)
				continue
			}
			alive += 1
			if on_goal(f, &c) {goal += 1}
		}
		switch {
		case players == 0:
			set_phase(s, .Waiting) // (everyone left)
		case alive == 0:
			end_round(s, .Lost, 0)
		case goal == alive:
			end_round(s, .Won, goal)
		case t >= FLOOD_ROUND_MAX:
			end_round(s, .Time_Up, goal)
		}
	case .Reveal:
		if t >= FLOOD_REVEAL {
			if present > 0 {flood_new_round(s)} else {set_phase(s, .Waiting)}
		}
	}
	flood_put(s)
}

// flood_put: every player's Flood record.
@(private = "file")
flood_put :: proc(s: ^Server) {
	f := &s.flood
	t := seconds_in_phase(s)
	st := game.Flood_State {
		phase   = f.phase,
		rule    = f.rule,
		result  = f.result,
		round   = f.round,
		seed    = f.seed,
		seconds = u16(t),
		level   = i16(f.level),
		goal_y  = FLOOD_GOAL_Y,
		goal_x  = i16(f.goal.x),
		goal_z  = i16(f.goal.y),
		made_it = u8(f.made_it),
	}
	#partial switch f.phase {
	case .Countdown:
		st.countdown =
			u8(math.ceil(max(FLOOD_COUNTDOWN - t, 0))) if f.built else u8(FLOOD_COUNTDOWN)
	case .Reveal:
		st.countdown = u8(math.ceil(max(FLOOD_REVEAL + FLOOD_COUNTDOWN - t, 0)))
	}
	for &c in s.clients {
		if !in_round(s, &c) || !c.flood_in {continue}
		st.players += 1
		if !c.flood_out {
			st.alive += 1
			if on_goal(f, &c) {st.on_goal += 1}
		}
	}
	for &c in s.clients {
		if c.state != .Playing {continue}
		mine := st
		mine.out = c.flood_out
		mine.under = u8(min(c.flood_under * 10 / game.TICK_RATE, 255))
		state_put(s, &c, .Flood, &mine)
	}
}

// admin_flood: /flood [restart | rule <name|random> | goal]
admin_flood :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	f := &s.flood
	if !f.on {
		notice(s, c, "Flood is off on this server")
		return true
	}
	if len(args) == 0 {
		notice(
			s,
			c,
			fmt.tprintf(
				"Flood round %d, %v, rule %s, seed %d, water at y=%d (rules: baseline tide rot heavy)",
				f.round,
				f.phase,
				game.FLOOD_RULE_NAMES[f.rule],
				f.seed,
				f.level,
			),
		)
		return true
	}
	switch args[0] {
	case "goal":
		// (testing: stand on the goal platform)
		g := [3]f64{f64(f.goal.x) + 3.5, FLOOD_GOAL_Y + 1, f64(f.goal.y) + 3.5}
		land(s, c, g, c.look, .Exact, remember = false)
		return true
	case "restart":
		flood_new_round(s)
		notice(s, c, "Flood: new round")
		return true
	case "rule":
		if len(args) < 2 {return false}
		if args[1] == "random" {
			f.forced = nil
			flood_new_round(s)
			return true
		}
		for name, rule in game.FLOOD_RULE_NAMES {
			if name == args[1] {
				f.forced = rule
				flood_new_round(s)
				notice(s, c, fmt.tprintf("Flood: new round under %s", name))
				return true
			}
		}
		notice(s, c, "Flood rules: baseline tide rot heavy random")
		return true
	}
	return false
}
