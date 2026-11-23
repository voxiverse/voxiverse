package overlay

import "core:testing"

import "client:engine"
import "client:font"
import "client:testkit"
import "client:ui"
import "common:game"
import "common:protocol"
import "common:starmap"
import "common:worldgen"

// The gate's address with the mouse: a symbol a click, none twice,
// Backspace and Erase take the last back; once whole the board takes no
// more, it says what lives there, and Open (or Enter) sends Open_Gate (this
// galaxy, the symbols picked) and closes it; Escape closes it too.
@(test)
test_gate_address :: proc(t: ^testing.T) {
	app := new(engine.App)
	app.settings = engine.SETTINGS_DEFAULTS
	defer free(app)
	ok: bool
	app.font, ok = font.load(engine.FONT_DATA)
	testing.expect(t, ok)
	testing.expect(t, ui.init(&app.ui, &app.font, drawn = engine.symbol_glyph))
	defer ui.destroy(&app.ui)
	s := new(engine.Session)
	defer free(s)
	pipe: protocol.Pipe
	protocol.pipe_init(&pipe)
	defer protocol.pipe_destroy(&pipe)
	s.endpoint = {&pipe, .Client}
	game.writer_init(&s.writer)
	defer game.writer_destroy(&s.writer)
	s.state = .Playing
	s.welcome.address = starmap.address_derive(3)
	s.reg = testkit.test_reg()
	app.session = s
	defer app.session = nil
	app.screen = .Game

	// Right-click with no gate aimed at: nothing opens.
	app.input.mouse_pressed = {.Right}
	gate_keys(app)
	app.input.mouse_pressed = {}
	testing.expect(t, !engine.overlay_is_open(&app.overlays, .Gate))
	testing.expect(
		t,
		is_gate_block(.Gate_Ring) &&
		is_gate_block(.Gate_Chevron_Lit) &&
		!is_gate_block(.Gate_Horizon),
	)
	gate := game.Block_Pos{10, 20, 30}
	gate_entry_open(app, gate)
	testing.expect(t, engine.overlay_is_open(&app.overlays, .Gate) && !engine.game_controls(app))

	SCREEN :: ui.Vec2{1280, 720}
	frame :: proc(app: ^engine.App, in_: ui.Input) {
		ui.begin_frame(&app.ui, in_, SCREEN, 1)
		draw_overlays(app, &app.ui)
		ui.end_frame(&app.ui)
	}
	layout :: proc(app: ^engine.App) -> Gate_Layout {
		ui.begin_frame(&app.ui, {}, SCREEN, 1)
		l := gate_layout(&app.ui)
		ui.end_frame(&app.ui)
		return l
	}
	click :: proc(app: ^engine.App, r: ui.Rect) {
		at := ui.Vec2{r.x + r.w / 2, r.y + r.h / 2}
		frame(app, {mouse = at})
		frame(app, {mouse = at, mouse_pressed = {.Left}, mouse_down = {.Left}})
		frame(app, {mouse = at, mouse_released = {.Left}})
	}
	says :: proc(app: ^engine.App, want: string) -> bool {
		for text in app.ui.texts {if text == want {return true}}
		return false
	}
	l := layout(app)
	e := &app.gate_entry
	// A symbol; the same again is taken; Backspace, then Erase (nothing left).
	click(app, l.symbols[12])
	click(app, l.symbols[12])
	testing.expect(t, e.count == 1 && e.symbols[0] == 12)
	frame(app, {keys_pressed = {.Backspace}})
	testing.expect_value(t, e.count, 0)
	click(app, l.symbols[4])
	click(app, l.erase)
	testing.expect_value(t, e.count, 0)
	// Open does nothing until the address is whole.
	click(app, l.open)
	testing.expect(t, engine.overlay_is_open(&app.overlays, .Gate))
	picks := [starmap.WORLD_LENGTH]u8{39, 0, 7, 21, 5, 33, 18}
	for p in picks[:starmap.WORLD_LENGTH - 1] {click(app, l.symbols[p])}
	// Six in, the pointer on a symbol: the line says what lives on that world.
	at := ui.Vec2{l.symbols[picks[6]].x + 2, l.symbols[picks[6]].y + 2}
	frame(app, {mouse = at})
	want_addr := starmap.Address{s.welcome.address.galaxy, picks}
	want := engine.life_line(worldgen.world_life(want_addr))
	testing.expectf(t, says(app, want), "the gate does not say %q", want)
	// Seven: whole, still open, the board full, the life still shown.
	click(app, l.symbols[picks[6]])
	click(app, l.symbols[1])
	testing.expect_value(t, e.count, starmap.WORLD_LENGTH)
	testing.expect(t, engine.overlay_is_open(&app.overlays, .Gate))
	frame(app, {})
	testing.expectf(t, says(app, want), "the whole address does not say %q", want)
	testing.expect(t, says(app, symbols_text(picks[:])), "the address is not written out")
	testing.expect(t, len(s.writer.buf) == 0, "sent before Open")
	click(app, l.open)
	testing.expect(t, !engine.overlay_is_open(&app.overlays, .Gate))
	m, decoded := protocol.decode_client(s.writer.buf[:], testkit.test_reg())
	sent, is_open := m.(protocol.Open_Gate)
	testing.expect(t, decoded && is_open, "no Open_Gate sent")
	testing.expect_value(t, sent.gate, gate)
	testing.expect_value(t, sent.address, want_addr)
	// Enter sends a whole address too.
	clear(&s.writer.buf)
	gate_entry_open(app, gate)
	for p in picks {click(app, l.symbols[p])}
	frame(app, {keys_pressed = {.Enter}})
	testing.expect(t, !engine.overlay_is_open(&app.overlays, .Gate))
	m, decoded = protocol.decode_client(s.writer.buf[:], testkit.test_reg())
	_, is_open = m.(protocol.Open_Gate)
	testing.expect(t, decoded && is_open, "Enter sent no Open_Gate")
	// Escape closes it.
	gate_entry_open(app, gate)
	escape(app)
	testing.expect(t, !engine.overlay_is_open(&app.overlays, .Gate))
	free_all(context.temp_allocator)
}
