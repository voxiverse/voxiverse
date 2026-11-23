package core


import "common:game"
import "common:protocol"
import "common:telemetry"

// Health, damage, death and what a character grows by. A player has health
// points (BASE_HEALTH, plus what they wear: common/game/mods.odin); a fall of more
// than 3 blocks onto ground costs a point a block, an explosion costs by how
// near it was; at nought a player dies (a Death event, the inventory dropped
// where they fell if the character's mode drops them and keep_inventory is off);
// they wait at the death screen and the Respawn button wakes them at the world's
// spawn once the world's respawn_delay is over (or they wake by themselves then,
// under respawn_auto), unhurt for its spawn_protection (damage.odin: the one
// pipeline). Every event that happens to
// a player may also earn experience (award_xp): the pipeline from something
// happening to the character growing, a table and a curve, kept as the counters
// `xp` and `level` (so saved with the character).

SAFE_FALL :: 3.0 // blocks

// health_tick: once a tick for each playing client, after its movement.
health_tick :: proc(s: ^Server, c: ^Client) {
	w := c.world
	most := most_health(s, c)
	if c.max_health == 0 {c.health = most} 	// (just joined: full)
	if most != c.max_health {
		c.max_health = most
		c.health = min(c.health, c.max_health)
	}
	if c.dead && c.world.rules.respawn_auto && s.tick >= respawn_due(c) {respawn(s, c)}
	if c.dead {
		c.airborne = false
		health := protocol.Health{c.health, c.max_health, true}
		state_put(s, c, .Health, &health)
		return
	}
	regenerate(s, c)
	effect_tick(s, c)
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
	health := protocol.Health{c.health, c.max_health, false}
	state_put(s, c, .Health, &health) // (nothing is sent while it is unchanged)
}

// head_in_water: c's eyes are in water (where a game drowns a player: the engine
// does not).
head_in_water :: proc(s: ^Server, c: ^Client) -> bool {
	w := c.world
	query := game.Block_Query{&w.chunks, chunks_block, &s.registry.blocks, {}}
	return game.in_water(query, game.player_eye(c.player), 0)
}

// heal_player: c recovers amount health points (not past its most; not a dead one).
heal_player :: proc(c: ^Client, amount: f32) {
	if c.dead || !(amount > 0) {return}
	c.health = min(c.health + amount, c.max_health)
}

// Effect: what a consumable a player used up still does (item_consume): health a second
// and a fraction of harm taken off, until a tick. Not saved: it ends with its time, a
// death or the session.
Effect :: struct {
	regen, defence: f32,
	until:          u64,
}

// item_consume: c uses up one of the stack in its hand if it is a consumable (its item's
// `consume`): healed at once, then what it does for its seconds, in place of any effect
// still running. "" or why not.
item_consume :: proc(s: ^Server, c: ^Client) -> string {
	if c.dead || c.state != .Playing {return "You cannot use anything now"}
	held := game.inventory_held(&c.inventory)
	info, _ := game.item_info(s.registry, held.item)
	use, ok := info.consume.?
	if game.stack_empty(held) || !ok {return "That is nothing to use up"}
	if !item_spend(s, c, held.item, 1) {return "That is nothing to use up"}
	heal_player(c, use.heal)
	c.effect = {}
	if use.seconds > 0 {
		c.effect = {use.regen, use.defence, s.tick + seconds_ticks(use.seconds)}
	}
	record(s, c, .Item_Used, game.item_name(s.registry, held.item))
	return ""
}

// effect_tick: a running effect's health for this tick; one whose time is up ends.
@(private)
effect_tick :: proc(s: ^Server, c: ^Client) {
	if c.effect == {} {return}
	if s.tick >= c.effect.until {
		c.effect = {}
		return
	}
	heal_player(c, c.effect.regen / f32(game.TICK_RATE))
}

// effect_defence: the fraction of harm c's running effect takes off.
@(private)
effect_defence :: proc(s: ^Server, c: ^Client) -> f32 {
	return c.effect.defence if s.tick < c.effect.until else 0
}

// most_health: c's most health: its character's (BASE_HEALTH and what it wears) and
// the game's bonus.
@(private)
most_health :: proc(s: ^Server, c: ^Client) -> f32 {
	return max(character_mods(s, c).max_health + c.health_bonus, 1)
}

// player_health_bonus: the game adds bonus health points to c's most (a level's,
// a blessing's; 0: none): from the next tick its health tops out there, a lower most
// cuts what it has. It stays with the seat until the game changes it.
player_health_bonus :: proc(s: ^Server, c: ^Client, bonus: f32) {
	c.health_bonus = max(bonus, 0)
}

// --- Experience ----------------------------------------------------------

// xp_for: what an event of kind earns (0: nothing).
xp_for :: proc(kind: telemetry.Kind) -> u64 {
	#partial switch kind {
	case .Block_Mined, .Block_Placed, .Entity_Hit:
		return 1
	case .Item_Used:
		return 2
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
	award_xp_amount(s, c, xp_for(kind))
}

// award_xp_amount: c earns gain experience (a level gained is told as one).
award_xp_amount :: proc(s: ^Server, c: ^Client, gain: u64) {
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
