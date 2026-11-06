package main

import "core:testing"

import "client:dev"
import "client:engine"
import "client:hud"
import "client:testkit"
import "common:game"
import "server:core"

// Sprint and sneak (held or toggled), the sprint's widening of the view,
// view bobbing, F (the offhand swap over a stepped server), hold P (the
// player list) and F3's coordinates.

@(private = "file")
open_world :: proc() -> ^engine.Session {
	s := new(engine.Session)
	s.reg = testkit.test_reg()
	s.state = .Playing
	return s
}

@(private = "file")
close_world :: proc(s: ^engine.Session) {
	delete(s.others)
	delete(s.grants)
	free(s)
}

@(test)
test_sprint_and_sneak_modes :: proc(t: ^testing.T) {
	s := open_world()
	defer close_world(s)
	hold := engine.SETTINGS_DEFAULTS
	toggle := engine.SETTINGS_DEFAULTS
	toggle.sprint_toggle, toggle.sneak_toggle = true, true
	forward := [2]f32{0, 1}

	// Held: on while the key is down, and nothing is left over.
	a := engine.Actions {
		down = {.Sprint, .Sneak},
		move = forward,
	}
	a.pressed = {.Sprint, .Sneak}
	engine.movement_toggles(s, &a, hold)
	in_ := engine.player_input(&a, s)
	testing.expect(t, .Sprint in in_.buttons && .Sneak in in_.buttons)
	a = {
		move = forward,
	}
	engine.movement_toggles(s, &a, hold)
	in_ = engine.player_input(&a, s)
	testing.expect(t, .Sprint not_in in_.buttons && .Sneak not_in in_.buttons, "released")

	// Toggled: a press (and its release) keeps it on until pressed again.
	a = {
		move    = forward,
		pressed = {.Sprint, .Sneak},
		down    = {.Sprint, .Sneak},
	}
	engine.movement_toggles(s, &a, toggle)
	a = {
		move = forward,
	}
	for _ in 0 ..< 5 {engine.movement_toggles(s, &a, toggle)}
	in_ = engine.player_input(&a, s)
	testing.expect(t, .Sprint in in_.buttons && .Sneak in in_.buttons, "kept after the release")
	a = {
		move    = forward,
		pressed = {.Sprint, .Sneak},
		down    = {.Sprint, .Sneak},
	}
	engine.movement_toggles(s, &a, toggle)
	a = {
		move = forward,
	}
	engine.movement_toggles(s, &a, toggle)
	in_ = engine.player_input(&a, s)
	testing.expect(
		t,
		.Sprint not_in in_.buttons && .Sneak not_in in_.buttons,
		"off by the second press",
	)

	// A toggled sprint ends when you stop moving (after you had started); a
	// toggled sneak does not.
	a = {
		pressed = {.Sprint, .Sneak},
		down    = {.Sprint, .Sneak},
	} // (pressed standing still)
	engine.movement_toggles(s, &a, toggle)
	a = {}
	engine.movement_toggles(s, &a, toggle)
	testing.expect(t, s.sprint_on && s.sneak_on, "standing still keeps what was just pressed")
	a = {
		move = forward,
	}
	engine.movement_toggles(s, &a, toggle)
	a = {}
	engine.movement_toggles(s, &a, toggle)
	testing.expect(t, !s.sprint_on, "stopping ends the sprint")
	testing.expect(t, s.sneak_on, "but not the sneak")
	// Back to Hold clears the toggles.
	engine.movement_toggles(s, &a, hold)
	testing.expect(t, !s.sneak_on)
}

@(test)
test_sprint_fov_kick :: proc(t: ^testing.T) {
	s := open_world()
	defer close_world(s)
	w := Fake_World{}
	sprint := engine.Actions {
		down = {.Sprint},
		move = {0, 1},
	}
	settings := engine.SETTINGS_DEFAULTS
	testing.expect_value(t, engine.camera_fov(s, settings), settings.fov)
	for _ in 0 ..< 12 {engine.camera_update(s, &sprint, settings, fake_query(&w), 0.016, true)} 	// 0.19 s
	testing.expect(
		t,
		abs(engine.camera_fov(s, settings) - settings.fov * 1.08) < 1e-3,
		"widened by 8%",
	)
	// Partway: the kick follows the clock (0.15 s to the top).
	s.fov_kick = 0
	engine.camera_update(s, &sprint, settings, fake_query(&w), 0.075, true)
	testing.expect(t, abs(s.fov_kick - 0.5) < 1e-4, "half way after half the time")
	// Released: back down.
	still := engine.Actions{}
	for _ in 0 ..< 12 {engine.camera_update(s, &still, settings, fake_query(&w), 0.016, true)}
	testing.expect_value(t, engine.camera_fov(s, settings), settings.fov)
	// Off by its setting, and by Reduce motion.
	for off in ([]string{"setting", "motion"}) {
		settings = engine.SETTINGS_DEFAULTS
		if off == "setting" {settings.sprint_fov_kick = false} else {settings.reduce_motion = true}
		for _ in 0 ..< 12 {engine.camera_update(s, &sprint, settings, fake_query(&w), 0.016, true)}
		testing.expect_value(t, engine.camera_fov(s, settings), settings.fov)
	}
	// Standing still while the key is down does not widen it.
	s.fov_kick = 0
	standing := engine.Actions {
		down = {.Sprint},
	}
	for _ in 0 ..< 12 {engine.camera_update(s, &standing, engine.SETTINGS_DEFAULTS, fake_query(&w), 0.016, true)}
	testing.expect_value(t, s.fov_kick, 0)
}

@(test)
test_view_bobbing :: proc(t: ^testing.T) {
	w := Fake_World{}
	walk :: proc(s: ^engine.Session, w: ^Fake_World, settings: engine.Settings) {
		s.prediction.state.on_ground = true
		s.prediction.state.velocity = {0, 0, 4}
		a := engine.Actions {
			move = {0, 1},
		}
		for _ in 0 ..< 120 {engine.camera_update(s, &a, settings, fake_query(w), 0.016, true)}
	}
	s := open_world()
	defer close_world(s)
	s.camera = {
		position = {0.5, 1.6, 0.5},
	}
	moved := false
	for i in 0 ..< 200 {
		walk(s, &w, engine.SETTINGS_DEFAULTS)
		dy := s.view.position.y - s.camera.position.y
		testing.expect(t, abs(dy) <= engine.BOB_HEIGHT + 1e-9, "within the bob's height")
		if abs(dy) > 0.005 || abs(s.view.roll) > 0.0005 {moved = true}
		if i > 10 {break}
	}
	testing.expect(t, moved, "walking bobs the view")
	testing.expect(t, s.bob_amp > 0.99)
	// Off by its setting and by Reduce motion: the view is the eyes.
	for off in ([]string{"setting", "motion"}) {
		quiet := new(engine.Session)
		quiet.reg = testkit.test_reg()
		defer free(quiet)
		quiet.camera = {
			position = {0.5, 1.6, 0.5},
		}
		settings := engine.SETTINGS_DEFAULTS
		if off == "setting" {settings.view_bobbing = false} else {settings.reduce_motion = true}
		walk(quiet, &w, settings)
		testing.expect_value(t, quiet.view.position, quiet.camera.position)
		testing.expect_value(t, quiet.view.roll, 0)
	}
	// Standing, flying or in the air: none.
	s.prediction.state.on_ground = false
	a := engine.Actions{}
	for _ in 0 ..< 30 {engine.camera_update(s, &a, engine.SETTINGS_DEFAULTS, fake_query(&w), 0.016, true)}
	testing.expect_value(t, s.bob_amp, 0)
}

@(test)
test_player_list :: proc(t: ^testing.T) {
	s := open_world()
	defer close_world(s)
	rows := hud.player_rows(s)
	testing.expect_value(t, len(rows), 1)
	testing.expect_value(t, rows[0].ping, "-") // alone in our own world
	s.others[7] = {
		name = "zed",
	}
	s.others[3] = {
		name = "bob",
	}
	s.config.name = "amy"
	s.remote = true
	s.net.rtt_ms = 42
	rows = hud.player_rows(s)
	testing.expect_value(t, len(rows), 3)
	testing.expect_value(t, rows[0].name, "amy")
	testing.expect_value(t, rows[0].ping, "42 ms")
	testing.expect_value(t, rows[1].name, "bob")
	testing.expect_value(t, rows[2].name, "zed")
}

// The list's kills and deaths: the most kills first, then the fewest
// deaths, then the name; ourselves among the rest.
@(test)
test_player_list_kills_and_deaths :: proc(t: ^testing.T) {
	s := open_world()
	defer close_world(s)
	s.config.name = "amy"
	s.tally = {
		kills  = 3,
		deaths = 1,
	}
	s.others[1] = {
		name   = "bob",
		kills  = 3,
		deaths = 0,
	}
	s.others[2] = {
		name   = "cy",
		kills  = 5,
		deaths = 9,
	}
	s.others[3] = {
		name   = "al",
		kills  = 3,
		deaths = 1,
	}
	rows := hud.player_rows(s)
	names := [?]string{"cy", "bob", "al", "amy"}
	testing.expect_value(t, len(rows), len(names))
	for n, i in names {testing.expect_value(t, rows[i].name, n)}
	testing.expect_value(t, rows[0].kills, "5")
	testing.expect_value(t, rows[0].deaths, "9")
	testing.expect_value(t, rows[3].kills, "3")
	testing.expect_value(t, engine.tr(.Players_Kills), "Kills")
	testing.expect_value(t, engine.tr(.Players_Deaths), "Deaths")
}

@(test)
test_f3_coordinates :: proc(t: ^testing.T) {
	s := open_world()
	defer close_world(s)
	s.rules = game.RULES_DEFAULTS
	testing.expect(t, dev.coordinates_shown(s), "on by the rule")
	s.rules.show_coordinates = false
	testing.expect(
		t,
		!dev.coordinates_shown(s),
		"off by the rule, for a player without the permission",
	)
	append(&s.grants, game.Grant{pattern = "debug.coordinates", allow = true})
	testing.expect(t, dev.coordinates_shown(s), "and not for one with it")
}

// F: the hand's item and the offhand slot's change places, validated by the
// server and predicted at once. Over a stepped server: the launcher in the
// hand goes to the offhand and back; with nothing in either, nothing moves.
@(test)
test_swap_offhand_over_the_wire :: proc(t: ^testing.T) {
	// (on the heap: a Frame_Rig holds a whole Harness, 95 KB, and a test thread's stack is 512 KB on macOS)
	rig := new(Frame_Rig)
	defer free(rig)
	config := core.Config {
		seed              = 33,
		view_radius       = 3,
		view_height       = 2,
		max_players       = 2,
		listen            = true,
		no_natural_spawns = true,
		rules             = engine.still_rules(),
	}
	if !testing.expect(t, core.harness_start(&rig.h, config)) {return}
	defer core.harness_stop(&rig.h)
	s := new(engine.Session)
	defer free(s)
	key: game.Account_Key
	game.account_key_set(&key, {0 ..< 32 = 9})
	engine.session_start(
		s,
		{
			name = "swapper",
			key = key,
			join = engine.Join{address = core.harness_address(&rig.h)},
			view_radius = 3,
			view_height = 2,
			registry = testkit.test_reg(),
			net = &rig.h.net,
		},
	)
	defer engine.session_end(s, nil, nil)
	rig_add(rig, s)
	idle: engine.Actions
	rig.actions = &idle
	core.harness_step_until(&rig.h, proc(data: rawptr) -> bool {
			s := (^Frame_Rig)(data).s
			return s.state == .Playing && s.server_inventory.slots[0].item != 0
		}, rig, 3000)
	if !testing.expect_value(t, s.state, engine.Session_State.Playing) {return}
	launcher := s.inventory.slots[0].item // (whatever the kit put in the hand)
	testing.expect(t, launcher != 0)
	swap := engine.Actions {
		pressed = {.Swap_Offhand},
	}
	rig_frame(rig, &swap)
	testing.expect_value(t, s.inventory.equipment[.Offhand].item, launcher) // predicted at once
	testing.expect(t, game.stack_empty(s.inventory.slots[0]))
	for _ in 0 ..< 60 {rig_frame(rig, &idle)}
	testing.expect_value(t, s.server_inventory.equipment[.Offhand].item, launcher) // and the server's word
	testing.expect(t, game.stack_empty(s.server_inventory.slots[0]))
	rig_frame(rig, &swap)
	for _ in 0 ..< 60 {rig_frame(rig, &idle)}
	testing.expect_value(t, s.server_inventory.slots[0].item, launcher)
	testing.expect(t, game.stack_empty(s.server_inventory.equipment[.Offhand]))
	// Both empty: nothing to swap (not even sent as a change).
	s.inventory.slots[0] = {}
	s.server_inventory.slots[0] = {}
	before := s.inventory
	rig_frame(rig, &swap)
	testing.expect(t, s.inventory == before)
}
