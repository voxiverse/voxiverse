package client

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"

import "../base"
import "../common/game"
import "../server/collector"
import "platform"
import "ui"

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
	// A slash is a server command (as in the chat); plain words are the client's own.
	if text[0] == '/' {
		session := app.session
		if session == nil || session.state != .Playing {
			console_print(c, "server commands need a world (join or start one)", .Warning)
		} else if len(text) > 1 {
			send_message(session, game.Command{text[1:]})
		}
		return
	}
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
	if session := app.session; session != nil {
		for name in session.commands {
			if name == args[0] {
				console_print(
					c,
					fmt.tprintf("'%s' is a server command: type /%s", args[0], text),
					.Warning,
				)
				return
			}
		}
	}
	console_print(
		c,
		fmt.tprintf("unknown command '%s' (try: help; server commands start with /)", args[0]),
		.Warning,
	)
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
	ui.fill_rect(ctx, area, t.console_fill) // opaque: blending is linear, so even 8% shows through
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
			color = t.log_warn
		case .Error, .Fatal:
			color = t.log_error
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
			"screen <title|game|menu|inventory [creative]|stats|options [tab]|worlds [create]|multiplayer [direct]|quit>: switch screens (game: back to it; menu: the game menu; quit: the quit dialog)",
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
				case "stats":
					if app.session != nil && game_controls(app) {stats_open(app)}
				case "inventory":
					if app.session != nil && game_controls(app) {
						inventory_open(app)
						if then == "creative" {app.inventory_view.tab = .Creative}
					}
				case "options":
					app.options.tab, app.options.scroll, app.options.listening = .Video, 0, .None
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
				case "credits":
					app.credits = {}
					app.screen = .Credits
				case "quit":
					overlay_open(&app.overlays, .Quit_Dialog)
				case:
					console_print(
						&app.console,
						"screen: title, game, menu, inventory, stats, options, credits, worlds, multiplayer or quit",
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
				console_print(
					&app.console,
					"  /<command>  a server command (the world and the players): /help lists them",
				)
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
			"report",
			"report <note>: send the developer a note with the version and the last console lines (needs Share play data on, in a saved universe)",
			proc(app: ^App, args: []string) {
				text := report_text(app, strings.join(args, " ", context.temp_allocator))
				s := app.session
				switch {
				case !app.settings.share_data:
					console_print(
						&app.console,
						"report: turn on Share play data (Options, Profile) first",
						.Warning,
					)
				case s == nil || !session_hosting(s) || s.config.save_dir == "":
					console_print(
						&app.console,
						"report: play a saved universe (reports go with its play data)",
						.Warning,
					)
				case collector.report_write(
					     filepath.join(
						     {s.config.save_dir, "telemetry"},
						     context.temp_allocator,
					     ) or_else "",
					     text,
				     ):
					extra := audio_report_copy(
						app,
						filepath.join(
							{s.config.save_dir, "telemetry"},
							context.temp_allocator,
						) or_else "",
					)
					console_print(
						&app.console,
						fmt.tprintf(
							"report: queued; it goes with the next upload%s%s",
							"; " if extra != "" else "",
							extra,
						),
					)
				case:
					console_print(&app.console, "report: could not write it", .Warning)
				}
			},
		},
		args = {1, -1},
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
	console_register(
		c,
		{
			"audio_capture",
			"write the audio recorder's last minute to captures/audio-<n>.vxac (F9); read it with build audiodump",
			proc(app: ^App, args: []string) {
				if audio_ring_save(app, "console") {
					console_print(&app.console, "audio capture written (see the log for its path)")
				} else {
					console_print(&app.console, "audio_capture: nothing to write yet", .Warning)
				}
			},
		},
	)
	when base.DEV {
		console_register(
			c,
			{
				"pad",
				"pad <button> down|up, pad <axis> <value>, pad connect <family>, pad disconnect: a synthetic gamepad (slot 0), for scripts and trying without one",
				proc(app: ^App, args: []string) {
					if msg, ok := pad_inject(app, args); !ok {
						console_print(&app.console, msg, .Warning)
					}
				},
			},
			args = {1, 2},
		)
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
			"export",
			"export <save> [file]: write a save as one file (default: <name>.vxu beside the saves); close it first if it is being played",
			proc(app: ^App, args: []string) {
				path, why := save_export(args[0], args[1] if len(args) > 1 else "")
				if why != "" {
					console_print(&app.console, fmt.tprintf("export: %s", why), .Warning)
					return
				}
				console_print(&app.console, fmt.tprintf("exported to %s", path))
			},
		},
		complete_world,
		args = {1, 2},
	)
	console_register(
		c,
		{
			"import",
			"import <file> [name]: make a new save from an exported file",
			proc(app: ^App, args: []string) {
				name := strings.join(args[1:], " ", context.temp_allocator)
				path, why := save_import(args[0], name)
				if why != "" {
					console_print(&app.console, fmt.tprintf("import: %s", why), .Warning)
					return
				}
				worlds_refresh(&app.worlds)
				console_print(
					&app.console,
					fmt.tprintf(
						"imported as %s (universe %s plays it)",
						path,
						filepath.base(path),
					),
				)
			},
		},
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

// report_text: a note, with what helps to read it: the version, the system,
// the last console lines.
report_text :: proc(app: ^App, note: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "note: %s", note)
	fmt.sbprintfln(&b, "version: %s (%s build)", base.version_text(), base.build_name())
	fmt.sbprintfln(&b, "os: %v", ODIN_OS)
	fmt.sbprint(&b, audio_report_lines(app))
	c := &app.console
	sync.guard(&c.mutex)
	first := max(0, c.count - 100)
	for i in first ..< c.count {
		fmt.sbprintln(&b, c.lines[(c.first + i) % CONSOLE_MAX_LINES].text)
	}
	return strings.to_string(b)
}

// pad_inject: the `pad` command: appends the event for slot 0 to
// app.injected (false and why if the words mean nothing).
pad_inject :: proc(app: ^App, args: []string) -> (message: string, ok: bool) {
	usage :: "pad: pad <button> down|up, pad <axis> <value>, pad connect <family>, pad disconnect"
	if len(args) == 0 {return usage, false}
	if args[0] == "disconnect" {
		append(&app.injected, platform.Pad_Connect_Event{pad = 0, connected = false})
		return "", true
	}
	if args[0] == "connect" {
		family := platform.Pad_Family.Xbox
		if len(args) > 1 {
			found := false
			for f in platform.Pad_Family {
				if strings.equal_fold(fmt.tprint(f), args[1]) {family, found = f, true}
			}
			if !found {return "pad: the family is generic, xbox, playstation, switch or steam_deck", false}
		}
		append(
			&app.injected,
			platform.Pad_Connect_Event{pad = 0, connected = true, family = family},
		)
		return "", true
	}
	if len(args) < 2 {return usage, false}
	for b in platform.Pad_Button {
		if b != .None && strings.equal_fold(fmt.tprint(b), args[0]) {
			switch args[1] {
			case "down":
				append(
					&app.injected,
					platform.Pad_Button_Event{pad = 0, button = b, pressed = true},
				)
			case "up":
				append(
					&app.injected,
					platform.Pad_Button_Event{pad = 0, button = b, pressed = false},
				)
			case:
				return "pad: say down or up", false
			}
			return "", true
		}
	}
	for a in platform.Pad_Axis {
		if strings.equal_fold(fmt.tprint(a), args[0]) {
			value, number := strconv.parse_f32(args[1])
			if !number {return "pad: the axis value is a number", false}
			append(
				&app.injected,
				platform.Pad_Axis_Event{pad = 0, axis = a, value = clamp(value, -1, 1)},
			)
			return "", true
		}
	}
	return usage, false
}
