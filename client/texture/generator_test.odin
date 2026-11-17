package texture

import "core:testing"

// The textures that cover a block face edge to edge in the world, each with
// the ways it repeats: across (left to right) and down (top to bottom). A
// side whose top differs from its bottom (grass over dirt) tiles only across;
// a framed one (a lamp, a door, a cut sandstone top) not at all.
@(private = "file", rodata)
TILING := [?]struct {
	g:            Generator,
	across, down: bool,
} {
	{.Stone, true, true},
	{.Dirt, true, true},
	{.Grass_Top, true, true},
	{.Grass_Side, true, false},
	{.Sand, true, true},
	{.Gravel, true, true},
	{.Bedrock, true, true},
	{.Snow, true, true},
	{.Ice, true, true},
	{.Clay, true, true},
	{.Sandstone_Side, true, true},
	{.Log_Side, true, true},
	{.Spruce_Log_Side, true, true},
	{.Coal_Ore, true, true},
	{.Iron_Ore, true, true},
	{.Copper_Ore, true, true},
	{.Cobblestone, true, true},
	{.Stone_Bricks, true, true},
	{.Planks, true, true},
	{.Farmland_Top, true, true},
	{.Farmland_Moist_Top, true, true},
}

// A texture that tiles shows no seam: the mean step in brightness from its
// last column to its first is not much larger than the largest mean step
// between two neighbouring columns inside it (and so for rows). The grit in
// a texture is white noise, which differs column to column by chance, hence
// the margin (the worst texture without a seam, iron ore down, is at 1.26); a texture whose
// patterns do not wrap steps far further at its edge.
@(test)
test_textures_tile_without_a_seam :: proc(t: ^testing.T) {
	for e in TILING {
		pixels: [SIZE * SIZE]Rgba
		generate(e.g, pixels[:])
		light :: proc(p: Rgba) -> f32 {return 0.3 * f32(p.r) + 0.59 * f32(p.g) + 0.11 * f32(p.b)}
		step :: proc(pixels: []Rgba, a, b: int, columns: bool) -> f32 {
			sum: f32
			for i in 0 ..< SIZE {
				pa := pixels[i * SIZE + a] if columns else pixels[a * SIZE + i]
				pb := pixels[i * SIZE + b] if columns else pixels[b * SIZE + i]
				sum += abs(light(pa) - light(pb))
			}
			return sum / SIZE
		}
		for columns in ([2]bool{true, false}) {
			if columns && !e.across || !columns && !e.down {continue}
			inside: f32
			for a in 0 ..< SIZE - 1 {inside = max(inside, step(pixels[:], a, a + 1, columns))}
			seam := step(pixels[:], SIZE - 1, 0, columns)
			testing.expectf(
				t,
				seam <= 1.35 * inside,
				"%v has a seam %s: %.1f, inside at most %.1f",
				e.g,
				"across" if columns else "down",
				seam,
				inside,
			)
		}
	}
}
