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
	lines:     [CONSOLE_MAX_LINES]Console_Line, // ring buffer
	first:     int,
	count:     int,
	mutex:     sync.Mutex,
	line:      Line_Editor, // (console_line.odin)
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
	node:       string, // the permission it needs ("": none)
}

// Command_Spec: what console_register is given (the rest apart).
Command_Spec :: struct {
	name: string,
	help: string, // "name <args>: what it does" (up to ": ", its usage)
	run:  proc(app: ^App, args: []string),
}

Command_Need :: enum u8 {
	World, // in a world (playing)
	Host, // the world runs here
}
Command_Needs :: bit_set[Command_Need]

// Completer: what argument `arg` (0: the first) can be, for Tab.
Completer :: proc(app: ^App, arg: int, args: []string) -> []string

console_init :: proc(c: ^Console, allocator := context.allocator) {
	c.allocator = allocator
	line_editor_init(&c.line, allocator)
	c.commands = make([dynamic]Command, allocator)
}

console_destroy :: proc(c: ^Console) {
	for i in 0 ..< c.count {delete(c.lines[(c.first + i) % CONSOLE_MAX_LINES].text, c.allocator)}
	line_editor_destroy(&c.line)
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
	node := "",
) {
	append(&c.commands, Command{cmd, complete, args, needs, node})
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
	if cmd.node != "" && (s == nil || !session_allowed(s, cmd.node)) {
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
console_ui :: proc(app: ^App, ctx: ^ui.Context, top: bool) {
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
	if top && .Ctrl in ctx.input.modifiers && .L in ctx.input.keys_pressed {
		console_clear(c)
		ctx.input.keys_pressed -= {.L}
	}
	hint: ui.Rect
	if c.line.searching {hint = ui.cut_bottom(&inner, t.row_height)}
	r := line_edit(
		app,
		ctx,
		&c.line,
		"console input",
		input_rect,
		hint,
		"command (help; Tab completes)",
		top,
		console_candidates,
	)
	if len(r.choices) > 0 {
		console_print(c, strings.join(r.choices, "   ", context.temp_allocator), .Debug)
	}
	if r.submitted {
		console_execute(app, r.line)
		c.scroll = 0
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
			"screen <title|game|menu|inventory|options [tab]|worlds [create]|multiplayer [direct]|quit>: switch screens (game: back to it; menu: the game menu; quit: the quit dialog)",
			proc(app: ^App, args: []string) {
				then := args[1] if len(args) > 1 else ""
				switch args[0] {
				case "title":
					app.screen = .Title
				case "menu":
					if app.session != nil {overlay_open(&app.overlays, .Game_Menu)}
				case "game":
					if overlay_is_open(&app.overlays, .Inventory) {inventory_close(app)}
					for o in ([]Overlay{.Options, .Game_Menu, .Quit_Dialog}) {
						overlay_close(&app.overlays, o)
					}
				case "inventory":
					if app.session != nil && game_controls(app) {inventory_open(app)}
				case "options":
					app.options.tab, app.options.scroll, app.options.listening = .Video, 0, 0
					for tab in Options_Tab {
						if strings.equal_fold(fmt.tprint(tab), then) {app.options.tab = tab}
					}
					if app.session != nil {
						overlay_open(&app.overlays, .Game_Menu) // over the game
						overlay_open(&app.overlays, .Options)
					} else {
						app.screen = .Options
					}
				case "worlds":
					worlds_refresh(&app.worlds)
					app.screen = .Worlds
					if then == "create" {
						clear(&app.worlds.name)
						append(&app.worlds.name, "New Save")
						app.worlds.mode = .Create
					}
				case "multiplayer":
					multiplayer_open(app)
					if then == "direct" &&
					   app.multiplayer.mode == .List {app.multiplayer.mode = .Direct}
				case "quit":
					overlay_open(&app.overlays, .Quit_Dialog)
				case:
					console_print(
						&app.console,
						"screen: title, game, menu, inventory, options, worlds, multiplayer or quit",
						.Warning,
					)
				}
			},
		},
		complete_screen,
		args = {1, 2},
	)
	console_register(c, {"console", "show the console", proc(app: ^App, args: []string) {
			overlay_open(&app.overlays, .Console)
		}})
	console_register(c, {"help", "list commands", proc(app: ^App, args: []string) {
				for cmd in app.console.commands {
					console_print(&app.console, fmt.tprintf("  %-10s %s", cmd.name, cmd.help))
				}
			}}, complete_command)
	console_register(c, {"clear", "clear the console", proc(app: ^App, args: []string) {
			console_clear(&app.console)
		}})
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
				if app.session.state == .Playing &&
				   !allowed_here(app, "tp", "teleport.tp") {return}
				session_teleport(app.session, t)
			},
		},
		args = {3, 5},
	)
	console_register(
		c,
		{
			"set",
			"set <name> <value>: change a variable (vars lists them)",
			proc(app: ^App, args: []string) {
				if table, servers := server_table(args[0]); servers {
					// The server's: ask it (it announces the result).
					if app.session == nil {
						console_print(
							&app.console,
							"set: that belongs to a world's server; enter one first",
							.Warning,
						)
						return
					}
					if _, ok := base.var_find(table, args[0]); !ok {
						console_print(
							&app.console,
							fmt.tprintf(
								"set: no variable '%s' (try: vars %s)",
								args[0],
								strings.trim_suffix(table.prefix, "."),
							),
							.Warning,
						)
						return
					}
					if !allowed_here(
						app,
						"set",
						"world.gen" if table.prefix == "worldgen." else "world.rules",
					) {return}
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
	when base.DEV {
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
			"universe",
			"universe <name>: play the saved universe name (created if new)",
			proc(app: ^App, args: []string) {
				name := strings.join(args, " ", context.temp_allocator)
				path := filepath.join({saves_dir(), name}, context.temp_allocator) or_else name
				if os.exists(path) {enter_world(app, path, 0)} else {world_create(app, name, "")}
			},
		},
		complete_world,
		args = {1, -1},
	)
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
}

// allowed_here: the server lets this player do node (asking
// anyway would end the connection); else says so.
@(private = "file")
allowed_here :: proc(app: ^App, command, node: string) -> bool {
	if app.session != nil && session_allowed(app.session, node) {return true}
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
		send_message(app.session, game.Command{"open_lan"})
	}
}
