package core

import "core:fmt"
import "core:math"
import "core:strconv"

import "common:game"

// The damage pipeline: everything that hurts a player (falls, explosions,
// weapons, commands) goes through `damage`, which asks the abilities and the
// rules, and everything that kills goes through `die`. A death is told from
// its source (game.death_text); there are no branches per source. The names a
// script will call are in script_api.odin.

Damage_Source :: struct {
	kind:     game.Source_Kind,
	attacker: Maybe(u16), // the player who did it
	creature: u32, // the entity that did it (its id; 0: none): a creature's blow or shot
	kind_of:  game.Kind_Id, // ... its kind (named in the message, though it is gone)
	weapon:   string, // its item's name, for the message
	stack:    game.Stack, // what the player struck or shot with (empty: nothing, or no player)
	pos:      [3]f64, // where it came from (when placed)
	placed:   bool,
}

// Harm: what hurt a player, as a game's hurt and died hooks are told it.
Harm :: struct {
	amount:   f32, // the health points it took
	kind:     game.Source_Kind, // a fall, an explosion, a weapon...
	by:       ^Client, // the player who did it (the one hurt, for its own rocket; nil: nobody, or one no longer playing)
	creature: u32, // the entity that did it (its id; 0: none; it may be gone)
	weapon:   string, // what a shot came from: its item's name ("" for any other)
}

// Harming: a harm about to be done, as a game's harming hook is shown it before it is:
// the hook may change the amount (a player's stats, armour, a critical blow, a rolled
// weapon); 0 or less and nothing is done. Every harm passes it: player to player,
// player to entity, entity to player, entity to entity, blasts, falls, the game's own.
Harming :: struct {
	amount:   f32,
	kind:     game.Source_Kind,
	by:       ^Client, // the player who does it (nil: none)
	creature: u32, // the entity that does it (its id; 0: none)
	stack:    game.Stack, // what the player strikes or shoots with (empty: nothing, or no player)
	to:       ^Client, // the player harmed (nil: an entity)
	entity:   game.Entity_Handle, // the entity harmed (0: a player)
	world:    ^World, // where
}

// harming: what the game's harming hook makes of an amount (the amount, with none).
harming :: proc(s: ^Server, h: Harming) -> f32 {
	if s.config.game.harming == nil {return h.amount}
	h := h
	s.config.game.harming(s, &h)
	return h.amount
}

Damage_Result :: enum u8 {
	Ignored, // nothing to hurt (not playing, dead, no amount)
	Blocked, // invulnerable, just come back (spawn_protection), pvp off, or no health at all
	Hurt,
	Killed,
}

// damage: hurt target by amount health points from source.
damage :: proc(s: ^Server, target: ^Client, amount: f32, source: Damage_Source) -> Damage_Result {
	if !(amount > 0) || target.state != .Playing || target.dead {return .Ignored}
	if s.tick < target.protected_until {return .Blocked}
	abilities := game.derive_abilities(s.registry, target.mode, &target.inventory)
	if .Invulnerable in abilities {return .Blocked}
	if attacker, by_player := source.attacker.?; by_player {
		if int(attacker) != int(player_id(s, target)) && !target.world.rules.pvp {return .Blocked}
	}
	if .Health not_in abilities {return .Blocked}
	taken := harming(
		s,
		{
			amount = amount,
			kind = source.kind,
			by = attacker(s, source),
			creature = source.creature,
			stack = source.stack,
			to = target,
			world = target.world,
		},
	)
	if !(taken > 0) {return .Blocked}
	target.health = max(target.health - taken, 0)
	target.last_damage = s.tick
	record(
		s,
		target,
		.Damage,
		game.damage_source_name(source.kind),
		i64(math.round(taken * 10)),
		i64(math.round(target.health * 10)),
	)
	hit := game.Damage_Hit {
		amount = taken,
		known  = source.placed,
	}
	if source.placed {
		d := source.pos - target.player.position
		hit.yaw = f32(math.atan2(-d.x, -d.z)) // (a yaw: 0 looks down -z)
	}
	event_send(s, target, .Damage_Hit, &hit)
	session_damage(s, target, taken, source, target.health <= 0)
	harm := Harm{taken, source.kind, attacker(s, source), source.creature, source.weapon}
	g := &s.config.game
	if target.health <= 0 {
		die(s, target, source)
		if g.died != nil {g.died(s, target, harm)}
		return .Killed
	}
	if g.hurt != nil {g.hurt(s, target, harm)}
	return .Hurt
}

// attacker: the playing client the source names (nil for none).
@(private = "file")
attacker :: proc(s: ^Server, source: Damage_Source) -> ^Client {
	if id, ok := source.attacker.?; ok && int(id) < len(s.clients) {
		if a := &s.clients[id]; a.state == .Playing {return a}
	}
	return nil
}

// attacker_name: who the source names ("" for none).
@(private = "file")
attacker_name :: proc(s: ^Server, source: Damage_Source) -> string {
	if a := attacker(s, source); a != nil {return client_name(a)}
	if info := game.kind_info(s.registry, source.kind_of);
	   info != nil {return game.kind_name(info)}
	return ""
}

// die: c is dead of source: counted and told to all, their things dropped by
// the mode and the rule, and they wait at the death screen for Respawn.
die :: proc(s: ^Server, c: ^Client, source: Damage_Source) {
	cause := game.damage_source_name(source.kind)
	killer := attacker_name(s, source)
	record(s, c, .Death, cause)
	stat_add(c, "deaths", 1)
	if id, ok := source.attacker.?; ok && killer != "" && int(id) != int(player_id(s, c)) {
		stat_add(&s.clients[id], "kills", 1)
	}
	died := game.Player_Died{cause, killer, source.weapon}
	event_send(s, c, .Player_Died, &died)
	chat_system(
		s,
		fmt.tprintf(
			"&7%s",
			game.death_text(source.kind, client_name(c), killer, source.weapon, false),
		),
	)
	w := c.world
	if .Drop_On_Death in game.derive_abilities(s.registry, c.mode, &c.inventory) &&
	   !w.rules.keep_inventory {
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
	c.health = 0
	c.dead = true
	c.died_at = s.tick
	c.airborne = false
	c.open_chest = nil
	disturb(s, c)
}

// respawn_due: the tick a dead c may come back at (the world's respawn_delay
// after its death).
respawn_due :: proc(c: ^Client) -> u64 {
	return c.died_at + seconds_ticks(c.world.rules.respawn_delay)
}

// respawn_ask: c pressed Respawn: it comes back once the delay is over
// (before then, nothing happens; the death screen counts it down).
respawn_ask :: proc(s: ^Server, c: ^Client) -> bool {
	if !c.dead || s.tick < respawn_due(c) {return false}
	return respawn(s, c)
}

// seconds_ticks: seconds of a rule as whole ticks, rounded.
@(private = "file")
seconds_ticks :: proc(seconds: f32) -> u64 {
	return u64(math.round(f64(max(seconds, 0)) * f64(game.TICK_RATE)))
}

// respawn: a dead c stands at the world's spawn with full health and the
// mode's kit (the Respawn button once the delay is over, or by itself under
// respawn_auto; also what leaving while dead does), unhurt for the world's
// spawn_protection, and then the game's respawned hook may move it and
// change what it holds.
respawn :: proc(s: ^Server, c: ^Client) -> bool {
	if !c.dead {return false}
	c.dead = false
	c.protected_until = s.tick + seconds_ticks(c.world.rules.spawn_protection)
	c.max_health = character_mods(s, c).max_health
	c.health = c.max_health
	c.airborne = false
	c.last_damage = s.tick
	land_at_spawn(s, c, remember = false)
	kit_give(s, c)
	record(s, c, .Respawned, game.mode_label(s.registry, c.mode))
	disturb(s, c)
	if s.config.game.respawned != nil {s.config.game.respawned(s, c)}
	return true
}

// kit_give: what the character's mode's kit has that they lack (so a kept
// inventory is not doubled); full magazines are the weapons' (weapons.odin).
kit_give :: proc(s: ^Server, c: ^Client) {
	if !c.mode_set {return}
	for e in s.registry.game_modes[c.mode].kit {
		have := game.inventory_count(&c.inventory, e.item)
		if have >= int(e.count) {continue}
		want := int(e.count) - have
		left := game.inventory_add_at(
			s.registry,
			&c.inventory,
			{e.item, want, game.new_ammo(s.registry, e.item), 0},
			e.place,
			e.worn,
		)
		ledger(s, c.world, .Kit, e.item, want - left.count)
		c.inv_changed = true
	}
	refill_weapons(s, c)
}

// regenerate: health comes back by itself for a mode that regenerates, under
// the rules (natural_regeneration, its delay and rate): after the delay without
// damage, the rate a second.
regenerate :: proc(s: ^Server, c: ^Client) {
	r := &c.world.rules
	if !r.natural_regeneration || c.health >= c.max_health {return}
	if .Regenerate not_in game.derive_abilities(s.registry, c.mode, &c.inventory) {return}
	delay := u64(math.round(f64(r.regen_delay) * f64(game.TICK_RATE)))
	if s.tick - c.last_damage < delay {return}
	heal_player(c, r.regen_rate / f32(game.TICK_RATE))
}

// admin_damage: damage <player> <amount>: hurt a player by a command (a source
// like any other: the abilities and rules decide).
@(private)
admin_damage :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	target := client_by_name(s, args[0])
	if target == nil {
		notice(s, c, fmt.tprintf("&cNo player %s here", args[0]))
		return true
	}
	amount, ok := strconv.parse_f32(args[1])
	if !ok || amount <= 0 {return false}
	result := damage(s, target, amount, {kind = .Command})
	notice(s, c, fmt.tprintf("%s: %v", client_name(target), result))
	return true
}
