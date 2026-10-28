package server

import "core:math"

import "../common/game"
import "../common/netcode"

// Hitscan weapons. A weapon is an item with a `weapon` object (data: its
// damage, magazine, rate, range...); this file is the only place that fires
// one. The client says "I pulled the trigger, aiming yaw/pitch"; the server
// decides everything else: the weapon, the magazine, the rate, the dead, the
// ray from where it has the player's eye (blocks first, then bodies as the
// shooter saw them: rewind.odin) and the damage (damage.odin: the abilities
// and the pvp rule have their say). The client predicts only effects.

SHOT_HEARD :: 96.0 // blocks: others within this see the tracer
HEAD_START :: 0.75 // the head is the top quarter of a body's box

Shot_Target :: enum u8 {
	None,
	Block,
	Player,
	Creature,
}

// Shot_Result: what a ray from a weapon met first.
Shot_Result :: struct {
	kind:     Shot_Target,
	distance: f64, // to what it met (the range when nothing)
	player:   ^Client,
	creature: u32, // an entity id
	head:     bool,
}

// shooter_latency_ms: how far behind the world a client sees: their round trip
// and the interpolation delay it draws others with.
shooter_latency_ms :: proc(s: ^Server, c: ^Client) -> f32 {
	rtt: f32
	if peer, remote := c.link.(netcode.Peer_Id); remote && s.listening {
		if conn := netcode.host_conn(&s.host, peer); conn != nil {rtt = conn.rtt_ms}
	}
	return rtt + 1000 * f32(game.INTERPOLATION_TICKS) / f32(game.TICK_RATE)
}

// held_weapon: the weapon in c's hand: its stack, what it does, its item's name.
held_weapon :: proc(
	s: ^Server,
	c: ^Client,
) -> (
	stack: ^game.Stack,
	info: game.Weapon_Info,
	name: string,
	ok: bool,
) {
	stack = &c.inventory.slots[clamp(c.inventory.selected, 0, game.HOTBAR_SLOTS - 1)]
	if game.stack_empty(stack^) {return}
	item, _ := game.item_info(s.registry, stack.item)
	info, ok = item.weapon.?
	name = game.item_name(s.registry, stack.item)
	return
}

// shot_trace: the first thing a ray from origin along dir (a unit vector) meets
// within range: a block, or a player or creature as it stood latency_ms ago.
// A body in front of a wall is hit; one behind it is not.
shot_trace :: proc(
	s: ^Server,
	shooter: ^Client,
	origin, dir: [3]f64,
	range: f64,
	latency_ms: f32,
) -> Shot_Result {
	w := shooter.world
	res := Shot_Result {
		distance = range,
	}
	query := game.Block_Query{&w.chunks, chunks_block, &s.registry.blocks}
	if hit, ok := game.raycast(query, origin, dir, range); ok {
		res.kind, res.distance = .Block, hit.distance
	}
	frame := rewind_frame(s, w, rewind_ticks(latency_ms))
	for &o, i in s.clients {
		if &o == shooter || o.state != .Playing || o.world != w || o.dead {continue}
		body := o.player
		if frame != nil {
			if b, there := rewind_body(frame.players[:], u32(i)); there {
				body.position, body.crouched = b.position, b.crouched
			}
		}
		lo, hi := game.player_box(body)
		if t, hit := game.ray_box(origin, dir, lo, hi, res.distance); hit && t < res.distance {
			point := origin + dir * t
			res = {.Player, t, &o, 0, point.y >= lo.y + HEAD_START * (hi.y - lo.y)}
		}
	}
	for &ent in w.entities.list {
		if !game.ENTITY_INFO[ent.kind].hittable {continue}
		at := ent.body.position
		if frame != nil {
			if b, there := rewind_body(frame.creatures[:], ent.id); there {at = b.position}
		}
		lo, hi := game.entity_box(ent.kind, at)
		if t, hit := game.ray_box(origin, dir, lo, hi, res.distance); hit && t < res.distance {
			point := origin + dir * t
			res = {.Creature, t, nil, ent.id, point.y >= lo.y + HEAD_START * (hi.y - lo.y)}
		}
	}
	return res
}

// spread_offset: a repeatable pair of offsets in -1 ..< 1 from a seed.
@(private = "file")
spread_offset :: proc(seed: u64) -> [2]f32 {
	h := seed * 0x9E37_79B9_7F4A_7C15
	h ~= h >> 31
	h *= 0xD1B5_4A32_D192_ED03
	h ~= h >> 29
	return {f32(h & 0xFFFF) / 32768 - 1, f32((h >> 16) & 0xFFFF) / 32768 - 1}
}

// weapon_interval: ticks between shots, as a fraction (the rate is shots a second).
weapon_interval :: proc(info: game.Weapon_Info) -> f64 {
	return f64(game.TICK_RATE) / f64(info.fire_rate)
}

// weapon_shoot: c pulled the trigger of the weapon in hand, aimed yaw/pitch.
// false: refused (no weapon, the wrong slot, reloading, empty, too early).
weapon_shoot :: proc(
	s: ^Server,
	c: ^Client,
	m: game.Shoot,
	claimed_latency_ms := f32(-1),
) -> bool {
	if c.dead || int(m.slot) != c.inventory.selected {return false}
	stack, info, name, ok := held_weapon(s, c)
	if !ok {return false}
	if c.reload_until != 0 {return false} 	// (reloading: the trigger does nothing)
	if !info.automatic && !m.press {return false}
	// The rate: a shot a little early (a tick's jitter) is let through, the
	// average is the data's; a client that keeps firing too early is counted.
	if f64(s.tick) + 1 < c.shot_due {
		c.shots_refused += 1
		return false
	}
	if stack.ammo == 0 {
		weapon_reload(s, c)
		return false
	}
	c.shot_due = max(c.shot_due, f64(s.tick) - 1) + weapon_interval(info)
	stack.ammo -= 1
	c.inv_changed = true

	yaw, pitch := m.yaw, m.pitch
	if info.spread > 0 {
		o := spread_offset(s.tick * 31 + u64(player_id(s, c)) + 1)
		yaw += o.x * info.spread
		pitch = clamp(pitch + o.y * info.spread, -game.PITCH_LIMIT, game.PITCH_LIMIT)
	}
	dir := forward(yaw, pitch)
	origin := game.player_eye(c.player)
	latency_ms := claimed_latency_ms if claimed_latency_ms >= 0 else shooter_latency_ms(s, c)
	res := shot_trace(s, c, origin, dir, f64(info.range), latency_ms)

	id := player_id(s, c)
	hit, killed := false, false
	switch res.kind {
	case .Player:
		amount := info.damage * (info.headshot if res.head else 1)
		source := Damage_Source {
			kind     = .Weapon,
			attacker = id,
			weapon   = name,
			pos      = origin,
			placed   = true,
		}
		switch damage(s, res.player, amount, source) {
		case .Hurt:
			hit = true
		case .Killed:
			hit, killed = true, true
		case .Ignored, .Blocked:
		}
	case .Creature:
		w := c.world
		if ent, index := entity_find(w, res.creature); ent != nil {
			hit = true
			record(s, c, .Entity_Hit, game.ENTITY_INFO[ent.kind].name)
			if entity_attack(w, ent, c.player.position) {
				killed = true
				record(s, c, .Entity_Killed, game.ENTITY_INFO[ent.kind].name)
				entity_died(w, index)
			} else {
				entity_hurt_shown(w, res.creature)
			}
		}
	case .Block, .None:
	}
	if hit {
		confirm := game.Hit_Confirm {
			kill     = killed,
			headshot = res.head,
		}
		event_send(s, c, .Hit_Confirm, &confirm)
	}
	record(s, c, .Shot_Fired, name, 1 if hit else 0)

	// Everyone else near sees the tracer.
	shot := game.Shot{id, stack.item, origin, origin + dir * res.distance}
	for &o in s.clients {
		if &o == c || o.state != .Playing || o.world != c.world {continue}
		d := o.player.position - origin
		if d.x * d.x + d.y * d.y + d.z * d.z > SHOT_HEARD * SHOT_HEARD {continue}
		event_send(s, &o, .Shot, &shot)
	}
	return true
}

// weapon_reload: start reloading the weapon in hand (nothing if it is full,
// already reloading, or no weapon). The magazine fills when the time is up
// (weapons_tick); changing the held slot cancels it.
weapon_reload :: proc(s: ^Server, c: ^Client) -> bool {
	if c.dead || c.reload_until != 0 {return false}
	stack, info, _, ok := held_weapon(s, c)
	if !ok || int(stack.ammo) >= info.magazine {return false}
	ticks := max(1, int(math.ceil(f64(info.reload_time) * game.TICK_RATE)))
	c.reload_until = s.tick + u64(ticks)
	c.reload_slot = c.inventory.selected
	return true
}

// weapons_tick: once a tick for each playing client: a reload ends or is
// cancelled (the hand moved on, or the weapon is gone).
weapons_tick :: proc(s: ^Server, c: ^Client) {
	if c.reload_until == 0 {return}
	stack, info, _, ok := held_weapon(s, c)
	if c.dead || !ok || c.inventory.selected != c.reload_slot {
		c.reload_until = 0
		return
	}
	if s.tick >= c.reload_until {
		stack.ammo = u8(info.magazine)
		c.reload_until = 0
		c.inv_changed = true
	}
}

// refill_weapons: every weapon c carries has a full magazine again (the kit's).
refill_weapons :: proc(s: ^Server, c: ^Client) {
	fill :: proc(s: ^Server, st: ^game.Stack) -> bool {
		if game.stack_empty(st^) {return false}
		item, _ := game.item_info(s.registry, st.item)
		w, is_weapon := item.weapon.?
		if !is_weapon || int(st.ammo) == w.magazine {return false}
		st.ammo = u8(w.magazine)
		return true
	}
	for &st in c.inventory.slots {if fill(s, &st) {c.inv_changed = true}}
	for &st in c.inventory.equipment {if fill(s, &st) {c.inv_changed = true}}
	if fill(s, &c.inventory.cursor) {c.inv_changed = true}
	c.reload_until = 0
}
