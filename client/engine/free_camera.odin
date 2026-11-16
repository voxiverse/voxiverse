package engine

import "core:math"

import "client:render"
import "client:ui"
import "common:game"

// The free camera and the pointer's tools: what a game whose players have no body
// (game.Ability.Bodiless: a city builder, a strategy game, a factory) plays with. The
// game asks for the camera (Game.camera, kind .Free) with its limits; the player pans
// it over the ground (the movement keys, the pointer at a window's edge, the middle
// button dragged), zooms it (the wheel), and turns it (F5, a quarter turn; Shift and the
// wheel). The camera looks at the player's own focus, which pans by the ordinary input
// (Player_Input.move along the camera's heading, at the world's fly speed), so the
// server, which streams the world round that focus, stays the judge of where it is.
//
// The pointer is free. What is under it (the ground block, an entity) and its buttons'
// presses and drags (pointer_tool) are the game's to read; a click on the UI (a
// widget, a ui.panel) is never the world's. A game marks the ground with
// ground_fill (translucent, over each column's top), ground_outline (the edge of a
// rectangle on the ground) and structure_ghost (a template's blocks, tinted), drawn
// with the debug pass's lines and fills.

FREE_ZOOM_STEP :: 0.88 // the distance is multiplied by this for each step of the wheel towards
FREE_TURN_STEP :: math.PI / 12 // radians the camera turns for each step of the wheel with Shift
FREE_EDGE :: 6 // pixels: the pointer this near a window's edge (not over the UI) pans
FREE_DRAG_PIXELS :: 120 // pixels: the middle button dragged this far pans at full speed
CLICK_SLOP :: 4 // pixels: a press released within this is a click, not a drag

// Free_View: the free camera's own state (the session's): how far it is and where it
// looks, within the game's limits.
Free_View :: struct {
	set:      bool, // taken from the game's camera the first frame
	distance: f32,
	heading:  f32,
	drag:     [2]f32, // where the middle button went down (pixels)
	dragging: bool,
}

// Pointer_Button: the buttons a game's pointer tools read.
Pointer_Button :: enum u8 {
	Primary, // the left button
	Secondary, // the right
}

// Pointer_Press: one button of the pointer this frame. A press over the UI is the UI's
// and starts none.
Pointer_Press :: struct {
	down:     bool, // held (a press the world took)
	pressed:  bool, // went down this frame
	released: bool, // came up this frame (after a press the world took)
	clicked:  bool, // released where it went down: a click, not a drag
	from:     game.Block_Pos, // the ground block it went down on
	entity:   u32, // the entity it went down on (0: none)
	at:       [2]f32, // where it went down, pixels
}

// Pointer_Tool: what the free pointer is over and does (pointer_tool).
Pointer_Tool :: struct {
	ground:    game.Block_Pos, // the top block of the ground under the pointer
	on_ground: bool, // ... there is one (the pointer is over the world, not the sky)
	entity:    u32, // the entity under it (0: none)
	over_ui:   bool, // over the UI: clicks are the UI's
	buttons:   [Pointer_Button]Pointer_Press,
}

// camera_free: the session's camera is a free one (the game chose .Free).
camera_free :: proc(s: ^Session) -> bool {
	return s != nil && s.state == .Playing && s.game_camera.kind == .Free
}

// free_camera_update: the wheel, Shift, F5 and the middle button turn and zoom the free
// camera; its move this frame (the keys, the edges, the drag: x right, y up the
// screen) for player_input.
free_camera_update :: proc(s: ^Session, input: ^Input_State, actions: ^Actions) {
	c := s.game_camera
	f := &s.free
	if !f.set {
		f.set, f.distance, f.heading = true, c.distance, c.heading
	}
	near, far := max(c.near, 2), max(c.far, c.near, 2)
	shift := input.held & {.Left_Shift, .Right_Shift} != {}
	if input.wheel.y != 0 && !s.pointer_over_ui {
		if shift {
			f.heading += f32(input.wheel.y) * FREE_TURN_STEP
		} else {
			f.distance *= math.pow(FREE_ZOOM_STEP, f32(input.wheel.y))
		}
	}
	if action_pressed(actions, .Camera) {f.heading += math.PI / 2}
	f.heading = math.mod(f.heading + math.TAU, math.TAU)
	f.distance = clamp(f.distance if f.distance > 0 else c.distance, near, far)

	move := actions.move
	if .Middle in input.mouse_pressed && !s.pointer_over_ui {
		f.drag, f.dragging = input.mouse, true
	}
	if .Middle not_in input.mouse_down {f.dragging = false}
	if f.dragging {
		d := (f.drag - input.mouse) / FREE_DRAG_PIXELS // (the ground follows the hand)
		move += {d.x, -d.y}
	}
	if size := s.screen_view.size;
	   s.screen_view.set && input.mouse_down == {} && !s.pointer_over_ui {
		p := input.mouse
		if p.x >= 0 && p.y >= 0 && p.x < size.x && p.y < size.y {
			if p.x < FREE_EDGE {move.x -= 1}
			if p.x >= size.x - FREE_EDGE {move.x += 1}
			if p.y < FREE_EDGE {move.y += 1}
			if p.y >= size.y - FREE_EDGE {move.y -= 1}
		}
	}
	if l := math.sqrt(move.x * move.x + move.y * move.y); l > 1 {move /= l}
	// Zoomed in, the ground crosses the screen faster: it pans slower.
	s.free_move = move * clamp(f.distance / far, 0.25, 1)
}

// camera_free_view: the free camera's view of the focus (the predicted feet).
camera_free_view :: proc(s: ^Session) -> View {
	return camera_top_down(
		s.feet,
		{
			kind = .Top_Down,
			distance = s.free.distance,
			angle = s.game_camera.angle,
			heading = s.free.heading,
		},
	)
}

// pointer_tool: what the free pointer is over and its buttons this frame (all zero
// with any other camera).
pointer_tool :: proc(s: ^Session) -> ^Pointer_Tool {
	return &s.tool
}

// pointer_tool_update: once a frame under the free camera, after pointer_update.
pointer_tool_update :: proc(s: ^Session, input: ^Input_State) {
	t := &s.tool
	t.over_ui = s.pointer_over_ui
	t.on_ground, t.entity = false, s.aim_entity.? or_else 0
	if hit, ok := s.aim.?; ok {
		t.ground, t.on_ground = hit.block, true
	}
	mouse := [Pointer_Button]ui.Mouse_Button {
		.Primary   = .Left,
		.Secondary = .Right,
	}
	for &b, button in t.buttons {
		m := mouse[button]
		b.pressed, b.released, b.clicked = false, false, false
		if m in input.mouse_pressed && !t.over_ui && t.on_ground {
			b = {
				down    = true,
				pressed = true,
				from    = t.ground,
				entity  = t.entity,
				at      = input.mouse,
			}
		}
		if b.down && m not_in input.mouse_down {
			d := input.mouse - b.at
			b.down, b.released = false, true
			b.clicked = abs(d.x) + abs(d.y) <= CLICK_SLOP
		}
	}
}

// block_rect: the rectangle of blocks between two corners, lowest corner first.
block_rect :: proc(a, b: game.Block_Pos) -> (lo, hi: game.Block_Pos) {
	return {
		min(a.x, b.x),
		min(a.y, b.y),
		min(a.z, b.z),
	}, {max(a.x, b.x), max(a.y, b.y), max(a.z, b.z)}
}

// MAX_FILL_VERTICES: the ground marks' and ghosts' triangles a frame (more are not drawn).
MAX_FILL_VERTICES :: 6 * 32768

// surface_top: the y of the top of the highest solid block of column (x, z) from hi
// down to lo (lo when there is none).
@(private = "file")
surface_top :: proc(s: ^Session, x, z, lo, hi: i32) -> f64 {
	q := game.Block_Query{&s.world, world_block, &s.reg.blocks, {}}
	for y := hi; y >= lo; y -= 1 {
		_, loaded := world_block(&s.world, {x, y, z})
		if loaded && game.solid_at(q, {x, y, z}) {return f64(y + 1)}
	}
	return f64(lo)
}

// ground_fill: a translucent cover over the ground of the blocks lo..hi (x and z;
// each column's cover lies on its highest solid block between lo.y and hi.y): a zone,
// a road's reach, a heat map. One quad a column, MAX_FILL_VERTICES a frame.
ground_fill :: proc(s: ^Session, lo, hi: game.Block_Pos, color: [4]u8) {
	a, b := block_rect(lo, hi)
	for z in a.z ..= b.z {
		for x in a.x ..= b.x {
			if len(s.fills) + 6 > MAX_FILL_VERTICES {return}
			y := surface_top(s, x, z, a.y, b.y) + 0.03
			x0, z0 := f64(x), f64(z)
			fill_quad(s, {x0, y, z0}, {x0 + 1, y, z0}, {x0 + 1, y, z0 + 1}, {x0, y, z0 + 1}, color)
		}
	}
}

// ground_outline: the edge of the rectangle lo..hi drawn on the ground (each side's
// segments at their columns' tops), in lines.
ground_outline :: proc(s: ^Session, lo, hi: game.Block_Pos, color: [4]u8) {
	a, b := block_rect(lo, hi)
	if len(s.world_lines) + 4 * int(b.x - a.x + b.z - a.z + 2) > MAX_WORLD_LINES {return}
	edge :: proc(s: ^Session, x, z, y0, y1: i32, p, q: [3]f64, color: [4]u8) {
		y := surface_top(s, x, z, y0, y1) + 0.05
		world_line(s, {p.x, y, p.z}, {q.x, y, q.z}, color)
	}
	for x in a.x ..= b.x {
		x0 := f64(x)
		edge(s, x, a.z, a.y, b.y, {x0, 0, f64(a.z)}, {x0 + 1, 0, f64(a.z)}, color)
		edge(s, x, b.z, a.y, b.y, {x0, 0, f64(b.z + 1)}, {x0 + 1, 0, f64(b.z + 1)}, color)
	}
	for z in a.z ..= b.z {
		z0 := f64(z)
		edge(s, a.x, z, a.y, b.y, {f64(a.x), 0, z0}, {f64(a.x), 0, z0 + 1}, color)
		edge(s, b.x, z, a.y, b.y, {f64(b.x + 1), 0, z0}, {f64(b.x + 1), 0, z0 + 1}, color)
	}
}

// structure_ghost: a template's blocks (not its void or air) placed with its lowest
// corner at `at`, turned rotation quarter turns, drawn as translucent blocks: what a
// placement would build, tinted (green for allowed, red for not: the game's colour).
structure_ghost :: proc(
	s: ^Session,
	t: ^game.Template,
	at: game.Block_Pos,
	rotation: u8,
	color: [4]u8,
) {
	size := game.rotated_size(t.size, rotation)
	for y in i32(0) ..< size.y {
		for z in i32(0) ..< size.z {
			for x in i32(0) ..< size.x {
				cell := game.template_cell(t, {x, y, z}, rotation)
				if cell == game.VOID || game.Block(cell) == .Air {continue}
				if len(s.fills) + 36 > MAX_FILL_VERTICES {return}
				p := at + {x, y, z}
				lo := [3]f64{f64(p.x), f64(p.y), f64(p.z)}
				fill_box(s, lo + 0.02, lo + 0.98, color)
			}
		}
	}
}

@(private = "file")
fill_quad :: proc(s: ^Session, a, b, c, d: [3]f64, color: [4]u8) {
	append(
		&s.fills,
		render.Debug_Point{a, color},
		render.Debug_Point{b, color},
		render.Debug_Point{c, color},
		render.Debug_Point{a, color},
		render.Debug_Point{c, color},
		render.Debug_Point{d, color},
	)
}

@(private = "file")
fill_box :: proc(s: ^Session, lo, hi: [3]f64, color: [4]u8) {
	x0, y0, z0, x1, y1, z1 := lo.x, lo.y, lo.z, hi.x, hi.y, hi.z
	fill_quad(s, {x0, y0, z0}, {x1, y0, z0}, {x1, y0, z1}, {x0, y0, z1}, color)
	fill_quad(s, {x0, y1, z0}, {x1, y1, z0}, {x1, y1, z1}, {x0, y1, z1}, color)
	fill_quad(s, {x0, y0, z0}, {x1, y0, z0}, {x1, y1, z0}, {x0, y1, z0}, color)
	fill_quad(s, {x0, y0, z1}, {x1, y0, z1}, {x1, y1, z1}, {x0, y1, z1}, color)
	fill_quad(s, {x0, y0, z0}, {x0, y0, z1}, {x0, y1, z1}, {x0, y1, z0}, color)
	fill_quad(s, {x1, y0, z0}, {x1, y0, z1}, {x1, y1, z1}, {x1, y1, z0}, color)
}

// fills_draw: the frame's ground marks and ghosts, into the debug fills (then gone).
fills_draw :: proc(s: ^Session, d: ^render.Debug_Draw) {
	append(&d.triangles, ..s.fills[:])
	clear(&s.fills)
	append(&d.vertices, ..s.world_lines[:])
	clear(&s.world_lines)
}
