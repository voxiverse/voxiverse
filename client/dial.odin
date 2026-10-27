package client

import "core:strings"
import "core:unicode/utf8"

import "../common/game"
import "ui"

// The dial overlay: right-click a gate's ring and pick a world of this
// galaxy, symbol by symbol (none twice; Backspace takes the last back).
// The seventh sends Dial; the server says what came of it (a notice, or
// the chevrons lighting).

Dial_View :: struct {
	gate:    game.Block_Pos, // the block of the gate clicked
	symbols: [game.WORLD_LENGTH]u8,
	count:   int,
}

DIAL_COLUMNS :: 8
DIAL_BUTTON :: ui.Vec2{48, 48}

// is_gate_block: a block one dials a gate by.
is_gate_block :: proc(b: game.Block) -> bool {
	return b == .Gate_Ring || b == .Gate_Chevron || b == .Gate_Chevron_Lit
}

// dial_keys: Use on an aimed gate opens the dial overlay.
dial_keys :: proc(app: ^App) {
	s := app.session
	if s == nil ||
	   s.state != .Playing ||
	   app.settings.keys.use not_in app.input.pressed ||
	   !game_controls(app) {return}
	hit, aimed := s.aim.?
	if !aimed {return}
	if b, known := world_block(&s.world, hit.block); !known || !is_gate_block(b) {return}
	dial_open(app, hit.block)
}

dial_open :: proc(app: ^App, gate: game.Block_Pos) {
	overlay_open(&app.overlays, .Dial)
	app.dial = {
		gate = gate,
	}
}

// dial_add: one more symbol; the seventh dials. False if it is taken.
dial_add :: proc(app: ^App, symbol: u8) -> bool {
	d := &app.dial
	for k in d.symbols[:d.count] {if k == symbol {return false}}
	d.symbols[d.count] = symbol
	d.count += 1
	if d.count < game.WORLD_LENGTH {return true}
	overlay_close(&app.overlays, .Dial)
	if s := app.session; s != nil {
		send_message(s, game.Dial{d.gate, {galaxy = s.welcome.address.galaxy, world = d.symbols}})
	}
	return true
}

symbol_text :: proc(symbol: u8) -> string {
	bytes, n := utf8.encode_rune(game.SYMBOL_RUNES[symbol])
	return strings.clone(string(bytes[:n]), context.temp_allocator)
}

// dial_layout: the panel and each symbol's button.
@(private)
Dial_Layout :: struct {
	panel:   ui.Rect,
	dialed:  ui.Rect, // the chevrons so far
	symbols: [game.SYMBOLS]ui.Rect,
	erase:   ui.Rect,
	cancel:  ui.Rect,
}

@(private)
dial_layout :: proc(ctx: ^ui.Context) -> (l: Dial_Layout) {
	t := &ctx.theme
	gap := t.spacing
	rows := (game.SYMBOLS + DIAL_COLUMNS - 1) / DIAL_COLUMNS
	grid_w := DIAL_COLUMNS * (DIAL_BUTTON.x + gap) - gap
	grid_h := f32(rows) * (DIAL_BUTTON.y + gap) - gap
	w := grid_w + 2 * t.padding
	h := 3 * t.row_height + DIAL_BUTTON.y + grid_h + 4 * gap + 2 * t.padding
	l.panel = ui.rect_center(ctx.screen, w, h)
	inner := ui.rect_shrink(l.panel, t.padding)
	ui.cut_top(&inner, 2 * t.row_height) // the title, this galaxy
	l.dialed = ui.cut_top(&inner, DIAL_BUTTON.y)
	ui.cut_top(&inner, 2 * gap)
	for i in 0 ..< game.SYMBOLS {
		row, col := i / DIAL_COLUMNS, i % DIAL_COLUMNS
		l.symbols[i] = {
			inner.x + f32(col) * (DIAL_BUTTON.x + gap),
			inner.y + f32(row) * (DIAL_BUTTON.y + gap),
			DIAL_BUTTON.x,
			DIAL_BUTTON.y,
		}
	}
	buttons := ui.cut_bottom(&inner, t.row_height)
	l.cancel = ui.cut_right(&buttons, (buttons.w - gap) / 2)
	ui.cut_right(&buttons, gap)
	l.erase = buttons
	return
}

dial_ui :: proc(app: ^App, ctx: ^ui.Context, top: bool) {
	ui.push_id(ctx, "dial")
	defer ui.pop_id(ctx)
	t := &ctx.theme
	d := &app.dial
	s := app.session
	if s == nil {return}
	if top && .Backspace in ctx.input.keys_pressed && d.count > 0 {d.count -= 1}
	l := dial_layout(ctx)
	ui.panel(ctx, l.panel)
	inner := ui.rect_shrink(l.panel, t.padding)
	ui.label(ctx, "Dial a world", ui.cut_top(&inner, t.row_height), .Center)
	here := s.welcome.address
	galaxy := strings.builder_make(context.temp_allocator)
	strings.write_string(&galaxy, "in galaxy ")
	for g in here.galaxy {strings.write_rune(&galaxy, game.SYMBOL_RUNES[g])}
	ui.label(
		ctx,
		strings.to_string(galaxy),
		ui.cut_top(&inner, t.row_height),
		.Center,
		t.text_muted,
	)
	// The seven chevrons: what is dialed so far.
	slots := l.dialed
	slot_w := (slots.w - f32(game.WORLD_LENGTH - 1) * t.spacing) / game.WORLD_LENGTH
	for k in 0 ..< game.WORLD_LENGTH {
		r := ui.Rect{slots.x + f32(k) * (slot_w + t.spacing), slots.y, slot_w, slots.h}
		lit := k < d.count
		ui.fill_rect(ctx, r, {0, 0, 0, 230})
		ui.stroke_rect(ctx, r, 2 if lit else 1, t.text if lit else {255, 255, 255, 60})
		if lit {ui.draw_text(ctx, r, symbol_text(d.symbols[k]), t.font_size * 1.5, t.text, .Center)}
	}
	for i in 0 ..< game.SYMBOLS {
		used := false
		for k in d.symbols[:d.count] {if int(k) == i {used = true}}
		ui.push_id_int(ctx, i)
		if ui.button(ctx, symbol_text(u8(i)), l.symbols[i], disabled = used) {dial_add(app, u8(i))}
		ui.pop_id(ctx)
	}
	if ui.button(ctx, "Erase", l.erase, disabled = d.count == 0) {d.count -= 1}
	if ui.button(ctx, "Cancel", l.cancel) {overlay_close(&app.overlays, .Dial)}
}
