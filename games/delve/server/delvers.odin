package delve_server

import "core:fmt"
import "core:math"

import "common:base"
import "common:game"
import "games:delve"
import "server:core"

// The delvers: what their blows do (their level, their weapon's rolled bonus, a critical
// hit), what creatures' blows do to them, experience and levels, the whirl and the
// potion (the game's two actions), and the loot creatures and chests leave.

SHARE_RADIUS :: 24.0 // blocks: delvers this near a kill share its experience

// harming: every harm passes here before it is done. A delver's blow, shot or whirl:
// times its level's damage and its weapon's rolled bonus, and now and then a critical
// hit. A creature's blow or spit: its depth's toughness (an elite's more). The amount
// that lands floats up over what took it.
harming :: proc(s: ^core.Server, h: ^core.Harming) {
	d := state(s)
	w := s.home
	crit_hit := false
	if h.by != nil && h.entity != 0 && here(s, h.by) {
		h.amount *= delve.level_damage(seat(s, h.by).level)
		if weapon_of(d, h.stack.item) {
			h.amount *= 1 + f32(delve.loot_bonus(h.stack.data)) / 100
		}
		if crit(s) {
			h.amount *= delve.CRIT_DAMAGE
			crit_hit = true
		}
	}
	if h.creature != 0 && h.to != nil {
		h.amount = foe_damage(s, h.creature, h.amount)
	}
	if !(h.amount > 0) || h.world != w {return}
	at: [3]f64
	switch {
	case h.entity != 0:
		info := game.kind_info(s.registry, core.entity_kind(w, h.entity))
		at = core.entity_pos(w, h.entity) + {0, f64(info.box[1]), 0}
	case h.to != nil:
		at = h.to.player.position + {0, 1.9, 0}
	case:
		return
	}
	hit := delve.Hit {
		at     = {f32(at.x), f32(at.y), f32(at.z)},
		amount = u16(clamp(math.round(h.amount), 1, 65535)),
		crit   = crit_hit,
		taken  = h.to != nil,
	}
	for &c in s.clients {
		if !here(s, &c) || flat_distance(c.player.position, at) > 48 {continue}
		core.game_event(s, &c, &hit)
	}
}

// weapon_of: the item is one of the game's weapons (its data is a roll).
weapon_of :: proc(d: ^Run, item: game.Item) -> bool {
	for w in d.weapons {if w == item {return true}}
	return false
}

// entity_died: a creature's death gives experience to its killer and the delvers near,
// and its loot; the warden's opens the way down. A chest's spills its loot.
entity_died :: proc(
	s: ^core.Server,
	w: ^core.World,
	dead: core.Dead_Entity,
	harm: core.Entity_Harm,
) {
	d := state(s)
	if w != s.home {return}
	if dead.kind == d.chest {
		loot(s, dead.position, 2, coins = 4 + base.rng_int_max(&d.rng, 6), weapon_chance = 0.6)
		return
	}
	f := foe_of(s, dead.id)
	if f == nil {return}
	slot := f^
	foe_forget(s, dead.id)
	info := delve.FOES[slot.foe]
	xp := info.xp * slot.level * (3 if slot.elite else 1)
	if harm.by != nil && here(s, harm.by) {
		seat(s, harm.by).kills += 1
		for &c in s.clients {
			if !here(s, &c) || c.dead {continue}
			if &c != harm.by && flat_distance(c.player.position, dead.position) > SHARE_RADIUS {
				continue
			}
			gain(s, &c, xp)
		}
	}
	luck := 0
	chance := 0.06
	switch {
	case slot.foe == .Warden:
		luck, chance = 3, 1
	case slot.elite:
		luck, chance = 1, 0.5
	}
	coins := info.coins * slot.level * (3 if slot.elite else 1)
	loot(s, dead.position, luck, coins, chance)
	if slot.foe == .Warden {
		d.warden = 0
		by := core.client_name(harm.by) if harm.by != nil else ""
		event := delve.Warden_Down{by}
		for &c in s.clients {if here(s, &c) {core.game_event(s, &c, &event)}}
		core.announce(s, "&eThe Warden falls&r: the way down is open")
		open_way(s)
	}
}

// loot: coins, maybe a potion, maybe a weapon rolled for the depth (luck: better odds).
loot :: proc(s: ^core.Server, at: [3]f64, luck, coins: int, weapon_chance: f64) {
	d := state(s)
	w := s.home
	r := &d.rng
	above := at + {0, 0.5, 0}
	if coins > 0 {core.item_drop(s, w, above, {d.coin, coins, 0, 0})}
	if base.rng_f64(r) < 0.15 + 0.15 * f64(luck) {core.item_drop(s, w, above, {d.potion, 1, 0, 0})}
	if base.rng_f64(r) < weapon_chance {
		weapon, data := delve.loot_roll(r, d.depth, luck)
		core.item_drop(s, w, above, {d.weapons[weapon], 1, 0, data})
	}
}

// gain: c earns experience; each level reached raises its most health and tells it.
gain :: proc(s: ^core.Server, c: ^core.Client, xp: int) {
	p := seat(s, c)
	p.xp += xp
	for p.level < delve.MAX_LEVEL && p.xp >= delve.xp_to_next(p.level) {
		p.xp -= delve.xp_to_next(p.level)
		p.level += 1
		core.player_health_bonus(s, c, delve.level_health(p.level))
		core.heal_player(c, 4)
		event := delve.Level_Up{u8(clamp(p.level, 0, 255))}
		core.game_event(s, c, &event)
		core.notice(s, c, fmt.tprintf("&aLevel %d&r: more health, harder blows", p.level))
	}
}

// action: the whirl (0) strikes every creature around the delver; the potion (1) heals.
action :: proc(s: ^core.Server, c: ^core.Client, index: int) {
	if !here(s, c) {return}
	d := state(s)
	p := seat(s, c)
	switch index {
	case 0:
		if s.tick < p.whirl_at {return}
		p.whirl_at = s.tick + u64(delve.WHIRL_SECONDS * game.TICK_RATE)
		w := s.home
		held := game.inventory_held(&c.inventory)
		for h in core.entities_of(w, 0, c.player.position, delve.WHIRL_RADIUS) {
			if foe_of(s, core.entity_id(w, h)) == nil &&
			   core.entity_kind(w, h) != d.chest {continue}
			core.entity_harm(
				w,
				h,
				{amount = delve.WHIRL_DAMAGE, kind = .Hit, by = c, weapon = "whirl", stack = held},
			)
		}
	case 1:
		if c.health >= c.max_health || core.item_take(s, c, d.potion, 1) == 0 {return}
		core.heal_player(c, delve.POTION_HEAL)
	}
}

// picking: coins and potions always go into the pack; a weapon too (the hotbar holds
// them), the engine's way.
picking :: proc(s: ^core.Server, c: ^core.Client, stack: game.Stack) -> core.Pickup {
	return .Take if here(s, c) && !c.dead else .Leave
}
