package stopwatch_client

import "core:fmt"

import "client:engine"
import "client:ui"
import "common:game"
import "common:protocol"
import "games:stopwatch"

// Stopwatch's client part (the game: games/stopwatch): it keeps what the server last
// said of the player's time and the record, shows it on the HUD and in F3, and says
// it to the `stopwatch` console command.

GAME :: engine.Game {
	info     = stopwatch.INFO,
	kinds    = stopwatch.KINDS,
	state    = View,
	received = received,
	hud      = hud,
	debug    = debug,
	commands = {
		{
			"stopwatch",
			"stopwatch: your time and the record, as the server last said (/stopwatch asks it)",
			command,
		},
	},
}

// View: what the session knows of the game.
View :: struct {
	times:  stopwatch.Times, // the server's last word (zero until the first)
	told:   int, // Times received
	holder: [game.MAX_NAME_LENGTH]u8, // who broke the record last ("" none since we joined)
	held:   int,
}

view :: proc(s: ^engine.Session) -> ^View {return engine.game_state(s, View)}

received :: proc(s: ^engine.Session, r: protocol.Received) {
	v := view(s)
	if times, ok := engine.game_value(s, r, stopwatch.Times); ok && times != nil {
		v.times = times^
		v.told += 1
	} else if broken, is_broken := engine.game_value(s, r, stopwatch.Record_Broken); is_broken {
		v.held = copy(v.holder[:], broken.name)
	}
}

// clock: whole seconds as minutes and seconds.
clock :: proc(seconds: u32) -> string {
	return fmt.tprintf("%d:%02d", seconds / 60, seconds % 60)
}

// line: what the HUD and the command say.
line :: proc(v: ^View) -> string {
	if v.held == 0 {
		return fmt.tprintf("Stopwatch  %s   record %s", clock(v.times.time), clock(v.times.record))
	}
	return fmt.tprintf(
		"Stopwatch  %s   record %s (%s)",
		clock(v.times.time),
		clock(v.times.record),
		string(v.holder[:v.held]),
	)
}

// hud: the line at the top of the screen, on the HUD's backing.
hud :: proc(s: ^engine.Session, ctx: ^ui.Context) {
	v := view(s)
	if v.told == 0 {return}
	t := &ctx.theme
	text := line(v)
	w := ui.measure_text(ctx, text, t.font_size) + 2 * t.padding
	r := ui.Rect {
		ctx.screen.x + (ctx.screen.w - w) / 2,
		ctx.screen.y + 2 * t.spacing + t.row_height,
		w,
		t.row_height,
	}
	ui.fill_rect(ctx, r, t.hud_fill)
	ui.label(ctx, text, r, .Center, t.text)
}

debug :: proc(s: ^engine.Session) -> string {
	v := view(s)
	return fmt.tprintf("time %ds record %ds, told %d times", v.times.time, v.times.record, v.told)
}

command :: proc(app: ^engine.App, args: []string) {
	engine.console_print(&app.console, line(view(app.session)))
}
