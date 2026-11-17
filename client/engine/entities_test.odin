package engine

import "core:testing"

import "client:render"
import "common:game"

// A kind's shaped model: a box for each part, turned about the middle of its top; a
// walking part swings with the stride, a striking one goes forward while the kind
// strikes; the part's skin is the pass's.
@(test)
test_shaped_model_moves_its_parts :: proc(t: ^testing.T) {
	parts := []game.Model_Part {
		{lo = {-0.3, 0.7, -0.2}, hi = {0.3, 1.4, 0.2}, hinge = {0, 1.4, 0}, color = {90, 140, 60}},
		{
			lo = {-0.3, 0, -0.1},
			hi = {-0.05, 0.7, 0.1},
			hinge = {-0.175, 0.7, 0},
			color = {40, 40, 40},
			skin = .Legs,
			swing = .Walk,
		},
		{
			lo = {0.3, 0.6, -0.1},
			hi = {0.5, 1.4, 0.1},
			hinge = {0.4, 1.4, 0},
			color = {90, 140, 60},
			swing = .Strike,
		},
	}
	info := game.Kind_Info {
		model    = .Parts,
		parts    = parts,
		looks    = {"striking"},
		striking = 1,
	}
	d: render.Entity_Draw
	d.boxes = make([dynamic]render.Entity_Box, context.temp_allocator)
	v := Other_View {
		position = {10, 64, 10},
	}
	shaped(&d, v, &info, 0.4, {}, 0)
	if !testing.expect_value(t, len(d.boxes), 3) {return}
	body, leg, arm := d.boxes[0], d.boxes[1], d.boxes[2]
	testing.expect_value(t, body.pitch, 0)
	testing.expect(t, leg.pitch != 0, "the leg did not swing as it walked")
	testing.expect_value(t, arm.pitch, leg.pitch) // (a striking part walks as a leg until it strikes)
	testing.expect_value(t, leg.part, render.Entity_Part.Legs)
	// The leg hangs from its hip: the top of its box, at the creature's feet + 0.7.
	testing.expect(t, abs(leg.pivot.y - 64.7) < 1e-5 && leg.hi.y == 0 && leg.lo.y < -0.69)
	testing.expect_value(t, body.color, [4]u8{90, 140, 60, 255})

	clear(&d.boxes)
	shaped(&d, v, &info, 0.4, HURT, 1)
	testing.expect_value(t, d.boxes[2].pitch, STRIKE_RAISE)
	testing.expect(t, d.boxes[0].color != [4]u8{90, 140, 60, 255}, "not red while hurt")
}

// A creature's looks change its model as its data says, with nothing in the code about
// the creature: a part shown only by a look, one a look hides, a colour by a look, the
// whole model's size by a look, and a head that pitches as the server says.
@(test)
test_looks_change_a_model :: proc(t: ^testing.T) {
	SHORN, LAMB, BLACK :: u16(1), u16(2), u16(4)
	parts := []game.Model_Part {
		{
			lo = {-0.3, 0.3, -0.4},
			hi = {0.3, 0.8, 0.4},
			hinge = {0, 0.8, 0},
			color = {230, 220, 200},
			hidden = SHORN,
			recolor = {{BLACK, {30, 30, 30}}, {}},
		},
		{
			lo = {-0.2, 0.3, -0.3},
			hi = {0.2, 0.7, 0.3},
			hinge = {0, 0.7, 0},
			color = {200, 160, 150},
			shown = SHORN,
		},
		{
			lo = {-0.1, 0.5, -0.8},
			hi = {0.1, 0.9, -0.4},
			hinge = {0, 0.7, -0.4},
			color = {120, 90, 70},
			swing = .Pitch,
		},
	}
	info := game.Kind_Info {
		model = .Parts,
		parts = parts,
		looks = {"shorn", "lamb", "black"},
		scale = {LAMB, 0.5},
	}
	d: render.Entity_Draw
	d.boxes = make([dynamic]render.Entity_Box, context.temp_allocator)
	v := Other_View {
		position = {0, 10, 0},
		pitch    = -1.2,
	}
	shaped(&d, v, &info, 0, {}, 0)
	if !testing.expect_value(t, len(d.boxes), 2) {return}
	testing.expect_value(t, d.boxes[0].color, [4]u8{230, 220, 200, 255})
	testing.expect_value(t, d.boxes[1].pitch, f32(-1.2))
	clear(&d.boxes)
	shaped(&d, v, &info, 0, {}, BLACK)
	testing.expect_value(t, d.boxes[0].color, [4]u8{30, 30, 30, 255})
	clear(&d.boxes)
	shaped(&d, v, &info, 0, {}, SHORN | LAMB)
	if !testing.expect_value(t, len(d.boxes), 2) {return}
	testing.expect_value(t, d.boxes[0].color, [4]u8{200, 160, 150, 255})
	testing.expect(
		t,
		abs(d.boxes[0].pivot.y - 10.35) < 1e-5,
		"a lamb's parts are not half size about its feet",
	)
	testing.expect(t, abs((d.boxes[0].hi.x - d.boxes[0].lo.x) - 0.2) < 1e-5)
}
