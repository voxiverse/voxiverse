package core


import "core:fmt"
import "core:log"
import "core:strconv"
import "core:strings"

import "common:game"
import "common:protocol"

// Health, damage, death and what a character grows by. A player has health
// points (BASE_HEALTH, plus what they wear: common/game/mods.odin); a fall of more
// than 3 blocks onto ground costs a point a block, an explosion costs by how
// near it was; at nought a player dies (a Death event, the inventory dropped
// where they fell if the character's mode drops them and keep_inventory is off);
// they wait at the death screen and the Respawn button wakes them at the world's
// spawn once the world's respawn_delay is over (or they wake by themselves then,
// under respawn_auto), unhurt for its spawn_protection (damage.odin: the one
// pipeline). What a survivor does may also earn experience (experience_gain), where
// the registry has a level curve (data/levels): kept as the counters `xp` and `level`
// (so saved with the character), and spent on its skills (admin_skill), which every
// rule they change reads (game.skill_value).

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
		health := protocol.Health{c.health, c.max_health, true, game.NO_ITEM, 0}
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
	health := protocol.Health{c.health, c.max_health, false, game.NO_ITEM, 0}
	if c.effect != {} && s.tick < c.effect.until {
		left := (c.effect.until - s.tick + game.TICK_RATE - 1) / game.TICK_RATE
		health.effect, health.effect_left =
			c.effect.item, u16(min(left, protocol.MAX_EFFECT_SECONDS))
	}
	state_put(s, c, .Health, &health) // (nothing is sent while it is unchanged: the effect's time once a second)
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
// and a fraction of harm taken off, until a tick; the item, which its player is shown with
// its seconds left (Health). Not saved: it ends with its time, a death or the session.
Effect :: struct {
	regen, defence: f32,
	until:          u64,
	item:           game.Item,
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
	strength := game.skill_value(s.registry, &c.skills, .Consume_Strength, 1)
	heal_player(c, use.heal * strength)
	c.effect = {}
	if use.seconds > 0 {
		c.effect = {
			use.regen * strength,
			use.defence,
			s.tick + seconds_ticks(use.seconds),
			held.item,
		}
	}
	record(s, c, .Item_Used, game.item_name(s.registry, held.item))
	quest_note(s, c, {goal = .Use, item = held.item, count = 1})
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

// most_health: c's most health: its character's (BASE_HEALTH and what it wears) as its
// skills make it, and the game's bonus.
@(private)
most_health :: proc(s: ^Server, c: ^Client) -> f32 {
	worn := character_mods(s, c).max_health
	return max(game.skill_value(s.registry, &c.skills, .Max_Health, worn) + c.health_bonus, 1)
}

// player_health_bonus: the game adds bonus health points to c's most (a level's,
// a blessing's; 0: none): from the next tick its health tops out there, a lower most
// cuts what it has. It stays with the seat until the game changes it.
player_health_bonus :: proc(s: ^Server, c: ^Client, bonus: f32) {
	c.health_bonus = max(bonus, 0)
}

// --- Experience and skills -------------------------------------------------

// survivor: whether what c does counts for its quests and earns it experience: playing,
// alive and able to be hurt (not in creative, not watching).
@(private)
survivor :: proc(s: ^Server, c: ^Client) -> bool {
	if c.state != .Playing || c.dead {return false}
	a := game.derive_abilities(s.registry, c.mode, &c.inventory)
	return .Health in a && .Invulnerable not_in a && .Bodiless not_in a && .Spectate not_in a
}

// experience: the experience c's character has earned (its counter `xp`).
@(private)
experience :: proc(c: ^Client) -> u64 {
	return c.stats["xp"] or_else 0
}

// experience_gain: c earns gain experience, where the registry has a level curve
// (game.progression_on) and c is a survivor: kept as its counter `xp`, and a level gained
// as `level` and told (Level_Up). Its player sees both in the `progress` record.
experience_gain :: proc(s: ^Server, c: ^Client, gain: u64) {
	if gain == 0 || !game.progression_on(s.registry) || !survivor(s, c) {return}
	experience_add(s, c, gain)
}

// experience_add: gain experience to c, whoever it is (the xp command's).
@(private = "file")
experience_add :: proc(s: ^Server, c: ^Client, gain: u64) {
	stat_add(c, "xp", gain)
	xp := experience(c)
	level := u64(game.level_of(s.registry, xp))
	if now := c.stats["level"] or_else 1; level > now {
		counter_set(&c.stats, "level", level)
		emit_event(
			s,
			event_for(s, c.world, .Level_Up, player_id(s, c), "", {i64(level), i64(xp), 0}),
		)
	}
}

// experience_note: what a quest's step counts that earns experience too: a creature
// killed (the curve's kill for each point of its threat), an item made (counted as
// `items.made.<item>`; the curve's make the first time) and an encounter won.
@(private)
experience_note :: proc(s: ^Server, c: ^Client, e: game.Quest_Event) {
	p := &s.registry.progression
	#partial switch e.goal {
	case .Kill:
		threat := game.kind_threat(game.kind_info(s.registry, e.creature))
		experience_gain(s, c, u64(p.xp[.Kill]) * u64(threat))
	case .Make:
		if e.count <= 0 {return}
		counter := fmt.tprintf("items.made.%s", game.item_name(s.registry, e.item))
		first := (c.stats[counter] or_else 0) == 0
		stat_add(c, counter, u64(e.count))
		if first {experience_gain(s, c, u64(p.xp[.Make]))}
	case .Win:
		experience_gain(s, c, u64(p.xp[.Win]))
	}
}

// skill_value: a rule's value as c's skills make it (game.skill_value): what a game's
// own rule a skill changes reads (a recipe's time, `.Craft_Time`, and its yield).
skill_value :: proc(s: ^Server, c: ^Client, effect: game.Skill_Effect, base: f32) -> f32 {
	return game.skill_value(s.registry, &c.skills, effect, base)
}

// SKILL_REFUSALS: what a player is told of a rank it cannot learn.
@(private = "file", rodata)
SKILL_REFUSALS := [game.Skill_Refusal]string {
	.None    = "",
	.Unknown = "&cNo such skill",
	.Full    = "&cYou have every rank of that skill",
	.Shut    = "&cSpend more points in its branch first",
	.Points  = "&cYou have too few skill points",
}

// admin_skill: skill [<skill> | reset]: with nothing, c's level, experience and points and
// its rank in each skill; with a skill (its id, or its name without the namespace), a rank
// more of it if c can learn one (game.skill_learn); with reset, every skill unlearnt for
// nothing where the curve allows it (game.respec_near: by its respec block).
@(private)
admin_skill :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	reg := s.registry
	if len(reg.skills) == 0 {
		notice(s, c, "&cThere are no skills to learn here")
		return true
	}
	xp := experience(c)
	if len(args) == 0 {
		given, spent := game.skill_points(reg, xp, &c.skills)
		notice(
			s,
			c,
			fmt.tprintf(
				"Level %d, %d experience: %d of %d points left",
				game.level_of(reg, xp),
				xp,
				given - spent,
				given,
			),
		)
		for &def, i in reg.skills {
			notice(s, c, fmt.tprintf("%s %d/%d", def.id, c.skills.ranks[i], def.ranks))
		}
		return true
	}
	if args[0] == "reset" {
		w := c.world
		query := game.Block_Query{&w.chunks, chunks_block, &reg.blocks, {}}
		if !game.respec_near(reg, query, c.player.position) {
			_, _, name := strings.partition(reg.progression.respec_name, ":")
			block, _ := strings.replace_all(name, "_", " ", context.temp_allocator)
			article :=
				"an" if len(block) > 0 && strings.index_byte("aeiou", block[0]) >= 0 else "a"
			notice(
				s,
				c,
				fmt.tprintf(
					"&cStand within %d blocks of %s %s to unlearn your skills",
					reg.progression.respec_reach,
					article,
					block,
				),
			)
			return true
		}
		c.skills = {}
		given, _ := game.skill_points(reg, xp, &c.skills)
		log.infof("server skills unlearnt name=%s", client_name(c))
		notice(s, c, fmt.tprintf("Your skills are unlearnt: %d points to spend", given))
		return true
	}
	at, found := game.skill_by_id(reg, args[0])
	for &def, i in reg.skills {
		if found {break}
		_, _, name := strings.partition(def.id, ":")
		if name == args[0] {at, found = i, true}
	}
	if !found {
		notice(s, c, fmt.tprintf("&cNo skill %s", args[0]))
		return true
	}
	if why := game.skill_learn(reg, &c.skills, xp, at); why != .None {
		notice(s, c, SKILL_REFUSALS[why])
		return true
	}
	def := &reg.skills[at]
	log.infof(
		"server skill learnt name=%s skill=%s rank=%d",
		client_name(c),
		def.id,
		c.skills.ranks[at],
	)
	notice(s, c, fmt.tprintf("%s: rank %d of %d", def.title, c.skills.ranks[at], def.ranks))
	return true
}

// admin_xp: xp <player> <amount>: give a player (a name or a selector, @s) experience
// (whatever its mode: the command's word, not a deed).
@(private)
admin_xp :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	target := find_player(s, c, args[0])
	if target == nil {
		notice(s, c, fmt.tprintf("&cNo player %s here", args[0]))
		return true
	}
	amount, ok := strconv.parse_u64(args[1])
	if !ok || amount == 0 || amount > 1_000_000_000 {return false}
	if !game.progression_on(s.registry) {
		notice(s, c, "&cThere is no experience here")
		return true
	}
	experience_add(s, target, amount)
	notice(s, c, fmt.tprintf("%s: %d experience", client_name(target), experience(target)))
	return true
}
