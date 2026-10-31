package server

import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "common:game"

// Hitscan weapons: the server alone decides (the ray from where it has the
// player's eye, blocks first, bodies as the shooter saw them), the numbers are
// the data's, magazines and reloads and the rate are the server's timers, the
// pvp rule and the abilities have their say, and the others see the shot as an
// event.

@(private = "file")
Result :: struct {
	hit_100_past, miss_100_now, hit_0_now, hit_400_capped, miss_400_old, miss_400_now: bool,
	rewound_ticks_100, rewound_ticks_400, rewound_ticks_9999:                          int,
	wall_kind:                                                                         Shot_Target,
	wall_bob_hurt:                                                                     bool,
	body_damage, head_damage, data_damage:                                             f32,
	head_trace:                                                                        bool,
	ammo_after_12, ammo_after_reload, ammo_while_reloading:                            int,
	reload_started, reload_when_full, reload_cancelled:                                bool,
	full_after_refill:                                                                 bool,
	semi_refused, auto_ok, rifle_shots, pistol_shots, early_refused:                   int,
	pvp_off_hurt, pvp_on_hurt, creature_hit:                                           bool,
	killed:                                                                            bool,
	ammo_on_wire_ok:                                                                   bool,
	bad_slot, dead_shot:                                                               bool,
}

@(private = "file")
res: Result

@(private = "file")
Rig :: struct {
	alice, bob:            ^Client,
	w:                     ^World,
	base:                  [3]f64,
	pistol, rifle, sniper: game.Item,
}

@(private = "file")
aim :: proc(from, to: [3]f64) -> (yaw, pitch: f32) {
	d := to - from
	return f32(math.atan2(-d.x, -d.z)), f32(math.atan2(d.y, math.sqrt(d.x * d.x + d.z * d.z)))
}

// shoot_at: c fires the weapon in hand at a point, at a latency (the rate is
// not what is tried: it starts clear).
@(private = "file")
shoot_at :: proc(s: ^Server, c: ^Client, target: [3]f64, latency: f32, press := true) -> bool {
	yaw, pitch := aim(game.player_eye(c.player), target)
	c.shot_due = 0
	return weapon_shoot(
		s,
		c,
		{slot = u8(c.inventory.selected), press = press, yaw = yaw, pitch = pitch},
		latency,
	)
}

@(private = "file")
hold :: proc(rig: ^Rig, item: game.Item) {
	reg := rig.alice.world.server.registry
	rig.alice.inventory.slots[0] = {item, 1, game.new_ammo(reg, item)}
	rig.alice.inventory.selected = 0
	rig.alice.reload_until = 0
}

@(private = "file")
stage :: proc(s: ^Server) -> (rig: Rig, ok: bool) {
	rig.alice, rig.bob = client_by_name(s, "alice"), client_by_name(s, "bob")
	if rig.alice == nil || rig.bob == nil {return}
	rig.w = rig.alice.world
	reg := s.registry
	rig.pistol, _ = game.item_by_name(reg, "pistol")
	rig.rifle, _ = game.item_by_name(reg, "rifle")
	rig.sniper, _ = game.item_by_name(reg, "sniper")
	survival, _ := game.mode_find(reg, "survival")
	for c in ([]^Client{rig.alice, rig.bob}) {
		set_game_mode(s, c, survival, {"test", ""})
		c.max_health, c.health, c.dead = 100, 100, false
	}
	rig.w.rules.pvp = true
	rig.base = rig.alice.player.position
	// A clear room: air around both, in the shooter's line.
	p := game.Block_Pos {
		i32(math.floor(rig.base.x)),
		i32(math.floor(rig.base.y)),
		i32(math.floor(rig.base.z)),
	}
	for dx in i32(-7) ..= 7 {
		for dz in i32(-6) ..= 6 {
			for dy in i32(0) ..= 3 {
				set_block(rig.w, p + {dx, dy, dz}, .Air, test_act(rig.w))
			}
		}
	}
	rig.alice.player.position = rig.base
	rig.bob.player.position = rig.base + {4, 0, 0}
	hold(&rig, rig.sniper)
	return rig, true
}

@(private = "file")
chest :: proc(c: ^Client) -> [3]f64 {return c.player.position + {0, 0.9, 0}}

@(private = "file")
head :: proc(c: ^Client) -> [3]f64 {return c.player.position + {0, 1.6, 0}}

@(private = "file")
hurt :: proc(c: ^Client) -> bool {
	was := c.health < 100
	c.health = 100
	c.dead = false
	return was
}

@(private = "file")
shots_scenario :: proc(s: ^Server, _: rawptr) {
	rig, ok := stage(s)
	if !ok {return}
	s.tick += 20_000
	alice, bob, w := rig.alice, rig.bob, rig.w
	reg := s.registry

	// The numbers are the data's: the sniper's 18 on the body, 36 on the head.
	shoot_at(s, alice, chest(bob), 0)
	res.body_damage = 100 - bob.health
	bob.health = 100
	shoot_at(s, alice, head(bob), 0)
	res.head_damage = 100 - bob.health
	bob.health = 100
	res.head_trace =
		shot_trace(s, alice, game.player_eye(alice.player), {1, 0, 0}, 50, 0).kind == .Player
	// ... and changing the data changes them, with no code changed.
	info := &reg.items.pack[int(rig.sniper - game.PACK_ITEMS)]
	was := info.weapon.?.damage
	changed := info.weapon.?
	changed.damage = 9
	info.weapon = changed
	hold(&rig, rig.sniper)
	shoot_at(s, alice, chest(bob), 0)
	res.data_damage = 100 - bob.health
	bob.health = 100
	changed.damage = was
	info.weapon = changed

	// Lag compensation: bob crosses the line of fire at 8 blocks a second.
	start := rig.base + {4, 0, 0}
	t0 := s.tick
	for i in 0 ..< 12 {
		s.tick = t0 + u64(i)
		bob.player.position = start + {0, 0, 8.0 * f64(i) / game.TICK_RATE}
		rewind_record(s, w)
	}
	s.tick = t0 + 12 // (bob stands where the last tick left him: 2.93 across)
	res.rewound_ticks_100 = rewind_ticks(100)
	res.rewound_ticks_400 = rewind_ticks(400)
	res.rewound_ticks_9999 = rewind_ticks(9999)
	hold(&rig, rig.sniper)
	at :: proc(start: [3]f64, across: f64) -> [3]f64 {return start + {0, 0.9, across}}
	live := bob.player.position
	res.hit_100_past = false
	shoot_at(s, alice, at(start, 8.0 * 8 / game.TICK_RATE), 100) // where he was 3 ticks back
	res.hit_100_past = hurt(bob)
	shoot_at(s, alice, at(start, live.z - start.z), 100) // where he is now
	res.miss_100_now = !hurt(bob)
	shoot_at(s, alice, at(start, live.z - start.z), 0) // no latency: now
	res.hit_0_now = hurt(bob)
	// Past the cap: tested at the capped rewind (8 ticks back), no further.
	hold(&rig, rig.sniper)
	shoot_at(s, alice, at(start, 8.0 * 3 / game.TICK_RATE), 400)
	res.hit_400_capped = hurt(bob)
	shoot_at(s, alice, at(start, 0), 400) // where he was 400 ms ago: out of the window
	res.miss_400_old = !hurt(bob)
	shoot_at(s, alice, at(start, live.z - start.z), 400)
	res.miss_400_now = !hurt(bob)
	bob.player.position = start

	// A wall: the shot stops at the block, the player behind it is not hit.
	wall := game.Block_Pos {
		i32(math.floor(rig.base.x)) + 2,
		i32(math.floor(rig.base.y)) + 1,
		i32(math.floor(rig.base.z)),
	}
	set_block(w, wall, .Stone, test_act(w))
	hold(&rig, rig.sniper)
	yaw, pitch := aim(game.player_eye(alice.player), chest(bob))
	_ = pitch
	shoot_at(s, alice, chest(bob), 0)
	res.wall_bob_hurt = hurt(bob)
	res.wall_kind =
		shot_trace(s, alice, game.player_eye(alice.player), forward(yaw, pitch), 100, 0).kind
	set_block(w, wall, .Air, test_act(w))
	hold(&rig, rig.sniper)

	// The dead and the wrong slot cannot shoot.
	alice.dead = true
	res.dead_shot = shoot_at(s, alice, chest(bob), 0)
	alice.dead = false
	res.bad_slot = weapon_shoot(s, alice, {slot = 3, press = true}, 0)
	bob.health = 100
}

@(private = "file")
magazine_scenario :: proc(s: ^Server, _: rawptr) {
	rig, ok := stage(s)
	if !ok {return}
	alice, bob := rig.alice, rig.bob
	hold(&rig, rig.pistol)
	up := alice.player.position + {0, 50, 0}
	// Twelve shots, then empty: the thirteenth starts a reload and fires nothing.
	fired := 0
	for _ in 0 ..< 12 {if shoot_at(s, alice, up, 0) {fired += 1}}
	res.ammo_after_12 = int(alice.inventory.slots[0].ammo) + 100 * fired
	res.reload_started = !shoot_at(s, alice, up, 0) && alice.reload_until != 0
	// The reload takes its time: nothing at 41 ticks, full at 42 (1.4 s).
	s.tick += 41
	weapons_tick(s, alice)
	res.ammo_while_reloading = int(alice.inventory.slots[0].ammo)
	s.tick += 1
	weapons_tick(s, alice)
	res.ammo_after_reload = int(alice.inventory.slots[0].ammo)
	res.reload_when_full = weapon_reload(s, alice) // (nothing to do)
	// Changing the held slot cancels a reload.
	alice.inventory.slots[0].ammo = 3
	weapon_reload(s, alice)
	alice.inventory.selected = 1
	weapons_tick(s, alice)
	res.reload_cancelled = alice.reload_until == 0 && alice.inventory.slots[0].ammo == 3
	alice.inventory.selected = 0
	// The kit's refill.
	alice.inventory.slots[0].ammo = 0
	alice.inventory.slots[1] = {rig.rifle, 1, 0}
	refill_weapons(s, alice)
	res.full_after_refill =
		alice.inventory.slots[0].ammo == 12 && alice.inventory.slots[1].ammo == 30

	// The rate and the trigger: semi-automatic needs a press each time.
	hold(&rig, rig.pistol)
	alice.shot_due = 0
	res.semi_refused = 0
	if !weapon_shoot(s, alice, {slot = 0, press = false}, 0) {res.semi_refused += 1}
	// A second a pistol is held down: 4 shots a second (the data's), not one a tick.
	hold(&rig, rig.pistol)
	alice.shot_due = 0
	count := 0
	for _ in 0 ..< 30 {
		s.tick += 1
		alice.inventory.slots[0].ammo = 12
		if weapon_shoot(s, alice, {slot = 0, press = true}, 0) {count += 1}
	}
	res.pistol_shots = count
	res.early_refused = alice.shots_refused
	// An automatic rifle held for a second: 10 shots.
	hold(&rig, rig.rifle)
	alice.shot_due = 0
	alice.inventory.slots[0].ammo = 30
	count = 0
	for _ in 0 ..< 30 {
		s.tick += 1
		if weapon_shoot(s, alice, {slot = 0, press = false}, 0) {count += 1}
	}
	res.rifle_shots = count
	_ = bob
}

@(private = "file")
rules_scenario :: proc(s: ^Server, _: rawptr) {
	rig, ok := stage(s)
	if !ok {return}
	alice, bob, w := rig.alice, rig.bob, rig.w
	s.tick += 20_000
	hold(&rig, rig.pistol)
	// pvp off: a shot at a player does nothing; a creature is still hit.
	w.rules.pvp = false
	shoot_at(s, alice, chest(bob), 0)
	res.pvp_off_hurt = hurt(bob)
	sheep := entity_spawn(w, .Sheep, rig.base + {-4, 0, 0}, false)
	if sheep != nil {
		before := sheep.health
		shoot_at(s, alice, sheep.body.position + {0, 0.4, 0}, 0)
		res.creature_hit = sheep.health == before - 1
	}
	// pvp on: it hurts (the pistol's 5).
	w.rules.pvp = true
	hold(&rig, rig.pistol)
	shoot_at(s, alice, chest(bob), 0)
	res.pvp_on_hurt = hurt(bob)
	// A kill: the sniper on the head of a bob with 5 left, the message in chat.
	hold(&rig, rig.sniper)
	bob.health = 5
	shoot_at(s, alice, head(bob), 0)
	res.killed = bob.dead
}

@(test)
test_weapons :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "weapons"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	os.make_directory_all(dir)
	res = {}
	h: Harness
	srv := &h.srv
	if !testing.expect(
		t,
		harness_start(
			&h,
			Config {
				seed = 22,
				mode = "survival",
				view_radius = 2,
				view_height = 1,
				save_dir = dir,
				max_players = 4,
				listen = true,
				generator = .Classic,
				no_sheep = true,
			},
		),
	) {return}
	defer harness_stop(&h)
	alice, bob: Net_Client
	net_connect(&alice, 0, "alice", h = &h)
	net_connect(&bob, 0, "bob", h = &h)
	defer net_close(&alice)
	defer net_close(&bob)
	both := []^Net_Client{&alice, &bob}
	ok := net_wait(t, both, proc(cs: []^Net_Client) -> bool {
		return cs[0].welcomed && cs[1].welcomed && cs[0].mode != "" && cs[1].mode != ""
	})
	if !testing.expect(t, ok, "never joined") {return}
	// (Standing still: the room is built around where they are.)
	ok = net_wait(
		t,
		both,
		proc(cs: []^Net_Client) -> bool {return at_rest(cs[0]) && at_rest(cs[1])},
		30,
	)
	if !testing.expect(t, ok, "never came to rest") {return}

	call(srv, shots_scenario, nil)
	testing.expect_value(t, res.rewound_ticks_100, 3)
	testing.expect_value(t, res.rewound_ticks_400, REWIND_MAX_TICKS)
	testing.expect_value(t, res.rewound_ticks_9999, REWIND_MAX_TICKS)
	testing.expect_value(t, res.body_damage, f32(18))
	testing.expect_value(t, res.head_damage, f32(36))
	testing.expect(t, res.head_trace, "the ray along the line meets the player")
	testing.expect_value(t, res.data_damage, f32(9)) // (the data changed, no code)
	testing.expect(t, res.hit_100_past, "aimed where he was 100 ms ago: a hit")
	testing.expect(t, res.miss_100_now, "aimed where he is now at 100 ms: a miss")
	testing.expect(t, res.hit_0_now, "no latency: tested where he is")
	testing.expect(t, res.hit_400_capped, "400 ms is the cap: tested at the capped rewind")
	testing.expect(t, res.miss_400_old, "where he was 400 ms ago is outside the window")
	testing.expect(t, res.miss_400_now, "where he is now: a miss at the cap too")
	testing.expect_value(t, res.wall_kind, Shot_Target.Block)
	testing.expect(t, !res.wall_bob_hurt, "a shot through a wall hits the wall, not the player")
	testing.expect(t, !res.dead_shot, "the dead do not shoot")
	testing.expect(t, !res.bad_slot, "a shot from a slot that is not in hand is refused")

	call(srv, magazine_scenario, nil)
	testing.expect_value(t, res.ammo_after_12, 1200) // 12 shots, 0 left
	testing.expect(t, res.reload_started, "an empty magazine starts a reload")
	testing.expect_value(t, res.ammo_while_reloading, 0)
	testing.expect_value(t, res.ammo_after_reload, 12)
	testing.expect(t, !res.reload_when_full, "R with a full magazine does nothing")
	testing.expect(t, res.reload_cancelled, "changing the held slot cancels the reload")
	testing.expect(t, res.full_after_refill, "refill_weapons fills every magazine")
	testing.expect_value(t, res.semi_refused, 1) // (a semi-automatic weapon needs a new press)
	testing.expectf(
		t,
		res.pistol_shots >= 4 && res.pistol_shots <= 5,
		"a held pistol made %d shots in a second",
		res.pistol_shots,
	)
	testing.expect(t, res.early_refused > 0, "too-early shots are refused and counted")
	testing.expectf(
		t,
		res.rifle_shots >= 9 && res.rifle_shots <= 11,
		"a held rifle made %d shots in a second",
		res.rifle_shots,
	)

	// Stand clear of the old shots' damage, then the rules.
	call(srv, rules_scenario, nil)
	testing.expect(t, !res.pvp_off_hurt, "pvp off: a shot at a player does nothing")
	testing.expect(t, res.creature_hit, "pvp off: a creature is still hit")
	testing.expect(t, res.pvp_on_hurt, "pvp on: it hurts")
	testing.expect(t, res.killed, "the sniper's headshot killed the weakened player")

	// The others saw the shots as events; the shooter was told of the hits
	// (the last one a kill) and the death is in both chats, once.
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {
		if cs[1].shots_seen == 0 || len(cs[0].confirms) == 0 {return false}
		for c in cs {
			found := false
			for line in c.chat {
				if strings.contains(
					game.format_strip(line.text),
					"bob was shot by alice (sniper)",
				) {found = true}
			}
			if !found {return false}
		}
		return true
	})
	testing.expect(t, ok, "the shots, the confirm or the death message did not reach them")
	testing.expect_value(t, alice.shots_seen, 0) // (the shooter predicts its own)
	last := alice.confirms[len(alice.confirms) - 1]
	testing.expect(t, last.kill && last.headshot, "the kill's confirm says kill and headshot")
	for c in both {
		n := 0
		for line in c.chat {
			if game.format_strip(line.text) == "bob was shot by alice (sniper)" {n += 1}
		}
		testing.expect_value(t, n, 1)
	}
}
