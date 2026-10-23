package client

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:strings"
import "core:sync"

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

// console_logger forwards log messages into the console (combine with the
// usual loggers via log.create_multi_logger).
console_logger :: proc(c: ^Console) -> log.Logger {
	return log.Logger {
		procedure = proc(
			data: rawptr,
			level: log.Level,
			text: string,
			options: log.Options,
			location := #caller_location,
		) {
			console_print(cast(^Console)data, text, level)
		},
		data = c,
		lowest_level = .Info,
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
		{"ui_scale", "ui_scale <n>: UI scale (0 = automatic)", proc(app: ^App, args: []string) {
				if len(args) != 1 {
					console_print(
						&app.console,
						fmt.tprintf(
							"ui_scale is %.2f (%s)",
							app.settings.ui_scale if app.settings.ui_scale > 0 else ui_scale(app),
							"fixed" if app.settings.ui_scale > 0 else "automatic",
						),
					)
					return
				}
				value, ok := parse_f32(args[0])
				if !ok || (value != 0 && (value < 0.5 || value > 4)) {
					console_print(&app.console, "ui_scale: give 0 (automatic) or 0.5..4", .Warning)
					return
				}
				app.settings.ui_scale = value
			}},
	)
}
