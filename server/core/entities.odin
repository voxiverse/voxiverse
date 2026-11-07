package core

import "core:log"
import "core:math"
import "core:slice"
import "core:strings"

import "common:base"
import "common:game"

// Entities on the server: sheep and rockets. What each kind is lies in
// the registry (game.kind_info); what it does each tick, in the systems (below). A
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
SPAWN_HEIGHT :: 4096 // half the cylinder's height: no vertical limit
SPAWN_MIN, SPAWN_MAX :: 16, 40 // blocks from a player where sheep appear
DESPAWN_DISTANCE :: 80 // natural sheep this far from everyone go
PATH_BUDGET_PER_TICK :: 1500 // A* nodes for all entities in one tick
PATH_BUDGET_EACH :: 400
HURT_TICKS :: game.TICK_RATE / 3 // how long a hit stuns (no steering)
FLEE_TICKS :: game.TICK_RATE * 5

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
	lookups: int, // id lookups made (a test counts them)
	next_id: u32,
	budget:  int, // A* nodes left this tick
	rng:     base.Rng,
}

entities_init :: proc(e: ^Entities, seed: i64) {
	e.next_id = 1
	e.rng = base.rng_make(u64(seed) ~ 0x0e7e_0e7e)
}

entities_destroy :: proc(e: ^Entities) {
	e^ = {}
}

// entity_spawn adds an entity at position (bottom centre); nil if full.
entity_spawn :: proc(
	w: ^World,
	kind: game.Kind_Id,
	position: [3]f64,
	natural: bool,
) -> game.Entity_Handle {
	e := &w.entities
	if entity_count(w) >= MAX_ENTITIES {return 0}
	id := e.next_id
	e.next_id += 1
	_, h, _ := entity_world_spawn(
		w.entity_world,
		w.server.registry,
		kind,
		position,
		{},
		game.Entity_Id(id),
		natural,
	)
	if h == 0 {return 0}
	// applied at once, so the components exist when the caller has the entity
	game.store_apply(&w.entity_world.store)
	entity_set_yaw(w, h, base.rng_f32_range(&e.rng, -math.PI, math.PI))
	return h
}

// entities_sync_spatial moves each listed entity's spatial box to its position
// (after store_apply, so every entity has its link): what the spatial service
// answers is where the entity is at the end of every tick.
entities_sync_spatial :: proc(w: ^World) {
	ew := w.entity_world
	it := entities_each(w)
	for h in entities_next(&it) {
		sl := game.store_get(&ew.store, h, C_SPATIAL_LINK, Spatial_Link)
		if sl == nil {continue}
		lo, hi := game.entity_box(
			game.kind_info(w.server.registry, entity_kind(w, h)),
			entity_pos(w, h),
		)
		game.spatial_move(&ew.spatial, sl.handle, lo, hi)
	}
}

// entity_looks: what clients are told about how an entity looks: bit i is the kind's
// i-th look, each computed from the components it names.
entity_looks :: proc(w: ^World, reg: ^game.Registry, h: game.Entity_Handle) -> (bits: u16) {
	info := game.kind_info(reg, entity_kind(w, h))
	if info == nil {return}
	for look, i in info.looks {
		on: bool
		switch look {
		case .Shorn:
			on = entity_wool(w, h).shorn
		case .Lamb:
			on = entity_breeding(w, h).growth < game.LAMB_TICKS
		case .Black:
			on = game.genes_black(entity_genes(w, h).genes)
		case .Spotted:
			on = game.genes_spotted(entity_genes(w, h).genes)
		case .In_Love:
			on = entity_breeding(w, h).love > 0
		}
		if on {bits |= 1 << u16(i)}
	}
	return
}


// sheep_use: wheat feeds it (an adult becomes ready to breed; a lamb grows
// up a tenth sooner), anything else shears an adult by hand: 1 to 3 wool
// (white or black by its genes) fall, and it is shorn until it eats grass.
sheep_use :: proc(s: ^Server, c: ^Client, h: game.Entity_Handle) -> bool {
	w := c.world
	lamb := entity_breeding(w, h).growth < game.LAMB_TICKS
	held := game.inventory_held(&c.inventory)
	if !game.stack_empty(held) && held.item == game.item_of_material(.Wheat) {
		switch {
		case lamb:
			entity_breeding(w, h).growth = min(
				entity_breeding(w, h).growth + game.LAMB_TICKS / 10,
				game.LAMB_TICKS,
			)
		case entity_breeding(w, h).love == 0 && entity_breeding(w, h).wait == 0:
			entity_breeding(w, h).love = game.BREED_READY_TICKS
		case:
			return false
		}
		record(s, c, .Item_Used, "wheat")
		if !lamb {record(s, c, .Sheep_Fed)}
		if !has_ability(s, c, .Infinite_Items) {
			ledger(s, w, .Use, held.item, -1)
			c.inventory.slots[c.inventory.selected].count -= 1
			game.inventory_tidy(&c.inventory)
			c.inv_changed = true
		}
		return true
	}
	if entity_wool(w, h).shorn || lamb {return false}
	entity_wool(w, h).shorn = true
	record(s, c, .Sheep_Sheared)
	r := &w.entities.rng
	wool := game.item_of_block(
		s.registry,
		.Wool_Black if game.genes_black(entity_genes(w, h).genes) else .Wool,
	)
	for _ in 0 ..< base.rng_int_range(r, 1, 4) {
		v := [3]f32{base.rng_f32_range(r, -1, 1), 2.5, base.rng_f32_range(r, -1, 1)}
		ledger(s, w, .Drop_Mob, wool, 1)
		spawn_item(w, entity_pos(w, h) + {0, 0.6, 0}, {wool, 1, 0}, v, -1)
	}
	return true
}

// sheep_life: a sheep's clocks, one tick: a lamb grows, love and the wait
// after a lamb run down.
sheep_life :: proc(w: ^World, h: game.Entity_Handle) {
	if entity_breeding(w, h).growth < game.LAMB_TICKS {entity_breeding(w, h).growth += 1}
	if entity_breeding(w, h).love > 0 {entity_breeding(w, h).love -= 1}
	if entity_breeding(w, h).wait > 0 {entity_breeding(w, h).wait -= 1}
}

// mate_for: the nearest other sheep that is ready to breed within range of
// ent (an adult in love), if any. The spatial service names the sheep near
// ent (its boxes are where the sheep were at the end of the last tick, so it
// asks a little wider than BREED_RANGE); the store says how far each is now
// and whether it is ready.
mate_for :: proc(w: ^World, h: game.Entity_Handle) -> game.Entity_Handle {
	ew := w.entity_world
	kind_id := w.server.registry.engine.sheep
	if kind_id == 0 {return 0}
	near := make([dynamic]game.Entity_Id, context.temp_allocator)
	game.spatial_sphere(
		&ew.spatial,
		entity_pos(w, h),
		game.BREED_RANGE + MATE_SLACK,
		{kind = u16(kind_id), exclude = game.Entity_Id(entity_id(w, h))},
		&near,
	)
	slice.sort(near[:]) // the lowest id wins a tie, as the list's order did
	best: game.Entity_Handle
	best_d := f64(game.BREED_RANGE * game.BREED_RANGE)
	for id in near {
		other, _ := entity_find(w, u32(id))
		if other == 0 ||
		   entity_kind(w, other) != w.server.registry.engine.sheep ||
		   entity_breeding(w, other).love <= 0 {continue}
		if entity_breeding(w, other).growth < game.LAMB_TICKS {continue}
		d := entity_pos(w, other) - entity_pos(w, h)
		if dd := d.x * d.x + d.y * d.y + d.z * d.z; dd < best_d {best, best_d = other, dd}
	}
	return best
}

// MATE_SLACK: how far a sheep can have moved since the spatial service last
// saw it (a sheep runs 4.2 blocks a second; a tick is a twentieth of that).
@(private = "file")
MATE_SLACK :: 2

// breed: a and b have met: a lamb between them, of both, and each waits.
@(private = "file")
breed :: proc(w: ^World, a, b: game.Entity_Handle) {
	r := &w.entities.rng
	at := (entity_pos(w, a) + entity_pos(w, b)) / 2
	genes := game.genes_child(entity_genes(w, a).genes, entity_genes(w, b).genes, r)
	entity_breeding(w, a).love, entity_breeding(w, b).love = 0, 0
	entity_breeding(w, a).wait, entity_breeding(w, b).wait =
		game.BREED_WAIT_TICKS, game.BREED_WAIT_TICKS
	if lamb := entity_spawn(w, w.server.registry.engine.sheep, at, false); lamb != 0 {
		entity_genes(w, lamb).genes, entity_breeding(w, lamb).growth = genes, 0
		record_world(w.server, w, .Sheep_Born)
	}
}

// use_entity: a player uses an entity, if it is within reach.
use_entity :: proc(s: ^Server, c: ^Client, id: u32) {
	h, _ := entity_find(c.world, id)
	if h == 0 || !entity_reachable(c, h) {return}
	if entity_kind(c.world, h) == s.registry.engine.sheep {sheep_use(s, c, h)} 	// (the only kind a player uses)
}

// entity_reachable: ent is within a player's reach from where the server
// has them (with the slack edits have).
entity_reachable :: proc(c: ^Client, h: game.Entity_Handle) -> bool {
	eye := game.player_eye(c.player)
	lo, hi := game.entity_box(
		game.kind_info(c.world.server.registry, entity_kind(c.world, h)),
		entity_pos(c.world, h),
	)
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
	h := entity_spawn(c.world, s.registry.engine.rocket, start, false)
	if h == 0 {return false}
	entity_set_look(c.world, h, yaw, pitch)
	entity_set_velocity(
		c.world,
		h,
		{f32(dir.x), f32(dir.y), f32(dir.z)} *
		game.kind_info(s.registry, entity_kind(c.world, h)).projectile.speed,
	)
	entity_owner(c.world, h).client = i32(player_id(s, c))
	entity_owner(c.world, h).action = u32(action_begin(c.world, actor_of(s, c), .Explosion))
	record(s, c, .Rocket_Fired)
	return true
}

// explode: a blast at center. Everyone near is shown it, the sphere is
// carved (where loaded), and what is near is thrown (sheep hurt).
explode :: proc(w: ^World, center: [3]f64, radius: f64, action: Action_Id) {
	s := w.server
	record_world(s, w, .Explosion, n0 = i64(radius))
	for i in players_near(w, center, 160 + PLAYER_MARGIN, SPAWN_HEIGHT) {
		c := &s.clients[i]
		d := c.player.position - center
		if d.x * d.x + d.z * d.z < 160 * 160 {
			blast := game.Explosion{center, f32(radius)}
			event_send(s, c, .Explosion, &blast)
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
	for i in players_near(w, center, reach + PLAYER_MARGIN, reach + PLAYER_MARGIN) {
		c := &s.clients[i]
		if impulse, near := push(c.player.position + {0, 0.9, 0}, center, reach); near {
			c.player.velocity += impulse
			disturb(s, c)
			c.player.on_ground = false
			d := c.player.position + {0, 0.9, 0} - center
			distance := math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
			damage(
				s,
				c,
				f32(1 - distance / reach) * 12,
				{kind = .Explosion, pos = center, placed = true},
			)
		}
	}
	// What is thrown comes from the spatial service: the boxes it holds are
	// where things stood at the end of the last tick, so the sphere is widened
	// by ROCKET_REACH. Candidates are walked in id order; a death removes its
	// row, so each is found again by id.
	found := make([dynamic]game.Entity_Id, context.temp_allocator)
	game.spatial_sphere(
		&w.entity_world.spatial,
		center,
		reach + ROCKET_REACH,
		{all = {.Hittable}},
		&found,
	)
	slice.sort(found[:])
	for fid in found {
		id := u32(fid)
		h, ok := entity_find(w, id)
		if !ok {continue}
		impulse, near := push(entity_pos(w, h) + {0, 0.4, 0}, center, reach)
		if !near || !game.kind_info(w.server.registry, entity_kind(w, h)).hittable {continue}
		entity_set_velocity(w, h, entity_velocity(w, h) + impulse)
		entity_set_on_ground(w, h, false)
		d := entity_pos(w, h) - center
		health := entity_health_of(w, h)
		health -= 3 if d.x * d.x + d.y * d.y + d.z * d.z < radius * radius else 1
		entity_set_health(w, h, health)
		if health <= 0 {
			entity_died(w, h)
			continue
		}
		scare(entity_brain(w, h), center)
		entity_hurt_shown(w, id)
	}
}

// ROCKET_REACH: how far past a rocket's step a box can be and still be
// tested: a tall box's height, and a tick of its owner's or a target's running.
ROCKET_REACH :: 4

// rocket_step flies a rocket one tick; where it hit, if it did.
rocket_step :: proc(w: ^World, h: game.Entity_Handle) -> (at: [3]f64, hit: bool) {
	s := w.server
	if f32(entity_age_of(w, h)) * game.TICK_SECONDS >
	   game.kind_info(s.registry, entity_kind(w, h)).projectile.life {return entity_pos(w, h), true}
	v := entity_velocity(w, h)
	v.y -= game.kind_info(s.registry, entity_kind(w, h)).projectile.gravity * game.TICK_SECONDS
	entity_set_velocity(w, h, v)
	speed := math.sqrt(f64(v.x * v.x + v.y * v.y + v.z * v.z))
	if speed < 1e-6 {return entity_pos(w, h), true}
	dir := [3]f64{f64(v.x), f64(v.y), f64(v.z)} / speed
	step := speed * f64(game.TICK_SECONDS)
	from := entity_pos(w, h) + {0, 0.15, 0}
	nearest := step
	hit_at: [3]f64
	query := game.Block_Query{&w.chunks, chunks_block, &w.server.registry.blocks, {}}
	if b, ok := game.raycast(query, from, dir, step); ok {
		nearest, hit_at, hit = b.distance, from + dir * b.distance, true
	} else if !chunk_ready(w, from) {
		return from, true // flew out of the loaded world
	}
	// Who the step can reach comes from the spatial service: the boxes it
	// holds are where things stood at the end of the last tick, so it asks
	// around the step's middle, wide enough for a tall box (its entry is the
	// bottom centre) and for a tick of movement. The list and the clients say
	// where each is now; both are walked in id order.
	ew := w.entity_world
	mid := from + dir * (step / 2)
	reach := step / 2 + ROCKET_REACH
	near := make([dynamic]game.Entity_Id, context.temp_allocator)
	game.spatial_sphere(
		&ew.spatial,
		mid,
		reach,
		{all = {.Hittable}, exclude = game.Entity_Id(entity_id(w, h))},
		&near,
	)
	slice.sort(near[:])
	for id in near {
		other, there := entity_find(w, u32(id))
		if !there {continue}
		oinfo := game.kind_info(s.registry, entity_kind(w, other))
		if !oinfo.hittable {continue}
		lo, hi := game.entity_box(oinfo, entity_pos(w, other))
		if d, ok := game.ray_box(from, dir, lo, hi, nearest);
		   ok {nearest, hit_at, hit = d, from + dir * d, true}
	}
	clear(&near)
	game.spatial_sphere(&ew.spatial, mid, reach, {all = {.Player}}, &near)
	who := make([dynamic]int, context.temp_allocator)
	for id in near {
		ph, live := game.store_find(&ew.store, id)
		if !live {continue}
		link := game.store_get(&ew.store, ph, game.C_PLAYER_LINK, game.Player_Link)
		if link != nil && int(link.client) < len(s.clients) {append(&who, int(link.client))}
	}
	slice.sort(who[:])
	for i in who {
		c := &s.clients[i]
		if c.state != .Playing ||
		   c.world != w ||
		   (i == int(entity_owner(w, h).client) &&
				   entity_age_of(w, h) < game.TICK_RATE / 3) {continue}
		lo, hi := game.player_box(c.player)
		if d, ok := game.ray_box(from, dir, lo, hi, nearest);
		   ok {nearest, hit_at, hit = d, from + dir * d, true}
	}
	if hit {return hit_at, true}
	entity_set_pos(w, h, entity_pos(w, h) + dir * step)
	entity_set_yaw(w, h, f32(math.atan2(-dir.x, -dir.z)))
	entity_set_pitch(w, h, clamp(f32(math.asin(clamp(dir.y, -1, 1))), -1.5, 1.5)) // within the protocol's limit
	return {}, false
}

forward :: proc(yaw, pitch: f32) -> [3]f64 {
	cp := base.cos(f64(pitch))
	return {-base.sin(f64(yaw)) * cp, base.sin(f64(pitch)), -base.cos(f64(yaw)) * cp}
}

// scare: hit from a place, the brain flees and is stunned (the rest of it
// reset; fields set one by one, a Brain literal would be built on the stack).
@(private = "file")
scare :: proc(b: ^Brain, from: [3]f64) {
	b^ = {}
	b.state = .Flee
	b.timer = FLEE_TICKS
	b.from = from
	b.hurt = HURT_TICKS
}

// entity_attack: a player hits an entity (the reach is checked by the
// caller). Knocked back, hurt (or dead), and scared.
entity_attack :: proc(w: ^World, h: game.Entity_Handle, from: [3]f64) -> (died: bool) {
	entity_set_health(w, h, entity_health_of(w, h) - 1)
	away := entity_pos(w, h) - from
	l := math.sqrt(away.x * away.x + away.z * away.z)
	if l > 1e-6 {away /= l} else {away = {1, 0, 0}}
	kb := game.ATTACK_KNOCKBACK
	entity_set_velocity(w, h, {f32(away.x) * kb[0], kb[1], f32(away.z) * kb[0]})
	entity_set_on_ground(w, h, false)
	scare(entity_brain(w, h), from)
	return entity_health_of(w, h) <= 0
}

// The door: what the store says of an entity (nil when it has no such part).
entity_transform :: proc(w: ^World, h: game.Entity_Handle) -> ^game.Transform {
	return game.store_get(&w.entity_world.store, h, game.C_TRANSFORM, game.Transform)
}

// entity_pos: where ent is (its Transform; zero if it has none).
entity_pos :: proc(w: ^World, h: game.Entity_Handle) -> [3]f64 {
	if tf := entity_transform(w, h); tf != nil {return tf.position}
	return {}
}

entity_set_pos :: proc(w: ^World, h: game.Entity_Handle, p: [3]f64) {
	if tf := entity_transform(w, h); tf != nil {tf.position = p}
}

entity_yaw :: proc(w: ^World, h: game.Entity_Handle) -> f32 {
	if tf := entity_transform(w, h); tf != nil {return tf.yaw}
	return 0
}

entity_pitch :: proc(w: ^World, h: game.Entity_Handle) -> f32 {
	if tf := entity_transform(w, h); tf != nil {return tf.pitch}
	return 0
}

entity_set_yaw :: proc(w: ^World, h: game.Entity_Handle, yaw: f32) {
	if tf := entity_transform(w, h); tf != nil {tf.yaw = yaw}
}

entity_set_pitch :: proc(w: ^World, h: game.Entity_Handle, pitch: f32) {
	if tf := entity_transform(w, h); tf != nil {tf.pitch = pitch}
}

entity_set_look :: proc(w: ^World, h: game.Entity_Handle, yaw, pitch: f32) {
	if tf := entity_transform(w, h); tf != nil {tf.yaw, tf.pitch = yaw, pitch}
}

// entity_body_step: game.body_step on ent, which sees one Entity_Body: the
// position, velocity and ground contact come from the store before it and
// go back after. The one place a mover is gathered and written back.
entity_body_step :: proc(
	w: ^World,
	h: game.Entity_Handle,
	info: ^game.Kind_Info,
	wish: [2]f32,
	jump: bool,
	query: game.Block_Query,
) {
	body := game.Entity_Body {
		position  = entity_pos(w, h),
		velocity  = entity_velocity(w, h),
		on_ground = entity_on_ground(w, h),
	}
	game.body_step(&body, info, wish, jump, &w.rules, query, game.TICK_SECONDS)
	entity_set_pos(w, h, body.position)
	entity_set_velocity(w, h, body.velocity)
	entity_set_on_ground(w, h, body.on_ground)
}

// entity_velocity, entity_on_ground: its Physics (zero and false without one).
entity_velocity :: proc(w: ^World, h: game.Entity_Handle) -> [3]f32 {
	if ph := entity_physics(w, h); ph != nil {return ph.velocity}
	return {}
}

entity_on_ground :: proc(w: ^World, h: game.Entity_Handle) -> bool {
	if ph := entity_physics(w, h); ph != nil {return ph.on_ground}
	return false
}

entity_set_velocity :: proc(w: ^World, h: game.Entity_Handle, v: [3]f32) {
	if ph := entity_physics(w, h); ph != nil {ph.velocity = v}
}

entity_set_on_ground :: proc(w: ^World, h: game.Entity_Handle, on: bool) {
	if ph := entity_physics(w, h); ph != nil {ph.on_ground = on}
}

entity_physics :: proc(w: ^World, h: game.Entity_Handle) -> ^game.Physics {
	return game.store_get(&w.entity_world.store, h, game.C_PHYSICS, game.Physics)
}

// The plain components behind the door. Each returns the entity's component;
// for one without it (a rocket has no wool) it returns a scratch value that is
// reset on every call, so reads see the default and a stray write goes nowhere.
@(thread_local, private = "file")
scratch_wool: game.Wool
@(thread_local, private = "file")
scratch_genes: game.Component_Genes
@(thread_local, private = "file")
scratch_breeding: game.Breeding
@(thread_local, private = "file")
scratch_stack: game.Component_Stack
@(thread_local, private = "file")
scratch_owner: game.Owner
@(thread_local, private = "file")
scratch_brain: Brain

// entity_brain: the entity's brain (a default one, written to nowhere, for an
// entity without it: only grazers have one).
entity_brain :: proc(w: ^World, h: game.Entity_Handle) -> ^Brain {
	if p := game.store_get(&w.entity_world.store, h, C_BRAIN, Brain); p != nil {return p}
	scratch_brain = {}
	return &scratch_brain
}

entity_wool :: proc(w: ^World, h: game.Entity_Handle) -> ^game.Wool {
	if p := game.store_get(&w.entity_world.store, h, game.C_WOOL, game.Wool); p != nil {return p}
	scratch_wool = {}
	return &scratch_wool
}

entity_genes :: proc(w: ^World, h: game.Entity_Handle) -> ^game.Component_Genes {
	if p := game.store_get(&w.entity_world.store, h, game.C_GENES, game.Component_Genes);
	   p != nil {return p}
	scratch_genes = {}
	return &scratch_genes
}

// entity_breeding: growth, love and wait (an adult's growth is LAMB_TICKS).
entity_breeding :: proc(w: ^World, h: game.Entity_Handle) -> ^game.Breeding {
	if p := game.store_get(&w.entity_world.store, h, game.C_BREEDING, game.Breeding);
	   p != nil {return p}
	scratch_breeding = {
		growth = game.LAMB_TICKS,
	}
	return &scratch_breeding
}

// entity_stack: a dropped item's stack.
entity_stack :: proc(w: ^World, h: game.Entity_Handle) -> ^game.Stack {
	if p := game.store_get(&w.entity_world.store, h, game.C_STACK, game.Component_Stack);
	   p != nil {return &p.stack}
	scratch_stack = {}
	return &scratch_stack.stack
}

// entity_owner: a rocket's or a dropped stack's client index (-1: none) and a
// rocket's journal action.
entity_owner :: proc(w: ^World, h: game.Entity_Handle) -> ^game.Owner {
	if p := game.store_get(&w.entity_world.store, h, game.C_OWNER, game.Owner); p != nil {return p}
	scratch_owner = {
		client = -1,
	}
	return &scratch_owner
}

entity_health :: proc(w: ^World, h: game.Entity_Handle) -> ^game.Entity_Health {
	return game.store_get(&w.entity_world.store, h, game.C_HEALTH, game.Entity_Health)
}

entity_age :: proc(w: ^World, h: game.Entity_Handle) -> ^game.Age {
	return game.store_get(&w.entity_world.store, h, game.C_AGE, game.Age)
}

entity_health_of :: proc(w: ^World, h: game.Entity_Handle) -> int {
	if hp := entity_health(w, h); hp != nil {return int(hp.health)}
	return 0
}

entity_set_health :: proc(w: ^World, h: game.Entity_Handle, health: int) {
	if hp := entity_health(w, h); hp != nil {hp.health = i32(health)}
}

entity_age_of :: proc(w: ^World, h: game.Entity_Handle) -> int {
	if age := entity_age(w, h); age != nil {return int(age.ticks)}
	return 0
}

entity_set_age :: proc(w: ^World, h: game.Entity_Handle, ticks: int) {
	if age := entity_age(w, h); age != nil {age.ticks = i32(ticks)}
}

entity_is_natural :: proc(w: ^World, h: game.Entity_Handle) -> bool {
	return game.store_get(&w.entity_world.store, h, game.C_NATURAL, game.Natural) != nil
}

// entity_find: the entity with this id (a player is no entity here).
entity_find :: proc(w: ^World, id: u32) -> (game.Entity_Handle, bool) {
	w.entities.lookups += 1
	h, ok := game.store_find(&w.entity_world.store, game.Entity_Id(id))
	if !ok || !entity_listed(w, h) {return 0, false}
	return h, true
}

// entities_put tells a client about the entities near it: what each is and
// where (a view: an entity out of its area, or gone from the world, is removed
// by not being put).
entities_put :: proc(s: ^Server, c: ^Client) {
	w := c.world
	// The entities within ENTITY_VIEW horizontally (players are not told as
	// entities), the lowest ids first, at most MAX_KNOWN_ENTITIES of them: the
	// query answers in id order, which is the order the set was always
	// cut in (a nearest-first cut changes the set every tick at the cap, and
	// the receiver refuses a create past its record cap before it applies the
	// removes of the same message).
	around := make([dynamic]game.Entity_Id, context.temp_allocator)
	game.spatial_cylinder(
		&w.entity_world.spatial,
		c.player.position,
		ENTITY_VIEW,
		SPAWN_HEIGHT,
		{none = {.Player}},
		&around,
	)
	for id in around[:min(len(around), game.MAX_KNOWN_ENTITIES)] {
		h, _ := entity_find(w, u32(id))
		if h == 0 {continue}
		key := game.key_entity(u32(id))
		record := game.Entity_Record{entity_kind(w, h), entity_stack(w, h)^}
		state_put(s, c, .Entity, &record, key)
		motion := game.Entity_Motion {
			entity_pos(w, h),
			entity_yaw(w, h),
			entity_pitch(w, h),
			entity_looks(w, s.registry, h),
		}
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
entity_died :: proc(w: ^World, h: game.Entity_Handle) {
	entity_retire(w, h, true)
}

// entity_gone: as entity_died, without a death to show (a stack picked up).
entity_gone :: proc(w: ^World, h: game.Entity_Handle) {
	entity_retire(w, h, false)
}

@(private = "file")
entity_retire :: proc(w: ^World, h: game.Entity_Handle, died: bool) {
	s := w.server
	id := entity_id(w, h)
	if died {
		for i in entity_watchers(w, entity_pos(w, h)) {
			c := &s.clients[i]
			if entity_known(c, id) {
				death := game.Entity_Died{id}
				event_send(s, c, .Entity_Died, &death)
			}
		}
	}
	_ = game.store_despawn(&w.entity_world.store, h)
}

// entity_hurt_shown: everyone who knows it sees it flinch.
entity_hurt_shown :: proc(w: ^World, id: u32) {
	s := w.server
	h, ok := entity_find(w, id)
	if !ok {return}
	for i in entity_watchers(w, entity_pos(w, h)) {
		c := &s.clients[i]
		if entity_known(c, id) {
			hurt := game.Entity_Hurt{id}
			event_send(s, c, .Entity_Hurt, &hurt)
		}
	}
}

// entity_watchers: the indexes (ascending) of the playing clients of w whose
// players are near enough to p to know an entity there: one spatial query over
// the player entities, not a walk over all clients. The view is widened by a
// margin, since a client was told one tick ago, when either side was a step
// away; callers still ask entity_known.
entity_watchers :: proc(w: ^World, p: [3]f64) -> []int {
	s := w.server
	ew := w.entity_world
	near := make([dynamic]game.Entity_Id, context.temp_allocator)
	game.spatial_cylinder(
		&ew.spatial,
		p,
		ENTITY_VIEW + 4,
		SPAWN_HEIGHT + 4,
		{all = {.Player}},
		&near,
	)
	who := make([dynamic]int, context.temp_allocator)
	for id in near {
		h, live := game.store_find(&ew.store, id)
		if !live {continue}
		link := game.store_get(&ew.store, h, game.C_PLAYER_LINK, game.Player_Link)
		if link == nil || int(link.client) >= len(s.clients) {continue}
		c := &s.clients[link.client]
		if c.state == .Playing && c.world == w {append(&who, int(link.client))}
	}
	slice.sort(who[:])
	return who[:]
}

// PLAYER_MARGIN: how far a player's entity may lag its client's position (the
// boxes are where players stood when the tick began).
PLAYER_MARGIN :: 8

// players_near: the indexes (ascending) of the playing clients of w whose
// player entities are within radius horizontally and half_height vertically of
// p. Callers widen the shape by PLAYER_MARGIN and test the client's own
// position, so the answer is what a walk over all clients gave, by one query.
players_near :: proc(w: ^World, p: [3]f64, radius, half_height: f64) -> []int {
	s := w.server
	ew := w.entity_world
	near := make([dynamic]game.Entity_Id, context.temp_allocator)
	game.spatial_cylinder(&ew.spatial, p, radius, half_height, {all = {.Player}}, &near)
	who := make([dynamic]int, context.temp_allocator)
	for id in near {
		h, live := game.store_find(&ew.store, id)
		if !live {continue}
		link := game.store_get(&ew.store, h, game.C_PLAYER_LINK, game.Player_Link)
		if link == nil || int(link.client) >= len(s.clients) {continue}
		c := &s.clients[link.client]
		if c.state == .Playing && c.world == w {append(&who, int(link.client))}
	}
	slice.sort(who[:])
	return who[:]
}

// summon puts an entity in front of a player (cheats: Admin "summon").
summon :: proc(s: ^Server, c: ^Client, kind: game.Kind_Id) -> bool {
	w := c.world
	query := game.Block_Query{&w.chunks, chunks_block, &w.server.registry.blocks, {}}
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
			if h := entity_spawn(w, kind, {f64(p.x) + 0.5, f64(p.y), f64(p.z) + 0.5}, false);
			   h != 0 {
				if kind == s.registry.engine.sheep {
					entity_genes(w, h).genes = game.genes_wild(&w.entities.rng)
				}
				log.infof(
					"server summoned kind=%s id=%d at=%v by=%s",
					game.kind_info(s.registry, kind).id,
					entity_id(w, h),
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
think :: proc(w: ^World, h: game.Entity_Handle) {
	b := entity_brain(w, h)
	r := &w.entities.rng
	if b.hurt > 0 {b.hurt -= 1}
	b.timer -= 1
	pos := entity_pos(w, h)
	// Ready to breed: toward another that is; else as before.
	if entity_breeding(w, h).love > 0 &&
	   entity_breeding(w, h).growth >= game.LAMB_TICKS &&
	   b.state != .Flee {
		if m := mate_for(w, h); m != 0 {
			b.state, b.look_at = .Mate, entity_pos(w, m)
		} else if b.state == .Mate {
			b.state, b.timer = .Idle, 20
		}
	} else if b.state == .Mate {
		b.state, b.timer = .Idle, 20
	}
	switch b.state {
	case .Mate:
		// Close enough: the one with the lower id has the lamb.
		if m := mate_for(w, h); m != 0 {
			d := entity_pos(w, m) - pos
			if d.x * d.x + d.z * d.z < 1.6 * 1.6 &&
			   entity_id(w, h) < entity_id(w, m) {breed(w, h, m)}
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
			plan(w, h, target)
		}
	case .Idle, .Look:
		if p, ok := nearest_player(w, pos, 6); ok && base.rng_f32(r) < 0.95 {
			b.state = .Look
			b.look_at = p + {0, game.PLAYER_EYE, 0}
		} else if b.state == .Look {
			b.state = .Idle
		}
		// A shorn sheep with grass in front of it wants to eat.
		if entity_wool(w, h).shorn && b.timer <= 0 && base.rng_f32(r) < 0.6 {
			if _, ahead := grass_ahead(w, h); ahead {
				b.state, b.timer = .Graze, base.rng_int_range(r, GRAZE_EAT_TICKS + 10, 120)
			}
		}
		if b.state != .Graze && b.timer <= 0 {
			switch {
			case base.rng_f32(r) < 0.55:
				target := pos + {base.rng_f64_range(r, -8, 8), 0, base.rng_f64_range(r, -8, 8)}
				if plan(w, h, target) {b.state, b.timer = .Wander, game.TICK_RATE * 12}
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
		if b.timer == GRAZE_EAT_TICKS {graze_eat(w, h)}
		if b.timer <= 0 {b.state, b.timer = .Idle, base.rng_int_range(r, 20, 60)}
	}
	// The head: down when grazing, at the player when looking, level else.
	want_pitch: f32 = 0
	switch b.state {
	case .Graze:
		want_pitch = -1.2
	case .Look:
		d :=
			b.look_at -
			(pos + {0, game.kind_box(game.kind_info(w.server.registry, entity_kind(w, h)))[1], 0})
		flat := math.sqrt(d.x * d.x + d.z * d.z)
		want_pitch = clamp(f32(math.atan2(d.y, flat)), -1, 1)
		entity_set_yaw(w, h, turn_towards(entity_yaw(w, h), f32(math.atan2(-d.x, -d.z)), 0.15))
	case .Idle, .Wander, .Flee, .Mate:
	}
	pitch := entity_pitch(w, h)
	entity_set_pitch(w, h, pitch + (want_pitch - pitch) * 0.2)
}

GRAZE_EAT_TICKS :: 10 // ticks left of a graze when the head is down and the grass goes

// grass_ahead: the grass block in front of ent's feet, if there is one.
@(private = "file")
grass_ahead :: proc(w: ^World, h: game.Entity_Handle) -> (p: game.Block_Pos, ok: bool) {
	pos := entity_pos(w, h)
	front :=
		pos + {-f64(base.sin(entity_yaw(w, h))) * 0.8, 0, -f64(base.cos(entity_yaw(w, h))) * 0.8}
	p = {i32(math.floor(front.x)), i32(math.floor(pos.y + 0.01)) - 1, i32(math.floor(front.z))}
	b, loaded := chunks_block(&w.chunks, p)
	return p, loaded && b == .Grass
}

// graze_eat: a sheep with its head down eats the grass in front of it: the
// block becomes dirt, and a shorn sheep has its wool back.
@(private = "file")
graze_eat :: proc(w: ^World, h: game.Entity_Handle) {
	p, ok := grass_ahead(w, h)
	if !ok || !entity_wool(w, h).shorn {return}
	set_block(w, p, .Dirt, world_act(w, .Graze))
	entity_wool(w, h).shorn = false
}

// plan finds a path to near target (from where the entity stands); false
// if this tick's budget is spent or there is nowhere to go.
@(private = "file")
plan :: proc(w: ^World, h: game.Entity_Handle, target: [3]f64) -> bool {
	e := &w.entities
	if e.budget < PATH_BUDGET_EACH {return false}
	query := game.Block_Query{&w.chunks, chunks_block, &w.server.registry.blocks, {}}
	pos := entity_pos(w, h)
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
	b := entity_brain(w, h)
	b.path = path
	b.step = 0
	b.stuck = 0
	return true
}

// steer: the wished-for velocity and whether to jump, following the path.
steer :: proc(w: ^World, h: game.Entity_Handle) -> (wish: [2]f32, jump: bool) {
	b := entity_brain(w, h)
	if b.hurt > 0 {return} 	// stunned: knockback carries it
	info := game.kind_info(w.server.registry, entity_kind(w, h))
	pos := entity_pos(w, h)
	vel := entity_velocity(w, h)
	if b.state == .Mate {
		// Straight at the one it wants (they are close, on open ground).
		to := [2]f64{b.look_at.x - pos.x, b.look_at.z - pos.z}
		dist := math.sqrt(to.x * to.x + to.y * to.y)
		if dist < 1 {return}
		wish = {f32(to.x / dist), f32(to.y / dist)} * info.walker.walk_speed
		entity_set_yaw(w, h, turn_towards(entity_yaw(w, h), f32(math.atan2(-to.x, -to.y)), 0.3))
		stuck := entity_on_ground(w, h) && abs(vel.x) + abs(vel.z) < 0.1 * info.walker.walk_speed
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
	speed := info.walker.run_speed if b.state == .Flee else info.walker.walk_speed
	dir := [2]f32{f32(to.x / max(dist, 1e-6)), f32(to.y / max(dist, 1e-6))}
	wish = dir * speed
	entity_set_yaw(w, h, turn_towards(entity_yaw(w, h), f32(math.atan2(-to.x, -to.y)), 0.3))
	// Up a step, or something in the way: jump.
	blocked := entity_on_ground(w, h) && math.abs(vel.x) + math.abs(vel.z) < 0.1 * speed
	jump = entity_on_ground(w, h) && (f64(target.y) > pos.y + 0.5 || blocked)
	if blocked {b.stuck += 1} else {b.stuck = 0}
	return
}

// spawn_natural: by day, sheep appear on grass around players with
// room for more, out of sight distance from everyone (but not far).
spawn_natural :: proc(w: ^World) {
	s := w.server
	if s.config.no_natural_spawns {return}
	day := game.time_of_day(w.clock)
	if day < 0.27 || day > 0.73 {return}
	r := &w.entities.rng
	query := game.Block_Query{&w.chunks, chunks_block, &w.server.registry.blocks, {}}
	for &c in s.clients {
		if c.state != .Playing || c.world != w {continue}
		// Every entity near, of any kind but the players (who were never counted).
		// The cylinder has no vertical limit, as the old count had none.
		around := make([dynamic]game.Entity_Id, context.temp_allocator)
		game.spatial_cylinder(
			&w.entity_world.spatial,
			c.player.position,
			SPAWN_NEAR,
			SPAWN_HEIGHT,
			{none = {.Player}},
			&around,
		)
		near := len(around)
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
				if sheep := entity_spawn(w, w.server.registry.engine.sheep, p, true);
				   sheep != 0 {entity_genes(w, sheep).genes = game.genes_wild(r)}
			}
		}
	}
}

anyone_within :: proc(w: ^World, p: [3]f64, distance: f64) -> bool {
	_, ok := nearest_player(w, p, distance)
	return ok
}

// nearest_player: the position of the player entity nearest p within the
// distance, asked of the spatial service (a player counts from its first tick
// in the world; clients that are not in w have no entity there).
@(private = "file")
nearest_player :: proc(w: ^World, p: [3]f64, within: f64) -> (at: [3]f64, ok: bool) {
	ew := w.entity_world
	id, _, found := game.spatial_nearest(&ew.spatial, p, within, {all = {.Player}})
	if !found {return}
	h, live := game.store_find(&ew.store, id)
	if !live {return}
	tf := game.store_get(&ew.store, h, game.C_TRANSFORM, game.Transform)
	if tf == nil {return}
	return tf.position, true
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

// The entity world of entities v2: the archetype store, the spatial service
// and what hangs off them (tag names, this tick's deaths, the world's rng).
// entity_world_spawn is the one way an entity comes to be; entity_kill the one way
// it dies. The world holds one (World.entity_world), ticked and applied by
// entities_tick. entity_spawn is the entity door's way in, entity_gone and
// entity_died the way out; every walk (entities_each) is in id order.

MAX_ENTITY_WORLD :: 4096 // entities a world holds
MAX_TAG_NAMES :: 256
MAX_TAG_NAME_LEN :: 32
HURT_KEPT_TICKS :: game.TICK_RATE * 10 // how long Hurt_By names a killer

// The server's own components, after the shared ones.
C_SPATIAL_LINK :: game.FIRST_SERVER_COMPONENT
C_BRAIN :: game.FIRST_SERVER_COMPONENT + 1 // a grazer's Brain (large: set at spawn)

// Spatial_Link: the entity's entry in the spatial service. Releasing it (the
// entity despawned) removes the entry.
Spatial_Link :: struct {
	handle: game.Spatial_Handle,
}

Spawn_Error :: enum u8 {
	None,
	Full, // the arena (or the store's command ring) is full
	Unknown_Kind,
	Not_Loaded, // its chunk is not loaded (checked by the caller that has chunks)
	Out_Of_Ids,
}

Tag_Error :: enum u8 {
	None,
	Stale, // the entity is gone or not applied yet
	Bad_Name, // empty, over 32 bytes, or outside [a-z0-9_:]
	Names_Full, // 256 names already
	Tags_Full, // the entity already has 4
}

Entity_Death :: struct {
	id:       game.Entity_Id,
	kind:     game.Kind_Id,
	position: [3]f64,
	cause:    u8,
	killer:   game.Entity_Id, // 0: none (or the damage was over 10 s ago)
	act:      Act,
}

Entity_World :: struct {
	store:          game.Entity_Store,
	spatial:        game.Spatial,
	rng:            base.Rng,
	budget:         int,
	tick:           u32,
	next_player_id: u32, // entities.odin: the ids of player entities
	tag_names:      [dynamic]string, // tag i is tag_names[i-1]
	deaths:         [dynamic]Entity_Death, // this tick's
	infos:          [game.FIRST_SERVER_COMPONENT + 2]game.Component_Info,
}

@(private = "file")
spatial_release :: proc(owner: rawptr, value: rawptr) {
	ew := (^Entity_World)(owner)
	if h := (^Spatial_Link)(value).handle; h != 0 {game.spatial_remove(&ew.spatial, h)}
}

entity_world_init :: proc(ew: ^Entity_World, seed: u64, max_entities := MAX_ENTITY_WORLD) {
	ew^ = {}
	shared := game.entity_component_infos()
	for info, i in shared {ew.infos[i] = info}
	ew.infos[C_SPATIAL_LINK] = game.Component_Info {
		name    = "spatial_link",
		type    = Spatial_Link,
		size    = size_of(Spatial_Link),
		align   = align_of(Spatial_Link),
		release = spatial_release,
	}
	ew.infos[C_BRAIN] = game.Component_Info {
		name  = "brain",
		type  = Brain,
		size  = size_of(Brain),
		align = align_of(Brain),
	}
	game.spatial_init(&ew.spatial)
	// room for the fixed list's worth of entries at once, so the tables are
	// at their size from the start and memory is flat while play goes on
	reserve(&ew.spatial.slots, 2 * MAX_ENTITIES)
	reserve(&ew.spatial.free, 2 * MAX_ENTITIES)
	reserve(&ew.spatial.cells, 256)
	// the store releases rows into the spatial service, so it is destroyed first
	assert(
		game.store_init(&ew.store, ew.infos[:], ew, max_entities, commands_per_entity = 6) == nil,
	)
	ew.rng = base.rng_make(seed)
}

entity_world_destroy :: proc(ew: ^Entity_World) {
	game.store_destroy(&ew.store)
	game.spatial_destroy(&ew.spatial)
	for n in ew.tag_names {delete(n)}
	delete(ew.tag_names)
	delete(ew.deaths)
	ew^ = {}
}

// entity_world_begin_tick: the tick counts on and last tick's deaths go.
entity_world_begin_tick :: proc(ew: ^Entity_World) {
	ew.tick += 1
	clear(&ew.deaths)
}

// entity_world_spawn (entity_spawn adds the cap and the yaw) queues an entity of the kind at position (its bottom centre),
// with the components the kind asks for. Like every structural change it is
// seen by queries after store_apply; its id and handle are good at once.
entity_world_spawn :: proc(
	ew: ^Entity_World,
	reg: ^game.Registry,
	kind: game.Kind_Id,
	position: [3]f64,
	act: Act,
	want: game.Entity_Id = 0, // 0: the store's next id
	natural := false, // spawned by itself: it may despawn
) -> (
	id: game.Entity_Id,
	h: game.Entity_Handle,
	err: Spawn_Error,
) {
	info := game.kind_info(reg, kind)
	if info == nil {return 0, 0, .Unknown_Kind}
	st := &ew.store
	// the spawn, its adds and the spatial link all need ring room
	if game.store_count(st) >= st.max || len(st.commands) - st.cmd_count < 6 {return 0, 0, .Full}

	set := game.Component_Set {
		int(game.C_TRANSFORM),
		int(game.C_HEALTH),
		int(game.C_AGE),
		int(game.C_ORIGIN),
		int(C_SPATIAL_LINK),
	}
	if info.physics != .None {set += {int(game.C_PHYSICS)}}
	if .Wool in info.with {set += {int(game.C_WOOL)}}
	if .Genes in info.with {set += {int(game.C_GENES)}}
	if .Breeding in info.with {set += {int(game.C_BREEDING)}}
	if info.physics == .Item {set += {int(game.C_STACK), int(game.C_OWNER)}}
	if info.physics == .Projectile {set += {int(game.C_OWNER)}}
	if info.brain == .Grazer {set += {int(C_BRAIN)}}
	if info.hittable {set += {int(game.C_HURT_BY)}}
	if info.model == .Player {set += {int(game.C_PLAYER_LINK)}}
	if len(info.fields) > 0 {set += {int(game.C_FIELDS)}}
	if natural {set += {int(game.C_NATURAL)}}

	serr: game.Store_Error
	if want == 0 {
		id, h, serr = game.store_spawn(st, set, kind)
	} else {
		id, h, serr = game.store_spawn_with_id(st, set, want, kind)
	}
	switch serr {
	case .None:
	case .Id_Exhausted:
		return 0, 0, .Out_Of_Ids
	case .Stale, .Command_Ring_Full, .Pool_Full, .Large_Component:
		return 0, 0, .Full
	}

	half := f64(info.box[0]) / 2
	lo := [3]f64{position.x - half, position.y, position.z - half}
	hi := [3]f64{position.x + half, position.y + f64(info.box[1]), position.z + half}
	flags: game.Spatial_Flags
	if info.hittable {flags += {.Hittable}}
	if info.saved {flags += {.Saved}}
	if info.model == .Player {flags += {.Player}}
	if info.physics == .Item {flags += {.Item}}
	sh, ok := game.spatial_insert(
		&ew.spatial,
		{id = id, lo = lo, hi = hi, kind = u16(kind), flags = flags},
	)
	if !ok {
		// a kind's box is at most 4 (checked at load): this cannot happen
		_ = game.store_despawn(st, h)
		return 0, 0, .Full
	}

	tf := game.Transform {
		position = position,
	}
	hp := game.Entity_Health {
		health = i32(info.health),
	}
	origin := game.Origin {
		action = u32(act.action),
	}
	link := Spatial_Link {
		handle = sh,
	}
	_ = game.store_add(st, h, game.C_TRANSFORM, &tf)
	_ = game.store_add(st, h, game.C_HEALTH, &hp)
	_ = game.store_add(st, h, game.C_ORIGIN, &origin)
	_ = game.store_add(st, h, C_SPATIAL_LINK, &link)
	if .Breeding in info.with {
		breeding := game.Breeding {
			growth = game.LAMB_TICKS, // (an adult; a lamb is made lower)
		}
		_ = game.store_add(st, h, game.C_BREEDING, &breeding)
	}
	if info.physics == .Item || info.physics == .Projectile {
		owner := game.Owner {
			client = -1,
		}
		_ = game.store_add(st, h, game.C_OWNER, &owner)
	}
	return id, h, .None
}

@(private = "file")
tag_name_ok :: proc(name: string) -> bool {
	if len(name) == 0 || len(name) > MAX_TAG_NAME_LEN {return false}
	for c in transmute([]u8)name {
		switch c {
		case 'a' ..= 'z', '0' ..= '9', '_', ':':
		case:
			return false
		}
	}
	return true
}

// tag_index: the interned index (1-based) of name, interning it when new.
@(private = "file")
tag_index :: proc(ew: ^Entity_World, name: string, intern: bool) -> (u16, Tag_Error) {
	if !tag_name_ok(name) {return 0, .Bad_Name}
	for n, i in ew.tag_names {
		if n == name {return u16(i + 1), .None}
	}
	if !intern {return 0, .None}
	if len(ew.tag_names) >= MAX_TAG_NAMES {return 0, .Names_Full}
	append(&ew.tag_names, strings.clone(name))
	return u16(len(ew.tag_names)), .None
}

// entity_tag adds the tag name to an entity (already applied), a no-op when
// it has it. An entity's first tag adds the Tags component, deferred like
// any structural change: it shows after the next store_apply.
entity_tag :: proc(ew: ^Entity_World, h: game.Entity_Handle, name: string) -> Tag_Error {
	st := &ew.store
	if base.pool_get(&st.slots, h) == nil {return .Stale}
	idx, err := tag_index(ew, name, true)
	if err != .None {return err}
	tags := game.store_get(st, h, game.C_TAGS, game.Tags)
	if tags == nil {
		fresh := game.Tags{}
		fresh.tags[0] = idx
		if game.store_add(st, h, game.C_TAGS, &fresh) != .None {return .Stale}
		return .None
	}
	free := -1
	for t, i in tags.tags {
		if t == idx {return .None}
		if t == 0 && free < 0 {free = i}
	}
	if free < 0 {return .Tags_Full}
	tags.tags[free] = idx
	return .None
}

entity_untag :: proc(ew: ^Entity_World, h: game.Entity_Handle, name: string) {
	idx, _ := tag_index(ew, name, false)
	tags := game.store_get(&ew.store, h, game.C_TAGS, game.Tags)
	if idx == 0 || tags == nil {return}
	for &t in tags.tags {
		if t == idx {t = 0}
	}
}

entity_has_tag :: proc(ew: ^Entity_World, h: game.Entity_Handle, name: string) -> bool {
	idx, _ := tag_index(ew, name, false)
	tags := game.store_get(&ew.store, h, game.C_TAGS, game.Tags)
	if idx == 0 || tags == nil {return false}
	for t in tags.tags {
		if t == idx {return true}
	}
	return false
}

// entity_tag_near adds (or removes) a tag on every entity of a kind (0: any)
// within radius of center, and returns how many it changed. It stops at the
// first error (a bad name, a full name table or a full entity).
entity_tag_near :: proc(
	ew: ^Entity_World,
	kind: game.Kind_Id,
	center: [3]f64,
	radius: f64,
	add: bool,
	name: string,
) -> (
	count: int,
	err: Tag_Error,
) {
	found := make([dynamic]game.Entity_Id, context.temp_allocator)
	game.spatial_sphere(&ew.spatial, center, radius, {kind = u16(kind)}, &found)
	for id in found {
		h, ok := game.store_find(&ew.store, id)
		if !ok {continue}
		if add {
			if err = entity_tag(ew, h, name); err != .None {return}
		} else {
			entity_untag(ew, h, name)
		}
		count += 1
	}
	return
}

// entity_hurt takes amount from the entity's health, remembering who did it
// (by: 0 for nobody), and kills it at zero. False for a stale handle or an
// entity without health.
entity_hurt :: proc(
	ew: ^Entity_World,
	h: game.Entity_Handle,
	amount: i32,
	act: Act,
	by: game.Entity_Id,
	cause: u8 = 0,
) -> bool {
	st := &ew.store
	hp := game.store_get(st, h, game.C_HEALTH, game.Entity_Health)
	if hp == nil {return false}
	hurt := game.Hurt_By {
		action = u32(act.action),
		entity = by,
		cause  = cause,
		tick   = ew.tick,
	}
	if hb := game.store_get(st, h, game.C_HURT_BY, game.Hurt_By); hb != nil {hb^ = hurt}
	hp.health -= amount
	if hp.health <= 0 {
		hp.health = 0
		entity_kill(ew, h, cause, act)
	}
	return true
}

// entity_kill records the death (with the killer named by Hurt_By within 10 s)
// and despawns the entity. Every death goes through here.
entity_kill :: proc(ew: ^Entity_World, h: game.Entity_Handle, cause: u8, act: Act) {
	st := &ew.store
	tf := game.store_get(st, h, game.C_TRANSFORM, game.Transform)
	if tf == nil {return}
	death := Entity_Death {
		kind     = game.store_kind(st, h),
		position = tf.position,
		cause    = cause,
		act      = act,
	}
	if s := base.pool_get(&st.slots, h); s != nil {
		if s.dying {return} 	// already dying: one death
		death.id = s.id
	}
	if hb := game.store_get(st, h, game.C_HURT_BY, game.Hurt_By);
	   hb != nil && hb.entity != 0 && ew.tick - hb.tick <= HURT_KEPT_TICKS {
		death.killer = hb.entity
	}
	if game.store_despawn(st, h) != .None {return}
	append(&ew.deaths, death)
}

// world_entity_spawn is entity_world_spawn for a caller with chunks: it
// refuses a position whose chunk (or the one below) is not ready.
world_entity_spawn :: proc(
	w: ^World,
	kind: game.Kind_Id,
	position: [3]f64,
	act: Act,
) -> (
	id: game.Entity_Id,
	h: game.Entity_Handle,
	err: Spawn_Error,
) {
	if !chunk_ready(w, position) {return 0, 0, .Not_Loaded}
	return entity_world_spawn(w.entity_world, w.server.registry, kind, position, act)
}

// world_entity_kill is entity_kill, then the Entity_Died event to every
// playing client of the world that knew the entity.
world_entity_kill :: proc(w: ^World, h: game.Entity_Handle, cause: u8, act: Act) {
	ew := w.entity_world
	before := len(ew.deaths)
	entity_kill(ew, h, cause, act)
	if len(ew.deaths) == before {return}
	s := w.server
	died := game.Entity_Died{u32(ew.deaths[before].id)}
	for &c in s.clients {
		if c.state == .Playing && c.world == w && entity_known(&c, died.entity) {
			event_send(s, &c, .Entity_Died, &died)
		}
	}
}

// --- Players as entities -----------------------------------------------------


// Players as entities: each playing client has an entity of the kind
// voxiverse:player in its world's entity world, so everything else finds
// players through the spatial service. The player's movement stays
// game.player_step on Client.player; the entity only follows it. The entity
// is spawned when the client arrives in a world and despawned when it leaves
// (travels, goes) or the world closes.

PLAYER_ID_BASE :: 1 << 30

// player_entity_sync (after simulate_player) keeps c's player entity: spawned
// in c's world if it has none there, its Transform and spatial box following
// c.player. An entity just spawned shows after the world's next store_apply
// (it is made at c.player.position, so it is right from the start).
player_entity_sync :: proc(s: ^Server, c: ^Client) {
	w := c.world
	if c.entity_id != 0 && c.entity_world != w {player_entity_release(s, c)}
	ew := w.entity_world
	if c.entity_id == 0 {
		kind, ok := game.registry_kind(s.registry, "player")
		if !ok {return}
		// (ids above the world's own: no other entity has one)
		ew.next_player_id += 1
		want := game.Entity_Id(PLAYER_ID_BASE + ew.next_player_id)
		id, _, err := entity_world_spawn(ew, s.registry, kind, c.player.position, {}, want)
		if err != .None {return}
		c.entity_id, c.entity_world = id, w
		return
	}
	h, found := game.store_find(&ew.store, c.entity_id)
	if !found {return}
	tf := game.store_get(&ew.store, h, game.C_TRANSFORM, game.Transform)
	if tf == nil {return} 	// not applied yet
	tf.position = c.player.position
	tf.yaw, tf.pitch = c.look[0], c.look[1]
	if link := game.store_get(&ew.store, h, game.C_PLAYER_LINK, game.Player_Link); link != nil {
		link.client = player_id(s, c)
	}
	if sl := game.store_get(&ew.store, h, C_SPATIAL_LINK, Spatial_Link); sl != nil {
		half := f64(game.PLAYER_WIDTH) / 2
		p := c.player.position
		game.spatial_move(
			&ew.spatial,
			sl.handle,
			{p.x - half, p.y, p.z - half},
			{p.x + half, p.y + f64(game.PLAYER_HEIGHT), p.z + half},
		)
	}
}

// player_entity_release despawns c's player entity (if its world is still
// open: a closed world took it along).
player_entity_release :: proc(s: ^Server, c: ^Client) {
	defer {c.entity_id, c.entity_world = 0, nil}
	if c.entity_id == 0 {return}
	open := false
	for w in s.worlds {open ||= w == c.entity_world}
	if !open {return}
	ew := c.entity_world.entity_world
	if h, ok := game.store_find(&ew.store, c.entity_id); ok {_ = game.store_despawn(&ew.store, h)}
}

// player_entities_release: the entities of clients that are no longer
// playing, or are in another world, go (before idle worlds unload).
player_entities_release :: proc(s: ^Server) {
	for &c in s.clients {
		if c.entity_id != 0 && (c.state != .Playing || c.world != c.entity_world) {
			player_entity_release(s, &c)
		}
	}
}

// ---- the door (everything outside this file uses these) ----

// The entities are the store's rows that are not players (a player's entity
// is the client's own, see player_entity_sync). Every walk is in id order.

// entity_listed: h is an entity of the world, not a player.
entity_listed :: proc(w: ^World, h: game.Entity_Handle) -> bool {
	slot := base.pool_get(&w.entity_world.store.slots, h)
	if slot == nil || slot.dying {return false} 	// (a despawn is queued: gone to every walk)
	return game.store_get(&w.entity_world.store, h, game.C_PLAYER_LINK, game.Player_Link) == nil
}

// entity_count: how many entities the world holds.
entity_count :: proc(w: ^World) -> int {
	n := 0
	it: base.Pool_Iterator
	for _, h in base.pool_next(&w.entity_world.store.slots, &it) {
		if entity_listed(w, h) {n += 1}
	}
	return n
}

// entity_get: the entity with this id.
entity_get :: proc(w: ^World, id: u32) -> (game.Entity_Handle, bool) {
	return entity_find(w, id)
}

// entity_kind: the kind of the entity (0 for a stale handle).
entity_kind :: proc(w: ^World, h: game.Entity_Handle) -> game.Kind_Id {
	if s := base.pool_get(&w.entity_world.store.slots, h); s != nil {return s.kind}
	return 0
}

// entity_id: the id of the entity (0 for a stale handle).
entity_id :: proc(w: ^World, h: game.Entity_Handle) -> u32 {
	if s := base.pool_get(&w.entity_world.store.slots, h); s != nil {return u32(s.id)}
	return 0
}

// Entity_Iter walks a snapshot of the entities, lowest id first.
Entity_Iter :: struct {
	w:       ^World,
	handles: []game.Entity_Handle, // in the temp allocator
	i:       int,
}

// entities_each starts a walk: `it := entities_each(w); for e, i in entities_next(&it)`,
// over the entities that stand now (those with an id above `after`). One
// despawned during the walk is skipped; one spawned during it is not walked.
entities_each :: proc(w: ^World, after: u32 = 0) -> Entity_Iter {
	Row :: struct {
		id: u32,
		h:  game.Entity_Handle,
	}
	rows := make([dynamic]Row, context.temp_allocator)
	it: base.Pool_Iterator
	for _, h in base.pool_next(&w.entity_world.store.slots, &it) {
		if id := entity_id(w, h); id > after && entity_listed(w, h) {append(&rows, Row{id, h})}
	}
	// ids order them (handles are slot places, reused)
	slice.sort_by(rows[:], proc(a, b: Row) -> bool {return a.id < b.id})
	handles := make([]game.Entity_Handle, len(rows), context.temp_allocator)
	for r, i in rows {handles[i] = r.h}
	return {w = w, handles = handles}
}

entities_next :: proc(it: ^Entity_Iter) -> (h: game.Entity_Handle, index: int, ok: bool) {
	for it.i < len(it.handles) {
		index = it.i
		it.i += 1
		h = it.handles[index]
		if slot := base.pool_get(&it.w.entity_world.store.slots, h); slot != nil && !slot.dying {
			return h, index, true
		}
	}
	return
}

// entities_snapshot: the entities that stand now, lowest id first (in the
// temp allocator).
entities_snapshot :: proc(w: ^World) -> []game.Entity_Handle {
	return entities_each(w).handles
}

// entities_clear despawns every entity (players stay).
entities_clear :: proc(w: ^World) {
	it := entities_each(w)
	for h in entities_next(&it) {_ = game.store_despawn(&w.entity_world.store, h)}
	game.store_apply(&w.entity_world.store)
}

// --- Systems -----------------------------------------------------------------

// The entity systems: what entities do each tick. Each is a procedure over the entities
// whose pack data gives them its components (the kind's `physics`, `brain` and
// `with`), never over a kind by name, and they run in this fixed order:
//
//  1. age: every entity grows a tick older; a natural one nobody is near goes.
//  2. brains (grazer): a sheep's clocks, its thinking (which includes mating and
//     the lamb) and its steering; the wish goes to the walkers' physics.
//  3. walkers' physics: every walker takes its step (the wish its brain made,
//     none for a walker without a brain).
//  4. items: a dropped stack expires, falls, merges and is picked up.
//  5. rockets: a projectile flies and hits (its explosion waits for the end).
//  6. explosions: those the rockets made go off, changing the set.
//
// A walker whose ground is not loaded waits, frozen, until it is.

@(private = "file")
Blast :: struct {
	sphere: Sphere,
	action: Action_Id,
}

@(private = "file")
Wish :: struct {
	wish: [2]f32,
	jump: bool,
}

// entities_tick: spawning, despawning, thinking and moving, every tick.
entities_tick :: proc(w: ^World) {
	base.profile_scope("entities")
	s := w.server
	w.entities.budget = PATH_BUDGET_PER_TICK
	entity_world_begin_tick(w.entity_world)
	defer {
		game.store_apply(&w.entity_world.store)
		entities_sync_spatial(w)
	}
	if s.tick % SPAWN_EVERY == 0 {spawn_natural(w)}
	query := game.Block_Query{&w.chunks, chunks_block, &w.server.registry.blocks, {}}
	blasts := make([dynamic]Blast, context.temp_allocator)
	wishes := make(map[game.Entity_Handle]Wish, context.temp_allocator)
	system_age(w)
	system_brains(w, &wishes)
	system_walkers(w, &wishes, query)
	system_items(w)
	system_rockets(w, &blasts)
	// After the walk: explosions change the set.
	for b in blasts {explode(w, b.sphere.center, b.sphere.radius, b.action)}
}

// system_age: one tick older; a natural entity with nobody near goes.
@(private = "file")
system_age :: proc(w: ^World) {
	it := entities_each(w)
	for h in entities_next(&it) {
		entity_set_age(w, h, entity_age_of(w, h) + 1)
		if entity_is_natural(w, h) && !anyone_within(w, entity_pos(w, h), DESPAWN_DISTANCE) {
			entity_gone(w, h)
		}
	}
}

@(private = "file")
kind_of :: proc(w: ^World, h: game.Entity_Handle) -> ^game.Kind_Info {
	return game.kind_info(w.server.registry, entity_kind(w, h))
}

// system_brains: the grazers. Entities in id order; one spawned during the
// walk (a lamb) has a higher id and is walked in this same tick, after the
// ones that were there.
@(private = "file")
system_brains :: proc(w: ^World, wishes: ^map[game.Entity_Handle]Wish) {
	walked: u32
	for {
		it := entities_each(w, after = walked)
		any := false
		for h in entities_next(&it) {
			any = true
			walked = max(walked, entity_id(w, h))
			if kind_of(w, h).brain != .Grazer || !chunk_ready(w, entity_pos(w, h)) {continue}
			sheep_life(w, h)
			think(w, h)
			wish, jump := steer(w, h)
			wishes[h] = {wish, jump}
		}
		if !any {break}
	}
}

// system_walkers: the physics of everything that walks.
@(private = "file")
system_walkers :: proc(w: ^World, wishes: ^map[game.Entity_Handle]Wish, query: game.Block_Query) {
	it := entities_each(w)
	for h in entities_next(&it) {
		info := kind_of(w, h)
		if info.physics != .Walker || !chunk_ready(w, entity_pos(w, h)) {continue}
		wish := wishes[h] or_else {}
		entity_body_step(w, h, info, wish.wish, wish.jump, query)
	}
}

@(private = "file")
system_items :: proc(w: ^World) {
	it := entities_each(w)
	for h in entities_next(&it) {
		if kind_of(w, h).physics == .Item && item_tick(w, h) {entity_gone(w, h)}
	}
}

@(private = "file")
system_rockets :: proc(w: ^World, blasts: ^[dynamic]Blast) {
	it := entities_each(w)
	for h in entities_next(&it) {
		info := kind_of(w, h)
		if info.physics != .Projectile {continue}
		if at, hit := rocket_step(w, h); hit {
			append(
				blasts,
				Blast{{at, f64(info.projectile.explode)}, Action_Id(entity_owner(w, h).action)},
			)
			entity_died(w, h) // its explosion is what players see
		}
	}
}
