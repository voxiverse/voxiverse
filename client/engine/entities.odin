package engine

import "core:math"
import "core:time"

import "client:mesh"
import "client:render"
import "common:base"
import "common:game"

// Entities as the client shows them: interpolated like the other players
// (players.odin), drawn as boxes in the entity pass. A creature is its kind's parts
// (its pack's model): legs that swing as fast as it walks, a head that pitches as the
// server's pitch says, parts shown, hidden, coloured and sized by its looks, specks that
// rise from it by a look; it flashes red when hit and bursts into a puff of pixels when
// it dies. Nothing here knows any particular creature.

HURT_FLASH :: 250 * time.Millisecond
PUFF_SECONDS :: 0.7
PUFF_PIECES :: 14
MAX_PUFFS :: 1024

// Puff: a particle, a piece of something (a dying entity, debris, smoke,
// flame) flying out and falling, or drifting and slowing. It shrinks as it
// ages.
Puff :: struct {
	position: [3]f64,
	velocity: [3]f32,
	age:      f32, // seconds
	life:     f32, // seconds it lasts
	size:     f32, // half-width, blocks
	gravity:  f32, // blocks/s²
	drag:     f32, // fraction of its speed lost per second
	color:    [4]u8,
}

// puff_add adds p, unless there are MAX_PUFFS already (then it is dropped:
// effects are not worth growing memory for).
puff_add :: proc(s: ^Session, p: Puff) {
	if len(s.puffs) < cap(s.puffs) {append(&s.puffs, p)}
}

@(private = "file")
SMOKE :: [4]u8{70, 68, 66, 255}
@(private = "file")
FLAME :: [4]u8{255, 170, 60, 255}

@(private = "file")
HURT :: [4]u8{236, 84, 72, 255}

// entities_draw adds the entities and puffs to the entity pass and moves
// the puffs on by dt.
entities_draw :: proc(s: ^Session, d: ^render.Entity_Draw, dt: f32) {
	// Puffs are local effects: they move on and fade whatever the connection.
	now, live := session_others_now(s)
	for _, &e in s.entities {
		if !live {break}
		v, ok := track_view(&e.track, now)
		if !ok {continue}
		moved := v.position - e.last_seen
		e.stride += f32(math.sqrt(moved.x * moved.x + moved.z * moved.z))
		e.last_seen = v.position
		hurt := e.hurt_at != {} && time.tick_since(e.hurt_at) < HURT_FLASH
		info := game.kind_info(s.reg, e.kind)
		if info == nil {continue}
		switch info.model {
		case .Rocket:
			rocket(s, d, v)
		case .Item:
			dropped_item(s, d, v, e.stack)
		case .Box:
			lo, hi := game.entity_box(info, {})
			render.entity_box(
				d,
				v.position,
				v.yaw,
				0,
				{f32(lo.x), 0, f32(lo.z)},
				{f32(hi.x), f32(hi.y), f32(hi.z)},
				{info.color[0], info.color[1], info.color[2], 255},
				.Body,
			)
		case .Parts:
			shaped(d, v, info, e.stride, hurt, e.looks)
			look_puffs(s, v, info, e.looks)
		case .Player: // (players are drawn as players, not from here)
		}
	}
	for i := 0; i < len(s.puffs); {
		p := &s.puffs[i]
		p.age += dt
		if p.age > p.life {
			unordered_remove(&s.puffs, i)
			continue
		}
		p.velocity.y -= p.gravity * dt
		p.velocity *= max(1 - p.drag * dt, 0)
		p.position += {f64(p.velocity.x * dt), f64(p.velocity.y * dt), f64(p.velocity.z * dt)}
		size := p.size * (1 - p.age / p.life * 0.6)
		render.entity_box(d, p.position, 0, 0, -size, size, p.color, .Body)
		i += 1
	}
}

// STRIKE_RAISE: radians a striking part swings forward (a raised arm, a lunging head).
STRIKE_RAISE :: 1.5

// shaped: a kind's own boxes (its model's parts), turned with it, sized by its looks
// about its feet; a part a look hides (or one not shown) is left out, and a look may
// colour it. A part that swings turns about its hinge: to and fro with the stride, forward
// while it strikes, up and down with its pitch. Red while hurt.
@(private)
shaped :: proc(
	d: ^render.Entity_Draw,
	v: Other_View,
	info: ^game.Kind_Info,
	stride: f32,
	hurt: bool,
	looks: u16,
) {
	walk := math.sin(stride * 4) * 0.7
	k := f32(1)
	if info.scale.look != 0 && looks & info.scale.look != 0 {k = info.scale.factor}
	for part in info.parts {
		if looks & part.shown != part.shown || looks & part.hidden != 0 {continue}
		angle: f32
		switch part.swing {
		case .None:
		case .Walk:
			angle = walk
		case .Walk_Back:
			angle = -walk
		case .Strike:
			angle = STRIKE_RAISE if looks & info.striking != 0 else walk
		case .Pitch:
			angle = v.pitch
		}
		rgb := part.color
		for c in part.recolor {
			if c.look != 0 && looks & c.look != 0 {rgb = c.color; break}
		}
		color := [4]u8{rgb[0], rgb[1], rgb[2], 255}
		skin := [game.Part_Skin]render.Entity_Part {
			.Body = .Body,
			.Legs = .Legs,
			.Head = .Head,
		}
		render.entity_box(
			d,
			v.position + turn_yaw(part.hinge * k, v.yaw),
			v.yaw,
			angle,
			(part.lo - part.hinge) * k,
			(part.hi - part.hinge) * k,
			HURT if hurt else color,
			skin[part.skin],
		)
	}
}

// look_puffs: the specks a creature's looks let rise (a heart over one in love), each
// frame by its chance, from its height (sized with it).
@(private = "file")
look_puffs :: proc(s: ^Session, v: Other_View, info: ^game.Kind_Info, looks: u16) {
	k := f32(1)
	if info.scale.look != 0 && looks & info.scale.look != 0 {k = info.scale.factor}
	for p in info.puffs {
		if looks & p.look == 0 || base.rng_f32(base.cosmetic_rng()) >= p.chance {continue}
		puff_add(
			s,
			Puff {
				position = v.position +
				{
						base.rng_f64_range(base.cosmetic_rng(), -0.3, 0.3),
						f64(p.height * k),
						base.rng_f64_range(base.cosmetic_rng(), -0.3, 0.3),
					},
				velocity = {0, 0.9, 0},
				life = 1.1,
				size = 0.09,
				drag = 0.5,
				color = {p.color[0], p.color[1], p.color[2], 255},
			},
		)
	}
}

// rocket: a dark body with a hot tail, leaving smoke.
@(private = "file")
rocket :: proc(s: ^Session, d: ^render.Entity_Draw, v: Other_View) {
	centre := v.position + {0, 0.15, 0}
	render.entity_box(
		d,
		centre,
		v.yaw,
		v.pitch,
		{-0.1, -0.1, -0.35},
		{0.1, 0.1, 0.35},
		{60, 62, 70, 255},
		.Body,
	)
	tail := centre + turn_yaw({0, 0, 0.4}, v.yaw)
	render.entity_box(d, tail, v.yaw, v.pitch, -0.07, 0.07, FLAME, .Body)
	if base.rng_f32(base.cosmetic_rng()) < 0.6 {
		puff_add(
			s,
			Puff {
				position = tail,
				velocity = {
					base.rng_f32_range(base.cosmetic_rng(), -0.4, 0.4),
					base.rng_f32_range(base.cosmetic_rng(), 0.2, 0.8),
					base.rng_f32_range(base.cosmetic_rng(), -0.4, 0.4),
				},
				life = 1.2,
				size = 0.12,
				drag = 2,
				color = SMOKE,
			},
		)
	}
}

// explosion_effects: the debris of what was there (the blocks are still
// the old ones: the bulk edit comes after), smoke, and the boom.
explosion_effects :: proc(s: ^Session, center: [3]f64, radius: f64) {
	for _ in 0 ..< min(60, (cap(s.puffs) - len(s.puffs)) / 2) {
		// A random point in the sphere; a piece of its block, flung out.
		p: [3]f64
		for {
			p = {
				base.rng_f64_range(base.cosmetic_rng(), -1, 1),
				base.rng_f64_range(base.cosmetic_rng(), -1, 1),
				base.rng_f64_range(base.cosmetic_rng(), -1, 1),
			}
			if p.x * p.x + p.y * p.y + p.z * p.z <= 1 {break}
		}
		at := center + p * radius
		b, _ := world_block(
			&s.world,
			{i32(math.floor(at.x)), i32(math.floor(at.y)), i32(math.floor(at.z))},
		)
		if !game.block_collides(&s.reg.blocks, b) {continue}
		out :=
			[3]f32{f32(p.x), f32(p.y) + 0.6, f32(p.z)} *
			base.rng_f32_range(base.cosmetic_rng(), 6, 14)
		puff_add(
			s,
			{
				position = at,
				velocity = out,
				life = base.rng_f32_range(base.cosmetic_rng(), 0.8, 1.6),
				size = 0.11,
				gravity = 22,
				color = debris_colour(s, b),
			},
		)
	}
	for _ in 0 ..< 24 {
		dir := [3]f32 {
			base.rng_f32_range(base.cosmetic_rng(), -1, 1),
			base.rng_f32_range(base.cosmetic_rng(), -0.2, 1),
			base.rng_f32_range(base.cosmetic_rng(), -1, 1),
		}
		puff_add(
			s,
			{
				position = center,
				velocity = dir * f32(radius) * 1.6,
				life = base.rng_f32_range(base.cosmetic_rng(), 1, 2),
				size = base.rng_f32_range(base.cosmetic_rng(), 0.25, 0.45),
				drag = 2,
				color = SMOKE,
			},
		)
	}
	for _ in 0 ..< 10 {
		dir := [3]f32 {
			base.rng_f32_range(base.cosmetic_rng(), -1, 1),
			base.rng_f32_range(base.cosmetic_rng(), -1, 1),
			base.rng_f32_range(base.cosmetic_rng(), -1, 1),
		}
		puff_add(
			s,
			{
				position = center,
				velocity = dir * 8,
				life = 0.25,
				size = 0.3,
				drag = 2,
				color = FLAME,
			},
		)
	}
	append(&s.sounds, Sound_Event{.Explosion, .Air, center, 1, {}})
}

// entity_died: its puff, of its own colours (its model's first part's mostly, its last
// part's the rest), and its last sound.
entity_died :: proc(s: ^Session, e: ^Other_Entity) {
	at := e.last_seen
	most, rest := [4]u8{128, 128, 128, 255}, [4]u8{96, 96, 96, 255}
	if info := game.kind_info(s.reg, e.kind); info != nil {
		if len(info.parts) > 0 {
			first, last := info.parts[0].color, info.parts[len(info.parts) - 1].color
			most, rest = {first[0], first[1], first[2], 255}, {last[0], last[1], last[2], 255}
		} else if info.model == .Box {
			most = {info.color[0], info.color[1], info.color[2], 255}
			rest = most
		}
	}
	for _ in 0 ..< PUFF_PIECES {
		angle := base.rng_f32_range(base.cosmetic_rng(), 0, math.TAU)
		speed := base.rng_f32_range(base.cosmetic_rng(), 1.5, 3.5)
		offset := [3]f64 {
			f64(base.rng_f32_range(base.cosmetic_rng(), -0.3, 0.3)),
			f64(base.rng_f32_range(base.cosmetic_rng(), 0.3, 0.8)),
			f64(base.rng_f32_range(base.cosmetic_rng(), -0.3, 0.3)),
		}
		puff_add(
			s,
			{
				position = at + offset,
				velocity = {
					math.cos(angle) * speed,
					base.rng_f32_range(base.cosmetic_rng(), 2, 5),
					math.sin(angle) * speed,
				},
				life = PUFF_SECONDS,
				size = 0.07,
				gravity = 18,
				color = most if base.rng_f32(base.cosmetic_rng()) < 0.7 else rest,
			},
		)
	}
	append(&s.sounds, Sound_Event{.Entity_Die, .Air, at + {0, 0.5, 0}, 1, entity_voice(s, e)})
}

// entity_voice: the voice an entity cries in, its kind's (a kind the registry has not: the
// bleat, every creature's default).
entity_voice :: proc(s: ^Session, e: ^Other_Entity) -> game.Entity_Voice {
	if info := game.kind_info(s.reg, e.kind); info != nil {return info.voice}
	return .Bleat
}

// entity_aimed: the nearest entity on the ray within reach (and nearer
// than max_distance), if any.
entity_aimed :: proc(
	s: ^Session,
	origin, dir: [3]f64,
	max_distance: f64,
) -> (
	id: u32,
	distance: f64,
	ok: bool,
) {
	now, live := session_others_now(s)
	if !live {return}
	distance = max_distance
	for key, &e in s.entities {
		info := game.kind_info(s.reg, e.kind)
		if info == nil || !info.hittable {continue}
		v, seen := track_view(&e.track, now)
		if !seen {continue}
		lo, hi := game.entity_box(info, v.position)
		if d, hit := game.ray_box(origin, dir, lo, hi, distance); hit && d <= distance {
			id, distance, ok = key, d, true
		}
	}
	return
}

// turn_yaw turns an offset as a body facing yaw turns it.
turn_yaw :: proc(p: [3]f32, yaw: f32) -> [3]f64 {
	c, s := math.cos(yaw), math.sin(yaw)
	return {f64(p.x * c + p.z * s), f64(p.y), f64(-p.x * s + p.z * c)}
}

// dropped_item: a small cube of the item's colour, turning and bobbing
// (more of them stacked for a bigger stack).
@(private = "file")
dropped_item :: proc(s: ^Session, d: ^render.Entity_Draw, v: Other_View, stack: game.Stack) {
	colour := item_colour(s, stack.item)
	t := f32(time.duration_seconds(time.tick_since({}))) // (any steady clock)
	spin := t * 1.5
	bob := f64(math.sin(t * 2.5) * 0.06 + 0.06)
	cubes := 1 if stack.count < 8 else (2 if stack.count < 32 else 3)
	for k in 0 ..< cubes {
		offset := [3]f64{f64(k) * 0.07, f64(k) * 0.05, f64(k) * -0.06}
		render.entity_box(
			d,
			v.position + {0, bob, 0} + offset,
			spin,
			0,
			{-0.12, 0, -0.12},
			{0.12, 0.24, 0.12},
			colour,
			.Body,
		)
	}
}

// item_colour: an item's look in one colour: its block's, its model's first colour, or a
// tool's grey.
item_colour :: proc(s: ^Session, item: game.Item) -> [4]u8 {
	info, _ := game.item_info(s.reg, item)
	if info.block != .Air {return block_colour(s, info.block)}
	if m, has := info.model.?;
	   has && int(m) < len(s.reg.models) {return s.reg.models[m].palette[0]}
	return {60, 60, 64, 255}
}

// block_colour: b's look in one colour (the average of its side): a minimap's ground.
block_colour :: proc(s: ^Session, b: game.Block) -> [4]u8 {
	side := mesh.block_texture(s.reg, b, .Pos_X)
	sum: [3]u32
	n: u32
	for c in s.texels[side] {
		if c.a == 0 {continue}
		sum += {u32(c.r), u32(c.g), u32(c.b)}
		n += 1
	}
	if n == 0 {return {128, 128, 128, 255}}
	return {u8(sum.r / n), u8(sum.g / n), u8(sum.b / n), 255}
}

// debris_colour: a piece of b, broken up: one of the pixels of its side
// (not a hole in it).
@(private = "file")
debris_colour :: proc(s: ^Session, b: game.Block) -> [4]u8 {
	side := mesh.block_texture(s.reg, b, .Pos_X)
	pixels := &s.texels[side]
	for _ in 0 ..< 8 {
		c := pixels[base.rng_int_max(base.cosmetic_rng(), len(pixels))]
		if c.a != 0 {return {c.r, c.g, c.b, 255}}
	}
	return {128, 128, 128, 255}
}
