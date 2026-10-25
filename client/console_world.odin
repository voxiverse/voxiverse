package client

import "core:math"
import "core:strconv"
import "core:strings"

import "../game"

// The developer console's world primitives (PLAN.md M19, commands): placing
// the camera for a picture, and `server <command>`, any server command sent
// as the chat sends it, with our permissions (everything that changes the
// world is the server's). Nothing that duplicates a key, the UI or a server
// command.

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
			"server",
			"server <command...>: run a server command, as /command in the chat does (the server checks it)",
			proc(app: ^App, args: []string) {
				send_message(
					app.session,
					game.Command{strings.join(args, " ", context.temp_allocator)},
				)
			},
		},
		args = {1, -1},
		needs = {.World},
	)
}
