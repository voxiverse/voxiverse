package client

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"

import "../base"
import "../game"
import "../ui"

// The developer console: the log as scrollback, plus a command line. Toggle
// with the ` key. Log lines can arrive from any thread (e.g. the Vulkan
// validation layer's), hence the mutex.

CONSOLE_MAX_LINES :: 1000

Console :: struct {
	open:      bool,
	lines:     [CONSOLE_MAX_LINES]Console_Line, // ring buffer
	first:     int,
	count:     int,
	mutex:     sync.Mutex,
	input:     [dynamic]u8,
	history:   [dynamic]string, // lines typed (oldest first; console_line.odin)
	line:      Console_Line_State,
	scroll:    f32, // lines scrolled up from the bottom
	commands:  [dynamic]Command,
	allocator: runtime.Allocator,
}

@(private)
Console_Line :: struct {
	text:  string,
	level: log.Level,
}

Command :: struct {
	using spec: Command_Spec,
	complete:   Completer,
	args:       [2]int, // how many arguments: at least, at most (-1: any); {}: not checked
	needs:      Command_Needs,
}

// Command_Spec: what console_register is given (the rest apart).
Command_Spec :: struct {
	name: string,
	help: string, // "name <args>: what it does" (up to ": ", its usage)
	run:  proc(app: ^App, args: []string),
}

Command_Need :: enum u8 {
	World, // in a world (playing)
	Cheats, // the server lets this player cheat (asking anyway would end the connection)
	Host, // the world runs here
}
Command_Needs :: bit_set[Command_Need]

// Completer: what argument `arg` (0: the first) can be, for Tab.
Completer :: proc(app: ^App, arg: int, args: []string) -> []string

console_init :: proc(c: ^Console, allocator := context.allocator) {
	c.allocator = allocator
	c.input = make([dynamic]u8, allocator)
	c.history = make([dynamic]string, allocator)
	c.commands = make([dynamic]Command, allocator)
	c.line = {
		browsing = -1,
		found    = -1,
		draft    = make([dynamic]u8, allocator),
		query    = make([dynamic]u8, allocator),
	}
}

console_destroy :: proc(c: ^Console) {
	for i in 0 ..< c.count {delete(c.lines[(c.first + i) % CONSOLE_MAX_LINES].text, c.allocator)}
	for h in c.history {delete(h, c.allocator)}
	delete(c.input)
	delete(c.history)
	delete(c.line.draft)
	delete(c.line.query)
	delete(c.commands)
}

// console_register adds a command. What it needs and how many arguments
// it takes are checked before it runs (with a warning if not).
console_register :: proc(
	c: ^Console,
	cmd: Command_Spec,
	complete: Completer = nil,
	args := [2]int{},
	needs := Command_Needs{},
) {
	append(&c.commands, Command{cmd, complete, args, needs})
}

console_print :: proc(c: ^Console, text: string, level := log.Level.Info) {
	sync.guard(&c.mutex)
	line := strings.clone(text, c.allocator)
	if c.count == CONSOLE_MAX_LINES {
		delete(c.lines[c.first].text, c.allocator)
		c.lines[c.first] = {line, level}
		c.first = (c.first + 1) % CONSOLE_MAX_LINES
	} else {
		c.lines[(c.first + c.count) % CONSOLE_MAX_LINES] = {line, level}
		c.count += 1
	}
}

// console_listener receives every log line (base.log_set_listener); lines
// from other threads show their tag.
console_listener :: proc(data: rawptr, level: log.Level, tag: string, text: string) {
	c := (^Console)(data)
	if tag == "main" {
		console_print(c, text, level)
	} else {
		console_print(c, fmt.tprintf("[%s] %s", tag, text), level)
	}
}

console_execute :: proc(app: ^App, line: string) {
	c := &app.console
	text := strings.trim_space(line)
	if text == "" {return}
	console_print(c, fmt.tprintf("> %s", text))
	args := strings.fields(text, context.temp_allocator)
	for &cmd in c.commands {
		if cmd.name != args[0] {continue}
		if problem := command_refused(app, &cmd, len(args) - 1); problem != "" {
			console_print(c, fmt.tprintf("%s: %s", cmd.name, problem), .Warning)
		} else {
			cmd.run(app, args[1:])
		}
		return
	}
	console_print(c, fmt.tprintf("unknown command '%s' (try: help)", args[0]), .Warning)
}

// command_refused: why cmd cannot run now with n arguments ("": it can).
@(private = "file")
command_refused :: proc(app: ^App, cmd: ^Command, n: int) -> string {
	if cmd.args != {} && (n < cmd.args[0] || (cmd.args[1] >= 0 && n > cmd.args[1])) {
		usage, _, _ := strings.partition(cmd.help, ": ")
		if !strings.has_prefix(usage, cmd.name) {usage = cmd.name}
		return fmt.tprintf("usage: %s", usage)
	}
	s := app.session
	if .World in cmd.needs && (s == nil || s.state != .Playing) {return "not in a world"}
	if .Cheats in cmd.needs && (s == nil || !session_can_cheat(s)) {
		return "not allowed on this server"
	}
	if .Host in cmd.needs && (s == nil || !session_hosting(s)) {
		return "only the host can do that"
	}
	return ""
}

// console_clear empties the scrollback.
console_clear :: proc(c: ^Console) {
	sync.guard(&c.mutex)
	for i in 0 ..< c.count {delete(c.lines[(c.first + i) % CONSOLE_MAX_LINES].text, c.allocator)}
	c.first, c.count = 0, 0
}

// console_ui draws the console over the top half of the screen.
console_ui :: proc(app: ^App, ctx: ^ui.Context) {
	c := &app.console
	t := &ctx.theme
	prev := ui.begin_layer(ctx, .Popup)
	defer ui.end_layer(ctx, prev)
	area := ctx.screen
	area.h *= 0.5
	ui.fill_rect(ctx, area, {0, 0, 0, 255}) // opaque: blending is linear, so even 8% shows through
	ui.fill_rect(ctx, {area.x, area.y + area.h - 1, area.w, 1}, t.border)

	inner := ui.rect_shrink(area, t.padding)
	input_rect := ui.cut_bottom(&inner, t.row_height)
	ui.cut_bottom(&inner, t.spacing)
	console_line_keys(app, ctx)
	if c.line.searching {
		hint := ui.cut_bottom(&inner, t.row_height)
		if line, run := console_search_ui(app, ctx, hint, input_rect); run {
			console_remember(c, line)
			console_execute(app, line)
			clear(&c.input)
			c.scroll = 0
		}
	} else {
		if ui.text_input(
			ctx,
			"console input",
			&c.input,
			input_rect,
			"command (help; Tab completes)",
		) {
			line := string(c.input[:])
			console_remember(c, line)
			console_execute(app, line)
			clear(&c.input)
			c.scroll = 0
		}
		// Keep the input focused while the console is open.
		ctx.focused = ui.get_id(ctx, "console input")
	}

	line_h := t.font_size * 1.35
	if ui.rect_contains(area, ctx.input.mouse) {c.scroll += ctx.input.wheel.y * 3}

	// Copy the visible lines, then draw unlocked: drawing can log (which
	// takes this mutex), and other threads may log meanwhile.
	visible_lines := make([dynamic]Console_Line, context.temp_allocator)
	{
		sync.guard(&c.mutex)
		visible := int(inner.h / line_h)
		c.scroll = clamp(c.scroll, 0, f32(max(c.count - visible, 0)))
		for i := c.count - 1 - int(c.scroll); i >= 0 && len(visible_lines) <= visible; i -= 1 {
			line := c.lines[(c.first + i) % CONSOLE_MAX_LINES]
			append(
				&visible_lines,
				Console_Line{strings.clone(line.text, context.temp_allocator), line.level},
			)
		}
	}
	ui.push_clip_rect(ctx, inner)
	defer ui.pop_clip_rect(ctx)
	y := inner.y + inner.h - line_h
	for line in visible_lines {
		color := t.text
		#partial switch line.level {
		case .Warning:
			color = {255, 200, 80, 255}
		case .Error, .Fatal:
			color = {255, 100, 100, 255}
		case .Debug:
			color = t.text_muted
		}
		ui.draw_text(ctx, {inner.x, y, inner.w, line_h}, line.text, t.font_size, color)
		y -= line_h
	}
}

register_builtin_commands :: proc(c: ^Console) {
	console_register(
		c,
		{
			"screen",
			"screen <title|options|worlds|multiplayer|quit>: switch screens (quit: the quit dialog)",
			proc(app: ^App, args: []string) {
				switch args[0] {
				case "title":
					app.screen = .Title
				case "options":
					if app.session != nil {
						app.paused, app.in_game_options = true, true // over the game
					} else {
						app.screen = .Options
					}
				case "worlds":
					worlds_refresh(&app.worlds)
					app.screen = .Worlds
				case "multiplayer":
					multiplayer_open(app)
				case "quit":
					app.quit_dialog = true
				case:
					console_print(
						&app.console,
						"screen: title, options, worlds, multiplayer or quit",
						.Warning,
					)
				}
			},
		},
		complete_screen,
		args = {1, 1},
	)
	console_register(c, {"console", "show the console", proc(app: ^App, args: []string) {
			app.console.open = true
		}})
	console_register(c, {"help", "list commands", proc(app: ^App, args: []string) {
				for cmd in app.console.commands {
					console_print(&app.console, fmt.tprintf("  %-10s %s", cmd.name, cmd.help))
				}
			}}, complete_command)
	console_register(c, {"quit", "quit the game", proc(app: ^App, args: []string) {
			app.quit = true
		}})
	console_register(
		c,
		{
			"singleplayer",
			"enter a singleplayer world",
			proc(app: ^App, args: []string) {
				enter_world(app, "", SCRATCH_SEED) // a scratch world: nothing saved
			},
		},
	)
	console_register(
		c,
		{"debug", "toggle the debug overlay (F3)", proc(app: ^App, args: []string) {
				app.debug.overlay = !app.debug.overlay
			}},
	)
	console_register(c, {"leave", "leave the world", proc(app: ^App, args: []string) {
			leave_world(app)
		}})
	console_register(
		c,
		{
			"tp",
			"tp <x> <y> <z> [yaw pitch]: move the player (feet; angles in degrees)",
			proc(app: ^App, args: []string) {
				if app.session == nil {
					console_print(&app.console, "tp: not in a world", .Warning)
					return
				}
				values: [5]f64
				if len(args) == 4 {
					console_print(&app.console, "tp: usage: tp <x> <y> <z> [yaw pitch]", .Warning)
					return
				}
				for a, i in args {
					ok: bool
					if values[i], ok = strconv.parse_f64(a); !ok {
						console_print(&app.console, "tp: numbers please", .Warning)
						return
					}
				}
				t := game.Teleport {
					position = {values[0], values[1], values[2]},
				}
				if len(args) == 5 {
					t.yaw = f32(values[3]) * math.RAD_PER_DEG
					t.pitch = clamp(
						f32(values[4]) * math.RAD_PER_DEG,
						-game.PITCH_LIMIT,
						game.PITCH_LIMIT,
					)
				} else {
					t.yaw, t.pitch = app.session.camera.yaw, app.session.camera.pitch
				}
				if app.session.state == .Playing && !cheats_allowed(app, "tp") {return}
				session_teleport(app.session, t)
			},
		},
		args = {3, 5},
	)
	console_register(
		c,
		{
			"fly_test",
			"fly_test <blocks> [quit]: fly and check memory stays flat",
			fly_test_command,
		},
	)
	console_register(
		c,
		{
			"blast_test",
			"blast_test <shots> [quit]: blow up terrain and check budgets, meshes, memory, sync",
			blast_test_command,
		},
	)
	console_register(
		c,
		{
			"set",
			"set <name> <value>: change a variable (vars lists them)",
			proc(app: ^App, args: []string) {
				if strings.has_prefix(args[0], "rules.") {
					// The server's: ask it (it announces the result).
					if app.session == nil {
						console_print(
							&app.console,
							"set: rules belong to a world's server; enter one first",
							.Warning,
						)
						return
					}
					if _, ok := base.var_find(game.rules_table(), args[0]); !ok {
						console_print(
							&app.console,
							fmt.tprintf("set: no rule '%s' (try: vars rules)", args[0]),
							.Warning,
						)
						return
					}
					if !cheats_allowed(app, "set rules") {return}
					session_set_rule(app.session, args[0], args[1])
					return
				}
				for v in app_variables(app) {
					err := base.var_set(v.table, v.data, args[0], args[1])
					switch err {
					case .Unknown_Name:
						continue
					case .None:
					case .Bad_Value:
						console_print(
							&app.console,
							fmt.tprintf("set: '%s' is not a valid value for %s", args[1], args[0]),
							.Warning,
						)
						return
					case .Out_Of_Range:
						var, _ := base.var_find(v.table, args[0])
						console_print(
							&app.console,
							fmt.tprintf("set: %s is %g..%g; clamped", args[0], var.min, var.max),
							.Warning,
						)
					}
					if v.data == &app.settings {settings_changed(app)}
					var, _ := base.var_find(v.table, args[0])
					console_print(
						&app.console,
						fmt.tprintf("%s = %s", args[0], base.var_format(v.table, v.data, var)),
					)
					return
				}
				console_print(
					&app.console,
					fmt.tprintf("set: no variable '%s' (try: vars)", args[0]),
					.Warning,
				)
			},
		},
		complete_variables,
		args = {2, 2},
	)
	console_register(
		c,
		{
			"vars",
			"vars [filter]: list variables with their values",
			proc(app: ^App, args: []string) {
				filter := args[0] if len(args) > 0 else ""
				for v in app_variables(app) {
					for &var in v.table.vars {
						name := base.var_name(v.table, &var)
						if !strings.contains(name, filter) {continue}
						value := base.var_format(v.table, v.data, &var)
						console_print(
							&app.console,
							fmt.tprintf("  %-22s %-8s %s", name, value, var.help),
						)
					}
				}
			},
		},
		complete_vars,
	)
	console_register(
		c,
		{"reset", "reset <name>: back to the default value", proc(app: ^App, args: []string) {
				for v in app_variables(app) {
					if var, ok := base.var_find(v.table, args[0]); ok {
						base.var_reset(v.table, v.data, var)
						if v.data == &app.settings {settings_changed(app)}
						console_print(
							&app.console,
							fmt.tprintf("%s = %s", args[0], base.var_format(v.table, v.data, var)),
						)
						return
					}
				}
				console_print(
					&app.console,
					fmt.tprintf("reset: no variable '%s'", args[0]),
					.Warning,
				)
			}},
		complete_variables,
		args = {1, 1},
	)
	console_register(
		c,
		{
			"screenshot",
			"screenshot [name]: save the next frame as a PNG (F2)",
			proc(app: ^App, args: []string) {
				screenshot_request(app, args[0] if len(args) > 0 else "")
			},
		},
	)
	when ODIN_DEBUG {
		console_register(
			c,
			{"crash", "crash the game (tests the crash handler)", proc(app: ^App, args: []string) {
					intrinsics.volatile_store((^int)(uintptr(8)), 1)
				}},
		)
	}
	console_register(
		c,
		{
			"net_trace",
			"record every message of this world to net.trace",
			proc(app: ^App, args: []string) {
				if app.session == nil {
					console_print(
						&app.console,
						"net_trace: not in a world (set debug.net_trace 1 to trace the next one)",
						.Warning,
					)
					return
				}
				session_trace(app.session)
			},
		},
		args = {0, 0},
	)
	console_register(
		c,
		{
			"break",
			"hit the aimed entity, or break the aimed block (left click)",
			proc(app: ^App, args: []string) {
				if session_attack(app.session) {return}
				if !session_edit(app.session, false, .Air) {
					console_print(&app.console, "break: nothing breakable aimed at", .Warning)
				}
			},
		},
		args = {0, 0},
		needs = {.World},
	)
	console_register(
		c,
		{
			"place",
			"place [block]: place against the aimed face (right click)",
			proc(app: ^App, args: []string) {
				block, holding := held_item(app.session).(game.Block)
				if !holding {block = .Stone}
				if len(args) > 0 {
					b, found := game.block_by_name(args[0])
					if found && game.can_place(b) {block = b} else {
						console_print(
							&app.console,
							fmt.tprintf("place: no placeable block '%s'", args[0]),
							.Warning,
						)
						return
					}
				}
				if !session_edit(app.session, true, block) {
					console_print(
						&app.console,
						"place: nowhere to place (aim at a face in reach, not into yourself)",
						.Warning,
					)
				}
			},
		},
		complete_block,
		args = {0, 1},
		needs = {.World},
	)
	console_register(
		c,
		{
			"world",
			"world <name>: play the saved world name (created if new)",
			proc(app: ^App, args: []string) {
				name := strings.join(args, " ", context.temp_allocator)
				path := filepath.join({saves_dir(), name}, context.temp_allocator) or_else name
				if os.exists(path) {enter_world(app, path, 0)} else {world_create(app, name, "")}
			},
		},
		complete_world,
		args = {1, -1},
	)
	console_register(c, {"save", "save the world now", proc(app: ^App, args: []string) {
				if app.session.config.save_dir == "" {
					console_print(&app.console, "save: not in a saved world", .Warning)
					return
				}
				send_message(app.session, game.Admin{"save"})
			}}, args = {0, 0}, needs = {.World, .Cheats})
	console_register(
		c,
		{
			"join",
			"join <host[:port]> [password]: play on a server",
			proc(app: ^App, args: []string) {
				if app.session != nil {leave_world(app)}
				join_server(app, args[0], args[1] if len(args) > 1 else "")
			},
		},
		args = {1, 2},
	)
	register_world_commands(c)
	console_register(
		c,
		{
			"open_lan",
			"open_lan: let others on the LAN join this world",
			proc(app: ^App, args: []string) {
				session_open_lan(app)
			},
		},
		args = {0, 0},
	)
	console_register(
		c,
		{
			"time",
			"time [sunrise|day|noon|sunset|night|midnight|0..1]: show or set the time of day",
			proc(app: ^App, args: []string) {
				if len(args) == 0 {
					f := game.time_of_day(app.session.clock)
					minutes := int(f * 24 * 60)
					console_print(
						&app.console,
						fmt.tprintf(
							"day %d, %02d:%02d (%.3f)",
							int(app.session.clock),
							minutes / 60,
							minutes % 60,
							f,
						),
						.Info,
					)
					return
				}
				if _, ok := game.parse_time_of_day(args[0]); !ok {
					console_print(&app.console, "time: not a time of day", .Warning)
					return
				}
				if !cheats_allowed(app, "time") {return}
				send_message(
					app.session,
					game.Admin{strings.concatenate({"time ", args[0]}, context.temp_allocator)},
				)
			},
		},
		complete_time,
		args = {0, 1},
		needs = {.World},
	)
	console_register(c, {"tune", "toggle the tuning panel (F4)", proc(app: ^App, args: []string) {
			app.tuning = !app.tuning
		}})
}

// cheats_allowed: the server lets this player run cheat commands (asking
// anyway would end the connection); else says so.
@(private = "file")
cheats_allowed :: proc(app: ^App, command: string) -> bool {
	if app.session != nil && session_can_cheat(app.session) {return true}
	console_print(&app.console, fmt.tprintf("%s: not allowed on this server", command), .Warning)
	return false
}

// session_open_lan asks our own server to take players from the LAN.
session_open_lan :: proc(app: ^App) {
	switch {
	case app.session == nil || app.session.state != .Playing:
		console_print(&app.console, "open_lan: not in a world", .Warning)
	case !session_hosting(app.session):
		console_print(&app.console, "open_lan: only the host can open the world", .Warning)
	case:
		send_message(app.session, game.Admin{"open_lan"})
	}
}
