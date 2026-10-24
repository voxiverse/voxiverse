package client

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

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

// wrap_formatted: text broken into lines at most width wide (at spaces; a
// word too long for a line, anywhere), each a formatted line of its own
// (it starts with the codes for the style it continues). Temp allocator.
wrap_formatted :: proc(ctx: ^ui.Context, text: string, size, width: f32) -> []string {
	spans := make([dynamic]game.Span, context.temp_allocator)
	game.format_parse(text, &spans)
	lines := make([dynamic]string, context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	x: f32
	for s in spans {
		effects := text_effects(s.style)
		codes := style_codes(s.style)
		strings.write_string(&b, codes)
		rest := s.text
		for len(rest) > 0 {
			// The next piece: a word and the space after it.
			end := strings.index_byte(rest, ' ')
			end = len(rest) if end < 0 else end + 1
			piece := rest[:end]
			w := ui.measure_text_styled(ctx, piece, size, effects)
			if x > 0 && x + w > width {
				append(&lines, strings.clone(strings.to_string(b), context.temp_allocator))
				strings.builder_reset(&b)
				strings.write_string(&b, codes)
				x = 0
			}
			if w > width {
				// Too long for a line of its own: as many letters as fit.
				n, fit := 0, f32(0)
				for r, i in piece {
					size_r := utf8.rune_size(r)
					rw := ui.measure_text_styled(ctx, piece[i:i + size_r], size, effects)
					if fit + rw > width && n > 0 {break}
					fit += rw
					n = i + size_r
				}
				piece, w = piece[:n], fit
			}
			for ch in transmute([]u8)piece {
				if ch == '&' {strings.write_byte(&b, '&')} 	// (as written)
				strings.write_byte(&b, ch)
			}
			x += w
			rest = rest[len(piece):]
		}
	}
	if strings.builder_len(b) > 0 || len(lines) == 0 {append(&lines, strings.to_string(b))}
	return lines[:]
}

// style_codes: the codes that start a span in style s (after a reset).
@(private = "file")
style_codes :: proc(s: game.Text_Style) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "&r")
	if s.colored {fmt.sbprintf(&b, "&#%02x%02x%02x", s.color.r, s.color.g, s.color.b)}
	if s.bold {strings.write_string(&b, "&l")}
	if s.italic {strings.write_string(&b, "&o")}
	if s.underline {strings.write_string(&b, "&n")}
	if s.strike {strings.write_string(&b, "&m")}
	return strings.to_string(b)
}
