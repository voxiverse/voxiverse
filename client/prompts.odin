package client

import "core:math"

import "../common/game"

import "platform"
import "ui"

// Button prompts: the glyph of the button or key an action is on, for the
// device used last, drawn along the bottom of menus ("A Select  B Back").
// The glyphs are made by code into the UI's atlas at start, like the item
// icons: white shapes with anti-aliased edges (4 x 4 samples a pixel) that
// the theme's colours tint, drawn smoothly. They are clean, not pixel art
// (the crunchy rule is for the world). Text inside a glyph (the A, an LB, a
// key's name) is the font's.

PROMPT_ICON_SIZE :: 64
PROMPT_SAMPLES :: 4 // per pixel, each way
PROMPT_BAR_HEIGHT :: 20 // the bar's height, and the glyphs'

Prompt_Shape :: enum {
	Disc, // a filled disc, the letter over it
	Ring, // the PlayStation circle (drawn in a disc)
	Cross,
	Square,
	Triangle,
	Bumper_Left,
	Bumper_Right,
	Trigger_Left,
	Trigger_Right,
	Stick, // a ring, L or R over it
	Dpad,
	Dpad_Up,
	Dpad_Down,
	Dpad_Left,
	Dpad_Right,
	Menu, // three bars
	View, // two squares
	Keycap, // a rounded key, its name over it
	Mouse_Left,
	Mouse_Right,
	Mouse_Middle,
}

Prompt_Glyph :: struct {
	shape: Prompt_Shape,
	text:  string,
}

// Prompt_Device: whose buttons the hints show.
Prompt_Device :: enum {
	Keyboard,
	Xbox,
	PlayStation,
}

Prompt_Item :: struct {
	action: Action,
	text:   string,
	also:   Action, // a second glyph beside the first (the tabs' two bumpers)
}

Prompt_Icons :: [Prompt_Shape]ui.Icon

PROMPTS_SHOWN_MAX :: 32

// prompts_seen: the glyphs drawn since the frame began (tests read them).
prompts_seen :: proc(app: ^App) -> []Prompt_Glyph {
	return app.prompts_shown[:app.prompts_count]
}

// prompt_icons_init draws every shape into the atlas.
prompt_icons_init :: proc(icons: ^Prompt_Icons, ctx: ^ui.Context) -> bool {
	pixels := make([][4]u8, PROMPT_ICON_SIZE * PROMPT_ICON_SIZE, context.temp_allocator)
	for shape in Prompt_Shape {
		prompt_shape_pixels(shape, pixels)
		icons[shape] = ui.add_icon(ctx, PROMPT_ICON_SIZE, pixels) or_return
	}
	return true
}

// prompt_shape_pixels: shape as white with its coverage in the alpha.
prompt_shape_pixels :: proc(shape: Prompt_Shape, pixels: [][4]u8) {
	N :: PROMPT_ICON_SIZE
	for y in 0 ..< N {
		for x in 0 ..< N {
			sum: f32
			for sy in 0 ..< PROMPT_SAMPLES {
				for sx in 0 ..< PROMPT_SAMPLES {
					p := [2]f32 {
						(f32(x) + (f32(sx) + 0.5) / PROMPT_SAMPLES) / N,
						(f32(y) + (f32(sy) + 0.5) / PROMPT_SAMPLES) / N,
					}
					sum += shape_cover(shape, p)
				}
			}
			a := u8(math.round(255 * sum / (PROMPT_SAMPLES * PROMPT_SAMPLES)))
			pixels[x + y * N] = {255, 255, 255, a}
		}
	}
}

// Distances in units of the icon's size; a stroke is 5 px of 64.
@(private = "file")
STROKE :: f32(5) / PROMPT_ICON_SIZE

// shape_cover: how much of the shape is at p (0 or 1; the dpad's other arms 0.35).
@(private = "file")
shape_cover :: proc(shape: Prompt_Shape, p: [2]f32) -> f32 {
	c := p - {0.5, 0.5}
	d := math.sqrt(c.x * c.x + c.y * c.y)
	inside :: proc(b: bool) -> f32 {return 1 if b else 0}
	switch shape {
	case .Disc:
		return inside(d <= 0.46)
	case .Ring:
		return inside(d <= 0.26 && d >= 0.26 - STROKE)
	case .Cross:
		return inside(
			abs(c.x) <= 0.24 &&
			abs(c.y) <= 0.24 &&
			abs(abs(c.x) - abs(c.y)) <= STROKE * 0.5 * 1.4142,
		)
	case .Square:
		m := max(abs(c.x), abs(c.y))
		return inside(m <= 0.24 && m >= 0.24 - STROKE)
	case .Triangle:
		// Apex up, base down; the outline of a triangle 0.5 wide.
		top, bottom := f32(-0.27), f32(0.2)
		if c.y < top || c.y > bottom {return 0}
		half := 0.26 * (c.y - top) / (bottom - top)
		edge := abs(abs(c.x) - half)
		return inside(edge <= STROKE * 0.6 || c.y >= bottom - STROKE && abs(c.x) <= half)
	case .Bumper_Left:
		return inside(rounded(c, {0, 0}, {0.46, 0.3}, {0.3, 0.1}, c.x < 0))
	case .Bumper_Right:
		return inside(rounded(c, {0, 0}, {0.46, 0.3}, {0.3, 0.1}, c.x > 0))
	case .Trigger_Left:
		return inside(rounded(c, {0, 0}, {0.46, 0.46}, {0.4, 0.12}, c.x < 0))
	case .Trigger_Right:
		return inside(rounded(c, {0, 0}, {0.46, 0.46}, {0.4, 0.12}, c.x > 0))
	case .Stick:
		return inside(d <= 0.46 && d >= 0.46 - STROKE)
	case .Dpad, .Dpad_Up, .Dpad_Down, .Dpad_Left, .Dpad_Right:
		arm := f32(0.16) // half the arm's width
		up := abs(c.x) <= arm && c.y <= 0 && c.y >= -0.46
		down := abs(c.x) <= arm && c.y >= 0 && c.y <= 0.46
		left := abs(c.y) <= arm && c.x <= 0 && c.x >= -0.46
		right := abs(c.y) <= arm && c.x >= 0 && c.x <= 0.46
		any := up || down || left || right
		if !any {return 0}
		#partial switch shape {
		case .Dpad_Up:
			return 1 if up else 0.35
		case .Dpad_Down:
			return 1 if down else 0.35
		case .Dpad_Left:
			return 1 if left else 0.35
		case .Dpad_Right:
			return 1 if right else 0.35
		}
		return 1
	case .Menu:
		for row in -1 ..= 1 {
			if abs(c.y - f32(row) * 0.2) <= STROKE * 0.6 && abs(c.x) <= 0.34 {return 1}
		}
		return 0
	case .View:
		a := max(abs(c.x + 0.09), abs(c.y + 0.09))
		b := max(abs(c.x - 0.09), abs(c.y - 0.09))
		in_a := a <= 0.22 && a >= 0.22 - STROKE
		in_b := b <= 0.22 && b >= 0.22 - STROKE
		return inside(in_a || in_b)
	case .Keycap:
		return inside(rounded(c, {0, 0}, {0.46, 0.46}, {0.18, 0.18}, true))
	case .Mouse_Left, .Mouse_Right, .Mouse_Middle:
		// The body outlined, its top split into two buttons, one lit.
		body := rounded(c, {0, 0}, {0.3, 0.46}, {0.3, 0.3}, true)
		inner := rounded(
			c,
			{0, 0},
			{0.3 - STROKE, 0.46 - STROKE},
			{0.3 - STROKE, 0.3 - STROKE},
			true,
		)
		if !body {return 0}
		if !inner {return 1}
		if c.y < -0.06 {
			if abs(c.x) <= STROKE * 0.5 {return 1}
			lit := (shape == .Mouse_Left && c.x < 0) || (shape == .Mouse_Right && c.x > 0)
			if shape == .Mouse_Middle {lit = abs(c.x) <= STROKE && c.y > -0.3}
			return 1 if lit else 0
		}
		if c.y >= -0.06 && c.y < -0.06 + STROKE {return 1}
		return 0
	}
	return 0
}

// rounded: whether c is within the rectangle of half-size h around centre,
// its corners rounded: radii (round on `side`'s corners, the other's square-ish).
@(private = "file")
rounded :: proc(c, centre, h, radii: [2]f32, side: bool) -> bool {
	q := [2]f32{abs(c.x - centre.x), abs(c.y - centre.y)}
	if q.x > h.x || q.y > h.y {return false}
	r := radii.x if side else radii.y
	r = min(r, min(h.x, h.y))
	dx, dy := q.x - (h.x - r), q.y - (h.y - r)
	if dx > 0 && dy > 0 {return dx * dx + dy * dy <= r * r}
	return true
}

// prompt_device: whose buttons the hints show: the setting, or (Auto) what
// the player used last.
prompt_device :: proc(app: ^App) -> Prompt_Device {
	switch app.settings.button_prompts {
	case 1:
		return .Keyboard
	case 2:
		return .Xbox
	case 3:
		return .PlayStation
	}
	if app.actions.device == .Keyboard {return .Keyboard}
	return .PlayStation if app.actions.pad_family == .PlayStation else .Xbox
}

// prompt_glyph_for: the glyph of the first source action has on device (a
// pad's button, as the family or the setting would name it).
prompt_glyph_for :: proc(
	w: ^platform.Window,
	device: Prompt_Device,
	family: platform.Pad_Family,
	action: Action,
	settings: ^Settings,
) -> Prompt_Glyph {
	if device == .Keyboard {
		for k in action_keys(&settings.keys, action) {
			if k == .Unknown {continue}
			#partial switch k {
			case .Mouse_Left:
				return {.Mouse_Left, ""}
			case .Mouse_Right:
				return {.Mouse_Right, ""}
			case .Mouse_Middle:
				return {.Mouse_Middle, ""}
			}
			name := key_label(w, k)
			switch name {
			case "Escape":
				name = "Esc"
			case "Left Shift", "Right Shift":
				name = "Shift"
			case "Backspace":
				name = "Bksp"
			}
			return {.Keycap, name}
		}
		return {.Keycap, "?"}
	}
	// A pad: the family the glyphs are drawn for.
	style := family
	if device == .PlayStation {style = .PlayStation} else if family == .PlayStation {style = .Xbox}
	for b in action_pads(&settings.pad, action) {
		if b == .None {continue}
		name := pad_button_name(style, 0, b)
		playstation := style == .PlayStation
		#partial switch b {
		case .A:
			return {.Cross, ""} if playstation else {.Disc, name}
		case .B:
			return {.Ring, ""} if playstation else {.Disc, name}
		case .X:
			return {.Square, ""} if playstation else {.Disc, name}
		case .Y:
			return {.Triangle, ""} if playstation else {.Disc, name}
		case .Left_Bumper:
			return {.Bumper_Left, name}
		case .Right_Bumper:
			return {.Bumper_Right, name}
		case .Left_Trigger:
			return {.Trigger_Left, name}
		case .Right_Trigger:
			return {.Trigger_Right, name}
		case .Left_Stick:
			return {.Stick, "L"}
		case .Right_Stick:
			return {.Stick, "R"}
		case .Back:
			return {.View, ""}
		case .Start:
			return {.Menu, ""}
		case .Dpad_Up:
			return {.Dpad_Up, ""}
		case .Dpad_Down:
			return {.Dpad_Down, ""}
		case .Dpad_Left:
			return {.Dpad_Left, ""}
		case .Dpad_Right:
			return {.Dpad_Right, ""}
		}
	}
	return {.Disc, "?"}
}

// prompt_glyph: the glyph of action for the device in use.
prompt_glyph :: proc(app: ^App, action: Action) -> Prompt_Glyph {
	return prompt_glyph_for(
		&app.window,
		prompt_device(app),
		app.actions.pad_family,
		action,
		&app.settings,
	)
}

// prompt_glyph_width: how wide the glyph is drawn, PROMPT_BAR_HEIGHT high.
prompt_glyph_width :: proc(ctx: ^ui.Context, g: Prompt_Glyph) -> f32 {
	h := f32(PROMPT_BAR_HEIGHT)
	#partial switch g.shape {
	case .Keycap:
		return max(h, ui.measure_text(ctx, g.text, ctx.theme.font_size * 0.75) + 10)
	case .Bumper_Left, .Bumper_Right, .Trigger_Left, .Trigger_Right:
		return h * 1.5
	}
	return h
}

// prompt_glyph_draw draws g in r (its height PROMPT_BAR_HEIGHT), in the
// theme's ink, and records it for tests.
prompt_glyph_draw :: proc(
	app: ^App,
	ctx: ^ui.Context,
	g: Prompt_Glyph,
	r: ui.Rect,
	ink: ui.Color,
) {
	t := &ctx.theme
	if app.prompts_count < PROMPTS_SHOWN_MAX {
		app.prompts_shown[app.prompts_count] = g
		app.prompts_count += 1
	}
	over := t.background // text over a filled shape
	small := t.font_size * 0.75
	#partial switch g.shape {
	case .Cross, .Ring, .Square, .Triangle:
		ui.draw_icon(ctx, r, app.prompt_icons[.Disc], ink)
		ui.draw_icon(ctx, r, app.prompt_icons[g.shape], over)
	case .Stick:
		ui.draw_icon(ctx, r, app.prompt_icons[.Stick], ink)
		ui.draw_text(ctx, r, g.text, small, ink, .Center)
	case .Dpad, .Dpad_Up, .Dpad_Down, .Dpad_Left, .Dpad_Right, .Menu, .View:
		ui.draw_icon(ctx, r, app.prompt_icons[g.shape], ink)
	case .Mouse_Left, .Mouse_Right, .Mouse_Middle:
		ui.draw_icon(ctx, r, app.prompt_icons[g.shape], ink)
	case:
		ui.draw_icon(ctx, r, app.prompt_icons[g.shape], ink)
		ui.draw_text(ctx, r, g.text, small, over, .Center)
	}
}

// prompt_bar_wanted: whether the bar shows at all. One place to change the
// rule (always; only while a pad is in use: app.actions.device == .Pad).
prompt_bar_wanted :: proc(app: ^App) -> bool {return app.settings.prompt_bar}

// prompt_bar draws items along the bottom edge of the screen, right-aligned:
// each a glyph (two for the tabs) and its word, in the theme's muted ink.
prompt_bar :: proc(app: ^App, ctx: ^ui.Context, items: []Prompt_Item) {
	if len(items) == 0 || !prompt_bar_wanted(app) {return}
	t := &ctx.theme
	gap := 2 * t.spacing
	widths := make([]f32, len(items), context.temp_allocator)
	total: f32
	for item, i in items {
		w := prompt_glyph_width(ctx, prompt_glyph(app, item.action))
		if item.also != .None {w += 2 + prompt_glyph_width(ctx, prompt_glyph(app, item.also))}
		w += 6 + ui.measure_text(ctx, item.text, t.font_size)
		widths[i] = w
		total += w + gap
	}
	prev := ui.begin_layer(ctx, .Tooltip)
	defer ui.end_layer(ctx, prev)
	x := ctx.screen.w - total - t.padding + gap
	y := ctx.screen.h - PROMPT_BAR_HEIGHT - 2
	ink := t.text_muted
	for item in items {
		g := prompt_glyph(app, item.action)
		gw := prompt_glyph_width(ctx, g)
		prompt_glyph_draw(app, ctx, g, {x, y, gw, PROMPT_BAR_HEIGHT}, ink)
		x += gw + 2
		if item.also != .None {
			g2 := prompt_glyph(app, item.also)
			gw2 := prompt_glyph_width(ctx, g2)
			prompt_glyph_draw(app, ctx, g2, {x, y, gw2, PROMPT_BAR_HEIGHT}, ink)
			x += gw2 + 2
		}
		x += 4
		word := ui.measure_text(ctx, item.text, t.font_size)
		ui.draw_text(ctx, {x, y, word, PROMPT_BAR_HEIGHT}, item.text, t.font_size, ink, .Left)
		x += word + gap
	}
}

// prompt_items: what the bar says for what is on the screen (none over the
// game itself).
prompt_items :: proc(app: ^App) -> []Prompt_Item {
	items := make([dynamic]Prompt_Item, context.temp_allocator)
	tabs := Prompt_Item{.Tab_Prev, "Tabs", .Tab_Next}
	if ui.osk_is_open(&app.ui) {
		append(&items, Prompt_Item{.Menu_Confirm, "Type", .None})
		append(&items, Prompt_Item{.Menu_Secondary, "Delete", .None})
		append(&items, Prompt_Item{.Menu_Tertiary, "Space", .None})
		append(&items, Prompt_Item{.Tab_Prev, "Cursor", .Tab_Next})
		append(&items, Prompt_Item{.Pause, "Done", .None})
		append(&items, Prompt_Item{.Menu_Back, "Close", .None})
		return items[:]
	}
	select := Prompt_Item{.Menu_Confirm, "Select", .None}
	back := Prompt_Item{.Menu_Back, "Back", .None}
	if top, open := overlay_top(&app.overlays); open {
		#partial switch top {
		case .Options:
			append(&items, select, back, tabs)
		case .Dial:
			append(&items, select, Prompt_Item{.Menu_Secondary, "Erase", .None}, back)
		case .Game_Menu, .Quit_Dialog, .Consent, .Chat:
			append(&items, select, back)
		case .Inventory:
			inventory_prompts(app, &items)
		case .Stats:
			append(
				&items,
				Prompt_Item{.Menu_Confirm, "Open", .None},
				Prompt_Item{.Menu_Back, "Close", .None},
				tabs,
			)
		}
		return items[:]
	}
	switch app.screen {
	case .Title:
		append(&items, select, Prompt_Item{.Menu_Back, "Quit", .None})
	case .Options:
		append(&items, select, back, tabs)
	case .Worlds, .Multiplayer, .Failed, .Credits:
		append(&items, select, back)
	case .Game:
		s := app.session
		if s == nil {break}
		if s.state == .Choosing {
			append(&items, select, back)
		} else if s.state == .Connecting || s.loading != nil {
			append(&items, select)
		}
	}
	return items[:]
}

// inventory_prompts: the inventory's bar: what A, X and Y do under the pad's
// cursor (with a stack on it A puts down and X puts one).
@(private = "file")
inventory_prompts :: proc(app: ^App, items: ^[dynamic]Prompt_Item) {
	v := &app.inventory_view
	holding := app.session != nil && !game.stack_empty(app.session.inventory.cursor)
	on_catalog := v.cursor >= CURSOR_CATALOG_BASE
	append(items, Prompt_Item{.Menu_Confirm, "Put" if holding else "Take", .None})
	if !on_catalog {
		append(items, Prompt_Item{.Menu_Secondary, "One" if holding else "Half", .None})
	}
	append(items, Prompt_Item{.Menu_Tertiary, "Search" if on_catalog else "Move", .None})
	append(items, Prompt_Item{.Menu_Back, "Close", .None})
	if v.tab != .Chest {append(items, Prompt_Item{.Tab_Prev, "Tabs", .Tab_Next})}
}
