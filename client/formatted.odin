package client

import "../game"
import "../ui"

// Formatted text on screen: & codes (game/format.odin) drawn with ui's
// styled text, span by span.

// draw_formatted draws text from pos (its baseline, UI units); color is
// for spans without a colour of their own (its alpha for all). Returns the
// width drawn.
draw_formatted :: proc(
	ctx: ^ui.Context,
	pos: ui.Vec2,
	text: string,
	size: f32,
	color: ui.Color,
	allowed := game.FORMAT_ALL,
) -> f32 {
	spans := make([dynamic]game.Span, context.temp_allocator)
	game.format_parse(text, &spans, allowed)
	x := pos.x
	for s in spans {
		c := color
		if s.style.colored {c.rgb = s.style.color}
		x += ui.draw_text_styled(ctx, {x, pos.y}, s.text, size, c, text_effects(s.style))
	}
	return x - pos.x
}

// measure_formatted: the width draw_formatted would draw.
measure_formatted :: proc(
	ctx: ^ui.Context,
	text: string,
	size: f32,
	allowed := game.FORMAT_ALL,
) -> f32 {
	spans := make([dynamic]game.Span, context.temp_allocator)
	game.format_parse(text, &spans, allowed)
	width: f32
	for s in spans {width += ui.measure_text_styled(ctx, s.text, size, text_effects(s.style))}
	return width
}

@(private = "file")
text_effects :: proc(s: game.Text_Style) -> ui.Text_Effects {
	e: ui.Text_Effects
	if s.bold {e += {.Bold}}
	if s.italic {e += {.Italic}}
	if s.underline {e += {.Underline}}
	if s.strike {e += {.Strike}}
	return e
}
