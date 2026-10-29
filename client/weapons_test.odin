package client

import "core:math"
import "core:os"
import "core:path/filepath"
import "core:testing"

import "../common/game"
import "../server"

// Weapons on the client: the effects are at once and the client's own (the
// tracer, the flash, the sound, the recoil, the magazine), a hit is only the
// server's word (the marker), a semi-automatic weapon needs a press for each
// shot, a reload takes its time, the sniper's zoom eases in and out.

@(private = "file")
has_sound :: proc(s: ^Session, kind: Sound_Kind) -> bool {
	for e in s.sounds {if e.kind == kind {return true}}
	return false
}

@(test)
test_weapons_over_a_stepped_server :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "client_weapons"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	rig: Frame_Rig
	config := server.Config {
		save_dir    = dir,
		kit         = "rocket_launcher 1", // (the world's kit: the blocks of the other tests are not wanted)
		seed        = 33,
		view_radius = 3,
		view_height = 2,
		max_players = 2,
		listen      = true,
		no_sheep    = true,
		mode        = "survival",
		rules       = still_rules(),
	}
	if !testing.expect(t, server.harness_start(&rig.h, config)) {return}
	defer server.harness_stop(&rig.h)
	s := new(Session)
	defer free(s)
	key: game.Account_Key
	game.account_key_set(&key, {0 ..< 32 = 7})
	session_start(
		s,
		{
			name = "shooter",
			key = key,
			join = Join{address = server.harness_address(&rig.h)},
			view_radius = 3,
			view_height = 2,
			registry = test_reg(),
			net = &rig.h.net,
		},
	)
	defer session_end(s, nil, nil)
	rig_add(&rig, s)
	idle: Actions
	pistol, _ := game.item_by_name(s.reg, "pistol")
	rig.actions = &idle
	server.harness_step_until(&rig.h, proc(data: rawptr) -> bool {
			s := (^Frame_Rig)(data).s
			pistol, _ := game.item_by_name(s.reg, "pistol")
			return(
				s.state == .Playing &&
				s.server_inventory.slots[game.HOTBAR_SLOTS].item == pistol &&
				s.prediction.state.on_ground \
			)
		}, &rig, 3000)
	if !testing.expect_value(t, s.state, Session_State.Playing) {return}
	// The survival kit: the hotbar's rifle, shotgun, sniper, launcher and hook, the pistol in
	// the pockets. The pistol is what this test fires: it swaps into the first slot.
	rifle, _ := game.item_by_name(s.reg, "rifle")
	shotgun, _ := game.item_by_name(s.reg, "shotgun")
	sniper, _ := game.item_by_name(s.reg, "sniper")
	testing.expect_value(t, s.inventory.slots[0].item, rifle)
	testing.expect_value(t, s.inventory.slots[1].item, shotgun)
	session_inventory_do(s, {.Swap_Hotbar, game.HOTBAR_SLOTS, 0})
	server.harness_step_until(&rig.h, proc(data: rawptr) -> bool {
			s := (^Frame_Rig)(data).s
			pistol, _ := game.item_by_name(s.reg, "pistol")
			return s.server_inventory.slots[0].item == pistol
		}, &rig, 300)
	testing.expect_value(t, s.inventory.slots[0].item, pistol)
	testing.expect_value(t, s.inventory.slots[0].ammo, u8(12))
	testing.expect_value(t, s.inventory.slots[2].item, sniper)
	testing.expect_value(t, s.inventory.slots[2].ammo, u8(5))
	for _ in 0 ..< 30 {rig_frame(&rig, &idle)}

	// A target in front of us, a block off, in line with the eyes' look down at it.
	feet := s.prediction.state.position
	sheep := server.entity_spawn(rig.h.srv.worlds[0], .Sheep, feet + {0, 0, -1.4}, false)
	if !testing.expect(t, sheep != nil) {return}
	s.camera.yaw = 0
	s.camera.pitch = f32(math.atan2(-(1.62 - 0.45), 1.0))
	for _ in 0 ..< 6 {rig_frame(&rig, &idle)} 	// (a few ticks of history to rewind to)
	sheep.body.position = feet + {0, 0, -1.4}

	// Fire: the effects are there the same frame; no hit is guessed.
	press := Actions {
		pressed = {.Attack},
		down    = {.Attack},
	}
	rig_frame(&rig, &press)
	testing.expect_value(t, s.shots, 1)
	testing.expect(t, has_sound(s, .Shot_Pistol), "the shot's sound plays at once")
	testing.expect(t, len(s.puffs) > 0, "the tracer and the flash are at once")
	testing.expect(t, s.recoil > 0, "the view kicks")
	testing.expect_value(t, weapon_ammo(s, held(s)), 11) // the counter, predicted
	testing.expect_value(t, s.confirms, 0) // (a hit is the server's word)
	testing.expect_value(t, s.marker, f32(0))
	// Held down, a semi-automatic pistol fires once.
	hold_down := Actions {
		down = {.Attack},
	}
	for _ in 0 ..< 20 {rig_frame(&rig, &hold_down)}
	testing.expect_value(t, s.shots, 1)
	rig_frame(&rig, &idle)
	// The server's word arrived: the magazine, the hit.
	for _ in 0 ..< 10 {rig_frame(&rig, &idle)}
	testing.expect_value(t, s.server_inventory.slots[0].ammo, u8(11))
	testing.expect_value(t, s.confirms, 1)
	testing.expect(t, has_sound(s, .Hit), "the hit has its sound")

	// R: reload (not twice); the magazine is full again after the reload time.
	reload := Actions {
		pressed = {.Reload},
	}
	rig_frame(&rig, &reload)
	testing.expect(t, weapon_reloading(s), "the reload shows")
	rig_frame(&rig, &reload)
	for _ in 0 ..< int(1.4 * game.TICK_RATE) + 10 {rig_frame(&rig, &idle)}
	testing.expect_value(t, s.server_inventory.slots[0].ammo, u8(12))
	testing.expect(t, !weapon_reloading(s))

	// The sniper: holding the use button zooms (the field of view eases to a
	// quarter), releasing eases back; turning is slower while zoomed.
	select := Actions {
		pressed = {.Hotbar_3},
	}
	rig_frame(&rig, &select)
	zoom := Actions {
		down = {.Use},
	}
	for _ in 0 ..< 30 {rig_frame(&rig, &zoom)}
	fov := camera_fov(s, SETTINGS_DEFAULTS)
	testing.expectf(
		t,
		abs(fov - SETTINGS_DEFAULTS.fov * 0.25) < 1,
		"zoomed field of view %v of %v",
		fov,
		SETTINGS_DEFAULTS.fov,
	)
	testing.expect(t, zoom_factor(s) < 0.3)
	for _ in 0 ..< 30 {rig_frame(&rig, &idle)}
	testing.expect(t, abs(camera_fov(s, SETTINGS_DEFAULTS) - SETTINGS_DEFAULTS.fov) < 1)
}

// The scale of looking follows the zoom: a quarter of the view, a quarter of the turn.
@(test)
test_zoom_slows_the_look :: proc(t: ^testing.T) {
	v1, v2: View
	input := Input_State {
		look = {100, 0},
	}
	a: Actions
	look_update(&v1, &input, &a, SETTINGS_DEFAULTS, 0.016)
	look_update(&v2, &input, &a, SETTINGS_DEFAULTS, 0.016, 0.25)
	testing.expect(t, abs(v2.yaw - v1.yaw * 0.25) < 1e-6)
}
