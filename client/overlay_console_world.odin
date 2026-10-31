package client

import "core:math"
import "core:strconv"
import "core:strings"

import "common:game"


// The developer console's world primitives (docs/plan.md M19, commands): placing
// the camera for a picture. Everything that changes the world is a server
// command, typed with a slash (as in the chat); nothing here duplicates a key,
// the UI or a server command.

@(private)
register_world_commands :: proc(c: ^Console) {
	console_register(
		c,
		{
			"look",
			"look <yaw> <pitch>: turn to (degrees; yaw left from north, pitch up)",
			proc(app: ^App, args: []string) {
				yaw, y_ok := strconv.parse_f32(args[0])
				pitch, p_ok := strconv.parse_f32(args[1])
				if !y_ok || !p_ok {
					console_print(&app.console, "look <yaw> <pitch>: two numbers", .Warning)
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
			"use: the right button once on what is aimed at (a chest opens, a sheep is sheared)",
			proc(app: ^App, args: []string) {
				s := app.session
				if !(session_use_entity(s) || session_use_block(s)) {
					console_print(&app.console, "nothing aimed at that can be used", .Warning)
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
			proc(app: ^App, args: []string) {
				s := app.session
				for st, i in s.inventory.slots[:game.HOTBAR_SLOTS] {
					info, known := game.item_info(s.reg, st.item)
					if game.stack_empty(st) || !known {continue}
					if info.name == args[0] ||
					   strings.has_suffix(
						   info.name,
						   strings.concatenate({":", args[0]}, context.temp_allocator),
					   ) {
						session_inventory_do(s, {.Select, 0, i})
						return
					}
				}
				console_print(&app.console, "no such item on the hotbar", .Warning)
			},
		},
		args = {1, 1},
		needs = {.World},
	)
	console_register(
		c,
		{
			"camera",
			"camera <first|behind|facing> [degrees]: the camera's mode (F5 cycles them); the degrees turn a third person camera round the head, for a picture",
			proc(app: ^App, args: []string) {
				if len(args) > 1 {
					degrees, ok := strconv.parse_f32(args[1])
					if !ok {
						console_print(
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
					console_print(&app.console, "camera <first|behind|facing>", .Warning)
				}
			},
		},
		args = {1, 2},
		needs = {.World},
	)
}
