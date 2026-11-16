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
		{lo = {-0.3, 0.7, -0.2}, hi = {0.3, 1.4, 0.2}, color = {90, 140, 60}},
		{
			lo = {-0.3, 0, -0.1},
			hi = {-0.05, 0.7, 0.1},
			color = {40, 40, 40},
			skin = .Legs,
			swing = .Walk,
		},
		{lo = {0.3, 0.6, -0.1}, hi = {0.5, 1.4, 0.1}, color = {90, 140, 60}, swing = .Strike},
	}
	info := game.Kind_Info {
		model = .Parts,
		parts = parts,
		looks = {.Striking},
	}
	d: render.Entity_Draw
	d.boxes = make([dynamic]render.Entity_Box, context.temp_allocator)
	v := Other_View {
		position = {10, 64, 10},
	}
	shaped(&d, v, &info, 0.4, false, {})
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
	shaped(&d, v, &info, 0.4, true, {.Striking})
	testing.expect_value(t, d.boxes[2].pitch, STRIKE_RAISE)
	testing.expect(t, d.boxes[0].color != [4]u8{90, 140, 60, 255}, "not red while hurt")
}
