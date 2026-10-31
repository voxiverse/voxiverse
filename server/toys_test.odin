package server

import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "common:game"

// The party's toys on the server (issue #65): the survival kit's places on join and
// on respawn, and the shotgun: eight pellets of two, the pattern a function of
// the shot's seed (not of the server's tick), a magazine of six, a pump's
// pause, and "shotgun" in the death message.

@(private = "file")
Toys :: struct {
	kit:                     [game.INVENTORY_SLOTS]game.Item,
	feet:                    game.Item,
	full:                    bool, // every weapon in the kit has a full magazine
	respawn_kit:             [game.INVENTORY_SLOTS]game.Item,
	respawn_feet:            game.Item,
	respawn_full:            bool,
	by_seed:                 [40]f32, // the damage of the shot with seed `after` = i
	again, later:            f32, // seed 7 again, and at another tick
	ammo_before, ammo_after: int,
	interval:                f64,
	wall_hurt:               bool,
	killed:                  bool,
}

@(private = "file")
toys: Toys

@(private = "file")
aim_at :: proc(from, to: [3]f64) -> (yaw, pitch: f32) {
	d := to - from
	return f32(math.atan2(-d.x, -d.z)), f32(math.atan2(d.y, math.sqrt(d.x * d.x + d.z * d.z)))
}

@(private = "file")
full_magazines :: proc(s: ^Server, c: ^Client) -> bool {
	for st in c.inventory.slots {
		if game.stack_empty(st) {continue}
		info, _ := game.item_info(s.registry, st.item)
		if w, ok := info.weapon.?; ok && int(st.ammo) != w.magazine {return false}
	}
	return true
}

@(private = "file")
kit_scenario :: proc(s: ^Server, _: rawptr) {
	alice := client_by_name(s, "alice")
	if alice == nil {return}
	survival, _ := game.mode_find(s.registry, "survival")
	set_game_mode(s, alice, survival, {"test", ""})
	ledger_inventory(s, alice.world, .Clear, &alice.inventory)
	alice.inventory = {}
	kit_give(s, alice) // (what a spawn gives)
	toys.full = full_magazines(s, alice)
	for st, i in alice.inventory.slots {toys.kit[i] = st.item}
	toys.feet = alice.inventory.equipment[.Feet].item
	// Dead, and the Respawn button: the same again.
	ledger_inventory(s, alice.world, .Clear, &alice.inventory)
	alice.inventory = {}
	alice.health, alice.dead = 0, true
	respawn(s, alice)
	toys.respawn_full = full_magazines(s, alice)
	for st, i in alice.inventory.slots {toys.respawn_kit[i] = st.item}
	toys.respawn_feet = alice.inventory.equipment[.Feet].item
}

@(private = "file")
shoot :: proc(s: ^Server, c: ^Client, after: u32, yaw, pitch: f32) -> bool {
	c.shot_due = 0
	refill_weapons(s, c)
	return weapon_shoot(
		s,
		c,
		{after = after, slot = u8(c.inventory.selected), press = true, yaw = yaw, pitch = pitch},
		0,
	)
}

@(private = "file")
shotgun_scenario :: proc(s: ^Server, _: rawptr) {
	alice, bob := client_by_name(s, "alice"), client_by_name(s, "bob")
	if alice == nil || bob == nil {return}
	w := alice.world
	reg := s.registry
	shotgun, _ := game.item_by_name(reg, "shotgun")
	survival, _ := game.mode_find(reg, "survival")
	for c in ([]^Client{alice, bob}) {
		set_game_mode(s, c, survival, {"test", ""})
		c.max_health, c.health, c.dead = 100, 100, false
	}
	w.rules.pvp = true
	base := alice.player.position
	p := game.Block_Pos{i32(math.floor(base.x)), i32(math.floor(base.y)), i32(math.floor(base.z))}
	for dx in i32(-7) ..= 7 {
		for dz in i32(-6) ..= 6 {
			for dy in i32(0) ..= 3 {set_block(w, p + {dx, dy, dz}, .Air, test_act(w))}
		}
	}
	alice.player.position = base
	bob.player.position = base + {4, 0, 0}
	alice.inventory.slots[0] = {shotgun, 1, game.new_ammo(reg, shotgun)}
	alice.inventory.selected = 0
	alice.reload_until = 0
	s.tick += 20_000
	chest := bob.player.position + {0, 0.9, 0}
	yaw, pitch := aim_at(game.player_eye(alice.player), chest)

	hurt :: proc(bob: ^Client) -> f32 {
		d := 100 - bob.health
		bob.health = 100
		return d
	}
	for i in 0 ..< len(toys.by_seed) {
		shoot(s, alice, u32(i), yaw, pitch)
		toys.by_seed[i] = hurt(bob)
	}
	shoot(s, alice, 7, yaw, pitch)
	toys.again = hurt(bob)
	s.tick += 1234 // (the seed is not the tick)
	shoot(s, alice, 7, yaw, pitch)
	toys.later = hurt(bob)

	// The magazine, the pump's pause, the wall.
	alice.shot_due, alice.reload_until = 0, 0
	refill_weapons(s, alice)
	toys.ammo_before = int(alice.inventory.slots[0].ammo)
	weapon_shoot(s, alice, {after = 3, slot = 0, press = true, yaw = yaw, pitch = pitch}, 0)
	toys.ammo_after = int(alice.inventory.slots[0].ammo)
	hurt(bob)
	info, _ := game.item_info(reg, shotgun)
	toys.interval = weapon_interval(info.weapon.?)
	set_block(w, game.Block_Pos{p.x + 2, p.y, p.z}, .Stone, test_act(w))
	set_block(w, game.Block_Pos{p.x + 2, p.y + 1, p.z}, .Stone, test_act(w))
	shoot(s, alice, 8, yaw, pitch)
	toys.wall_hurt = hurt(bob) > 0
	set_block(w, game.Block_Pos{p.x + 2, p.y, p.z}, .Air, test_act(w))
	set_block(w, game.Block_Pos{p.x + 2, p.y + 1, p.z}, .Air, test_act(w))

	// A kill.
	bob.health = 1
	shoot(s, alice, 9, yaw, pitch)
	toys.killed = bob.dead
}

@(test)
test_party_toys :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "toys"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	os.make_directory_all(dir)
	toys = {}
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
	ok = net_wait(
		t,
		both,
		proc(cs: []^Net_Client) -> bool {return at_rest(cs[0]) && at_rest(cs[1])},
		30,
	)
	if !testing.expect(t, ok, "never came to rest") {return}

	// The kit: hotbar rifle, shotgun, sniper, launcher, hook; the pistol in the pockets;
	// jump boots on the feet; full magazines. On a spawn and on a respawn.
	call(srv, kit_scenario, nil)
	reg := srv.registry
	names := [?]string{"rifle", "shotgun", "sniper", "rocket_launcher", "grappling_hook"}
	for name, i in names {
		item, _ := game.item_by_name(reg, name)
		testing.expectf(t, toys.kit[i] == item, "hotbar slot %d is not the %s", i + 1, name)
		testing.expectf(
			t,
			toys.respawn_kit[i] == item,
			"after a respawn slot %d is not the %s",
			i + 1,
			name,
		)
	}
	pistol, _ := game.item_by_name(reg, "pistol")
	boots, _ := game.item_by_name(reg, "jump_boots")
	testing.expect_value(t, toys.kit[game.HOTBAR_SLOTS], pistol)
	testing.expect_value(t, toys.respawn_kit[game.HOTBAR_SLOTS], pistol)
	testing.expect_value(t, toys.feet, boots)
	testing.expect_value(t, toys.respawn_feet, boots)
	testing.expect(t, toys.full && toys.respawn_full, "the kit's magazines are full")

	// The shotgun.
	call(srv, shotgun_scenario, nil)
	spread_out := 0
	seen: [17]bool
	for d, i in toys.by_seed {
		testing.expectf(
			t,
			d <= 16 && int(d) % 2 == 0,
			"seed %d did %v damage: pellets are 2 each",
			i,
			d,
		)
		if d >= 0 && d <= 16 && !seen[int(d)] {
			seen[int(d)] = true
			spread_out += 1
		}
	}
	testing.expect(t, spread_out >= 3, "the pellets' pattern does not change with the seed")
	testing.expect(t, toys.by_seed[7] > 0, "a shotgun at 4 blocks hit with no pellet")
	testing.expect_value(t, toys.again, toys.by_seed[7])
	testing.expect_value(t, toys.later, toys.by_seed[7]) // (the same seed at another tick)
	testing.expect_value(t, toys.ammo_before, 6)
	testing.expect_value(t, toys.ammo_after, 5)
	testing.expectf(
		t,
		math.abs(toys.interval - 27) < 0.5,
		"%.1f ticks between shots, about 0.9 s",
		toys.interval,
	)
	testing.expect(t, !toys.wall_hurt, "pellets went through a wall")
	testing.expect(t, toys.killed, "the shotgun did not kill a player with 1 health")
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {
		for c in cs {
			found := false
			for line in c.chat {
				found ||= strings.contains(
					game.format_strip(line.text),
					"bob was shot by alice (shotgun)",
				)
			}
			if !found {return false}
		}
		return true
	})
	testing.expect(t, ok, "the death message does not name the shotgun")
}
