package client

import "core:math"
import "core:strconv"


// The developer console's world primitives (PLAN.md M19, commands): placing
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
}
