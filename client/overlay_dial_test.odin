package client

import "core:testing"

import "../common/game"
import "font"
import "ui"

// The dial overlay with the mouse: a symbol a click, none twice, Backspace
// and Erase take the last back, the seventh sends Dial (this galaxy, the
// symbols picked) and closes it; Escape closes it too.
@(test)
test_dial_overlay :: proc(t: ^testing.T) {
	app := new(App)
	app.settings = SETTINGS_DEFAULTS
	defer free(app)
	ok: bool
	app.font, ok = font.load(FONT_DATA)
	testing.expect(t, ok)
	app.symbol_font, ok = font.load(SYMBOL_FONT_DATA)
	testing.expect(t, ok)
	testing.expect(t, ui.init(&app.ui, &app.font, fallback = &app.symbol_font))
	defer ui.destroy(&app.ui)
	s := new(Session)
	defer free(s)
	pipe: game.Pipe
	game.pipe_init(&pipe)
	defer game.pipe_destroy(&pipe)
	s.endpoint = {&pipe, .Client}
	game.writer_init(&s.writer)
	defer game.writer_destroy(&s.writer)
	s.state = .Playing
	s.welcome.address = game.address_derive(3)
	s.reg = test_reg()
	app.session = s
	defer app.session = nil
	app.screen = .Game

	// Right-click with no gate aimed at: nothing opens.
	app.input.mouse_pressed = {.Right}
	dial_keys(app)
	app.input.mouse_pressed = {}
	testing.expect(t, !overlay_is_open(&app.overlays, .Dial))
	testing.expect(t, is_gate_block(.Gate_Chevron_Lit) && !is_gate_block(.Gate_Horizon))
	gate := game.Block_Pos{10, 20, 30}
	dial_open(app, gate)
	testing.expect(t, overlay_is_open(&app.overlays, .Dial) && !game_controls(app))

	SCREEN :: ui.Vec2{1280, 720}
	frame :: proc(app: ^App, in_: ui.Input) {
		ui.begin_frame(&app.ui, in_, SCREEN, 1)
		draw_overlays(app, &app.ui)
		ui.end_frame(&app.ui)
	}
	layout :: proc(app: ^App) -> Dial_Layout {
		ui.begin_frame(&app.ui, {}, SCREEN, 1)
		l := dial_layout(&app.ui)
		ui.end_frame(&app.ui)
		return l
	}
	click :: proc(app: ^App, r: ui.Rect) {
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
	for p in picks {click(app, l.symbols[p])}
	testing.expect(t, !overlay_is_open(&app.overlays, .Dial))
	m, decoded := game.decode_client(s.writer.buf[:], test_reg())
	sent, is_dial := m.(game.Dial)
	testing.expect(t, decoded && is_dial, "no Dial sent")
	testing.expect_value(t, sent.gate, gate)
	testing.expect_value(t, sent.address, game.Address{s.welcome.address.galaxy, picks})
	// Escape closes it.
	dial_open(app, gate)
	escape(app)
	testing.expect(t, !overlay_is_open(&app.overlays, .Dial))
	free_all(context.temp_allocator)
}
