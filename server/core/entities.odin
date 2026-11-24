package core

import "core:log"
import "core:math"
import "core:slice"
import "core:strings"

import "common:base"
import "common:game"
import "common:protocol"
import "server:path"

// Entities on the server: creatures, dropped stacks and rockets. What each kind is lies
// in the registry (game.kind_info); what it does each tick, in the systems (below). A
// creature's mind is its game's (Game.think) or its game's steering (walkers.odin): it
// walks its path (A*, server/path, within a shared node budget) and moves by the shared
// body physics; a rocket flies until it hits something and explodes. Each client is
// told about the ones near it: an Entity record (what it is) and an Entity_Motion record
// (where, how it looks) while it is near (the records go when it leaves), and an
// Entity_Died event when it dies. A kind with a spawn rule in its pack appears by itself
// around players and goes when nobody is near (spawn_natural); one whose ground is not
// loaded waits, frozen, until it is. Saved kinds are kept with the world (save.odin:
// entities.cfg).

MAX_ENTITIES :: 2048
ENTITY_VIEW :: 64 // blocks: a client is told about entities this near (horizontally)
ANY_HEIGHT :: 4096 // half a cylinder's height: no vertical limit
PATH_BUDGET_PER_TICK :: 1500 // A* nodes for all entities in one tick
PATH_BUDGET_EACH :: 400

Entities :: struct {
	lookups: int, // id lookups made (a test counts them)
	next_id: u32,
	budget:  int, // A* nodes left this tick (the steered walkers')
	rng:     base.Rng,
	walkers: Walkers, // the routes and changed blocks of the walkers games steer (walkers.odin)
}

entities_init :: proc(e: ^Entities, seed: i64) {
	e.next_id = 1
	e.rng = base.rng_make(u64(seed) ~ 0x0e7e_0e7e)
	walkers_init(&e.walkers)
}

entities_destroy :: proc(e: ^Entities) {
	walkers_destroy(&e.walkers)
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
	if kind_of_game(w.server, kind) {
		zero: game.Entity_Data
		_ = game.store_add(&w.entity_world.store, h, C_GAME_DATA, &zero)
	}
	// applied at once, so the components exist when the caller has the entity
	game.store_apply(&w.entity_world.store)
	entity_set_yaw(w, h, base.rng_f32_range(&e.rng, -math.PI, math.PI))
	return h
}

// kind_of_game: the kind is the game's own (its pack's: `<game>:<name>`) and the game
// keeps a record on each (Game.entity_data).
kind_of_game :: proc(s: ^Server, kind: game.Kind_Id) -> bool {
	if s.config.game.entity_data == nil {return false}
	info := game.kind_info(s.registry, kind)
	id := s.config.game.id
	return(
		info != nil &&
		len(info.id) > len(id) &&
		info.id[len(id)] == ':' &&
		info.id[:len(id)] == id \
	)
}

// entity_data: the game's record on an entity of its kinds (Game.entity_data, as the
// type it declared): zero when the entity came to be, saved and loaded with the world
// (entities.cfg, field by field), told to no one unless the game puts it in a record of
// its own keyed by the entity (protocol.key_entity). nil for an entity of another kind.
entity_data :: proc(w: ^World, h: game.Entity_Handle, $T: typeid) -> ^T {
	assert(w.server.config.game.entity_data == T, "not the game's entity_data")
	p := game.store_get(&w.entity_world.store, h, C_GAME_DATA, game.Entity_Data)
	return (^T)(&p.bytes) if p != nil else nil
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

// entity_looks: what clients are told about how an entity looks: bit i is its kind's i-th
// look, as its game set it (entity_show), and "striking" while its attack shows.
entity_looks :: proc(w: ^World, reg: ^game.Registry, h: game.Entity_Handle) -> (bits: u16) {
	info := game.kind_info(reg, entity_kind(w, h))
	if info == nil {return}
	if set := game.store_get(&w.entity_world.store, h, C_LOOKS, Looks);
	   set != nil {bits = set.bits}
	if info.striking != 0 && entity_striking(w, h) {bits |= info.striking}
	return
}

// Looks: the looks a game set on an entity (entity_show), bit i its kind's i-th.
Looks :: struct {
	bits: u16,
}

// entity_show: a look of the entity's kind (its pack's "looks", by name) shown or not:
// told to the players who know it, drawn as the kind's model says (a part shown or
// hidden, a colour, a size). False when its kind has no such look.
entity_show :: proc(w: ^World, h: game.Entity_Handle, look: string, on: bool) -> bool {
	bit := game.kind_look(game.kind_info(w.server.registry, entity_kind(w, h)), look)
	set := game.store_get(&w.entity_world.store, h, C_LOOKS, Looks)
	if bit == 0 || set == nil {return false}
	if on {set.bits |= bit} else {set.bits &~= bit}
	return true
}

// use_entity: a player uses an entity within its reach (a right click) with what it
// holds: what the use does is the game's entity_use hook's, judged as editing judges a
// block's change (it does what the use does for its own kinds; a refusal is told). The
// engine's own kinds are not used.
use_entity :: proc(s: ^Server, c: ^Client, id: u32) {
	h, _ := entity_find(c.world, id)
	if h == 0 || !entity_reachable(c, h) {return}
	if hook := s.config.game.entity_use; hook != nil {
		if refusal := hook(s, c, h, game.inventory_held(&c.inventory)); refusal != "" {
			notice(s, c, refusal)
		}
	}
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
	owner := entity_owner(c.world, h)
	owner.client, owner.generation = i32(player_id(s, c)), c.generation
	entity_owner(c.world, h).action = u32(action_begin(c.world, actor_of(s, c), .Explosion))
	record(s, c, .Rocket_Fired)
	return true
}

// explode: a blast at center. Everyone near is shown it, the sphere is
// carved (where loaded), and what is near is thrown (and hurt). size is its
// radius as the world's rules scale it: times explosion_size, the throw times
// explosion_throw. by: the player who set it off (a rocket's shooter), whom
// the players it hurts are told of and whose kill one is (damage.odin).
explode :: proc(w: ^World, center: [3]f64, size: f64, action: Action_Id, by: Maybe(u16) = nil) {
	s := w.server
	radius := size * f64(w.rules.explosion_size)
	throw := w.rules.explosion_throw
	record_world(s, w, .Explosion, n0 = i64(radius))
	for i in players_near(w, center, 160 + PLAYER_MARGIN, ANY_HEIGHT) {
		c := &s.clients[i]
		d := c.player.position - center
		if d.x * d.x + d.z * d.z < 160 * 160 {
			blast := protocol.Explosion{center, f32(radius)}
			event_send(s, c, .Explosion, &blast)
		}
	}
	bulk_edit(
		w,
		{shape = Sphere{center, radius}, op = .Carve, partial = true},
		{action, .Explosion},
	)
	reach := 2 * radius
	push :: proc(at, center: [3]f64, reach: f64, throw: f32) -> (impulse: [3]f32, ok: bool) {
		d := at - center
		l := math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
		if l >= reach {return}
		if l < 1e-6 {d, l = {0, 1, 0}, 1}
		dir := d / l
		strength := f32(1 - l / reach) * 16
		impulse = {f32(dir.x), f32(dir.y), f32(dir.z)} * strength + {0, 4, 0}
		return impulse * throw, true
	}
	for i in players_near(w, center, reach + PLAYER_MARGIN, reach + PLAYER_MARGIN) {
		c := &s.clients[i]
		if impulse, near := push(c.player.position + {0, 0.9, 0}, center, reach, throw); near {
			c.player.velocity += impulse
			disturb(s, c)
			c.player.on_ground = false
			d := c.player.position + {0, 0.9, 0} - center
			distance := math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
			damage(
				s,
				c,
				f32(1 - distance / reach) * 12,
				{kind = .Explosion, attacker = by, pos = center, placed = true},
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
		impulse, near := push(entity_pos(w, h) + {0, 0.4, 0}, center, reach, throw)
		if !near || !game.kind_info(w.server.registry, entity_kind(w, h)).hittable {continue}
		entity_set_velocity(w, h, entity_velocity(w, h) + impulse)
		entity_set_on_ground(w, h, false)
		d := entity_pos(w, h) - center
		harm := Entity_Harm {
			amount = 3 if d.x * d.x + d.y * d.y + d.z * d.z < radius * radius else 1,
			kind   = .Explosion,
			from   = center,
		}
		if seat, set := by.?; set && int(seat) < len(s.clients) {harm.by = &s.clients[seat]}
		entity_harm(w, h, harm)
	}
}

// ROCKET_REACH: how far past a rocket's step a box can be and still be
// tested: a tall box's height, and a tick of its owner's or a target's running.
ROCKET_REACH :: 4

// Shot_Hit: what a projectile's step met: a player (its seat) or an entity (its id),
// or neither (a block, its life's end, the edge of the loaded world).
Shot_Hit :: struct {
	player: int, // -1: none
	entity: u32, // 0: none
}

// rocket_step flies a projectile one tick; where it hit, and what, if it did. It flies
// through the creature that shot it.
rocket_step :: proc(w: ^World, h: game.Entity_Handle) -> (at: [3]f64, hit: bool, what: Shot_Hit) {
	what.player = -1
	s := w.server
	if f32(entity_age_of(w, h)) * game.TICK_SECONDS >
	   game.kind_info(s.registry, entity_kind(w, h)).projectile.life {return entity_pos(w, h), true, what}
	v := entity_velocity(w, h)
	v.y -= game.kind_info(s.registry, entity_kind(w, h)).projectile.gravity * game.TICK_SECONDS
	entity_set_velocity(w, h, v)
	speed := math.sqrt(f64(v.x * v.x + v.y * v.y + v.z * v.z))
	if speed < 1e-6 {return entity_pos(w, h), true, what}
	dir := [3]f64{f64(v.x), f64(v.y), f64(v.z)} / speed
	step := speed * f64(game.TICK_SECONDS)
	from := entity_pos(w, h) + {0, 0.15, 0}
	nearest := step
	hit_at: [3]f64
	query := game.Block_Query{&w.chunks, chunks_block, &w.server.registry.blocks, {}}
	if b, ok := game.raycast(query, from, dir, step); ok {
		nearest, hit_at, hit = b.distance, from + dir * b.distance, true
	} else if !chunk_ready(w, from) {
		return from, true, what // flew out of the loaded world
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
	shooter := entity_owner(w, h).entity
	for id in near {
		if u32(id) == shooter && shooter != 0 {continue}
		other, there := entity_find(w, u32(id))
		if !there {continue}
		oinfo := game.kind_info(s.registry, entity_kind(w, other))
		if !oinfo.hittable {continue}
		lo, hi := game.entity_box(oinfo, entity_pos(w, other))
		if d, ok := game.ray_box(from, dir, lo, hi, nearest); ok {
			nearest, hit_at, hit = d, from + dir * d, true
			what = {-1, u32(id)}
		}
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
		if d, ok := game.ray_box(from, dir, lo, hi, nearest); ok {
			nearest, hit_at, hit = d, from + dir * d, true
			what = {i, 0}
		}
	}
	if hit {return hit_at, true, what}
	entity_set_pos(w, h, entity_pos(w, h) + dir * step)
	entity_set_yaw(w, h, f32(math.atan2(-dir.x, -dir.z)))
	entity_set_pitch(w, h, clamp(f32(math.asin(clamp(dir.y, -1, 1))), -1.5, 1.5)) // within the protocol's limit
	return {}, false, what
}

forward :: proc(yaw, pitch: f32) -> [3]f64 {
	cp := base.cos(f64(pitch))
	return {-base.sin(f64(yaw)) * cp, base.sin(f64(pitch)), -base.cos(f64(yaw)) * cp}
}

// entity_attack: a player hits an entity (the reach is checked by the
// caller): knocked back and harmed (entity_harm, told where from). True: it died.
entity_attack :: proc(
	w: ^World,
	h: game.Entity_Handle,
	from: [3]f64,
	harm: Entity_Harm,
) -> (
	died: bool,
) {
	away := entity_pos(w, h) - from
	l := math.sqrt(away.x * away.x + away.z * away.z)
	if l > 1e-6 {away /= l} else {away = {1, 0, 0}}
	kb := game.ATTACK_KNOCKBACK
	entity_set_velocity(w, h, {f32(away.x) * kb[0], kb[1], f32(away.z) * kb[0]})
	entity_set_on_ground(w, h, false)
	harm := harm
	harm.from = from
	return entity_harm(w, h, harm)
}

// Entity_Harm: what hurt an entity, as a game's entity_hurt and entity_died hooks are
// told it.
Entity_Harm :: struct {
	amount:   int, // the health it took
	kind:     game.Source_Kind, // a hit, an explosion, a weapon, the game...
	by:       ^Client, // the player who did it (nil: nobody, or the game itself)
	creature: u32, // the entity that did it (its id; 0: none; it may be gone)
	weapon:   string, // what a shot came from: its item's name ("" for any other)
	stack:    game.Stack, // what the player struck or shot with (empty: nothing, or no player)
	from:     [3]f64, // where it came from: the striker, the shooter, the blast's centre (zero: the game's own, unless it says)
}

// Dead_Entity: an entity that died, as the entity_died hook is told it (it is gone
// from the world by then: its handle finds nothing).
Dead_Entity :: struct {
	id:       u32,
	kind:     game.Kind_Id,
	position: [3]f64,
}

// entity_harm takes harm.amount from an entity's health. Alive, everyone who knows it
// sees it flinch and the game's entity_hurt hook is told; at nought it dies (everyone
// who knew it sees it die), leaves its kind's drops (entity_drops) and the game's
// entity_died hook is told. True: it died. The one way an entity is hurt: a player's hit
// or shot, a blast, a game's tower.
entity_harm :: proc(w: ^World, h: game.Entity_Handle, harm: Entity_Harm) -> (died: bool) {
	if !entity_listed(w, h) || harm.amount <= 0 {return false}
	hp := entity_health(w, h)
	if hp == nil {return false}
	s := w.server
	g := &s.config.game
	harm := harm
	changed := harming(
		s,
		{
			amount = f32(harm.amount),
			kind = harm.kind,
			by = harm.by,
			creature = harm.creature,
			stack = harm.stack,
			entity = h,
			world = w,
		},
	)
	harm.amount = int(math.round(changed))
	if harm.amount <= 0 {return false}
	hp.health -= i32(harm.amount)
	if hp.health > 0 {
		entity_hurt_shown(w, entity_id(w, h))
		if g.entity_hurt != nil {g.entity_hurt(s, w, h, harm)}
		return false
	}
	hp.health = 0
	dead := Dead_Entity{entity_id(w, h), entity_kind(w, h), entity_pos(w, h)}
	entity_died(w, h)
	entity_drops(w, dead, harm.by)
	if harm.by != nil {quest_note(s, harm.by, {goal = .Kill, creature = dead.kind, count = 1})}
	if g.entity_died != nil {g.entity_died(s, w, dead, harm)}
	return true
}

// entity_drops: what a creature that died leaves where it fell, by its kind's drops: of
// each, on a draw of its chance (as the skills of the player who killed it, `by`, make it:
// its drop_chance), a count drawn between its least and its most, from the world's
// entities' randomness (so the same in every run), booked as a creature's drop. One gone
// without dying (entity_gone, despawned, a command's kill) leaves nothing.
entity_drops :: proc(w: ^World, dead: Dead_Entity, by: ^Client = nil) {
	s := w.server
	info := game.kind_info(s.registry, dead.kind)
	if info == nil {return}
	r := &w.entities.rng
	at := dead.position + {0, f64(info.box[1]) * 0.5, 0}
	for d in info.drops {
		chance := d.chance
		if by != nil {chance = game.skill_value(s.registry, &by.skills, .Drop_Chance, chance)}
		if base.rng_f32(r) >= chance {continue}
		n := base.rng_int_range(r, d.count[0], d.count[1] + 1)
		for n > 0 {
			st := game.Stack {
				item  = d.item,
				count = min(n, game.item_stack_size(s.registry, d.item)),
				ammo  = game.new_ammo(s.registry, d.item),
			}
			n -= st.count
			ledger_stack(s, w, .Drop_Mob, st)
			spawn_item(w, at, st, {0, 3, 0}, -1)
		}
	}
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

// entity_yaw: which way the entity faces, radians turning left from -z (0: gone).
entity_yaw :: proc(w: ^World, h: game.Entity_Handle) -> f32 {
	if tf := entity_transform(w, h); tf != nil {return tf.yaw}
	return 0
}

// entity_pitch: how far the entity looks up, radians (down below 0; 0: gone).
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

// entity_set_look: the entity turns to face yaw and look up pitch (radians, as entity_yaw
// and entity_pitch give them).
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
// for one without it (a rocket has no stack) it returns a scratch value that is
// reset on every call, so reads see the default and a stray write goes nowhere.
@(thread_local, private = "file")
scratch_stack: game.Component_Stack
@(thread_local, private = "file")
scratch_owner: game.Owner

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

// entity_health_of: the entity's health points (0: it has no health, or is gone).
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

// entities_put tells a client about the entities near it (in a world with fog, a
// player on a team: those its team sees; on none: those on no team near it, sides.odin): what each is and where (a view:
// an entity out of its area, or gone from the world, is removed by not being put).
entities_put :: proc(s: ^Server, c: ^Client) {
	w := c.world
	// The entities within ENTITY_VIEW horizontally (players are not told as
	// entities), the nearest first, at most MAX_KNOWN_ENTITIES of them (ties by
	// id): past the cap a crowd far off gives way to what is near. (The receiver
	// holds a kind's cap per whole message, so the set swapping its farthest for a
	// nearer one in one message is no overflow.)
	around := make([dynamic]game.Entity_Id, context.temp_allocator)
	if w.fog && c.team != 0 {
		// Under fog a player on a team is told of what its team sees, wherever it is
		// (sides.odin), and of nothing else.
		it := entities_each(w)
		for h in entities_next(&it) {
			if entity_seen(w, c.team, h) {append(&around, game.Entity_Id(entity_id(w, h)))}
		}
	} else {
		game.spatial_cylinder(
			&w.entity_world.spatial,
			c.player.position,
			ENTITY_VIEW,
			ANY_HEIGHT,
			{none = {.Player}},
			&around,
		)
		if w.fog {
			// On no side under fog: what is on no team near it, nothing a side has.
			kept := 0
			for id in around {
				if h, ok := entity_find(w, u32(id)); ok && entity_team(w, h) == 0 {
					around[kept] = id
					kept += 1
				}
			}
			resize(&around, kept)
		}
	}
	if len(around) > protocol.MAX_KNOWN_ENTITIES {nearest_first(w, c.player.position, around[:])}
	for id in around[:min(len(around), protocol.MAX_KNOWN_ENTITIES)] {
		h, _ := entity_find(w, u32(id))
		if h == 0 {continue}
		key := protocol.key_entity(u32(id))
		record := protocol.Entity_Record {
			kind  = entity_kind(w, h),
			stack = entity_stack(w, h)^,
		}
		if side := game.store_get(&w.entity_world.store, h, C_SIDE, Side); side != nil {
			record.team, record.vision = side.team, side.vision
		}
		if hp := entity_health(w, h); hp != nil {
			record.health = u16(clamp(hp.health, 0, 65535))
			record.max_health = u16(clamp(hp.max, 0, 65535))
		}
		state_put(s, c, .Entity, &record, key)
		if info := game.kind_info(s.registry, record.kind); info != nil && info.hittable {
			if game.logbook_meet(&c.logbook, record.kind) { 	// (a creature in its view: met)
				experience_gain(s, c, u64(s.registry.progression.xp[.Meet]))
			}
		}
		motion := protocol.Entity_Motion {
			entity_pos(w, h),
			entity_yaw(w, h),
			entity_pitch(w, h),
			entity_looks(w, s.registry, h),
		}
		if at, yaw, gliding := glide_shown(w, h); gliding {motion.position, motion.yaw = at, yaw}
		state_put(s, c, .Entity_Motion, &motion, key)
	}
}

// nearest_first sorts ids by their horizontal distance from p, the nearest first (ties
// by id: the same order every tick for the same places).
@(private = "file")
nearest_first :: proc(w: ^World, p: [3]f64, ids: []game.Entity_Id) {
	Near :: struct {
		d:  f64,
		id: game.Entity_Id,
	}
	near := make([]Near, len(ids), context.temp_allocator)
	for id, i in ids {
		near[i] = {1e18, id}
		if h, ok := game.store_find(&w.entity_world.store, id); ok {
			d := entity_pos(w, h) - p
			near[i].d = d.x * d.x + d.z * d.z
		}
	}
	slice.sort_by(near, proc(a, b: Near) -> bool {return a.d < b.d || (a.d == b.d && a.id < b.id)})
	for n, i in near {ids[i] = n.id}
}

// entity_known: c has been told about entity id (it is in its view).
entity_known :: proc(c: ^Client, id: u32) -> bool {
	return(
		c.tx.schema != nil &&
		protocol.replica_get(
			&c.tx.sent,
			int(protocol.State_Kind.Entity),
			protocol.key_entity(id),
		) !=
			nil \
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
				death := protocol.Entity_Died{id}
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
			hurt := protocol.Entity_Hurt{id}
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
		ANY_HEIGHT + 4,
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
		if path.standable(query, p) {
			if h := entity_spawn(w, kind, {f64(p.x) + 0.5, f64(p.y), f64(p.z) + 0.5}, false);
			   h != 0 {
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

// spawn_natural: the creatures of every kind with a spawn rule (its pack's `spawn`)
// appear by themselves around the players of the world: every `every` ticks within its
// hours (a night's run past midnight), near each player with fewer than `cap` of the kind
// within `within` blocks, on a draw of `chance`, a group of `group` at a place `distance`
// blocks away whose ground is `on` (under the open sky, for a rule that says `sky`), no
// player is nearer than its least distance and that is not within `safe` blocks of the
// world's spawn point; in its column, where its `place` says (spawn_spot: on the surface,
// in water, in a cave). Each is natural (it goes when nobody is near: system_age) and is
// told to the game's `spawned` hook, which may make it what it is or refuse it (it goes
// again).
spawn_natural :: proc(w: ^World) {
	s := w.server
	if s.config.no_natural_spawns {return}
	day := game.time_of_day(w.clock)
	r := &w.entities.rng
	query := game.Block_Query{&w.chunks, chunks_block, &w.server.registry.blocks, {}}
	for &info, i in s.registry.kinds {
		rule, has := info.spawn.?
		kind := game.Kind_Id(i + 1)
		if !has || s.tick % u64(rule.every) != 0 {continue}
		if !spawn_hours(rule.day, day) {continue}
		for &c in s.clients {
			if c.state != .Playing || c.world != w {continue}
			around := make([dynamic]game.Entity_Id, context.temp_allocator)
			game.spatial_cylinder(
				&w.entity_world.spatial,
				c.player.position,
				f64(rule.within),
				ANY_HEIGHT,
				{kind = u16(kind)},
				&around,
			)
			if len(around) >= rule.cap || base.rng_f32(r) > rule.chance {continue}
			angle := base.rng_f64_range(r, 0, math.TAU)
			distance := base.rng_f64_range(r, f64(rule.distance[0]), f64(rule.distance[1]))
			x := i32(math.floor(c.player.position.x + base.cos(angle) * distance))
			z := i32(math.floor(c.player.position.z + base.sin(angle) * distance))
			at, found := spawn_spot(w, &rule, x, z, query)
			if !found {continue}
			center := [3]f64{f64(x) + 0.5, f64(at.y), f64(z) + 0.5}
			if anyone_within(w, center, f64(rule.distance[0])) {continue}
			if rule.safe > 0 {
				d := center - w.spawn.position
				if d.x * d.x + d.z * d.z < f64(rule.safe * rule.safe) {continue}
			}
			group := base.rng_int_range(r, rule.group[0], rule.group[1] + 1)
			for _ in 0 ..< group {
				jitter := [3]f64 {
					base.rng_f64_range(r, -1.5, 1.5),
					0,
					base.rng_f64_range(r, -1.5, 1.5),
				}
				p := center + jitter
				b := game.Block_Pos{i32(math.floor(p.x)), at.y, i32(math.floor(p.z))}
				if !spawn_holds(w, &rule, b, query) || (rule.sky && !under_sky(w, b)) {continue}
				h := entity_spawn(w, kind, p, true)
				if h == 0 {continue}
				if s.config.game.spawned != nil && !s.config.game.spawned(s, w, h) {
					entity_gone(w, h)
				}
			}
		}
	}
}

CAVE_COVER :: 4 // blocks under its column's top a cave's spawn is looked for from
CAVE_DEPTH :: 48 // ... down to this many under it
WATER_DEPTH :: 32 // blocks of water a water's spawn looks down through for the bed

// spawn_spot: where in column (x, z) a creature of the rule appears, by its place: on the
// column's top block, if that is the rule's `on`, out of water; in the water over the
// column's bed (the water's surface is the column's top: water shades the sky), if the bed
// is `on`, two blocks deep at least; or on the floor of the first hollow going down from
// CAVE_COVER to CAVE_DEPTH blocks under the top, if the floor is `on`. False when there is
// none (or its blocks are not loaded).
@(private = "file")
spawn_spot :: proc(
	w: ^World,
	rule: ^game.Kind_Spawn_Rule,
	x, z: i32,
	query: game.Block_Query,
) -> (
	at: game.Block_Pos,
	found: bool,
) {
	top := column_top(w, x, z)
	switch rule.place {
	case .Surface:
		ground, loaded := chunks_block(&w.chunks, {x, top, z})
		at = {x, top + 1, z}
		return at,
			loaded && game.rule_matcher_has(&rule.on, ground) && spawn_holds(w, rule, at, query)
	case .Water:
		for y := top; y > top - WATER_DEPTH && y > game.WORLD_MIN_Y; y -= 1 {
			bed, loaded := chunks_block(&w.chunks, {x, y, z})
			if _, water := game.water_level(bed); water && loaded {continue}
			at = {x, y + 1, z}
			return at,
				loaded && game.rule_matcher_has(&rule.on, bed) && spawn_holds(w, rule, at, query)
		}
	case .Cave:
		for y := top - CAVE_COVER; y > top - CAVE_DEPTH && y > game.WORLD_MIN_Y; y -= 1 {
			at = {x, y, z}
			floor, loaded := chunks_block(&w.chunks, at - {0, 1, 0})
			if !loaded {return}
			if game.rule_matcher_has(&rule.on, floor) && spawn_holds(w, rule, at, query) {
				return at, true
			}
		}
	}
	return
}

// spawn_holds: a creature of the rule may appear in block b, by its place: one that
// stands (on the surface, in a cave) stands there out of water; one of the water has
// water there and above.
@(private = "file")
spawn_holds :: proc(
	w: ^World,
	rule: ^game.Kind_Spawn_Rule,
	b: game.Block_Pos,
	query: game.Block_Query,
) -> bool {
	wet :: proc(w: ^World, p: game.Block_Pos) -> bool {
		block, loaded := chunks_block(&w.chunks, p)
		_, water := game.water_level(block)
		return loaded && water
	}
	if rule.place == .Water {return wet(w, b) && wet(w, b + {0, 1, 0})}
	return path.standable(query, b) && !wet(w, b)
}

// spawn_hours: day (a fraction from midnight) is within a spawn rule's hours, from..to
// (from above to: a night, across midnight).
spawn_hours :: proc(hours: [2]f32, day: f64) -> bool {
	from, to := f64(hours[0]), f64(hours[1])
	if from <= to {return day >= from && day <= to}
	return day >= from || day <= to
}

// under_sky: nothing stands above the block p (the sky's light reaches it).
under_sky :: proc(w: ^World, p: game.Block_Pos) -> bool {
	return p.y > column_top(w, p.x, p.z)
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

@(private)
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
C_GAME_DATA :: game.FIRST_SERVER_COMPONENT + 2 // the game's record on an entity of its kinds (entity_data)
C_LOOKS :: game.FIRST_SERVER_COMPONENT + 3 // the looks its game set (a kind with looks)

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
	infos:          [game.FIRST_SERVER_COMPONENT + 5]game.Component_Info,
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
	ew.infos[C_STEER] = game.Component_Info {
		name  = "steer",
		type  = Steer,
		size  = size_of(Steer),
		align = align_of(Steer),
	}
	ew.infos[C_LOOKS] = game.Component_Info {
		name  = "looks",
		type  = Looks,
		size  = size_of(Looks),
		align = align_of(Looks),
	}
	ew.infos[C_SIDE] = game.Component_Info {
		name  = "side",
		type  = Side,
		size  = size_of(Side),
		align = align_of(Side),
	}
	ew.infos[C_GAME_DATA] = game.Component_Info {
		name  = "game_data",
		type  = game.Entity_Data,
		size  = size_of(game.Entity_Data),
		align = align_of(game.Entity_Data),
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
	if info.physics == .Item {set += {int(game.C_STACK), int(game.C_OWNER)}}
	if info.physics == .Projectile {set += {int(game.C_OWNER)}}
	if info.brain == .Steered || info.brain == .Game {set += {int(C_STEER)}}
	if info.hittable {set += {int(game.C_HURT_BY)}}
	if info.model == .Player {set += {int(game.C_PLAYER_LINK)}}
	if len(info.fields) > 0 {set += {int(game.C_FIELDS)}}
	if len(info.looks) > 0 {set += {int(C_LOOKS)}}
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
		max    = i32(info.health),
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
	died := protocol.Entity_Died{u32(ew.deaths[before].id)}
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
	if c.entity_id != 0 && (c.entity_world != w || bodiless(s, c)) {player_entity_release(s, c)}
	if bodiless(s, c) {return}
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

// entities_next: the walk's next entity that still stands (ok false: the walk is over).
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
// whose pack data gives them its components (the kind's `physics` and `brain`), never
// over a kind by name, and they run in this fixed order:
//
//  1. age: every entity grows a tick older; a natural one nobody is near goes.
//  2. brains: each kind's brain over its creatures (a game's: its think hook). Then the
//     steered walkers (walkers.odin): where their game or its brain sends them.
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
	by:     Maybe(u16), // the rocket's shooter
}

@(private)
Wish :: struct {
	wish: [2]f32,
	jump: bool,
}

// entities_tick: spawning, despawning, thinking and moving, every tick.
entities_tick :: proc(w: ^World) {
	base.profile_scope("entities")
	w.entities.budget = PATH_BUDGET_PER_TICK
	entity_world_begin_tick(w.entity_world)
	defer {
		game.store_apply(&w.entity_world.store)
		entities_sync_spatial(w)
	}
	spawn_natural(w)
	query := game.Block_Query{&w.chunks, chunks_block, &w.server.registry.blocks, {}}
	blasts := make([dynamic]Blast, context.temp_allocator)
	wishes := make(map[game.Entity_Handle]Wish, context.temp_allocator)
	system_age(w)
	system_brains(w, &wishes)
	system_steer(w, &wishes)
	system_walkers(w, &wishes, query)
	system_items(w)
	system_rockets(w, &blasts)
	// After the walk: explosions change the set.
	for b in blasts {explode(w, b.sphere.center, b.sphere.radius, b.action, b.by)}
}

// system_age: one tick older; a natural entity with no player of its world within its
// kind's despawn distance goes (with no player in the world at all, nothing goes: a
// world loaded before its players arrive keeps its creatures).
@(private = "file")
system_age :: proc(w: ^World) {
	// (the players where their clients have them: a player's entity follows a tick late,
	// and one just arrived has none yet)
	players := make([dynamic][3]f64, context.temp_allocator)
	for &c in w.server.clients {
		if c.state == .Playing && c.world == w {append(&players, c.player.position)}
	}
	it := entities_each(w)
	for h in entities_next(&it) {
		entity_set_age(w, h, entity_age_of(w, h) + 1)
		if len(players) == 0 || !entity_is_natural(w, h) {continue}
		far := f64(game.SPAWN_DESPAWN)
		if rule, has := kind_of(w, h).spawn.?; has {far = f64(rule.despawn)}
		near := false
		for p in players {
			d := p - entity_pos(w, h)
			near ||= d.x * d.x + d.z * d.z <= far * far
		}
		if !near {entity_gone(w, h)}
	}
}

@(private = "file")
kind_of :: proc(w: ^World, h: game.Entity_Handle) -> ^game.Kind_Info {
	return game.kind_info(w.server.registry, entity_kind(w, h))
}

// Brain_Proc: a brain: what the creatures of one kind do this tick, given them all at
// once (those whose ground is loaded, lowest id first), so a crowd costs one call and the
// brain may share its looking about among them. The engine has no mind of a creature's
// of its own (BRAINS): a kind whose brain is "game" has its game's (Game.think), one that
// is "steered" its game's steering, from its tick.
Brain_Proc :: proc(
	w: ^World,
	kind: game.Kind_Id,
	entities: []game.Entity_Handle,
	wishes: ^map[game.Entity_Handle]Wish,
)

@(rodata, private = "file")
BRAINS := [game.Entity_Brain]Brain_Proc {
	.None    = nil,
	.Steered = nil, // (its game steers it from its tick)
	.Game    = game_brain,
}

// game_brain: the game's think hook for its kind; the steering does the rest.
@(private = "file")
game_brain :: proc(
	w: ^World,
	kind: game.Kind_Id,
	entities: []game.Entity_Handle,
	wishes: ^map[game.Entity_Handle]Wish,
) {
	s := w.server
	if s.config.game.think != nil {s.config.game.think(s, w, kind, entities)}
}

// system_brains: each kind's brain over its creatures, the kinds in id order. A
// creature born during a brain's turn (a lamb) has a higher id and is given to its
// kind's brain again in this same tick, after the ones that were there.
@(private = "file")
system_brains :: proc(w: ^World, wishes: ^map[game.Entity_Handle]Wish) {
	walked: u32
	for {
		it := entities_each(w, after = walked)
		by_kind := make(map[game.Kind_Id][dynamic]game.Entity_Handle, context.temp_allocator)
		kinds := make([dynamic]game.Kind_Id, context.temp_allocator)
		any := false
		for h in entities_next(&it) {
			any = true
			walked = max(walked, entity_id(w, h))
			kind := entity_kind(w, h)
			if BRAINS[kind_of(w, h).brain] == nil || !chunk_ready(w, entity_pos(w, h)) {continue}
			if kind not_in by_kind {
				by_kind[kind] = make([dynamic]game.Entity_Handle, context.temp_allocator)
				append(&kinds, kind)
			}
			append(&by_kind[kind], h)
		}
		if !any {break}
		slice.sort(kinds[:])
		for kind in kinds {
			BRAINS[game.kind_info(w.server.registry, kind).brain](
				w,
				kind,
				by_kind[kind][:],
				wishes,
			)
		}
	}
}

// system_walkers: the physics of everything that walks.
@(private = "file")
system_walkers :: proc(w: ^World, wishes: ^map[game.Entity_Handle]Wish, query: game.Block_Query) {
	it := entities_each(w)
	for h in entities_next(&it) {
		info := kind_of(w, h)
		if info.physics != .Walker ||
		   !chunk_ready(w, entity_pos(w, h)) ||
		   entity_gliding(w, h) {continue}
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
		if at, hit, what := rocket_step(w, h); hit {
			owner := entity_owner(w, h)
			if info.projectile.explode == 0 {
				// A shot that does not explode hurts what it hit, and is gone.
				shot_lands(w, h, what)
				entity_died(w, h)
				continue
			}
			blast := Blast{{at, f64(info.projectile.explode)}, Action_Id(owner.action), nil}
			// (the shooter still in its seat: one who left is nobody, whoever sits there now)
			shooter := Player_Ref{u16(max(owner.client, 0)), owner.generation}
			if owner.client >= 0 && player_of(w.server, shooter) != nil {blast.by = shooter.seat}
			append(blasts, blast)
			entity_died(w, h) // its explosion is what players see
		}
	}
}
