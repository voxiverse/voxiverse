package console

import "core:math"
import "core:strconv"
import "core:strings"

import "client:engine"
import "common:base"
import "common:game"


// The developer console's world primitives (commands): placing
// the camera for a picture. Everything that changes the world is a server
// command, typed with a slash (as in the chat); nothing here duplicates a key,
// the UI or a server command.

@(private)
register_world_commands :: proc(c: ^engine.Console) {
	console_register(
		c,
		{
			"look",
			"look <yaw> <pitch>: turn to (degrees; yaw left from north, pitch up)",
			proc(app: ^engine.App, args: []string) {
				yaw, y_ok := strconv.parse_f32(args[0])
				pitch, p_ok := strconv.parse_f32(args[1])
				if !y_ok || !p_ok {
					engine.console_print(&app.console, "look <yaw> <pitch>: two numbers", .Warning)
					return
				}
				app.session.camera.yaw = math.to_radians(yaw)
				app.session.camera.pitch = math.to_radians(clamp(pitch, -89, 89))
			},
		},
		args = {2, 2},
		needs = {.World},
	)
	console_register(
		c,
		{
			"use",
			"use: the right button once on what is aimed at (a chest opens, a creature is used)",
			proc(app: ^engine.App, args: []string) {
				s := app.session
				if !(engine.session_use_entity(s) || engine.session_use_block(s)) {
					engine.console_print(
						&app.console,
						"nothing aimed at that can be used",
						.Warning,
					)
				}
			},
		},
		needs = {.World},
	)
	console_register(
		c,
		{
			"hold",
			"hold <item>: select the hotbar slot that holds this item (after /give; an empty name: the empty hand's slot)",
			proc(app: ^engine.App, args: []string) {
				s := app.session
				for st, i in s.inventory.slots[:game.HOTBAR_SLOTS] {
					info, known := game.item_info(s.reg, st.item)
					if game.stack_empty(st) || !known {continue}
					if info.name == args[0] ||
					   strings.has_suffix(
						   info.name,
						   strings.concatenate({":", args[0]}, context.temp_allocator),
					   ) {
						engine.session_inventory_do(s, {.Select, 0, i})
						return
					}
				}
				engine.console_print(&app.console, "no such item on the hotbar", .Warning)
			},
		},
		args = {1, 1},
		needs = {.World},
	)
	console_register(
		c,
		{
			"camera",
			"camera <first|behind|facing> [degrees]: the camera's mode (F5 cycles them); the degrees turn a third person camera round the head, for a picture. A development build's: camera at <x> <y> <z> <yaw> <pitch>: the camera put there, whatever the game's camera and the player (who stays); camera reset: the game's again",
			proc(app: ^engine.App, args: []string) {
				if args[0] == "at" || args[0] == "reset" {
					camera_place_command(app, args)
					return
				}
				if len(args) > 2 {
					engine.console_print(
						&app.console,
						"camera <first|behind|facing> [degrees]",
						.Warning,
					)
					return
				}
				if len(args) > 1 {
					degrees, ok := strconv.parse_f32(args[1])
					if !ok {
						engine.console_print(
							&app.console,
							"camera <first|behind|facing> [degrees]",
							.Warning,
						)
						return
					}
					app.session.orbit = math.to_radians(degrees)
				} else {
					app.session.orbit = 0
				}
				switch args[0] {
				case "first":
					app.session.camera_mode = .First
				case "behind":
					app.session.camera_mode = .Third_Behind
				case "facing":
					app.session.camera_mode = .Third_Facing
				case:
					engine.console_print(&app.console, "camera <first|behind|facing>", .Warning)
				}
			},
		},
		args = {1, 6},
		needs = {.World},
	)
}

// camera_place_command: `camera at <x> <y> <z> <yaw> <pitch>` and `camera reset`, a
// development build's (engine.camera_place).
@(private)
camera_place_command :: proc(app: ^engine.App, args: []string) {
	if !base.DEV {
		engine.console_print(&app.console, "camera at: a development build's", .Warning)
		return
	}
	s := app.session
	if args[0] == "reset" {
		engine.camera_release(s)
		return
	}
	view, ok := camera_at_parse(args[1:])
	if !ok {
		engine.console_print(
			&app.console,
			"camera at <x> <y> <z> <yaw> <pitch>: five numbers",
			.Warning,
		)
		return
	}
	engine.camera_place(s, view)
	// The session holds the chunks round the player alone.
	far := f64(i32(s.welcome.view_radius) - 1) * game.CHUNK_SIZE
	if d := view.position.xz - s.camera.position.xz; d.x * d.x + d.y * d.y > far * far {
		engine.console_print(
			&app.console,
			"camera at: farther from the player than the world it is sent (/tp it nearer first)",
			.Warning,
		)
	}
}

// camera_at_parse: the view `camera at` names, from its five numbers: where (blocks), the
// yaw and the pitch (degrees, as `look` and /tp take them).
camera_at_parse :: proc(args: []string) -> (view: engine.View, ok: bool) {
	if len(args) != 5 {return}
	n: [5]f64
	for a, i in args {n[i] = strconv.parse_f64(a) or_return}
	view.position = {n[0], n[1], n[2]}
	view.yaw = math.to_radians(f32(n[3]))
	view.pitch = math.to_radians(clamp(f32(n[4]), -89, 89))
	return view, true
}
