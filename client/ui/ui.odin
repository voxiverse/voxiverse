package ui

import "core:hash"
import "core:log"
import "core:mem"
import "core:mem/virtual"

import "client:font"

// Immediate-mode UI. Each frame:
//
//	ui.begin_frame(&ctx, input, scale, screen_size)
//	if ui.button(&ctx, "Play") { ... }
//	ui.end_frame(&ctx)   // ctx.output: draw lists + glyph atlas changes
//
// The output is plain data (vertices, indices, draw commands with scissor
// rects, an RGBA8 atlas of glyphs and icons with a dirty region); this package knows nothing
// about the GPU. Coordinates are UI units; `scale` turns them into pixels
// (output vertices are in pixels).
//
// Interaction model:
// - hot:     the widget under the mouse, decided once per frame from every
//            widget's rect, topmost layer first; widgets under a popup or
//            modal never get it. (Decided at end_frame, used next frame.)
// - active:  the widget the mouse button went down on; a click is a release
//            over the same widget, so dragging off cancels.
// - focused: keyboard and pad focus, moved by Tab, by directions (the arrows,
//            the pad: the nearest widget that way, nav_pick) and by clicking;
//            Enter, Space or the pad's Confirm activates it. The focus ring
//            shows once the keyboard or pad is used, and the mouse's hover
//            is idle until it moves.

Id :: distinct u64

Vec2 :: [2]f32

Rect :: struct {
	x, y, w, h: f32,
}

// Layers decide draw order and input priority. While anything is drawn on
// .Modal, widgets on lower layers are inert.
Layer :: enum u8 {
	Base,
	Popup,
	Modal,
	Keyboard, // the on-screen keyboard (keyboard.odin): over a modal, under tooltips
	Tooltip,
}

// Nav is a navigation event: from the pad (Input.nav) or the keyboard's
// arrows, Enter and Space (made in begin_frame).
Nav :: enum u8 {
	Up,
	Down,
	Left,
	Right,
	Confirm,
	Back,
	Secondary,
	Tertiary,
	Start,
}

DIRECTIONS :: bit_set[Nav]{.Up, .Down, .Left, .Right}

Mouse_Button :: enum u8 {
	Left,
	Right,
	Middle,
}

Key :: enum u8 {
	Tab,
	Enter,
	Escape,
	Space,
	Backspace,
	Delete,
	Left,
	Right,
	Up,
	Down,
	Home,
	End,
	Page_Up,
	Page_Down,
	// Letters, for the editing shortcuts (with Ctrl or Alt; widgets.odin).
	A,
	B,
	C,
	D,
	E,
	F,
	G,
	H,
	K,
	L,
	N,
	P,
	R,
	U,
	V,
	W,
	X,
	Y,
}

Modifier :: enum u8 {
	Shift,
	Ctrl,
	Alt,
}

// Input is everything the UI needs from one frame of platform events.
Input :: struct {
	mouse:          Vec2, // UI units
	mouse_down:     bit_set[Mouse_Button],
	mouse_pressed:  bit_set[Mouse_Button], // went down this frame
	mouse_released: bit_set[Mouse_Button],
	wheel:          Vec2, // notches, +y = up
	keys_pressed:   bit_set[Key], // includes auto-repeat
	modifiers:      bit_set[Modifier],
	text:           []rune, // typed text this frame
	time:           f64, // seconds, monotonic (tooltip delays)
	// From the pad (the client fills these from its actions; the keyboard's
	// arrows, Enter and Space arrive as keys_pressed).
	nav:            bit_set[Nav],
	nav_scroll:     f32, // rows this frame from the right stick
	pad:            bool, // the pad is the device used last
	// While the on-screen keyboard is open: the bumpers' cursor steps and the
	// stick press (Shift).
	osk_cursor:     int,
	osk_shift:      bool,
}

KILL_SIZE :: 1024
MAX_ID_DEPTH :: 32
MAX_CLIP_DEPTH :: 32
MAX_LAYOUT_DEPTH :: 32

Context :: struct {
	// Persistent
	theme:          Theme,
	theme_stack:    [8]Theme,
	theme_depth:    int,
	theme_over:     int, // scopes begun past the stack's depth (ignored)
	glyphs:         Glyph_Cache,
	hot:            Id,
	hot_layer:      Layer,
	active:         Id,
	focused:        Id,
	focus_visible:  bool, // keyboard navigation in use: draw focus rings
	modal_open:     bool, // a modal was drawn last frame: lower layers are inert
	keyboard_open:  bool, // the on-screen keyboard was drawn last frame: so are all below it
	osk:            Osk,
	focus_by_layer: [Layer]Id, // each layer's focus, for when the layer above goes
	top_layer:      Layer, // the layer that was interactive last frame
	default_id:     Id, // the widget a screen named with default_focus this frame
	default_next:   bool,
	pointer_idle:   bool, // a nav event came: no hover until the mouse moves
	idle_mouse:     Vec2,
	nav_accum:      f32, // fractions of rows scrolled by the stick
	kfv_id:         Id, // the focus keep_focus_visible last scrolled to
	edit:           Text_Edit, // state of the focused text field
	kill:           [KILL_SIZE]u8, // the last text killed (Ctrl+W, Ctrl+K, ...), for Ctrl+Y
	kill_len:       int,
	tip_id:         Id, // the tooltip's widget: hovered since tip_since
	tip_since:      f64,
	tip_hit:        bool, // a tooltip's area was hovered this frame
	errors:         int, // misuse so far (duplicate ids); checks fail on any
	reported:       [16]Id, // each logged once, not every frame
	frame_arena:    virtual.Arena,
	frame_alloc:    mem.Allocator,

	// Per frame (frame arena)
	input:          Input,
	scale:          f32,
	screen:         Rect, // UI units
	layer:          Layer,
	id_stack:       [MAX_ID_DEPTH]Id,
	id_depth:       int,
	clip_stack:     [MAX_CLIP_DEPTH]Rect,
	clip_depth:     int,
	layouts:        [MAX_LAYOUT_DEPTH]Layout,
	layout_depth:   int,
	widgets:        [dynamic]Widget, // every interactive widget this frame
	texts:          [dynamic]string, // every text drawn this frame (tests: what a player reads)
	modal_drawn:    bool,
	keyboard_drawn: bool,
	nav:            bit_set[Nav], // this frame's: the pad's and the keyboard's
	consumed:       bit_set[Nav], // taken by a widget: focus does not move for them
	focus_request:  Focus_Move,
	activate_focus: bool,
	output:         Output,
}

// Widget is what each interactive widget registers per frame, for hover
// arbitration and keyboard navigation.
@(private)
Widget :: struct {
	id:        Id,
	rect:      Rect, // clipped to its scissor
	full:      Rect, // as asked for, unclipped (a scrolled row below its view)
	clip:      Rect, // the scissor it was drawn in
	layer:     Layer,
	focusable: bool,
	label:     string, // what it says (find_widget)
}

@(private)
Focus_Move :: enum u8 {
	None,
	Next,
	Previous,
}

init :: proc(
	ctx: ^Context,
	f: ^font.Font,
	allocator := context.allocator,
	fallback: ^font.Font = nil, // for what f lacks
	loc := #caller_location,
) -> bool {
	ctx^ = {}
	ctx.theme = DEFAULT_THEME
	if virtual.arena_init_growing(&ctx.frame_arena) != nil {return false}
	ctx.frame_alloc = virtual.arena_allocator(&ctx.frame_arena)
	ok := glyph_cache_init(&ctx.glyphs, f, allocator, loc)
	ctx.glyphs.fallback = fallback
	return ok
}

destroy :: proc(ctx: ^Context) {
	glyph_cache_destroy(&ctx.glyphs)
	virtual.arena_destroy(&ctx.frame_arena)
	ctx^ = {}
}

// begin_frame starts a frame. screen_pixels is the framebuffer size; scale
// is pixels per UI unit (display scale).
begin_frame :: proc(ctx: ^Context, input: Input, screen_pixels: Vec2, scale: f32) {
	// The pointer comes back when the mouse moves or a button goes down (hover
	// is decided from the widgets of the frame before, before they are freed).
	if ctx.pointer_idle {
		d := input.mouse - ctx.idle_mouse
		if abs(d.x) + abs(d.y) > 2 || input.mouse_pressed != {} {
			ctx.pointer_idle = false
			resolve_hot(ctx, input.mouse)
		}
	}
	free_all(ctx.frame_alloc)
	ctx.input = input
	ctx.input.text = clone_slice(input.text, ctx.frame_alloc)
	ctx.scale = max(scale, 0.25)
	ctx.screen = {0, 0, screen_pixels.x / ctx.scale, screen_pixels.y / ctx.scale}
	ctx.layer = .Base
	ctx.id_depth, ctx.clip_depth, ctx.layout_depth = 0, 0, 0
	ctx.widgets = make([dynamic]Widget, 0, 64, ctx.frame_alloc)
	ctx.texts = make([dynamic]string, 0, 64, ctx.frame_alloc)
	ctx.modal_drawn = false
	ctx.keyboard_drawn = false
	ctx.tip_hit = false
	ctx.activate_focus = false
	ctx.focus_request = .None
	ctx.consumed = {}
	ctx.default_next = false
	ctx.default_id = 0
	output_begin(&ctx.output, ctx.frame_alloc)

	keys := input.keys_pressed
	if .Tab in keys {
		ctx.focus_request = .Previous if .Shift in input.modifiers else .Next
	}
	// The keyboard's arrows, Enter and Space navigate like the pad unless a
	// text field has focus (it uses them itself).
	ctx.nav = input.nav
	if !ctx.edit.active {
		if .Down in keys {ctx.nav += {.Down}}
		if .Up in keys {ctx.nav += {.Up}}
		if .Left in keys {ctx.nav += {.Left}}
		if .Right in keys {ctx.nav += {.Right}}
		if .Enter in keys || .Space in keys {ctx.nav += {.Confirm}}
	}
	if .Confirm in ctx.nav {ctx.activate_focus = true}
	if ctx.focus_request != .None || ctx.nav != {} {
		ctx.focus_visible = true
		if !ctx.pointer_idle {
			ctx.pointer_idle, ctx.idle_mouse = true, input.mouse
		}
	}
	if input.mouse_pressed != {} {ctx.focus_visible = false}
	if .Left not_in input.mouse_down && .Left not_in input.mouse_released {
		ctx.active = 0
	}
	push_clip_rect(ctx, ctx.screen)
}

// end_frame resolves hover for the next frame, applies keyboard navigation
// and finalises the output.
end_frame :: proc(ctx: ^Context) {
	ctx.modal_open = ctx.modal_drawn
	ctx.keyboard_open = ctx.keyboard_drawn
	if !ctx.pointer_idle {resolve_hot(ctx, ctx.input.mouse)} else {ctx.hot = 0}
	if ctx.focused != 0 && !widget_drawn(ctx, ctx.focused) {ctx.focused = 0}

	// Focus belongs to the top interactive layer: a layer that appears takes
	// focus to its first widget (the pad and keyboard users see it), the one
	// that goes gives the lower layer's focus back.
	top := top_layer(ctx)
	if top != ctx.top_layer {
		remembered := ctx.focus_by_layer[top]
		if ctx.focused != 0 && widget_on_layer(ctx, ctx.focused, top) {
			// (a screen put the focus there itself)
		} else if remembered != 0 && widget_on_layer(ctx, remembered, top) {
			ctx.focused = remembered
		} else if ctx.focus_visible || ctx.input.pad {
			ctx.focused = first_focus(ctx, top)
		} else {
			ctx.focused = 0
		}
		ctx.top_layer = top
	}
	// Keyboard focus moves among focusable widgets of the top interactive layer.
	if ctx.focus_request != .None {move_focus(ctx, top)}
	if ctx.focused != 0 && !widget_on_layer(ctx, ctx.focused, top) {ctx.focused = 0}
	pad_or_key := ctx.nav & (DIRECTIONS + {.Confirm})
	if pad_or_key != {} || ctx.input.pad {
		if ctx.focused == 0 {
			// The first event only shows where the focus is.
			ctx.focused = first_focus(ctx, top)
		} else {
			for dir in Nav.Up ..= Nav.Right {
				if dir in ctx.nav && dir not_in ctx.consumed {move_focus_dir(ctx, top, dir)}
			}
		}
	}
	ctx.focus_by_layer[top] = ctx.focused
	if !widget_drawn(ctx, ctx.edit.id) {ctx.edit.active = false}
	if !ctx.tip_hit {ctx.tip_id = 0}
	output_end(&ctx.output, &ctx.glyphs)
}

// resolve_hot: the topmost widget under the mouse; later widgets win within a layer.
@(private)
resolve_hot :: proc(ctx: ^Context, mouse: Vec2) {
	ctx.hot = 0
	floor := inert_below(ctx)
	best_layer := -1
	for w in ctx.widgets {
		if w.layer < floor {continue}
		if int(w.layer) >= best_layer && rect_contains(w.rect, mouse) {
			ctx.hot, ctx.hot_layer, best_layer = w.id, w.layer, int(w.layer)
		}
	}
}

// inert_below: widgets on layers under this one are drawn but do nothing
// (a modal or the on-screen keyboard was drawn last frame).
@(private)
inert_below :: proc(ctx: ^Context) -> Layer {
	if ctx.keyboard_open {return .Keyboard}
	if ctx.modal_open {return .Modal}
	return .Base
}

// top_layer: the layer whose focusable widgets navigation moves among.
@(private)
top_layer :: proc(ctx: ^Context) -> Layer {
	top := inert_below(ctx)
	for w in ctx.widgets {if w.focusable && w.layer > top {top = w.layer}}
	return top
}

@(private)
widget_drawn :: proc(ctx: ^Context, id: Id) -> bool {
	for w in ctx.widgets {if w.id == id {return true}}
	return false
}

@(private)
widget_on_layer :: proc(ctx: ^Context, id: Id, layer: Layer) -> bool {
	for w in ctx.widgets {if w.id == id {return w.focusable && w.layer == layer}}
	return false
}

// first_focus: the widget a screen named with default_focus, else the first
// focusable one drawn, on layer (0 if none).
@(private)
first_focus :: proc(ctx: ^Context, layer: Layer) -> Id {
	if ctx.default_id != 0 && widget_on_layer(ctx, ctx.default_id, layer) {return ctx.default_id}
	for w in ctx.widgets {
		if w.focusable && w.layer == layer {return w.id}
	}
	return 0
}

// default_focus: the next focusable widget drawn is where focus starts when
// its screen or dialog appears (and with nothing focused).
default_focus :: proc(ctx: ^Context) {
	ctx.default_next = true
}

// consume_nav: a widget used these directions this frame: focus does not
// move for them.
consume_nav :: proc(ctx: ^Context, set: bit_set[Nav]) {
	ctx.consumed += set
}

// focused_label: what the focused widget says ("" if none).
focused_label :: proc(ctx: ^Context) -> string {
	for w in ctx.widgets {if w.id == ctx.focused {return w.label}}
	return ""
}

// move_focus: Tab and Shift+Tab, in drawing order, wrapping.
@(private)
move_focus :: proc(ctx: ^Context, top: Layer) {
	candidates := make([dynamic]Id, 0, len(ctx.widgets), ctx.frame_alloc)
	for w in ctx.widgets {
		if w.focusable && w.layer == top {append(&candidates, w.id)}
	}
	if len(candidates) == 0 {return}
	current := -1
	for id, i in candidates {if id == ctx.focused {current = i}}
	n := len(candidates)
	switch {
	case current < 0:
		ctx.focused = candidates[0] if ctx.focus_request == .Next else candidates[n - 1]
	case ctx.focus_request == .Next:
		ctx.focused = candidates[(current + 1) % n]
	case:
		ctx.focused = candidates[(current - 1 + n) % n]
	}
}

// move_focus_dir: the focus goes to the nearest focusable widget of the top
// layer in direction dir (nav_pick), by their full rects. No wrapping.
@(private)
move_focus_dir :: proc(ctx: ^Context, top: Layer, dir: Nav) {
	rects := make([dynamic]Rect, 0, len(ctx.widgets), ctx.frame_alloc)
	ids := make([dynamic]Id, 0, len(ctx.widgets), ctx.frame_alloc)
	from: Rect
	for w in ctx.widgets {
		if !w.focusable || w.layer != top {continue}
		if w.id == ctx.focused {from = w.full; continue}
		append(&rects, w.full)
		append(&ids, w.id)
	}
	if i := nav_pick(from, rects[:], dir); i >= 0 {ctx.focused = ids[i]}
}

// nav_pick: which of candidates a move in direction dir from `from` lands on
// (-1: none). A candidate qualifies when its centre is more than 1 unit past
// from's centre in that direction; the lowest score wins, ties to the
// earlier: the gap between the near edges (0 if they overlap) plus twice the
// gap across (0 if the spans overlap) plus 0.05 times the centres' distance
// across.
nav_pick :: proc(from: Rect, candidates: []Rect, dir: Nav) -> int {
	if dir > .Right {return -1}
	vertical := dir == .Up || dir == .Down
	fc := Vec2{from.x + from.w / 2, from.y + from.h / 2}
	best, best_score := -1, f32(0)
	for c, i in candidates {
		cc := Vec2{c.x + c.w / 2, c.y + c.h / 2}
		gap, across_gap, across: f32
		if vertical {
			sign: f32 = 1 if dir == .Down else -1
			if (cc.y - fc.y) * sign <= 1 {continue}
			gap = (c.y - (from.y + from.h)) if dir == .Down else (from.y - (c.y + c.h))
			across_gap = max(c.x - (from.x + from.w), from.x - (c.x + c.w), 0)
			across = abs(cc.x - fc.x)
		} else {
			sign: f32 = 1 if dir == .Right else -1
			if (cc.x - fc.x) * sign <= 1 {continue}
			gap = (c.x - (from.x + from.w)) if dir == .Right else (from.x - (c.x + c.w))
			across_gap = max(c.y - (from.y + from.h), from.y - (c.y + c.h), 0)
			across = abs(cc.y - fc.y)
		}
		score := max(gap, 0) + 2 * across_gap + 0.05 * across
		if best < 0 || score < best_score {best, best_score = i, score}
	}
	return best
}

// ---------------------------------------------------------------------------
// Ids
// ---------------------------------------------------------------------------

// get_id hashes a label within the current id scope. "Label##suffix" shows
// "Label" but hashes the whole string, for repeated labels.
get_id :: proc(ctx: ^Context, label: string) -> Id {
	seed := ctx.id_stack[ctx.id_depth - 1] if ctx.id_depth > 0 else 0
	return Id(hash.fnv64a(transmute([]u8)label, u64(seed)) | 1)
}

get_id_int :: proc(ctx: ^Context, n: int) -> Id {
	seed := ctx.id_stack[ctx.id_depth - 1] if ctx.id_depth > 0 else 0
	value := n
	return Id(hash.fnv64a(mem.ptr_to_bytes(&value), u64(seed)) | 1)
}

push_id :: proc(ctx: ^Context, label: string) {
	assert(ctx.id_depth < MAX_ID_DEPTH, "ui: id stack overflow")
	ctx.id_stack[ctx.id_depth] = get_id(ctx, label)
	ctx.id_depth += 1
}

push_id_int :: proc(ctx: ^Context, n: int) {
	assert(ctx.id_depth < MAX_ID_DEPTH, "ui: id stack overflow")
	ctx.id_stack[ctx.id_depth] = get_id_int(ctx, n)
	ctx.id_depth += 1
}

pop_id :: proc(ctx: ^Context) {
	assert(ctx.id_depth > 0, "ui: pop_id without push_id")
	ctx.id_depth -= 1
}

// display_label drops a "##suffix" used only to make ids unique.
display_label :: proc(label: string) -> string {
	for i in 0 ..< len(label) - 1 {
		if label[i] == '#' && label[i + 1] == '#' {return label[:i]}
	}
	return label
}

// ---------------------------------------------------------------------------
// Layers, clipping
// ---------------------------------------------------------------------------

// begin_layer / end_layer draw subsequent widgets on another layer.
begin_layer :: proc(ctx: ^Context, layer: Layer) -> (previous: Layer) {
	previous = ctx.layer
	ctx.layer = layer
	if layer == .Modal {ctx.modal_drawn = true}
	if layer == .Keyboard {ctx.keyboard_drawn = true}
	return
}

end_layer :: proc(ctx: ^Context, previous: Layer) {
	ctx.layer = previous
}

push_clip_rect :: proc(ctx: ^Context, r: Rect) {
	assert(ctx.clip_depth < MAX_CLIP_DEPTH, "ui: clip stack overflow")
	clipped := r if ctx.clip_depth == 0 else rect_intersect(r, ctx.clip_stack[ctx.clip_depth - 1])
	ctx.clip_stack[ctx.clip_depth] = clipped
	ctx.clip_depth += 1
}

pop_clip_rect :: proc(ctx: ^Context) {
	assert(ctx.clip_depth > 1, "ui: pop_clip_rect without push_clip_rect")
	ctx.clip_depth -= 1
}

current_clip :: proc(ctx: ^Context) -> Rect {
	return ctx.clip_stack[ctx.clip_depth - 1]
}

// ---------------------------------------------------------------------------
// Interaction
// ---------------------------------------------------------------------------

Interaction :: struct {
	hovered: bool, // mouse over it (and nothing above it)
	pressed: bool, // mouse button is held on it
	clicked: bool, // activated: mouse released on it, or Enter/Space while focused
	focused: bool,
}

// interact registers a widget for this frame and reports how it is being
// used. Every interactive widget goes through here.
// loc is where the widget was called from, for error reports.
interact :: proc(
	ctx: ^Context,
	id: Id,
	r: Rect,
	focusable := true,
	label := "",
	loc := #caller_location,
) -> (
	it: Interaction,
) {
	// Two widgets with one id would share hover, press and focus state: one
	// silently eats the other's clicks. Same label in the same scope; give
	// one a "##suffix" or wrap its group in push_id.
	for w in ctx.widgets {
		if w.id == id {
			ctx.errors += 1
			if !already_reported(ctx, id) {
				log.errorf(
					"ui duplicate widget id this frame (same label in the same id scope?) at=%v",
					loc,
				)
			}
			break
		}
	}
	visible := rect_intersect(r, current_clip(ctx))
	append(
		&ctx.widgets,
		Widget {
			id = id,
			rect = visible,
			full = r,
			clip = current_clip(ctx),
			layer = ctx.layer,
			focusable = focusable,
			label = label,
		},
	)
	if ctx.default_next && focusable {
		ctx.default_id, ctx.default_next = id, false
	}
	// Under a modal or the keyboard: drawn, but no hover, clicks or focus, and
	// it must not touch the shared interaction state either.
	if ctx.layer < inert_below(ctx) {return}

	it.hovered = ctx.hot == id
	if it.hovered && .Left in ctx.input.mouse_pressed {
		ctx.active = id
		if focusable {ctx.focused = id}
	}
	if ctx.active == id && .Left in ctx.input.mouse_released {
		it.clicked = it.hovered
		ctx.active = 0
	}
	it.pressed = ctx.active == id && .Left in ctx.input.mouse_down
	it.focused = ctx.focused == id
	if it.focused && ctx.activate_focus {it.clicked = true}
	return
}

// find_widget: where the last frame drew the widget saying label, the
// topmost if several do (tests click by what a player reads).
find_widget :: proc(ctx: ^Context, label: string) -> (r: Rect, found: bool) {
	top: Layer
	for w in ctx.widgets {
		if w.label == label && (!found || w.layer >= top) {
			r, found, top = w.rect, true, w.layer
		}
	}
	return
}

@(private)
already_reported :: proc(ctx: ^Context, id: Id) -> bool {
	for r in ctx.reported {if r == id {return true}}
	for &r in ctx.reported {
		if r == 0 {
			r = id
			return false
		}
	}
	return true // table full: stop logging; errors still counts
}

// ---------------------------------------------------------------------------
// Geometry helpers
// ---------------------------------------------------------------------------

rect_contains :: proc(r: Rect, p: Vec2) -> bool {
	return p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h
}

rect_intersect :: proc(a, b: Rect) -> Rect {
	x0, y0 := max(a.x, b.x), max(a.y, b.y)
	x1, y1 := min(a.x + a.w, b.x + b.w), min(a.y + a.h, b.y + b.h)
	return {x0, y0, max(x1 - x0, 0), max(y1 - y0, 0)}
}

rect_shrink :: proc(r: Rect, by: f32) -> Rect {
	return {r.x + by, r.y + by, max(r.w - 2 * by, 0), max(r.h - 2 * by, 0)}
}

rect_expand :: proc(r: Rect, by: f32) -> Rect {
	return {r.x - by, r.y - by, r.w + 2 * by, r.h + 2 * by}
}

rect_center :: proc(outer: Rect, w, h: f32) -> Rect {
	return {outer.x + (outer.w - w) / 2, outer.y + (outer.h - h) / 2, w, h}
}

@(private)
clone_slice :: proc(s: []$T, allocator: mem.Allocator) -> []T {
	out := make([]T, len(s), allocator)
	copy(out, s)
	return out
}
