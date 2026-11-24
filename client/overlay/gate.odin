package overlay

import "core:strings"
import "core:unicode/utf8"

import "client:engine"
import "client:ui"
import "common:game"
import "common:protocol"
import "common:starmap"

// The gate's address: Use on a gate's frame opens it. The player writes the
// address of a world of this galaxy from the board of symbols, one a press
// (none twice; Backspace or Erase takes the last back), and Open (or Enter)
// sends it once it is whole. The server says what came of it: a notice, or
// the void gathering in the gate's opening.

// The board: a row for each of the symbols' bodies, a column for each set
// of marks (starmap.symbol_strokes), so alike symbols stand together.
GATE_BOARD_COLUMNS :: 8
GATE_BOARD_BUTTON :: ui.Vec2{48, 48}
GATE_ADDRESS_HEIGHT :: 56

// is_gate_block: a block of a gate's frame, by which one uses it.
is_gate_block :: proc(b: game.Block) -> bool {
	return b == .Gate_Ring || b == .Gate_Chevron || b == .Gate_Chevron_Lit
}

// gate_keys: Use on an aimed gate opens its address.
gate_keys :: proc(app: ^engine.App) {
	s := app.session
	if s == nil ||
	   s.state != .Playing ||
	   !engine.action_pressed(&app.actions, .Use) ||
	   !engine.game_controls(app) {return}
	hit, aimed := s.aim.?
	if !aimed {return}
	if b, known := engine.world_block(&s.world, hit.block); !known || !is_gate_block(b) {return}
	gate_entry_open(app, hit.block)
}

gate_entry_open :: proc(app: ^engine.App, gate: game.Block_Pos) {
	engine.overlay_open(&app.overlays, .Gate)
	app.gate_entry = {
		gate = gate,
	}
}

// gate_entry_add: one more symbol, while the address is not whole. False if
// it is taken, or there is no room.
gate_entry_add :: proc(app: ^engine.App, symbol: u8) -> bool {
	e := &app.gate_entry
	if e.count == starmap.WORLD_LENGTH {return false}
	for k in e.symbols[:e.count] {if k == symbol {return false}}
	e.symbols[e.count] = symbol
	e.count += 1
	return true
}

// gate_entry_send: a whole address goes to the server, and the overlay closes.
gate_entry_send :: proc(app: ^engine.App) -> bool {
	e := &app.gate_entry
	if e.count < starmap.WORLD_LENGTH {return false}
	engine.overlay_close(&app.overlays, .Gate)
	if s := app.session; s != nil {
		engine.send_message(
			s,
			protocol.Open_Gate{e.gate, {galaxy = s.welcome.address.galaxy, world = e.symbols}},
		)
	}
	return true
}

symbol_text :: proc(symbol: u8) -> string {
	bytes, n := utf8.encode_rune(starmap.symbol_rune(symbol))
	return strings.clone(string(bytes[:n]), context.temp_allocator)
}

// symbols_text: symbols as one run of text.
@(private)
symbols_text :: proc(symbols: []u8) -> string {
	b := strings.builder_make(context.temp_allocator)
	for s in symbols {strings.write_rune(&b, starmap.symbol_rune(s))}
	return strings.to_string(b)
}

// Gate_Layout: the panel, the address as written so far, and each button.
@(private)
Gate_Layout :: struct {
	panel:   ui.Rect,
	address: ui.Rect,
	life:    ui.Rect, // what lives on the world the address names (or would, one symbol on)
	symbols: [starmap.SYMBOLS]ui.Rect,
	erase:   ui.Rect,
	cancel:  ui.Rect,
	open:    ui.Rect,
}

@(private)
gate_layout :: proc(ctx: ^ui.Context) -> (l: Gate_Layout) {
	t := &ctx.theme
	gap := t.spacing
	rows := (starmap.SYMBOLS + GATE_BOARD_COLUMNS - 1) / GATE_BOARD_COLUMNS
	grid_w := GATE_BOARD_COLUMNS * (GATE_BOARD_BUTTON.x + gap) - gap
	grid_h := f32(rows) * (GATE_BOARD_BUTTON.y + gap) - gap
	w := grid_w + 2 * t.padding
	h := 4 * t.row_height + GATE_ADDRESS_HEIGHT + grid_h + 4 * gap + 2 * t.padding
	l.panel = ui.rect_center(ctx.screen, w, h)
	inner := ui.rect_shrink(l.panel, t.padding)
	ui.cut_top(&inner, 2 * t.row_height) // the title, this galaxy
	l.address = ui.cut_top(&inner, GATE_ADDRESS_HEIGHT)
	l.life = ui.cut_top(&inner, t.row_height)
	ui.cut_top(&inner, 2 * gap)
	for i in 0 ..< starmap.SYMBOLS {
		row, col := i / GATE_BOARD_COLUMNS, i % GATE_BOARD_COLUMNS
		l.symbols[i] = {
			inner.x + f32(col) * (GATE_BOARD_BUTTON.x + gap),
			inner.y + f32(row) * (GATE_BOARD_BUTTON.y + gap),
			GATE_BOARD_BUTTON.x,
			GATE_BOARD_BUTTON.y,
		}
	}
	buttons := ui.cut_bottom(&inner, t.row_height)
	third := (buttons.w - 2 * gap) / 3
	l.erase = ui.cut_left(&buttons, third)
	ui.cut_left(&buttons, gap)
	l.cancel = ui.cut_left(&buttons, third)
	ui.cut_left(&buttons, gap)
	l.open = buttons
	return
}

gate_ui :: proc(app: ^engine.App, ctx: ^ui.Context, top: bool) {
	ui.push_id(ctx, "gate")
	defer ui.pop_id(ctx)
	t := &ctx.theme
	e := &app.gate_entry
	s := app.session
	if s == nil {return}
	whole := e.count == starmap.WORLD_LENGTH
	// Backspace on a keyboard, X (the second action) on a pad: the last symbol back.
	if top &&
	   (.Backspace in ctx.input.keys_pressed || .Secondary in ctx.input.nav) &&
	   e.count > 0 {
		e.count -= 1
	}
	if top && whole && .Enter in ctx.input.keys_pressed && gate_entry_send(app) {return}
	whole = e.count == starmap.WORLD_LENGTH
	taken :: proc(e: ^engine.Gate_Entry, i: int) -> bool {
		for k in e.symbols[:e.count] {if int(k) == i {return true}}
		return false
	}
	l := gate_layout(ctx)
	ui.panel(ctx, l.panel)
	inner := ui.rect_shrink(l.panel, t.padding)
	ui.label(ctx, engine.tr(.Gate_Title), ui.cut_top(&inner, t.row_height), .Center)
	here := s.welcome.address
	ui.label(
		ctx,
		engine.tr(.Gate_Galaxy, symbols_text(here.galaxy[:])),
		ui.cut_top(&inner, t.row_height),
		.Center,
		t.text_muted,
	)
	// The address so far, as one line of writing in its field, and how much
	// of it there is.
	field := l.address
	ui.fill_rect(ctx, field, t.slot_fill)
	ui.stroke_rect(ctx, field, 2 if whole else 1, t.text if whole else t.faint_border)
	writing := ui.rect_shrink(field, t.padding)
	ui.draw_text(ctx, writing, symbols_text(e.symbols[:e.count]), t.font_size * 2.5, t.text, .Left)
	ui.draw_text(
		ctx,
		writing,
		engine.tr(.Gate_Count, e.count, starmap.WORLD_LENGTH),
		t.font_size,
		t.text_muted,
		.Right,
	)
	// What the world at the address is and what lives there: once whole, or one short with the pointer
	// on the symbol that would end it.
	life_at: Maybe(starmap.Address)
	if whole {
		life_at = starmap.Address{here.galaxy, e.symbols}
	} else if e.count == starmap.WORLD_LENGTH - 1 {
		for i in 0 ..< starmap.SYMBOLS {
			if taken(e, i) || !ui.rect_contains(l.symbols[i], ctx.input.mouse) {continue}
			a := starmap.Address {
				galaxy = here.galaxy,
			}
			copy(a.world[:], e.symbols[:e.count])
			a.world[starmap.WORLD_LENGTH - 1] = u8(i)
			life_at = a
			break
		}
	}
	if a, has := life_at.?; has {
		ui.label(ctx, engine.destination_line(a), l.life, .Center, t.text_muted)
	}
	// A pad's focus starts on, and after a symbol is taken goes to, the next
	// free one; on Open once the address is whole.
	start := -1
	for k in 0 ..< starmap.SYMBOLS {
		if whole {break}
		if !taken(e, (e.last + k) % starmap.SYMBOLS) {
			start = (e.last + k) % starmap.SYMBOLS
			break
		}
	}
	for i in 0 ..< starmap.SYMBOLS {
		ui.push_id_int(ctx, i)
		if i == start {ui.default_focus(ctx)}
		if ui.button(
			ctx,
			symbol_text(u8(i)),
			l.symbols[i],
			disabled = whole || taken(e, i),
			text_size = t.font_size * 2.5,
		) {
			e.last = i
			gate_entry_add(app, u8(i))
		}
		ui.pop_id(ctx)
	}
	if ui.button(ctx, engine.tr(.Gate_Erase), l.erase, disabled = e.count == 0) {e.count -= 1}
	if ui.button(ctx, engine.tr(.Cancel), l.cancel) {engine.overlay_close(&app.overlays, .Gate)}
	if whole {ui.default_focus(ctx)}
	if ui.button(ctx, engine.tr(.Gate_Open), l.open, disabled = !whole) {gate_entry_send(app)}
}
