package client

import "core:math"

import "client:render"
import "common:game"

// The grappling hook on the client. The line, the pull and the release are the
// shared movement code's (game.player_step reads Button.Grapple), so the
// prediction runs them like the server; this file only turns the held use
// button into that button and draws the rope.

ROPE_SPECK :: 0.7 // blocks between the specks a rope is drawn from
ROPE_SECONDS :: 0.05 // each speck lives a frame or two: redrawn every frame

// grapple_in_hand: the hook in the selected slot, if it is one.
grapple_in_hand :: proc(s: ^Session) -> (g: game.Grapple_Info, ok: bool) {
	stack := held(s)
	if game.stack_empty(stack) {return}
	info, _ := game.item_info(s.reg, stack.item)
	g, ok = info.grapple.?
	return
}

// grapple_button: the use button, held with a hook in hand, is the Grapple
// button of this tick's input.
grapple_button :: proc(s: ^Session, a: ^Actions) -> bool {
	if s.dead || s.state != .Playing || !action_down(a, .Use) {return false}
	_, ok := grapple_in_hand(s)
	return ok
}

// grapple_rope: a line of specks from the hand to the anchor while hooked.
grapple_rope :: proc(s: ^Session) {
	p := &s.prediction.state
	if !p.hooked {return}
	f := render.forward(s.camera.yaw, s.camera.pitch)
	dir := [3]f64{f64(f.x), f64(f.y), f64(f.z)}
	right := [3]f64{f64(math.cos(s.camera.yaw)), 0, -f64(math.sin(s.camera.yaw))}
	hand := s.camera.position + dir * 0.6 + right * 0.28 - {0, 0.25, 0}
	d := p.anchor - hand
	length := math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
	n := clamp(int(length / ROPE_SPECK), 2, 80)
	for i in 0 ..= n {
		t := f64(i) / f64(n)
		// (a slight sag toward the middle: a rope, not a ruler)
		sag := 4 * t * (1 - t) * min(length * 0.02, 0.5)
		puff_add(
			s,
			{
				position = hand + d * t - {0, sag, 0},
				life = ROPE_SECONDS,
				size = 0.035,
				color = {196, 164, 108, 255},
			},
		)
	}
}
