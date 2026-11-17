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
	// The kit's (a polished slab and a panel are framed, one a block: they do not tile;
	// nor does a log's round end).
	{.Stone_Tiles, true, true},
	{.Basalt, true, true},
	{.Basalt_Cobble, true, true},
	{.Basalt_Bricks, true, true},
	{.Basalt_Tiles, true, true},
	{.Sandstone_Cobble, true, true},
	{.Sandstone_Bricks, true, true},
	{.Sandstone_Tiles, true, true},
	{.Limestone, true, true},
	{.Limestone_Cobble, true, true},
	{.Limestone_Bricks, true, true},
	{.Limestone_Tiles, true, true},
	{.Slate, true, true},
	{.Slate_Cobble, true, true},
	{.Slate_Bricks, true, true},
	{.Slate_Tiles, true, true},
	{.Birch_Log, true, true},
	{.Birch_Planks, true, true},
	{.Spruce_Planks, true, true},
	{.Redwood_Log, true, true},
	{.Redwood_Planks, true, true},
	{.Weathered_Log, true, true},
	{.Weathered_Planks, true, true},
	// (A plate a block across, a panel, a screen or a vent is framed too.)
	{.Iron_Plate, true, true},
	{.Copper, true, true},
	{.Verdigris_Copper, true, true},
	{.Pipes, true, true},
	{.Concrete, true, true},
	{.Stained_Concrete, true, false},
	{.Concrete_Tiles, true, true},
	{.Asphalt, true, true},
	{.Red_Bricks, true, true},
	{.Conveyor_Top, true, true},
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
