package client

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:sync"

import "../base"
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
	history:   [dynamic]string,
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
	name: string,
	help: string,
	run:  proc(app: ^App, args: []string),
}

console_init :: proc(c: ^Console, allocator := context.allocator) {
	c.allocator = allocator
	c.input = make([dynamic]u8, allocator)
	c.history = make([dynamic]string, allocator)
	c.commands = make([dynamic]Command, allocator)
}

console_destroy :: proc(c: ^Console) {
	for i in 0 ..< c.count {delete(c.lines[(c.first + i) % CONSOLE_MAX_LINES].text, c.allocator)}
	for h in c.history {delete(h, c.allocator)}
	delete(c.input)
	delete(c.history)
	delete(c.commands)
}

console_register :: proc(c: ^Console, cmd: Command) {
	append(&c.commands, cmd)
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
	append(&c.history, strings.clone(text, c.allocator))
	console_print(c, fmt.tprintf("> %s", text))
	args := strings.fields(text, context.temp_allocator)
	for cmd in c.commands {
		if cmd.name == args[0] {
			cmd.run(app, args[1:])
			return
		}
	}
	console_print(c, fmt.tprintf("unknown command '%s' (try: help)", args[0]), .Warning)
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
	if ui.text_input(ctx, "console input", &c.input, input_rect, "command (help)") {
		console_execute(app, string(c.input[:]))
		clear(&c.input)
		c.scroll = 0
	}
	// Keep the input focused while the console is open.
	ctx.focused = ui.get_id(ctx, "console input")

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
			"screen <title|options|quit>: switch screens (quit: the quit dialog)",
			proc(app: ^App, args: []string) {
				switch args[0] if len(args) > 0 else "" {
				case "title":
					app.screen = .Title
				case "options":
					app.screen = .Options
				case "quit":
					app.quit_dialog = true
				case:
					console_print(&app.console, "screen: title, options or quit", .Warning)
				}
			},
		},
	)
	console_register(c, {"console", "show the console", proc(app: ^App, args: []string) {
			app.console.open = true
		}})
	console_register(c, {"help", "list commands", proc(app: ^App, args: []string) {
			for cmd in app.console.commands {
				console_print(&app.console, fmt.tprintf("  %-10s %s", cmd.name, cmd.help))
			}
		}})
	console_register(c, {"clear", "clear the console", proc(app: ^App, args: []string) {
			c := &app.console
			sync.guard(&c.mutex)
			for i in 0 ..< c.count {delete(c.lines[(c.first + i) % CONSOLE_MAX_LINES].text, c.allocator)}
			c.first, c.count = 0, 0
		}})
	console_register(c, {"quit", "quit the game", proc(app: ^App, args: []string) {
			app.quit = true
		}})
	console_register(
		c,
		{"singleplayer", "enter a singleplayer world", proc(app: ^App, args: []string) {
				enter_world(app)
			}},
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
			"tp <x> <y> <z> [yaw pitch]: move the camera (angles in degrees)",
			proc(app: ^App, args: []string) {
				if app.session == nil {
					console_print(&app.console, "tp: not in a world", .Warning)
					return
				}
				values: [5]f64
				if len(args) != 3 && len(args) != 5 {
					console_print(&app.console, "tp <x> <y> <z> [yaw pitch]", .Warning)
					return
				}
				for a, i in args {
					ok: bool
					if values[i], ok = strconv.parse_f64(a); !ok {
						console_print(&app.console, "tp: numbers please", .Warning)
						return
					}
				}
				cam := Fly_Camera {
					position = {values[0], values[1], values[2]},
				}
				if len(args) == 5 {
					cam.yaw = f32(values[3]) * math.RAD_PER_DEG
					cam.pitch = f32(values[4]) * math.RAD_PER_DEG
				}
				session_teleport(app.session, cam)
			},
		},
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
			"set",
			"set <name> <value>: change a variable (vars lists them)",
			proc(app: ^App, args: []string) {
				if len(args) != 2 {
					console_print(&app.console, "set <name> <value>", .Warning)
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
	)
	console_register(
		c,
		{"reset", "reset <name>: back to the default value", proc(app: ^App, args: []string) {
				if len(args) != 1 {
					console_print(&app.console, "reset <name>", .Warning)
					return
				}
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
	)
	console_register(c, {"tune", "toggle the tuning panel (F4)", proc(app: ^App, args: []string) {
			app.tuning = !app.tuning
		}})
}
