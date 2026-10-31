package client

import "client:mesh"
import "client:ui"
import "common:game"
import "common:worldgen"

// Planet_Palette: the colours of a world seen from space, read from the
// world's kind (worldgen.PALETTES holds its surface blocks, a block's look
// is its texture's average): no colour is written here.
Planet_Palette :: struct {
	water:  ui.Color,
	ground: ui.Color, // the palette's first block (grass on Earth)
	dry:    ui.Color, // its third (sand on Earth)
	ice:    ui.Color, // snow, at the poles
}

// planet_palette: the colours of a world with these parameters.
planet_palette :: proc(reg: ^game.Registry, p: worldgen.Params) -> Planet_Palette {
	surface := worldgen.PALETTES[clamp(int(p.palette), 0, len(worldgen.PALETTES) - 1)]
	return {
		water = ui.Color(mesh.block_average_colour(reg, .Water, .Pos_Y)),
		ground = ui.Color(mesh.block_average_colour(reg, surface[0], .Pos_Y)),
		dry = ui.Color(mesh.block_average_colour(reg, surface[2], .Pos_Y)),
		ice = ui.Color(mesh.block_average_colour(reg, .Snow, .Pos_Y)),
	}
}

// home_planet_palette: the home world's, which is Earth's whatever the seed
// (worldgen's defaults).
home_planet_palette :: proc(reg: ^game.Registry) -> Planet_Palette {
	return planet_palette(reg, worldgen.PARAMS_DEFAULTS)
}
