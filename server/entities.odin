package server

import "core:log"
import "core:math"

import "../base"
import "../common/game"

// Entities on the server: sheep and rockets. What each kind is lies in
// game.ENTITY_INFO; what it does each tick, in entities_tick's switch. A
// sheep thinks (a small state machine), walks its path (A*, path.odin,
// within a shared node budget) and moves by the shared body physics; a
// rocket flies until it hits something and explodes. Each client is told
// about the ones near it: an Entity record (what it is) and an Entity_Motion
// record (where) while it is near (the records go when it leaves), and an
// Entity_Died event when it dies. Sheep appear by day on grass around players and go
// when nobody is near; one whose ground is not loaded waits, frozen, until
// it is. Saved kinds are kept with the world (save.odin: entities.cfg).

MAX_ENTITIES :: 512
ENTITY_VIEW :: 64 // blocks: a client is told about entities this near (horizontally)
SPAWN_EVERY :: game.TICK_RATE * 2 // ticks between spawning attempts
SPAWN_CAP :: 6 // sheep near one player, at most
SPAWN_NEAR :: 48 // blocks: what counts as near a player, for the cap
SPAWN_MIN, SPAWN_MAX :: 16, 40 // blocks from a player where sheep appear
DESPAWN_DISTANCE :: 80 // natural sheep this far from everyone go
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
	owner:   int, // a rocket's: the client index that fired it; a dropped stack's dropper (-1: none)
	stack:   game.Stack, // a dropped item's
	shorn:   bool, // a sheep without its wool, until it grazes
	genes:   game.Genes, // a sheep's (genetics.odin)
	growth:  int, // a lamb's ticks of growing up (an adult's: LAMB_TICKS)
	love:    int, // ticks left that it is ready to breed (fed)
	wait:    int, // ticks left before it can breed again
	age:     int, // ticks
	action:  u32, // a rocket's: the journal action that fired it (journal.odin)
}

Brain_State :: enum u8 {
	Idle, // standing; looking about
	Look, // a player is close: watch them
	Wander, // walking a path somewhere nearby
	Graze, // head down for a while
	Flee, // hit: running away
	Mate, // ready to breed: walking to another that is
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
	rng:     base.Rng,
}

entities_init :: proc(e: ^Entities, seed: i64) {
	e.list = make([dynamic]Entity, 0, MAX_ENTITIES)
	e.next_id = 1
	e.rng = base.rng_make(u64(seed) ~ 0x0e7e_0e7e)
}

entities_destroy :: proc(e: ^Entities) {
	delete(e.list)
}

// entity_spawn adds an entity at position (bottom centre); nil if full.
entity_spawn :: proc(
	w: ^World,
	kind: game.Entity_Kind,
	position: [3]f64,
	natural: bool,
) -> ^Entity {
	e := &w.entities
	if len(e.list) == MAX_ENTITIES {return nil}
	append(
		&e.list,
		Entity {
			id = e.next_id,
			kind = kind,
			body = {position = position},
			yaw = base.rng_f32_range(&e.rng, -math.PI, math.PI),
			health = game.ENTITY_INFO[kind].health,
			growth = game.LAMB_TICKS, // (adult; a lamb is made lower)
			natural = natural,
			owner = -1,
		},
	)
	e.next_id += 1
	return &e.list[len(e.list) - 1]
}

// entities_tick: spawning, despawning, thinking and moving, every tick.
entities_tick :: proc(w: ^World) {
	base.profile_scope("entities")
	s := w.server
	e := &w.entities
	e.budget = PATH_BUDGET_PER_TICK
	if s.tick % SPAWN_EVERY == 0 {spawn_natural(w)}
	query := game.Block_Query{&w.chunks, chunks_block}
	Blast :: struct {
		sphere: Sphere,
		action: Action_Id,
	}
	blasts := make([dynamic]Blast, context.temp_allocator)
	for i := 0; i < len(e.list); {
		ent := &e.list[i]
		ent.age += 1
		if ent.natural && !anyone_within(w, ent.body.position, DESPAWN_DISTANCE) {
			unordered_remove(&e.list, i)
			continue
		}
		switch ent.kind {
		case .Sheep:
			if chunk_ready(w, ent.body.position) { 	// else its ground is not loaded (yet): it waits
				sheep_life(ent)
				think(w, ent)
				wish, jump := steer(w, ent)
				game.body_step(&ent.body, ent.kind, wish, jump, &w.rules, query, game.TICK_SECONDS)
			}
		case .Rocket:
			if at, hit := rocket_step(w, ent); hit {
				append(&blasts, Blast{{at, game.ROCKET_RADIUS}, Action_Id(ent.action)})
				entity_died(w, i) // its explosion is what players see
				continue
			}
		case .Item:
			if item_tick(w, i) {
				entity_gone(w, i)
				continue
			}
		}
		i += 1
	}
	// After the walk over the list: explosions change it.
	for b in blasts {explode(w, b.sphere.center, b.sphere.radius, b.action)}
}

// sheep_flags: what clients are told about a sheep.
sheep_flags :: proc(ent: ^Entity) -> (f: game.Sheep_Flags) {
	if ent.kind != .Sheep {return}
	if ent.shorn {f += {.Shorn}}
	if ent.growth < game.LAMB_TICKS {f += {.Lamb}}
	if game.genes_black(ent.genes) {f += {.Black}}
	if game.genes_spotted(ent.genes) {f += {.Spotted}}
	if ent.love > 0 {f += {.In_Love}}
	return
}

// Entity_Behaviour: what a kind does besides the physics every kind shares
// (the table the next kinds fill in).
Entity_Behaviour :: struct {
	// use: a player used it (right click); true if that did something.
	use: proc(s: ^Server, c: ^Client, ent: ^Entity) -> bool,
}

@(rodata)
ENTITY_BEHAVIOUR := [game.Entity_Kind]Entity_Behaviour {
	.Sheep = {use = sheep_use},
	.Rocket = {},
	.Item = {},
}

// sheep_use: wheat feeds it (an adult becomes ready to breed; a lamb grows
// up a tenth sooner), anything else shears an adult by hand: 1 to 3 wool
// (white or black by its genes) fall, and it is shorn until it eats grass.
sheep_use :: proc(s: ^Server, c: ^Client, ent: ^Entity) -> bool {
	w := c.world
	lamb := ent.growth < game.LAMB_TICKS
	held := game.inventory_held(&c.inventory)
	if !game.stack_empty(held) && held.item == game.item_of_material(.Wheat) {
		switch {
		case lamb:
			ent.growth = min(ent.growth + game.LAMB_TICKS / 10, game.LAMB_TICKS)
		case ent.love == 0 && ent.wait == 0:
			ent.love = game.BREED_READY_TICKS
		case:
			return false
		}
		record(s, c, .Item_Used, "wheat")
		if !lamb {record(s, c, .Sheep_Fed)}
		if !allowed(s, c, "items.infinite") {
			ledger(s, w, .Use, held.item, -1)
			c.inventory.slots[c.inventory.selected].count -= 1
			game.inventory_tidy(&c.inventory)
			c.inv_changed = true
		}
		return true
	}
	if ent.shorn || lamb {return false}
	ent.shorn = true
	record(s, c, .Sheep_Sheared)
	r := &w.entities.rng
	wool := game.item_of_block(.Wool_Black if game.genes_black(ent.genes) else .Wool)
	for _ in 0 ..< base.rng_int_range(r, 1, 4) {
		v := [3]f32{base.rng_f32_range(r, -1, 1), 2.5, base.rng_f32_range(r, -1, 1)}
		ledger(s, w, .Drop_Mob, wool, 1)
		spawn_item(w, ent.body.position + {0, 0.6, 0}, {wool, 1}, v, -1)
	}
	return true
}

// sheep_life: a sheep's clocks, one tick: a lamb grows, love and the wait
// after a lamb run down.
@(private = "file")
sheep_life :: proc(ent: ^Entity) {
	if ent.growth < game.LAMB_TICKS {ent.growth += 1}
	if ent.love > 0 {ent.love -= 1}
	if ent.wait > 0 {ent.wait -= 1}
}

// mate_for: the nearest other sheep that is ready to breed within range of
// ent (an adult in love), if any.
@(private = "file")
mate_for :: proc(w: ^World, ent: ^Entity) -> ^Entity {
	best: ^Entity
	best_d := f64(game.BREED_RANGE * game.BREED_RANGE)
	for &other in w.entities.list {
		if other.id == ent.id || other.kind != .Sheep || other.love <= 0 {continue}
		if other.growth < game.LAMB_TICKS {continue}
		d := other.body.position - ent.body.position
		if dd := d.x * d.x + d.y * d.y + d.z * d.z; dd < best_d {best, best_d = &other, dd}
	}
	return best
}

// breed: a and b have met: a lamb between them, of both, and each waits.
@(private = "file")
breed :: proc(w: ^World, a, b: ^Entity) {
	r := &w.entities.rng
	at := (a.body.position + b.body.position) / 2
	genes := game.genes_child(a.genes, b.genes, r)
	a.love, b.love = 0, 0
	a.wait, b.wait = game.BREED_WAIT_TICKS, game.BREED_WAIT_TICKS
	if lamb := entity_spawn(w, .Sheep, at, false); lamb != nil {
		lamb.genes, lamb.growth = genes, 0
		record_world(w.server, w, .Sheep_Born)
	}
}

// use_entity: a player uses an entity, if it is within reach.
use_entity :: proc(s: ^Server, c: ^Client, id: u32) {
	ent, _ := entity_find(c.world, id)
	if ent == nil || !entity_reachable(c, ent) {return}
	if use := ENTITY_BEHAVIOUR[ent.kind].use; use != nil {use(s, c, ent)}
}

// entity_reachable: ent is within a player's reach from where the server
// has them (with the slack edits have).
entity_reachable :: proc(c: ^Client, ent: ^Entity) -> bool {
	eye := game.player_eye(c.player)
	lo, hi := game.entity_box(ent.kind, ent.body.position)
	closest := [3]f64{clamp(eye.x, lo.x, hi.x), clamp(eye.y, lo.y, hi.y), clamp(eye.z, lo.z, hi.z)}
	d := closest - eye
	reach := f64(c.world.rules.reach) + game.EDIT_REACH_SLACK
	return d.x * d.x + d.y * d.y + d.z * d.z <= reach * reach
}

// fire launches a rocket from a player's eyes, aimed yaw/pitch.
fire :: proc(s: ^Server, c: ^Client, yaw, pitch: f32) -> bool {
	dir := forward(yaw, pitch)
	eye := game.player_eye(c.player)
	start := eye + dir * 0.8 - {0, 0.15, 0} // the box's bottom centre
	ent := entity_spawn(c.world, .Rocket, start, false)
	if ent == nil {return false}
	ent.yaw, ent.pitch = yaw, pitch
	ent.body.velocity = {f32(dir.x), f32(dir.y), f32(dir.z)} * game.ROCKET_SPEED
	ent.owner = int(player_id(s, c))
	ent.action = u32(action_begin(c.world, actor_of(s, c), .Explosion))
	record(s, c, .Rocket_Fired)
	return true
}

// explode: a blast at center. Everyone near is shown it, the sphere is
// carved (where loaded), and what is near is thrown (sheep hurt).
explode :: proc(w: ^World, center: [3]f64, radius: f64, action: Action_Id) {
	s := w.server
	record_world(s, w, .Explosion, n0 = i64(radius))
	for &c in s.clients {
		if c.state != .Playing || c.world != w {continue}
		d := c.player.position - center
		if d.x * d.x + d.z * d.z < 160 * 160 {
			blast := game.Explosion{center, f32(radius)}
			event_send(s, &c, .Explosion, &blast)
		}
	}
	bulk_edit(
		w,
		{shape = Sphere{center, radius}, op = .Carve, partial = true},
		{action, .Explosion},
	)
	reach := 2 * radius
	push :: proc(at, center: [3]f64, reach: f64) -> (impulse: [3]f32, ok: bool) {
		d := at - center
		l := math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
		if l >= reach {return}
		if l < 1e-6 {d, l = {0, 1, 0}, 1}
		strength := f32(1 - l / reach) * 16
		dir := d / l
		return {f32(dir.x) * strength, f32(dir.y) * strength + 4, f32(dir.z) * strength}, true
	}
	for &c in s.clients {
		if c.state != .Playing || c.world != w {continue}
		if impulse, near := push(c.player.position + {0, 0.9, 0}, center, reach); near {
			c.player.velocity += impulse
			disturb(s, &c)
			c.player.on_ground = false
			d := c.player.position + {0, 0.9, 0} - center
			distance := math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
			damage_player(s, &c, f32(1 - distance / reach) * 12, "explosion")
		}
	}
	for i := 0; i < len(w.entities.list); {
		ent := &w.entities.list[i]
		impulse, near := push(ent.body.position + {0, 0.4, 0}, center, reach)
		if !near || !game.ENTITY_INFO[ent.kind].hittable {
			i += 1
			continue
		}
		ent.body.velocity += impulse
		ent.body.on_ground = false
		d := ent.body.position - center
		ent.health -= 3 if d.x * d.x + d.y * d.y + d.z * d.z < radius * radius else 1
		if ent.health <= 0 {
			entity_died(w, i)
			continue
		}
		ent.brain = {
			state = .Flee,
			timer = FLEE_TICKS,
			from  = center,
			hurt  = HURT_TICKS,
		}
		entity_hurt_shown(w, ent.id)
		i += 1
	}
}

// rocket_step flies a rocket one tick; where it hit, if it did.
@(private = "file")
rocket_step :: proc(w: ^World, ent: ^Entity) -> (at: [3]f64, hit: bool) {
	s := w.server
	if f32(ent.age) * game.TICK_SECONDS > game.ROCKET_LIFE {return ent.body.position, true}
	ent.body.velocity.y -= game.ROCKET_GRAVITY * game.TICK_SECONDS
	v := ent.body.velocity
	speed := math.sqrt(f64(v.x * v.x + v.y * v.y + v.z * v.z))
	if speed < 1e-6 {return ent.body.position, true}
	dir := [3]f64{f64(v.x), f64(v.y), f64(v.z)} / speed
	step := speed * f64(game.TICK_SECONDS)
	from := ent.body.position + {0, 0.15, 0}
	nearest := step
	hit_at: [3]f64
	query := game.Block_Query{&w.chunks, chunks_block}
	if b, ok := game.raycast(query, from, dir, step); ok {
		nearest, hit_at, hit = b.distance, from + dir * b.distance, true
	} else if !chunk_ready(w, from) {
		return from, true // flew out of the loaded world
	}
	for &other in w.entities.list {
		if other.id == ent.id || !game.ENTITY_INFO[other.kind].hittable {continue}
		lo, hi := game.entity_box(other.kind, other.body.position)
		if d, ok := game.ray_box(from, dir, lo, hi, nearest);
		   ok {nearest, hit_at, hit = d, from + dir * d, true}
	}
	for &c, i in s.clients {
		if c.state != .Playing ||
		   c.world != w ||
		   (i == ent.owner && ent.age < game.TICK_RATE / 3) {continue}
		lo, hi := game.player_box(c.player)
		if d, ok := game.ray_box(from, dir, lo, hi, nearest);
		   ok {nearest, hit_at, hit = d, from + dir * d, true}
	}
	if hit {return hit_at, true}
	ent.body.position += dir * step
	ent.yaw = f32(math.atan2(-dir.x, -dir.z))
	ent.pitch = clamp(f32(math.asin(clamp(dir.y, -1, 1))), -1.5, 1.5) // within the protocol's limit
	return {}, false
}

@(private = "file")
forward :: proc(yaw, pitch: f32) -> [3]f64 {
	cp := base.cos(f64(pitch))
	return {-base.sin(f64(yaw)) * cp, base.sin(f64(pitch)), -base.cos(f64(yaw)) * cp}
}

// entity_attack: a player hits an entity (the reach is checked by the
// caller). Knocked back, hurt (or dead), and scared.
entity_attack :: proc(w: ^World, ent: ^Entity, from: [3]f64) -> (died: bool) {
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

entity_find :: proc(w: ^World, id: u32) -> (^Entity, int) {
	for &ent, i in w.entities.list {if ent.id == id {return &ent, i}}
	return nil, -1
}

// entities_put tells a client about the entities near it: what each is and
// where (a view: an entity out of its area, or gone from the world, is removed
// by not being put).
entities_put :: proc(s: ^Server, c: ^Client) {
	w := c.world
	near := f64(ENTITY_VIEW)
	told := 0
	for &ent in w.entities.list {
		d := ent.body.position - c.player.position
		if d.x * d.x + d.z * d.z > near * near {continue}
		if told == game.MAX_KNOWN_ENTITIES {break}
		told += 1
		key := game.key_entity(ent.id)
		record := game.Entity_Record{ent.kind, ent.stack}
		state_put(s, c, .Entity, &record, key)
		motion := game.Entity_Motion{ent.body.position, ent.yaw, ent.pitch, sheep_flags(&ent)}
		state_put(s, c, .Entity_Motion, &motion, key)
	}
}

// entity_known: c has been told about entity id (it is in its view).
entity_known :: proc(c: ^Client, id: u32) -> bool {
	return(
		c.tx.schema != nil &&
		game.replica_get(&c.tx.sent, int(game.State_Kind.Entity), game.key_entity(id)) != nil \
	)
}

// entity_died: tell everyone who knew it (they show it die), then forget it.
entity_died :: proc(w: ^World, index: int) {
	entity_remove(w, index, true)
}

// entity_gone: as entity_died, without a death to show (a stack picked up).
entity_gone :: proc(w: ^World, index: int) {
	entity_remove(w, index, false)
}

@(private = "file")
entity_remove :: proc(w: ^World, index: int, died: bool) {
	s := w.server
	id := w.entities.list[index].id
	if died {
		for &c in s.clients {
			if c.state == .Playing && c.world == w && entity_known(&c, id) {
				death := game.Entity_Died{id}
				event_send(s, &c, .Entity_Died, &death)
			}
		}
	}
	unordered_remove(&w.entities.list, index)
}

// entity_hurt_shown: everyone who knows it sees it flinch.
entity_hurt_shown :: proc(w: ^World, id: u32) {
	s := w.server
	for &c in s.clients {
		if c.state == .Playing && c.world == w && entity_known(&c, id) {
			hurt := game.Entity_Hurt{id}
			event_send(s, &c, .Entity_Hurt, &hurt)
		}
	}
}

// summon puts an entity in front of a player (cheats: Admin "summon").
summon :: proc(s: ^Server, c: ^Client, kind: game.Entity_Kind) -> bool {
	w := c.world
	query := game.Block_Query{&w.chunks, chunks_block}
	yaw := c.look[0]
	ahead := c.player.position + {-f64(base.sin(yaw)) * 3, 0, -f64(base.cos(yaw)) * 3}
	at := game.Block_Pos {
		i32(math.floor(ahead.x)),
		i32(math.floor(ahead.y)),
		i32(math.floor(ahead.z)),
	}
	for dy in ([]i32{0, 1, -1, 2, -2, 3, -3}) {
		p := at + {0, dy, 0}
		if standable(query, p) {
			if ent := entity_spawn(w, kind, {f64(p.x) + 0.5, f64(p.y), f64(p.z) + 0.5}, false);
			   ent != nil {
				if kind == .Sheep {
					ent.genes = game.genes_wild(&w.entities.rng)
				}
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
think :: proc(w: ^World, ent: ^Entity) {
	b := &ent.brain
	r := &w.entities.rng
	if b.hurt > 0 {b.hurt -= 1}
	b.timer -= 1
	pos := ent.body.position
	// Ready to breed: toward another that is; else as before.
	if ent.love > 0 && ent.growth >= game.LAMB_TICKS && b.state != .Flee {
		if m := mate_for(w, ent); m != nil {
			b.state, b.look_at = .Mate, m.body.position
		} else if b.state == .Mate {
			b.state, b.timer = .Idle, 20
		}
	} else if b.state == .Mate {
		b.state, b.timer = .Idle, 20
	}
	switch b.state {
	case .Mate:
		// Close enough: the one with the lower id has the lamb.
		if m := mate_for(w, ent); m != nil {
			d := m.body.position - pos
			if d.x * d.x + d.z * d.z < 1.6 * 1.6 && ent.id < m.id {breed(w, ent, m)}
		}
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
				{base.rng_f64_range(r, -3, 3), 0, base.rng_f64_range(r, -3, 3)}
			plan(w, ent, target)
		}
	case .Idle, .Look:
		if p, ok := nearest_player(w, pos, 6); ok && base.rng_f32(r) < 0.95 {
			b.state = .Look
			b.look_at = p + {0, game.PLAYER_EYE, 0}
		} else if b.state == .Look {
			b.state = .Idle
		}
		// A shorn sheep with grass in front of it wants to eat.
		if ent.shorn && b.timer <= 0 && base.rng_f32(r) < 0.6 {
			if _, ahead := grass_ahead(w, ent); ahead {
				b.state, b.timer = .Graze, base.rng_int_range(r, GRAZE_EAT_TICKS + 10, 120)
			}
		}
		if b.state != .Graze && b.timer <= 0 {
			switch {
			case base.rng_f32(r) < 0.55:
				target := pos + {base.rng_f64_range(r, -8, 8), 0, base.rng_f64_range(r, -8, 8)}
				if plan(w, ent, target) {b.state, b.timer = .Wander, game.TICK_RATE * 12}
			case base.rng_f32(r) < 0.5:
				b.state, b.timer = .Graze, base.rng_int_range(r, 40, 120)
			case:
				b.timer = base.rng_int_range(r, 30, 90)
			}
		}
	case .Wander:
		if b.step >= b.path.count || b.timer <= 0 || b.stuck > game.TICK_RATE * 2 {
			b.state, b.timer = .Idle, base.rng_int_range(r, 30, 120)
			b.path.count = 0
		}
	case .Graze:
		if b.timer == GRAZE_EAT_TICKS {graze_eat(w, ent)}
		if b.timer <= 0 {b.state, b.timer = .Idle, base.rng_int_range(r, 20, 60)}
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
	case .Idle, .Wander, .Flee, .Mate:
	}
	ent.pitch += (want_pitch - ent.pitch) * 0.2
}

GRAZE_EAT_TICKS :: 10 // ticks left of a graze when the head is down and the grass goes

// grass_ahead: the grass block in front of ent's feet, if there is one.
@(private = "file")
grass_ahead :: proc(w: ^World, ent: ^Entity) -> (p: game.Block_Pos, ok: bool) {
	pos := ent.body.position
	front := pos + {-f64(base.sin(ent.yaw)) * 0.8, 0, -f64(base.cos(ent.yaw)) * 0.8}
	p = {i32(math.floor(front.x)), i32(math.floor(pos.y + 0.01)) - 1, i32(math.floor(front.z))}
	b, loaded := chunks_block(&w.chunks, p)
	return p, loaded && b == .Grass
}

// graze_eat: a sheep with its head down eats the grass in front of it: the
// block becomes dirt, and a shorn sheep has its wool back.
@(private = "file")
graze_eat :: proc(w: ^World, ent: ^Entity) {
	p, ok := grass_ahead(w, ent)
	if !ok || !ent.shorn {return}
	set_block(w, p, .Dirt, world_act(w, .Graze))
	ent.shorn = false
}

// plan finds a path to near target (from where the entity stands); false
// if this tick's budget is spent or there is nowhere to go.
@(private = "file")
plan :: proc(w: ^World, ent: ^Entity, target: [3]f64) -> bool {
	e := &w.entities
	if e.budget < PATH_BUDGET_EACH {return false}
	query := game.Block_Query{&w.chunks, chunks_block}
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
steer :: proc(w: ^World, ent: ^Entity) -> (wish: [2]f32, jump: bool) {
	b := &ent.brain
	if b.hurt > 0 {return} 	// stunned: knockback carries it
	info := game.ENTITY_INFO[ent.kind]
	pos := ent.body.position
	if b.state == .Mate {
		// Straight at the one it wants (they are close, on open ground).
		to := [2]f64{b.look_at.x - pos.x, b.look_at.z - pos.z}
		dist := math.sqrt(to.x * to.x + to.y * to.y)
		if dist < 1 {return}
		wish = {f32(to.x / dist), f32(to.y / dist)} * info.walk_speed
		ent.yaw = turn_towards(ent.yaw, f32(math.atan2(-to.x, -to.y)), 0.3)
		stuck :=
			ent.body.on_ground &&
			abs(ent.body.velocity.x) + abs(ent.body.velocity.z) < 0.1 * info.walk_speed
		jump = stuck
		return
	}
	if b.state != .Wander && b.state != .Flee {return}
	if b.step >= b.path.count {return}
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

// spawn_natural: by day, sheep appear on grass around players with
// room for more, out of sight distance from everyone (but not far).
@(private = "file")
spawn_natural :: proc(w: ^World) {
	s := w.server
	if s.config.no_sheep {return}
	day := game.time_of_day(w.clock)
	if day < 0.27 || day > 0.73 {return}
	r := &w.entities.rng
	query := game.Block_Query{&w.chunks, chunks_block}
	for &c in s.clients {
		if c.state != .Playing || c.world != w {continue}
		near := 0
		for ent in w.entities.list {
			d := ent.body.position - c.player.position
			if d.x * d.x + d.z * d.z < SPAWN_NEAR * SPAWN_NEAR {near += 1}
		}
		if near >= SPAWN_CAP || base.rng_f32(r) > 0.5 {continue}
		angle := base.rng_f64_range(r, 0, math.TAU)
		distance := base.rng_f64_range(r, SPAWN_MIN, SPAWN_MAX)
		x := i32(math.floor(c.player.position.x + base.cos(angle) * distance))
		z := i32(math.floor(c.player.position.z + base.sin(angle) * distance))
		top := column_top(w, x, z)
		ground, loaded := chunks_block(&w.chunks, {x, top, z})
		at := game.Block_Pos{x, top + 1, z}
		if !loaded || ground != .Grass || !standable(query, at) {continue}
		center := [3]f64{f64(x) + 0.5, f64(at.y), f64(z) + 0.5}
		if anyone_within(w, center, SPAWN_MIN) {continue}
		herd := base.rng_int_range(r, 1, 4)
		for _ in 0 ..< herd {
			jitter := [3]f64{base.rng_f64_range(r, -1.5, 1.5), 0, base.rng_f64_range(r, -1.5, 1.5)}
			p := center + jitter
			b := game.Block_Pos{i32(math.floor(p.x)), at.y, i32(math.floor(p.z))}
			if standable(query, b) {
				if sheep := entity_spawn(w, .Sheep, p, true);
				   sheep != nil {sheep.genes = game.genes_wild(r)}
			}
		}
	}
}

@(private = "file")
anyone_within :: proc(w: ^World, p: [3]f64, distance: f64) -> bool {
	_, ok := nearest_player(w, p, distance)
	return ok
}

@(private = "file")
nearest_player :: proc(w: ^World, p: [3]f64, within: f64) -> (at: [3]f64, ok: bool) {
	s := w.server
	best := within * within
	for &c in s.clients {
		if c.state != .Playing || c.world != w {continue}
		d := c.player.position - p
		if l := d.x * d.x + d.y * d.y + d.z * d.z; l < best {
			best, at, ok = l, c.player.position, true
		}
	}
	return
}

// chunk_ready: the chunk at p and the one below are loaded (it can stand).
@(private)
chunk_ready :: proc(w: ^World, p: [3]f64) -> bool {
	b := game.Block_Pos{i32(math.floor(p.x)), i32(math.floor(p.y)), i32(math.floor(p.z))}
	c := chunks_get(&w.chunks, game.chunk_of(b))
	below := chunks_get(&w.chunks, game.chunk_of(b - {0, game.CHUNK_SIZE, 0}))
	return c != nil && c.state == .Ready && below != nil && below.state == .Ready
}

@(private = "file")
turn_towards :: proc(from, to: f32, rate: f32) -> f32 {
	d := math.mod(to - from + 3 * math.PI, math.TAU) - math.PI
	return from + d * rate
}
