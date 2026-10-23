package ui

import "core:hash"
import "core:log"
import "core:mem"
import "core:mem/virtual"

import "../font"

// Immediate-mode UI. Each frame:
//
//	ui.begin_frame(&ctx, input, scale, screen_size)
//	if ui.button(&ctx, "Play") { ... }
//	ui.end_frame(&ctx)   // ctx.output: draw lists + glyph atlas changes
//
// The output is plain data (vertices, indices, draw commands with scissor
// rects, an R8 glyph atlas with a dirty region); this package knows nothing
// about the GPU. Coordinates are UI units; `scale` turns them into pixels
// (output vertices are in pixels).
//
// Interaction model:
// - hot:     the widget under the mouse, decided once per frame from every
//            widget's rect, topmost layer first; widgets under a popup or
//            modal never get it. (Decided at end_frame, used next frame.)
// - active:  the widget the mouse button went down on; a click is a release
//            over the same widget, so dragging off cancels.
// - focused: keyboard focus, moved by Tab / arrows and by clicking; Enter or
//            Space activates it. The focus ring shows once the keyboard is used.

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
	Tooltip,
}

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
}

KILL_SIZE :: 1024
MAX_ID_DEPTH :: 32
MAX_CLIP_DEPTH :: 32
MAX_LAYOUT_DEPTH :: 32

Context :: struct {
	// Persistent
	theme:          Theme,
	glyphs:         Glyph_Cache,
	hot:            Id,
	hot_layer:      Layer,
	active:         Id,
	focused:        Id,
	focus_visible:  bool, // keyboard navigation in use: draw focus rings
	modal_open:     bool, // a modal was drawn last frame: lower layers are inert
	edit:           Text_Edit, // state of the focused text field
	kill:           [KILL_SIZE]u8, // the last text killed (Ctrl+W, Ctrl+K, ...), for Ctrl+Y
	kill_len:       int,
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
	modal_drawn:    bool,
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
	layer:     Layer,
	focusable: bool,
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
	loc := #caller_location,
) -> bool {
	ctx^ = {}
	ctx.theme = DEFAULT_THEME
	if virtual.arena_init_growing(&ctx.frame_arena) != nil {return false}
	ctx.frame_alloc = virtual.arena_allocator(&ctx.frame_arena)
	return glyph_cache_init(&ctx.glyphs, f, allocator, loc)
}

destroy :: proc(ctx: ^Context) {
	glyph_cache_destroy(&ctx.glyphs)
	virtual.arena_destroy(&ctx.frame_arena)
	ctx^ = {}
}

// begin_frame starts a frame. screen_pixels is the framebuffer size; scale
// is pixels per UI unit (display scale).
begin_frame :: proc(ctx: ^Context, input: Input, screen_pixels: Vec2, scale: f32) {
	free_all(ctx.frame_alloc)
	ctx.input = input
	ctx.input.text = clone_slice(input.text, ctx.frame_alloc)
	ctx.scale = max(scale, 0.25)
	ctx.screen = {0, 0, screen_pixels.x / ctx.scale, screen_pixels.y / ctx.scale}
	ctx.layer = .Base
	ctx.id_depth, ctx.clip_depth, ctx.layout_depth = 0, 0, 0
	ctx.widgets = make([dynamic]Widget, 0, 64, ctx.frame_alloc)
	ctx.modal_drawn = false
	ctx.activate_focus = false
	ctx.focus_request = .None
	output_begin(&ctx.output, ctx.frame_alloc)

	keys := input.keys_pressed
	if .Tab in keys {
		ctx.focus_request = .Previous if .Shift in input.modifiers else .Next
	}
	// Arrows navigate unless a text field has focus (it uses them itself).
	if !ctx.edit.active {
		if .Down in keys {ctx.focus_request = .Next}
		if .Up in keys {ctx.focus_request = .Previous}
		if .Enter in keys || .Space in keys {ctx.activate_focus = true}
	}
	if ctx.focus_request != .None {ctx.focus_visible = true}
	if input.mouse_pressed != {} {ctx.focus_visible = false}
	if .Left not_in input.mouse_down && .Left not_in input.mouse_released {
		ctx.active = 0
	}
	push_clip_rect(ctx, ctx.screen)
}

// end_frame resolves hover for the next frame, applies keyboard navigation
// and finalises the output.
end_frame :: proc(ctx: ^Context) {
	// Hover: topmost widget under the mouse; later widgets win within a layer.
	ctx.hot = 0
	ctx.modal_open = ctx.modal_drawn
	best_layer := -1
	for w in ctx.widgets {
		if ctx.modal_open && w.layer < .Modal {continue}
		if int(w.layer) >= best_layer && rect_contains(w.rect, ctx.input.mouse) {
			ctx.hot, ctx.hot_layer, best_layer = w.id, w.layer, int(w.layer)
		}
	}
	// Keyboard focus moves among focusable widgets of the top interactive layer.
	if ctx.focus_request != .None {move_focus(ctx)}
	// Focus on a widget that wasn't drawn this frame is dropped.
	if ctx.focused != 0 && !widget_drawn(ctx, ctx.focused) {ctx.focused = 0}
	if !widget_drawn(ctx, ctx.edit.id) {ctx.edit.active = false}
	output_end(&ctx.output, &ctx.glyphs)
}

@(private)
widget_drawn :: proc(ctx: ^Context, id: Id) -> bool {
	for w in ctx.widgets {if w.id == id {return true}}
	return false
}

@(private)
move_focus :: proc(ctx: ^Context) {
	top := Layer.Base
	for w in ctx.widgets {if w.focusable && w.layer > top {top = w.layer}}
	if ctx.modal_open {top = max(top, Layer.Modal)}
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
	append(&ctx.widgets, Widget{id = id, rect = visible, layer = ctx.layer, focusable = focusable})
	// Under a modal: drawn, but no hover, clicks or focus, and it must not
	// touch the shared interaction state either.
	if ctx.modal_open && ctx.layer < .Modal {return}

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

rect_center :: proc(outer: Rect, w, h: f32) -> Rect {
	return {outer.x + (outer.w - w) / 2, outer.y + (outer.h - h) / 2, w, h}
}

@(private)
clone_slice :: proc(s: []$T, allocator: mem.Allocator) -> []T {
	out := make([]T, len(s), allocator)
	copy(out, s)
	return out
}
