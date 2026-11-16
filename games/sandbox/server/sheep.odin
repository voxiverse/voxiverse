package sandbox_server

import "core:math"

import "common:base"
import "common:game"
import "games:sandbox"
import "server:core"

// The sheep (its pack's `sandbox:sheep`, whose brain is the game's): each stands and looks
// about, looks at a player who comes near, wanders, grazes (a shorn one eats the grass in
// front of it, which turns to dirt, and its wool grows back), and flees what hurt it. Fed
// wheat, an adult is ready to breed: two ready ones near each other walk together and have
// a lamb of both (genetics.odin), which grows up in LAMB_TICKS (wheat brings that forward).
// A player shears an adult by hand: 1 to 3 wool, black by its genes. They come by
// themselves by day on grass, with wild genes (the kind's spawn rule). What a player sees
// of one (shorn, a lamb, black, spotted, in love) is its looks, shown here and drawn by
// its pack's model.

Sheep_State :: enum u8 {
	Idle, // standing; looking about
	Look, // a player is close: watch them
	Wander, // walking somewhere nearby
	Graze, // head down for a while
	Flee, // hit: running away
	Mate, // ready to breed: walking to another that is
}

// Sheep: the game's record on each sheep (core.entity_data), kept with it.
Sheep :: struct {
	state: Sheep_State,
	shorn: bool,
	genes: sandbox.Genes,
	timer: i32, // ticks left in this state
	grows: i32, // ticks before it is grown (0: an adult; a lamb is born with LAMB_TICKS)
	love:  i32, // ticks it is still ready to breed
	wait:  i32, // ticks before it may breed again
}

GRAZE_EAT_TICKS :: 10 // ticks left of a graze when the head is down and the grass goes
FLEE_TICKS :: game.TICK_RATE * 5
FLEE_DISTANCE :: 10 // blocks it runs from what hurt it
LOOK_DISTANCE :: 6 // blocks within which it watches a player
WANDER_TICKS :: game.TICK_RATE * 12 // a walk's longest
WANDER_RANGE :: 8 // blocks it wanders, at most, each way
MATE_NEAR :: 1.6 // blocks apart at which two ready sheep have their lamb

// sheep: a sheep's record (nil for another creature).
sheep :: proc(s: ^core.Server, w: ^core.World, h: game.Entity_Handle) -> ^Sheep {
	if core.entity_kind(w, h) != state(s).sheep {return nil}
	return core.entity_data(w, h, Sheep)
}

// adult: the sheep has grown up.
adult :: proc(d: ^Sheep) -> bool {return d.grows <= 0}

// think: the game's brain for its kinds (Game.think): every sheep of the world, each tick.
think :: proc(
	s: ^core.Server,
	w: ^core.World,
	kind: game.Kind_Id,
	entities: []game.Entity_Handle,
) {
	if kind != state(s).sheep {return}
	for h in entities {sheep_think(s, w, h)}
}

// sheep_think: one sheep's tick: its clocks, its state, its head and its looks.
sheep_think :: proc(s: ^core.Server, w: ^core.World, h: game.Entity_Handle) {
	g := state(s)
	r := &g.rng
	d := sheep(s, w, h)
	if d == nil {return}
	if d.grows > 0 {d.grows -= 1}
	if d.love > 0 {d.love -= 1}
	if d.wait > 0 {d.wait -= 1}
	d.timer -= 1
	pos := core.entity_pos(w, h)
	// Ready to breed: toward another that is; close enough, the one with the lower id
	// has the lamb.
	if d.love > 0 && adult(d) && d.state != .Flee {
		if m := mate_for(s, w, h); m != 0 {
			d.state = .Mate
			at := core.entity_pos(w, m)
			core.entity_keep(w, h, at, 0, 1)
			gap := at - pos
			if gap.x * gap.x + gap.z * gap.z < MATE_NEAR * MATE_NEAR &&
			   core.entity_id(w, h) < core.entity_id(w, m) {breed(s, w, h, m)}
		} else if d.state == .Mate {rest(w, h, d, 20)}
	} else if d.state == .Mate {rest(w, h, d, 20)}
	player, near := nearest_player(s, w, pos, LOOK_DISTANCE)
	switch d.state {
	case .Mate:
	case .Flee:
		if d.timer <= 0 {rest(w, h, d, 20)}
	case .Idle, .Look:
		if near && base.rng_f32(r) < 0.95 {
			d.state = .Look
		} else if d.state == .Look {
			d.state = .Idle
		}
		// A shorn sheep with grass in front of it wants to eat.
		if d.shorn && d.timer <= 0 && base.rng_f32(r) < 0.6 {
			if _, ahead := grass_ahead(s, w, h); ahead {
				d.state, d.timer = .Graze, i32(base.rng_int_range(r, GRAZE_EAT_TICKS + 10, 120))
			}
		}
		if d.state != .Graze && d.timer <= 0 {
			switch {
			case base.rng_f32(r) < 0.55:
				target :=
					pos +
					{
							base.rng_f64_range(r, -WANDER_RANGE, WANDER_RANGE),
							0,
							base.rng_f64_range(r, -WANDER_RANGE, WANDER_RANGE),
						}
				core.entity_go(w, h, target)
				d.state, d.timer = .Wander, WANDER_TICKS
			case base.rng_f32(r) < 0.5:
				d.state, d.timer = .Graze, i32(base.rng_int_range(r, 40, 120))
			case:
				d.timer = i32(base.rng_int_range(r, 30, 90))
			}
		}
	case .Wander:
		if core.entity_arrived(w, h) || d.timer <= 0 {
			rest(w, h, d, i32(base.rng_int_range(r, 30, 120)))
		}
	case .Graze:
		if d.timer == GRAZE_EAT_TICKS {graze_eat(s, w, h)}
		if d.timer <= 0 {rest(w, h, d, i32(base.rng_int_range(r, 20, 60)))}
	}
	// The head: down when grazing, at the player when looking, level else.
	yaw, pitch := core.entity_yaw(w, h), core.entity_pitch(w, h)
	want: f32 = 0
	#partial switch d.state {
	case .Graze:
		want = -1.2
	case .Look:
		if near {
			eye := pos + {0, 0.9, 0}
			to := player + {0, game.PLAYER_EYE, 0} - eye
			flat := math.sqrt(to.x * to.x + to.z * to.z)
			want = clamp(f32(math.atan2(to.y, flat)), -1, 1)
			yaw = turn_towards(yaw, f32(math.atan2(-to.x, -to.z)), 0.15)
		}
	}
	core.entity_set_look(w, h, yaw, pitch + (want - pitch) * 0.2)
	show(w, h, d)
}

// show: what a player sees of the sheep, from its record.
show :: proc(w: ^core.World, h: game.Entity_Handle, d: ^Sheep) {
	core.entity_show(w, h, "shorn", d.shorn)
	core.entity_show(w, h, "lamb", !adult(d))
	core.entity_show(w, h, "black", sandbox.genes_black(d.genes))
	core.entity_show(w, h, "spotted", sandbox.genes_spotted(d.genes))
	core.entity_show(w, h, "in_love", d.love > 0)
}

// rest: the sheep stops what it did and stands for a while, at its walking pace again.
rest :: proc(w: ^core.World, h: game.Entity_Handle, d: ^Sheep, ticks: i32) {
	d.state, d.timer = .Idle, ticks
	core.entity_stand(w, h)
	core.entity_set_speed(w, h, 0)
}

// turn_towards: an angle a step (rate) of the way to another, the short way round.
turn_towards :: proc(from, to: f32, rate: f32) -> f32 {
	d := math.mod(to - from + 3 * math.PI, math.TAU) - math.PI
	return from + d * rate
}

// nearest_player: where the nearest living player of the world within reach of p stands.
nearest_player :: proc(
	s: ^core.Server,
	w: ^core.World,
	p: [3]f64,
	within: f64,
) -> (
	at: [3]f64,
	ok: bool,
) {
	best := within * within
	for &c in s.clients {
		if c.state != .Playing || c.world != w || c.dead {continue}
		d := c.player.position - p
		if dd := d.x * d.x + d.y * d.y + d.z * d.z;
		   dd <= best {at, ok, best = c.player.position, true, dd}
	}
	return
}

// mate_for: the nearest other sheep that is ready to breed (an adult in love) within
// BREED_RANGE of h, if any (the lowest id of the nearest).
mate_for :: proc(s: ^core.Server, w: ^core.World, h: game.Entity_Handle) -> game.Entity_Handle {
	for other in core.entities_of(w, state(s).sheep, core.entity_pos(w, h), sandbox.BREED_RANGE) {
		if other == h {continue}
		if d := sheep(s, w, other); d != nil && d.love > 0 && adult(d) {return other}
	}
	return 0
}

// breed: a and b have met: a lamb between them, of both, and each waits.
breed :: proc(s: ^core.Server, w: ^core.World, a, b: game.Entity_Handle) {
	g := state(s)
	da, db := sheep(s, w, a), sheep(s, w, b)
	at := (core.entity_pos(w, a) + core.entity_pos(w, b)) / 2
	genes := sandbox.genes_child(da.genes, db.genes, &g.rng)
	da.love, db.love = 0, 0
	da.wait, db.wait = sandbox.BREED_WAIT_TICKS, sandbox.BREED_WAIT_TICKS
	rest(w, a, da, 20)
	rest(w, b, db, 20)
	if lamb := core.entity_spawn(w, g.sheep, at, false); lamb != 0 {
		d := sheep(s, w, lamb)
		d.genes, d.grows = genes, sandbox.LAMB_TICKS
		show(w, lamb, d)
		core.stat_world(s, w, "sheep.born")
	}
}

// grass_ahead: the grass block in front of the sheep's feet, if there is one.
grass_ahead :: proc(
	s: ^core.Server,
	w: ^core.World,
	h: game.Entity_Handle,
) -> (
	p: game.Block_Pos,
	ok: bool,
) {
	pos := core.entity_pos(w, h)
	yaw := core.entity_yaw(w, h)
	front := pos + {-f64(base.sin(yaw)) * 0.8, 0, -f64(base.cos(yaw)) * 0.8}
	p = {i32(math.floor(front.x)), i32(math.floor(pos.y + 0.01)) - 1, i32(math.floor(front.z))}
	b, loaded := core.block_at(w, p)
	return p, loaded && b == state(s).grass
}

// graze_eat: a sheep with its head down eats the grass in front of it: the block
// becomes dirt, and a shorn sheep has its wool back.
graze_eat :: proc(s: ^core.Server, w: ^core.World, h: game.Entity_Handle) {
	d := sheep(s, w, h)
	p, ok := grass_ahead(s, w, h)
	if !ok || !d.shorn {return}
	core.set_block(w, p, state(s).dirt, core.game_act(s, w, .Graze))
	d.shorn = false
}

// entity_use: a player uses a sheep (Game.entity_use). Wheat feeds it: a lamb grows up a
// tenth sooner, an adult not waiting becomes ready to breed. Anything else shears an
// adult by hand: 1 to 3 wool fall (black by its genes), and it is shorn until it eats
// grass.
entity_use :: proc(
	s: ^core.Server,
	c: ^core.Client,
	h: game.Entity_Handle,
	stack: game.Stack,
) -> string {
	g := state(s)
	w := c.world
	d := sheep(s, w, h)
	if d == nil {return ""}
	if !game.stack_empty(stack) && stack.item == g.wheat {
		switch {
		case !adult(d):
			d.grows = max(d.grows - sandbox.LAMB_TICKS / 10, 0)
		case d.love == 0 && d.wait == 0:
			d.love = sandbox.BREED_READY_TICKS
		case:
			return "The sheep is not hungry"
		}
		lamb := !adult(d)
		core.item_spend(s, c, g.wheat)
		if !lamb {core.stat_count(s, c, "sheep.fed")}
		show(w, h, d)
		return ""
	}
	if !adult(d) {return "A lamb has no wool to shear yet"}
	if d.shorn {return "The sheep is shorn: its wool grows back as it grazes"}
	d.shorn = true
	core.stat_count(s, c, "sheep.sheared")
	wool := g.black_wool if sandbox.genes_black(d.genes) else g.wool
	at := core.entity_pos(w, h) + {0, 0.6, 0}
	for _ in 0 ..< base.rng_int_range(&g.rng, 1, 4) {core.item_drop(s, w, at, {wool, 1, 0, 0})}
	show(w, h, d)
	return ""
}

// spawned: a sheep that came by itself has wild genes (Game.spawned).
spawned :: proc(s: ^core.Server, w: ^core.World, h: game.Entity_Handle) -> bool {
	if d := sheep(s, w, h); d != nil {
		d.genes = sandbox.genes_wild(&state(s).rng)
		show(w, h, d)
	}
	return true
}

// entity_hurt: a hurt sheep runs from what hurt it (Game.entity_hurt).
entity_hurt :: proc(
	s: ^core.Server,
	w: ^core.World,
	h: game.Entity_Handle,
	harm: core.Entity_Harm,
) {
	d := sheep(s, w, h)
	if d == nil {return}
	r := &state(s).rng
	pos := core.entity_pos(w, h)
	away := pos - harm.from
	l := math.sqrt(away.x * away.x + away.z * away.z)
	if l < 1e-6 {away, l = {1, 0, 0}, 1}
	target :=
		pos +
		{away.x, 0, away.z} / l * FLEE_DISTANCE +
		{base.rng_f64_range(r, -3, 3), 0, base.rng_f64_range(r, -3, 3)}
	d.state, d.timer = .Flee, FLEE_TICKS
	core.entity_set_speed(w, h, game.kind_info(s.registry, state(s).sheep).walker.run_speed)
	core.entity_go(w, h, target)
}
