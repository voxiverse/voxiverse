package server

import "core:log"
import "core:math"
import "core:math/rand"

import "../game"

// Entities on the server: the critters. Each tick every awake one thinks
// (a small state machine), walks its path (A*, path.odin, within a shared
// node budget) and moves by the shared body physics. Each client is told
// about the ones near it: Entity_Spawn when one comes near (or into
// being), its place in an Entities batch every tick, Entity_Despawn when it
// leaves (or dies). Critters appear by day on grass around players and go
// when nobody is near; an entity whose ground is not loaded waits, frozen,
// until it is. All are saved with the world (save.odin: entities.cfg).

MAX_ENTITIES :: 512
MAX_KNOWN_ENTITIES :: 256 // per client
ENTITY_VIEW :: 64 // blocks: a client is told about entities this near (horizontally)
SPAWN_EVERY :: game.TICK_RATE * 2 // ticks between spawning attempts
SPAWN_CAP :: 6 // critters near one player, at most
SPAWN_NEAR :: 48 // blocks: what counts as near a player, for the cap
SPAWN_MIN, SPAWN_MAX :: 16, 40 // blocks from a player where critters appear
DESPAWN_DISTANCE :: 80 // natural critters this far from everyone go
PATH_BUDGET_PER_TICK :: 1500 // A* nodes for all entities in one tick
PATH_BUDGET_EACH :: 400
HURT_TICKS :: game.TICK_RATE / 3 // how long a hit stuns (no steering)
FLEE_TICKS :: game.TICK_RATE * 5

Entity :: struct {
	id:      u32,
	kind:    game.Entity_Kind,
	body:    game.Entity_Body,
	yaw:     f32, // body: radians, turning left from -z
	pitch:   f32, // head: up and down
	health:  int,
	natural: bool, // spawned by itself: may despawn
	brain:   Brain,
}

Brain_State :: enum u8 {
	Idle, // standing; looking about
	Look, // a player is close: watch them
	Wander, // walking a path somewhere nearby
	Graze, // head down for a while
	Flee, // hit: running away
}

Brain :: struct {
	state:   Brain_State,
	timer:   int, // ticks left in this state
	path:    Path,
	step:    int, // the next waypoint
	goal:    game.Block_Pos,
	look_at: [3]f64,
	from:    [3]f64, // fleeing from here
	hurt:    int, // ticks of stun left
	stuck:   int, // ticks without progress on the path
}

Entities :: struct {
	list:    [dynamic]Entity, // awake (in loaded chunks)
	next_id: u32,
	budget:  int, // A* nodes left this tick
	rng:     rand.Default_Random_State,
}

entities_init :: proc(e: ^Entities, seed: i64) {
	e.list = make([dynamic]Entity, 0, MAX_ENTITIES)
	e.next_id = 1
	e.rng = rand.create(u64(seed) ~ 0x0e7e_0e7e)
}

entities_destroy :: proc(e: ^Entities) {
	delete(e.list)
}

// entity_spawn adds an entity at position (bottom centre); nil if full.
entity_spawn :: proc(
	s: ^Server,
	kind: game.Entity_Kind,
	position: [3]f64,
	natural: bool,
) -> ^Entity {
	e := &s.entities
	if len(e.list) == MAX_ENTITIES {return nil}
	append(
		&e.list,
		Entity {
			id = e.next_id,
			kind = kind,
			body = {position = position},
			yaw = rand.float32_range(-math.PI, math.PI, rand.default_random_generator(&e.rng)),
			health = game.ENTITY_INFO[kind].health,
			natural = natural,
		},
	)
	e.next_id += 1
	return &e.list[len(e.list) - 1]
}

// entities_tick: spawning, despawning, thinking and moving, every tick.
entities_tick :: proc(s: ^Server) {
	e := &s.entities
	e.budget = PATH_BUDGET_PER_TICK
	if s.tick % SPAWN_EVERY == 0 {spawn_natural(s)}
	query := game.Block_Query{&s.world, world_block}
	for i := 0; i < len(e.list); {
		ent := &e.list[i]
		if ent.natural && !anyone_within(s, ent.body.position, DESPAWN_DISTANCE) {
			unordered_remove(&e.list, i)
			continue
		}
		if !chunk_ready(s, ent.body.position) {
			i += 1
			continue // its ground is not loaded (yet): it waits
		}
		think(s, ent)
		wish, jump := steer(s, ent)
		game.body_step(&ent.body, ent.kind, wish, jump, &s.rules, query, game.TICK_SECONDS)
		i += 1
	}
}

// entity_attack: a player hits an entity (the reach is checked by the
// caller). Knocked back, hurt (or dead), and scared.
entity_attack :: proc(s: ^Server, ent: ^Entity, from: [3]f64) -> (died: bool) {
	ent.health -= 1
	away := ent.body.position - from
	l := math.sqrt(away.x * away.x + away.z * away.z)
	if l > 1e-6 {away /= l} else {away = {1, 0, 0}}
	kb := game.ATTACK_KNOCKBACK
	ent.body.velocity = {f32(away.x) * kb[0], kb[1], f32(away.z) * kb[0]}
	ent.body.on_ground = false
	ent.brain = {
		state = .Flee,
		timer = FLEE_TICKS,
		from  = from,
		hurt  = HURT_TICKS,
	}
	return ent.health <= 0
}

entity_find :: proc(s: ^Server, id: u32) -> (^Entity, int) {
	for &ent, i in s.entities.list {if ent.id == id {return &ent, i}}
	return nil, -1
}

// replicate tells a client about the entities near it: spawns for new
// ones, despawns for those gone from its area (or from the world), and a
// batch of places every tick.
replicate :: proc(s: ^Server, c: ^Client) {
	near := f64(ENTITY_VIEW)
	visible := make(map[u32]struct{}, 64, context.temp_allocator)
	batch := game.Entities {
		tick = u32(s.tick),
	}
	for &ent in s.entities.list {
		d := ent.body.position - c.player.position
		if d.x * d.x + d.z * d.z > near * near {continue}
		if ent.id not_in c.known {
			if len(c.known) >= MAX_KNOWN_ENTITIES {continue}
			c.known[ent.id] = {}
			send_message(s, c, game.Entity_Spawn{ent.id, ent.kind, ent.body.position, ent.yaw})
		}
		visible[ent.id] = {}
		batch.entries[batch.count] = {ent.id, ent.body.position, ent.yaw, ent.pitch}
		batch.count += 1
		if batch.count == game.ENTITIES_PER_MESSAGE {
			send_message(s, c, batch)
			batch.count = 0
		}
	}
	if batch.count > 0 {send_message(s, c, batch)}
	gone := make([dynamic]u32, context.temp_allocator)
	for id in c.known {if id not_in visible {append(&gone, id)}}
	for id in gone {
		delete_key(&c.known, id)
		send_message(s, c, game.Entity_Despawn{id, false})
	}
}

// entity_died: tell everyone who knew it, then forget it.
entity_died :: proc(s: ^Server, index: int) {
	id := s.entities.list[index].id
	for &c in s.clients {
		if c.state == .Playing && id in c.known {
			delete_key(&c.known, id)
			send_message(s, &c, game.Entity_Despawn{id, true})
		}
	}
	unordered_remove(&s.entities.list, index)
}

// entity_hurt_shown: everyone who knows it sees it flinch.
entity_hurt_shown :: proc(s: ^Server, id: u32) {
	for &c in s.clients {
		if c.state == .Playing && id in c.known {send_message(s, &c, game.Entity_Hurt{id})}
	}
}

// summon puts an entity in front of a player (cheats: Admin "summon").
summon :: proc(s: ^Server, c: ^Client, kind: game.Entity_Kind) -> bool {
	query := game.Block_Query{&s.world, world_block}
	yaw := c.look[0]
	ahead := c.player.position + {-f64(math.sin(yaw)) * 3, 0, -f64(math.cos(yaw)) * 3}
	at := game.Block_Pos {
		i32(math.floor(ahead.x)),
		i32(math.floor(ahead.y)),
		i32(math.floor(ahead.z)),
	}
	for dy in ([]i32{0, 1, -1, 2, -2, 3, -3}) {
		p := at + {0, dy, 0}
		if standable(query, p) {
			if ent := entity_spawn(s, kind, {f64(p.x) + 0.5, f64(p.y), f64(p.z) + 0.5}, false);
			   ent != nil {
				log.infof(
					"server summoned kind=%v id=%d at=%v by=%s",
					kind,
					ent.id,
					p,
					client_name(c),
				)
				return true
			}
			return false
		}
	}
	return false
}

// --- Behaviour --------------------------------------------------------------

// think moves the brain from state to state.
@(private = "file")
think :: proc(s: ^Server, ent: ^Entity) {
	b := &ent.brain
	r := rand.default_random_generator(&s.entities.rng)
	if b.hurt > 0 {b.hurt -= 1}
	b.timer -= 1
	pos := ent.body.position
	switch b.state {
	case .Flee:
		if b.timer <= 0 {b.state, b.timer = .Idle, 20}
		if b.path.count == 0 || b.step >= b.path.count {
			// Somewhere away from what hit it.
			away := pos - b.from
			l := math.sqrt(away.x * away.x + away.z * away.z)
			if l < 1e-6 {away, l = {1, 0, 0}, 1}
			target :=
				pos +
				away / l * 10 +
				{rand.float64_range(-3, 3, r), 0, rand.float64_range(-3, 3, r)}
			plan(s, ent, target)
		}
	case .Idle, .Look:
		if p, ok := nearest_player(s, pos, 6); ok && rand.float32(r) < 0.95 {
			b.state = .Look
			b.look_at = p + {0, game.PLAYER_EYE, 0}
		} else if b.state == .Look {
			b.state = .Idle
		}
		if b.timer <= 0 {
			switch {
			case rand.float32(r) < 0.55:
				target := pos + {rand.float64_range(-8, 8, r), 0, rand.float64_range(-8, 8, r)}
				if plan(s, ent, target) {b.state, b.timer = .Wander, game.TICK_RATE * 12}
			case rand.float32(r) < 0.5:
				b.state, b.timer = .Graze, rand.int_range(40, 120, r)
			case:
				b.timer = rand.int_range(30, 90, r)
			}
		}
	case .Wander:
		if b.step >= b.path.count || b.timer <= 0 || b.stuck > game.TICK_RATE * 2 {
			b.state, b.timer = .Idle, rand.int_range(30, 120, r)
			b.path.count = 0
		}
	case .Graze:
		if b.timer <= 0 {b.state, b.timer = .Idle, rand.int_range(20, 60, r)}
	}
	// The head: down when grazing, at the player when looking, level else.
	want_pitch: f32 = 0
	switch b.state {
	case .Graze:
		want_pitch = -1.2
	case .Look:
		d := b.look_at - (pos + {0, game.ENTITY_INFO[ent.kind].height, 0})
		flat := math.sqrt(d.x * d.x + d.z * d.z)
		want_pitch = clamp(f32(math.atan2(d.y, flat)), -1, 1)
		ent.yaw = turn_towards(ent.yaw, f32(math.atan2(-d.x, -d.z)), 0.15)
	case .Idle, .Wander, .Flee:
	}
	ent.pitch += (want_pitch - ent.pitch) * 0.2
}

// plan finds a path to near target (from where the entity stands); false
// if this tick's budget is spent or there is nowhere to go.
@(private = "file")
plan :: proc(s: ^Server, ent: ^Entity, target: [3]f64) -> bool {
	e := &s.entities
	if e.budget < PATH_BUDGET_EACH {return false}
	query := game.Block_Query{&s.world, world_block}
	pos := ent.body.position
	start := game.Block_Pos {
		i32(math.floor(pos.x)),
		i32(math.floor(pos.y + 0.01)),
		i32(math.floor(pos.z)),
	}
	goal := game.Block_Pos{i32(math.floor(target.x)), start.y, i32(math.floor(target.z))}
	// The goal: a standable block in its column near this height.
	for dy in ([]i32{0, 1, -1, 2, -2, 3, -3}) {
		if standable(query, goal + {0, dy, 0}) {
			goal.y += dy
			break
		}
	}
	e.budget -= PATH_BUDGET_EACH
	path, ok := find_path(query, start, goal, PATH_BUDGET_EACH)
	if !ok || path.count == 0 {return false}
	ent.brain.path = path
	ent.brain.step = 0
	ent.brain.stuck = 0
	return true
}

// steer: the wished-for velocity and whether to jump, following the path.
@(private = "file")
steer :: proc(s: ^Server, ent: ^Entity) -> (wish: [2]f32, jump: bool) {
	b := &ent.brain
	if b.hurt > 0 {return} 	// stunned: knockback carries it
	if b.state != .Wander && b.state != .Flee {return}
	if b.step >= b.path.count {return}
	info := game.ENTITY_INFO[ent.kind]
	pos := ent.body.position
	target := b.path.steps[b.step]
	to := [2]f64{f64(target.x) + 0.5 - pos.x, f64(target.z) + 0.5 - pos.z}
	dist := math.sqrt(to.x * to.x + to.y * to.y)
	if dist < 0.25 && abs(f64(target.y) - pos.y) < 0.6 {
		b.step += 1
		b.stuck = 0
		return
	}
	speed := info.run_speed if b.state == .Flee else info.walk_speed
	dir := [2]f32{f32(to.x / max(dist, 1e-6)), f32(to.y / max(dist, 1e-6))}
	wish = dir * speed
	ent.yaw = turn_towards(ent.yaw, f32(math.atan2(-to.x, -to.y)), 0.3)
	// Up a step, or something in the way: jump.
	blocked :=
		ent.body.on_ground &&
		math.abs(ent.body.velocity.x) + math.abs(ent.body.velocity.z) < 0.1 * speed
	jump = ent.body.on_ground && (f64(target.y) > pos.y + 0.5 || blocked)
	if blocked {b.stuck += 1} else {b.stuck = 0}
	return
}

// spawn_natural: by day, critters appear on grass around players with
// room for more, out of sight distance from everyone (but not far).
@(private = "file")
spawn_natural :: proc(s: ^Server) {
	day := game.time_of_day(s.clock)
	if day < 0.27 || day > 0.73 {return}
	r := rand.default_random_generator(&s.entities.rng)
	query := game.Block_Query{&s.world, world_block}
	for &c in s.clients {
		if c.state != .Playing {continue}
		near := 0
		for ent in s.entities.list {
			d := ent.body.position - c.player.position
			if d.x * d.x + d.z * d.z < SPAWN_NEAR * SPAWN_NEAR {near += 1}
		}
		if near >= SPAWN_CAP || rand.float32(r) > 0.5 {continue}
		angle := rand.float64_range(0, math.TAU, r)
		distance := rand.float64_range(SPAWN_MIN, SPAWN_MAX, r)
		x := i32(math.floor(c.player.position.x + math.cos(angle) * distance))
		z := i32(math.floor(c.player.position.z + math.sin(angle) * distance))
		top := column_top(s, x, z)
		ground, loaded := world_block(&s.world, {x, top, z})
		at := game.Block_Pos{x, top + 1, z}
		if !loaded || ground != .Grass || !standable(query, at) {continue}
		center := [3]f64{f64(x) + 0.5, f64(at.y), f64(z) + 0.5}
		if anyone_within(s, center, SPAWN_MIN) {continue}
		herd := rand.int_range(1, 4, r)
		for _ in 0 ..< herd {
			jitter := [3]f64{rand.float64_range(-1.5, 1.5, r), 0, rand.float64_range(-1.5, 1.5, r)}
			p := center + jitter
			b := game.Block_Pos{i32(math.floor(p.x)), at.y, i32(math.floor(p.z))}
			if standable(query, b) {entity_spawn(s, .Critter, p, true)}
		}
	}
}

@(private = "file")
anyone_within :: proc(s: ^Server, p: [3]f64, distance: f64) -> bool {
	_, ok := nearest_player(s, p, distance)
	return ok
}

@(private = "file")
nearest_player :: proc(s: ^Server, p: [3]f64, within: f64) -> (at: [3]f64, ok: bool) {
	best := within * within
	for &c in s.clients {
		if c.state != .Playing {continue}
		d := c.player.position - p
		if l := d.x * d.x + d.y * d.y + d.z * d.z; l < best {
			best, at, ok = l, c.player.position, true
		}
	}
	return
}

// chunk_ready: the chunk at p and the one below are loaded (it can stand).
@(private)
chunk_ready :: proc(s: ^Server, p: [3]f64) -> bool {
	b := game.Block_Pos{i32(math.floor(p.x)), i32(math.floor(p.y)), i32(math.floor(p.z))}
	c := world_get(&s.world, game.chunk_of(b))
	below := world_get(&s.world, game.chunk_of(b - {0, game.CHUNK_SIZE, 0}))
	return c != nil && c.state == .Ready && below != nil && below.state == .Ready
}

@(private = "file")
turn_towards :: proc(from, to: f32, rate: f32) -> f32 {
	d := math.mod(to - from + 3 * math.PI, math.TAU) - math.PI
	return from + d * rate
}
