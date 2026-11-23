package font

import "core:math"

// Drawn glyphs: a glyph made by code instead of read from a font file, as
// straight strokes of one weight (the gate addresses' symbols). Each stroke
// is a band with square ends, so strokes meeting at a corner close it.

// Stroke: from one point to another, in em units, y up from the baseline;
// both the same point is a dot (a square a little wider than the weight).
Stroke :: [2][2]f32

Drawn :: struct {
	strokes: []Stroke,
	weight:  f32, // em
	advance: f32, // em
}

// rasterize_drawn renders a drawn glyph at an em size in pixels.
rasterize_drawn :: proc(
	g: Drawn,
	pixel_size: f32,
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	bm: Bitmap,
	ok: bool,
) {
	outline: Outline
	outline.points.allocator = context.temp_allocator
	outline.contours.allocator = context.temp_allocator
	for s in g.strokes {
		a := Point{s[0].x, -s[0].y} * pixel_size
		b := Point{s[1].x, -s[1].y} * pixel_size
		half := 0.5 * g.weight * pixel_size
		along := b - a
		length := math.sqrt(along.x * along.x + along.y * along.y)
		if length < 1e-4 {
			along, half = {1, 0}, half * 1.4
		} else {
			along /= length
		}
		along *= half
		across := Point{-along.y, along.x}
		// One winding for every band (it turns with the stroke).
		add_point(&outline, a - along + across)
		add_point(&outline, b + along + across)
		add_point(&outline, b + along - across)
		add_point(&outline, a - along - across)
		append(&outline.contours, len(outline.points))
	}
	return fill(&outline, allocator, loc)
}
