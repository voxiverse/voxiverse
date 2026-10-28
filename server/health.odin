package server

import "core:math"

import "../common/game"
import "../common/telemetry"

// Health, damage, death and what a character grows by. A player has health
// points (BASE_HEALTH, plus what they wear: common/game/mods.odin); a fall of more
// than 3 blocks onto ground costs a point a block, an explosion costs by how
// near it was; at nought a player dies (a Death event, the inventory dropped
// where they fell if rules.death_drops) and wakes at the world's spawn with
// full health. Rules.damage off: nothing hurts. Every event that happens to
// a player may also earn experience (award_xp): the pipeline from something
// happening to the character growing, a table and a curve, kept as the counters
// `xp` and `level` (so saved with the character).

SAFE_FALL :: 3.0 // blocks

// health_tick: once a tick for each playing client, after its movement.
health_tick :: proc(s: ^Server, c: ^Client) {
	w := c.world
	mods := game.derive_mods(s.registry, &c.inventory)
	if c.max_health == 0 {c.health = mods.max_health} 	// (just joined: full)
	if mods.max_health != c.max_health {
		c.max_health = mods.max_health
		c.health = min(c.health, c.max_health)
	}
	// A fall: from where the player left the ground to where they land.
	p := c.player
	query := game.Block_Query{&w.chunks, chunks_block, &w.server.registry.blocks}
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
			if drop > SAFE_FALL {damage_player(s, c, f32(drop - SAFE_FALL), "fall")}
		}
		c.airborne, c.fall_peak = false, p.position.y
	} else if !c.airborne {
		c.airborne, c.fall_peak = true, p.position.y
	} else {
		c.fall_peak = max(c.fall_peak, p.position.y)
	}
	health := game.Health{c.health, c.max_health}
	state_put(s, c, .Health, &health) // (nothing is sent while it is unchanged)
}

// damage_player hurts c by amount health points from cause; at nought they die.
damage_player :: proc(s: ^Server, c: ^Client, amount: f32, cause: string) {
	if !c.world.rules.damage || amount <= 0 || c.state != .Playing {return}
	c.health = max(c.health - amount, 0)
	record(s, c, .Damage, cause, i64(math.round(amount * 10)), i64(math.round(c.health * 10)))
	if c.health <= 0 {die(s, c, cause)}
}

// die: c is dead: their things dropped (by the rule), and they stand at the spawn again.
die :: proc(s: ^Server, c: ^Client, cause: string) {
	record(s, c, .Death, cause)
	died := game.Player_Died{cause}
	event_send(s, c, .Player_Died, &died)
	w := c.world
	if w.rules.death_drops {
		at := c.player.position + {0, 0.5, 0}
		for &st in c.inventory.slots {
			if !game.stack_empty(st) {spawn_item(w, at, st, {}, -1)}
			st = {}
		}
		for &st in c.inventory.equipment {
			if !game.stack_empty(st) {spawn_item(w, at, st, {}, -1)}
			st = {}
		}
		if !game.stack_empty(c.inventory.cursor) {spawn_item(w, at, c.inventory.cursor, {}, -1)}
		c.inventory.cursor = {}
		c.inv_changed = true
	}
	c.max_health = game.derive_mods(s.registry, &c.inventory).max_health
	c.health = c.max_health
	c.airborne = false
	land_at_spawn(s, c, remember = false)
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
		telemetry.emit(
			&s.sink,
			event_for(s, c.world, .Level_Up, player_id(s, c), "", {i64(level), i64(xp), 0}),
		)
	}
}
