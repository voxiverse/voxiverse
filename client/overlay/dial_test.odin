package overlay

import "core:testing"

import "client:engine"
import "client:font"
import "client:testkit"
import "client:ui"
import "common:game"
import "common:worldgen"

// The dial overlay with the mouse: a symbol a click, none twice, Backspace
// and Erase take the last back, the seventh sends Dial (this galaxy, the
// symbols picked) and closes it; Escape closes it too.
@(test)
test_dial_overlay :: proc(t: ^testing.T) {
	app := new(engine.App)
	app.settings = engine.SETTINGS_DEFAULTS
	defer free(app)
	ok: bool
	app.font, ok = font.load(engine.FONT_DATA)
	testing.expect(t, ok)
	app.symbol_font, ok = font.load(engine.SYMBOL_FONT_DATA)
	testing.expect(t, ok)
	testing.expect(t, ui.init(&app.ui, &app.font, fallback = &app.symbol_font))
	defer ui.destroy(&app.ui)
	s := new(engine.Session)
	defer free(s)
	pipe: game.Pipe
	game.pipe_init(&pipe)
	defer game.pipe_destroy(&pipe)
	s.endpoint = {&pipe, .Client}
	game.writer_init(&s.writer)
	defer game.writer_destroy(&s.writer)
	s.state = .Playing
	s.welcome.address = game.address_derive(3)
	s.reg = testkit.test_reg()
	app.session = s
	defer app.session = nil
	app.screen = .Game

	// Right-click with no gate aimed at: nothing opens.
	app.input.mouse_pressed = {.Right}
	dial_keys(app)
	app.input.mouse_pressed = {}
	testing.expect(t, !engine.overlay_is_open(&app.overlays, .Dial))
	testing.expect(t, is_gate_block(.Gate_Chevron_Lit) && !is_gate_block(.Gate_Horizon))
	gate := game.Block_Pos{10, 20, 30}
	dial_open(app, gate)
	testing.expect(t, engine.overlay_is_open(&app.overlays, .Dial) && !engine.game_controls(app))

	SCREEN :: ui.Vec2{1280, 720}
	frame :: proc(app: ^engine.App, in_: ui.Input) {
		ui.begin_frame(&app.ui, in_, SCREEN, 1)
		draw_overlays(app, &app.ui)
		ui.end_frame(&app.ui)
	}
	layout :: proc(app: ^engine.App) -> Dial_Layout {
		ui.begin_frame(&app.ui, {}, SCREEN, 1)
		l := dial_layout(&app.ui)
		ui.end_frame(&app.ui)
		return l
	}
	click :: proc(app: ^engine.App, r: ui.Rect) {
		at := ui.Vec2{r.x + r.w / 2, r.y + r.h / 2}
		frame(app, {mouse = at})
		frame(app, {mouse = at, mouse_pressed = {.Left}, mouse_down = {.Left}})
		frame(app, {mouse = at, mouse_released = {.Left}})
	}
	l := layout(app)
	d := &app.dial
	// A symbol; the same again is taken; Backspace, then Erase (nothing left).
	click(app, l.symbols[12])
	click(app, l.symbols[12])
	testing.expect(t, d.count == 1 && d.symbols[0] == 12)
	frame(app, {keys_pressed = {.Backspace}})
	testing.expect_value(t, d.count, 0)
	click(app, l.symbols[4])
	click(app, l.erase)
	testing.expect_value(t, d.count, 0)
	// Seven: Dial is sent, the overlay closes.
	picks := [game.WORLD_LENGTH]u8{39, 0, 7, 21, 5, 33, 18}
	for p in picks[:game.WORLD_LENGTH - 1] {click(app, l.symbols[p])}
	// Six in, the pointer on a symbol: the line says what lives on that world.
	at := ui.Vec2{l.symbols[picks[6]].x + 2, l.symbols[picks[6]].y + 2}
	frame(app, {mouse = at})
	want_addr := game.Address{s.welcome.address.galaxy, picks}
	want := engine.life_line(worldgen.world_life(want_addr))
	shown := false
	for text in app.ui.texts {shown ||= text == want}
	testing.expectf(t, shown, "the dial does not say %q", want)
	click(app, l.symbols[picks[6]])
	testing.expect(t, !engine.overlay_is_open(&app.overlays, .Dial))
	m, decoded := game.decode_client(s.writer.buf[:], testkit.test_reg())
	sent, is_dial := m.(game.Dial)
	testing.expect(t, decoded && is_dial, "no Dial sent")
	testing.expect_value(t, sent.gate, gate)
	testing.expect_value(t, sent.address, game.Address{s.welcome.address.galaxy, picks})
	// Escape closes it.
	dial_open(app, gate)
	escape(app)
	testing.expect(t, !engine.overlay_is_open(&app.overlays, .Dial))
	free_all(context.temp_allocator)
}
