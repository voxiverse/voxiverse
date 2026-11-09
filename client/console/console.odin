package console

import "base:intrinsics"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

import "client:dev"
import "client:engine"
import "client:menu"
import "client:platform"
import "client:screen"
import "client:ui"
import "common:base"
import "common:game"
import "server:collector"

// The developer console: the log as scrollback, plus a command line. Toggle
// with the ` key. Log lines can arrive from any thread (e.g. the Vulkan
// validation layer's), hence the mutex.

console_init :: proc(c: ^engine.Console, allocator := context.allocator) {
	c.allocator = allocator
	engine.line_editor_init(&c.line, allocator)
	c.commands = make([dynamic]engine.Command, allocator)
}

console_destroy :: proc(c: ^engine.Console) {
	for i in 0 ..< c.count {delete(c.lines[(c.first + i) % engine.CONSOLE_MAX_LINES].text, c.allocator)}
	engine.line_editor_destroy(&c.line)
	delete(c.commands)
}

// console_register adds a command. What it needs and how many arguments
// it takes are checked before it runs (with a warning if not).
console_register :: proc(
	c: ^engine.Console,
	cmd: engine.Command_Spec,
	complete: engine.Completer = nil,
	args := [2]int{},
	needs := engine.Command_Needs{},
	node := "",
) {
	append(&c.commands, engine.Command{cmd, complete, args, needs, node})
}

// console_listener receives every log line (base.log_set_listener); lines
// from other threads show their tag.
console_listener :: proc(data: rawptr, level: log.Level, tag: string, text: string) {
	c := (^engine.Console)(data)
	if tag == "main" {
		engine.console_print(c, text, level)
	} else {
		engine.console_print(c, fmt.tprintf("[%s] %s", tag, text), level)
	}
}

console_execute :: proc(app: ^engine.App, line: string) {
	c := &app.console
	text := strings.trim_space(line)
	if text == "" {return}
	engine.console_print(c, fmt.tprintf("> %s", text))
	// A slash is a server command (as in the chat); plain words are the client's own.
	if text[0] == '/' {
		// `/share` is the client's own: the server has no clipboard.
		if strings.equal_fold(strings.trim_space(text[1:]), "share") {
			engine.share_place(app)
			return
		}
		session := app.session
		if session == nil || session.state != .Playing {
			engine.console_print(c, "server commands need a world (join or start one)", .Warning)
		} else if len(text) > 1 {
			engine.send_message(session, game.Command{text[1:]})
		}
		return
	}
	args := strings.fields(text, context.temp_allocator)
	base.crash_bundle_action("command", args[0]) // (its name only: the arguments can hold names)
	for &cmd in c.commands {
		if cmd.name != args[0] {continue}
		if problem := command_refused(app, &cmd, len(args) - 1); problem != "" {
			engine.console_print(c, fmt.tprintf("%s: %s", cmd.name, problem), .Warning)
		} else {
			cmd.run(app, args[1:])
		}
		return
	}
	if session := app.session; session != nil {
		for name in session.commands {
			if name == args[0] {
				engine.console_print(
					c,
					fmt.tprintf("'%s' is a server command: type /%s", args[0], text),
					.Warning,
				)
				return
			}
		}
	}
	engine.console_print(
		c,
		fmt.tprintf("unknown command '%s' (try: help; server commands start with /)", args[0]),
		.Warning,
	)
}

// command_refused: why cmd cannot run now with n arguments ("": it can).
@(private = "file")
command_refused :: proc(app: ^engine.App, cmd: ^engine.Command, n: int) -> string {
	if cmd.args != {} && (n < cmd.args[0] || (cmd.args[1] >= 0 && n > cmd.args[1])) {
		usage, _, _ := strings.partition(cmd.help, ": ")
		if !strings.has_prefix(usage, cmd.name) {usage = cmd.name}
		return fmt.tprintf("usage: %s", usage)
	}
	s := app.session
	if .World in cmd.needs && (s == nil || s.state != .Playing) {return "not in a world"}
	if cmd.node != "" && (s == nil || !engine.session_allowed(s, cmd.node)) {
		return "not allowed on this server"
	}
	if .Host in cmd.needs && (s == nil || !engine.session_hosting(s)) {
		return "only the host can do that"
	}
	return ""
}

// console_clear empties the scrollback.
console_clear :: proc(c: ^engine.Console) {
	sync.guard(&c.mutex)
	for i in 0 ..< c.count {delete(c.lines[(c.first + i) % engine.CONSOLE_MAX_LINES].text, c.allocator)}
	c.first, c.count = 0, 0
}

// console_ui draws the console over the top half of the screen.
console_ui :: proc(app: ^engine.App, ctx: ^ui.Context, top: bool) {
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
	r := engine.line_edit(
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
		engine.console_print(c, strings.join(r.choices, "   ", context.temp_allocator), .Debug)
	}
	if r.submitted {
		console_execute(app, r.line)
		c.scroll = 0
	}

	line_h := t.font_size * 1.35
	if ui.rect_contains(area, ctx.input.mouse) {c.scroll += ctx.input.wheel.y * 3}

	// Copy the visible lines, then draw unlocked: drawing can log (which
	// takes this mutex), and other threads may log meanwhile.
	visible_lines := make([dynamic]engine.Console_Line, context.temp_allocator)
	{
		sync.guard(&c.mutex)
		visible := int(inner.h / line_h)
		c.scroll = clamp(c.scroll, 0, f32(max(c.count - visible, 0)))
		for i := c.count - 1 - int(c.scroll); i >= 0 && len(visible_lines) <= visible; i -= 1 {
			line := c.lines[(c.first + i) % engine.CONSOLE_MAX_LINES]
			append(
				&visible_lines,
				engine.Console_Line{strings.clone(line.text, context.temp_allocator), line.level},
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

register_builtin_commands :: proc(c: ^engine.Console) {
	register_workshop_command(c)
	console_register(
		c,
		{
			"screen",
			"screen <title|game|menu|inventory [creative]|stats|options [tab]|universes [create]|multiplayer [direct]|quit>: switch screens (game: back to it; menu: the game menu; quit: the quit dialog)",
			proc(app: ^engine.App, args: []string) {
				then := args[1] if len(args) > 1 else ""
				switch args[0] {
				case "title":
					app.screen = .Title
				case "menu":
					if app.session != nil {engine.overlay_open(&app.overlays, .Game_Menu)}
				case "game":
					menu.player_menu_close(app)
					for o in ([]engine.Overlay{.Options, .Game_Menu, .Quit_Dialog}) {
						engine.overlay_close(&app.overlays, o)
					}
				case "stats":
					if app.session != nil && engine.game_controls(app) {menu.stats_open(app)}
				case "inventory":
					if app.session != nil && engine.game_controls(app) {
						menu.inventory_open(app)
						if strings.equal_fold(fmt.tprint(engine.Inventory_Tab.Creative), then) {
							app.inventory_view.tab = .Creative
						}
					}
				case "options":
					app.options.tab, app.options.scroll, app.options.listening = .Video, 0, .None
					for tab in engine.Options_Tab {
						if strings.equal_fold(fmt.tprint(tab), then) {app.options.tab = tab}
					}
					if app.session != nil {
						engine.overlay_open(&app.overlays, .Game_Menu) // over the game
						engine.overlay_open(&app.overlays, .Options)
					} else {
						app.screen = .Options
					}
				case "universes":
					screen.universes_refresh(&app.universes)
					app.screen = .Universes
					if then == "create" {screen.creation_open(app)}
				case "multiplayer":
					screen.multiplayer_open(app)
					if then == "direct" &&
					   app.multiplayer.mode == .List {app.multiplayer.mode = .Direct}
				case "credits":
					app.credits = {}
					app.screen = .Credits
				case "quit":
					engine.overlay_open(&app.overlays, .Quit_Dialog)
				case:
					engine.console_print(
						&app.console,
						"screen: title, game, menu, inventory, stats, options, credits, universes, multiplayer or quit",
						.Warning,
					)
				}
			},
		},
		complete_screen,
		args = {1, 2},
	)
	console_register(
		c,
		{
			"title_date",
			"title_date [MM-DD | YYYY-MM-DD | off]: fake the date (the title's holiday splash and theme); with no argument, show it",
			proc(app: ^engine.App, args: []string) {
				if len(args) == 0 {
					y, m, d := 1970, 1, 1
					if o, ok := app.title_date_override.?;
					   ok {y, m, d = o[0], o[1], o[2]} else if ly, lm, ld, ok2 := engine.local_date_of(engine.app_wall(app)); ok2 {y, m, d = ly, lm, ld}
					engine.console_print(
						&app.console,
						fmt.tprintf("title_date: %04d-%02d-%02d", y, m, d),
					)
					return
				}
				if args[0] == "off" {
					app.title_date_override = nil
					app.splash = "" // re-pick for the local date
					engine.console_print(&app.console, "title_date: the local date again")
					return
				}
				now := engine.app_wall(app)
				cur_year := 2026
				if dt, ok := time.time_to_datetime(now); ok {cur_year = int(dt.year)}
				y, m, d, ok := engine.title_date_parse(args[0], cur_year)
				if !ok {
					engine.console_print(
						&app.console,
						fmt.tprintf("title_date: %q is not MM-DD, YYYY-MM-DD or off", args[0]),
						.Warning,
					)
					return
				}
				app.title_date_override = [3]int{y, m, d}
				app.splash = "" // re-pick for the faked date
				engine.console_print(
					&app.console,
					fmt.tprintf("title_date: %04d-%02d-%02d", y, m, d),
				)
			},
		},
		args = {0, 1},
	)
	console_register(
		c,
		{
			"share",
			"share this place: the code for a friend (on the clipboard and in the console)",
			proc(app: ^engine.App, args: []string) {
				engine.share_place(app)
			},
		},
	)
	console_register(c, {"console", "show the console", proc(app: ^engine.App, args: []string) {
			engine.overlay_open(&app.overlays, .Console)
		}})
	console_register(c, {"help", "list commands", proc(app: ^engine.App, args: []string) {
				for cmd in app.console.commands {
					engine.console_print(
						&app.console,
						fmt.tprintf("  %-10s %s", cmd.name, cmd.help),
					)
				}
				engine.console_print(
					&app.console,
					"  /<command>  a server command (the world and the players): /help lists them",
				)
			}}, complete_command)
	console_register(c, {"clear", "clear the console", proc(app: ^engine.App, args: []string) {
			console_clear(&app.console)
		}})
	console_register(c, {"quit", "quit the game", proc(app: ^engine.App, args: []string) {
			app.quit = true
		}})
	console_register(
		c,
		{
			"singleplayer",
			"enter a singleplayer world",
			proc(app: ^engine.App, args: []string) {
				engine.enter_world(app, "", engine.SCRATCH_SEED) // a scratch world: nothing saved
			},
		},
	)
	console_register(c, {"leave", "leave the world", proc(app: ^engine.App, args: []string) {
			engine.leave_world(app)
		}})
	console_register(
		c,
		{
			"set",
			"set <name> <value>: change a variable (vars lists them)",
			proc(app: ^engine.App, args: []string) {
				if table, servers := engine.server_table(args[0]); servers {
					// The server's: ask it (it announces the result).
					if app.session == nil {
						engine.console_print(
							&app.console,
							"set: that belongs to a world's server; enter one first",
							.Warning,
						)
						return
					}
					if _, ok := base.var_find(table, args[0]); !ok {
						engine.console_print(
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
						"world.gen" if table.prefix == "worldgen." else "voxiverse.command.rule",
					) {return}
					engine.session_set_rule(app.session, args[0], args[1])
					return
				}
				for v in engine.app_variables(app) {
					err := base.var_set(v.table, v.data, args[0], args[1])
					switch err {
					case .Unknown_Name:
						continue
					case .None:
					case .Bad_Value:
						engine.console_print(
							&app.console,
							fmt.tprintf("set: '%s' is not a valid value for %s", args[1], args[0]),
							.Warning,
						)
						return
					case .Out_Of_Range:
						var, _ := base.var_find(v.table, args[0])
						engine.console_print(
							&app.console,
							fmt.tprintf("set: %s is %g..%g; clamped", args[0], var.min, var.max),
							.Warning,
						)
					}
					if v.data == &app.settings {engine.settings_changed(app)}
					var, _ := base.var_find(v.table, args[0])
					engine.console_print(
						&app.console,
						fmt.tprintf("%s = %s", args[0], base.var_format(v.table, v.data, var)),
					)
					return
				}
				engine.console_print(
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
			proc(app: ^engine.App, args: []string) {
				filter := args[0] if len(args) > 0 else ""
				for v in engine.app_variables(app) {
					for &var in v.table.vars {
						name := base.var_name(v.table, &var)
						if !strings.contains(name, filter) {continue}
						value := base.var_format(v.table, v.data, &var)
						engine.console_print(
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
		{
			"reset",
			"reset <name>: back to the default value",
			proc(app: ^engine.App, args: []string) {
				for v in engine.app_variables(app) {
					if var, ok := base.var_find(v.table, args[0]); ok {
						base.var_reset(v.table, v.data, var)
						if v.data == &app.settings {engine.settings_changed(app)}
						engine.console_print(
							&app.console,
							fmt.tprintf("%s = %s", args[0], base.var_format(v.table, v.data, var)),
						)
						return
					}
				}
				engine.console_print(
					&app.console,
					fmt.tprintf("reset: no variable '%s'", args[0]),
					.Warning,
				)
			},
		},
		complete_variables,
		args = {1, 1},
	)
	console_register(
		c,
		{
			"report",
			"report <note>: send the developer a note with the version and the last console lines (needs Share play data on, in a saved universe)",
			proc(app: ^engine.App, args: []string) {
				text := report_text(app, strings.join(args, " ", context.temp_allocator))
				s := app.session
				switch {
				case !app.settings.share_data:
					engine.console_print(
						&app.console,
						"report: turn on Share play data (Options, Profile) first",
						.Warning,
					)
				case s == nil || !engine.session_hosting(s) || s.config.save_dir == "":
					engine.console_print(
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
					extra := dev.audio_report_copy(
						app,
						filepath.join(
							{s.config.save_dir, "telemetry"},
							context.temp_allocator,
						) or_else "",
					)
					engine.console_print(
						&app.console,
						fmt.tprintf(
							"report: queued; it goes with the next upload%s%s",
							"; " if extra != "" else "",
							extra,
						),
					)
				case:
					engine.console_print(&app.console, "report: could not write it", .Warning)
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
			proc(app: ^engine.App, args: []string) {
				engine.screenshot_request(app, args[0] if len(args) > 0 else "")
			},
		},
	)
	console_register(
		c,
		{
			"audio_capture",
			"write the audio recorder's last minute to captures/audio-<n>.vxac (F9); read it with build audiodump",
			proc(app: ^engine.App, args: []string) {
				if dev.audio_ring_save(app, "console") {
					engine.console_print(
						&app.console,
						"audio capture written (see the log for its path)",
					)
				} else {
					engine.console_print(
						&app.console,
						"audio_capture: nothing to write yet",
						.Warning,
					)
				}
			},
		},
	)
	console_register(
		c,
		{
			"renderdoc",
			"renderdoc [title]: capture the next frame into RenderDoc (F12)",
			proc(app: ^engine.App, args: []string) {
				if app.renderdoc.api == nil {
					engine.console_print(
						&app.console,
						"renderdoc: RenderDoc is not attached (start the game from RenderDoc)",
						.Warning,
					)
					return
				}
				app.renderdoc_requested = true
				if len(args) > 0 {app.renderdoc_title = args[0]}
				engine.console_print(&app.console, "renderdoc: frame capture queued")
			},
		},
	)
	when base.DEV {
		console_register(
			c,
			{
				"creation",
				"creation seed <n|text>: set the creation screen's seed as if typed (open it with `screen universes create`)",
				proc(app: ^engine.App, args: []string) {
					c := &app.creation
					seed, ok := game.seed_of_text(args[1] if len(args) > 1 else "")
					if args[0] != "seed" || !ok || app.screen != .Creation {
						engine.console_print(
							&app.console,
							"creation: usage: creation seed <n|text>, on the creation screen",
							.Warning,
						)
						return
					}
					clear(&c.seed_text)
					append(&c.seed_text, args[1])
					c.typed = true
					screen.creation_set_seed(c, seed, false)
				},
			},
			args = {2, 2},
		)
		console_register(
			c,
			{
				"ignite",
				"ignite show: play Ignite over the creation screen's galaxy and planet, without making a universe (hold it with set debug.ignite_at <seconds>)",
				proc(app: ^engine.App, args: []string) {
					if args[0] != "show" || app.screen != .Creation {
						engine.console_print(
							&app.console,
							"ignite: usage: ignite show, on the creation screen",
							.Warning,
						)
						return
					}
					screen.ignite_start(app, app.creation.stars, app.creation.seed)
				},
			},
			args = {1, 1},
		)
		console_register(
			c,
			{
				"pad",
				"pad <button> down|up, pad <axis> <value>, pad connect <family>, pad disconnect: a synthetic gamepad (slot 0), for scripts and trying without one",
				proc(app: ^engine.App, args: []string) {
					if msg, ok := pad_inject(app, args); !ok {
						engine.console_print(&app.console, msg, .Warning)
					}
				},
			},
			args = {1, 2},
		)
		console_register(
			c,
			{
				"crash",
				"crash the game (tests the crash handler)",
				proc(app: ^engine.App, args: []string) {
					intrinsics.volatile_store((^int)(uintptr(8)), 1)
				},
			},
		)
	}
	console_register(
		c,
		{
			"net_trace",
			"record every message of this world to net.trace",
			proc(app: ^engine.App, args: []string) {
				if app.session == nil {
					engine.console_print(
						&app.console,
						"net_trace: not in a world (set debug.net_trace 1 to trace the next one)",
						.Warning,
					)
					return
				}
				engine.session_trace(app.session)
			},
		},
		args = {0, 0},
	)
	console_register(
		c,
		{
			"universe",
			"universe <name>: play the saved universe name (created if new)",
			proc(app: ^engine.App, args: []string) {
				name := strings.join(args, " ", context.temp_allocator)
				path :=
					filepath.join({screen.saves_dir(), name}, context.temp_allocator) or_else name
				if os.exists(
					path,
				) {engine.enter_world(app, path, 0)} else {screen.world_create(app, name, "")}
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
			proc(app: ^engine.App, args: []string) {
				path, why := screen.save_export(args[0], args[1] if len(args) > 1 else "")
				if why != "" {
					engine.console_print(&app.console, fmt.tprintf("export: %s", why), .Warning)
					return
				}
				engine.console_print(&app.console, fmt.tprintf("exported to %s", path))
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
			proc(app: ^engine.App, args: []string) {
				name := strings.join(args[1:], " ", context.temp_allocator)
				path, why := screen.save_import(args[0], name)
				if why != "" {
					engine.console_print(&app.console, fmt.tprintf("import: %s", why), .Warning)
					return
				}
				screen.universes_refresh(&app.universes)
				engine.console_print(
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
			proc(app: ^engine.App, args: []string) {
				if app.session != nil {engine.leave_world(app)}
				engine.join_server(app, args[0], args[1] if len(args) > 1 else "")
			},
		},
		args = {1, 2},
	)
	register_world_commands(c)
}

// allowed_here: the server lets this player do node (asking
// anyway would end the connection); else says so.
@(private = "file")
allowed_here :: proc(app: ^engine.App, command, node: string) -> bool {
	if app.session != nil && engine.session_allowed(app.session, node) {return true}
	engine.console_print(
		&app.console,
		fmt.tprintf("%s: not allowed on this server", command),
		.Warning,
	)
	return false
}

// report_text: a note, with what helps to read it: the version, the system,
// the last console lines.
report_text :: proc(app: ^engine.App, note: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "note: %s", note)
	fmt.sbprintfln(&b, "version: %s (%s build)", base.version_text(), base.build_name())
	fmt.sbprintfln(&b, "os: %v", ODIN_OS)
	fmt.sbprint(&b, dev.audio_report_lines(app))
	c := &app.console
	sync.guard(&c.mutex)
	first := max(0, c.count - 100)
	for i in first ..< c.count {
		fmt.sbprintln(&b, c.lines[(c.first + i) % engine.CONSOLE_MAX_LINES].text)
	}
	return strings.to_string(b)
}

// pad_inject: the `pad` command: appends the event for slot 0 to
// app.injected (false and why if the words mean nothing).
pad_inject :: proc(app: ^engine.App, args: []string) -> (message: string, ok: bool) {
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
