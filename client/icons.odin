package client

import "../game"
import "../ui"
import "./mesh"

// Item icons, made by code at start-up into the UI's atlas: a block's item is
// a cube seen from a corner (its top and two sides from the block's own
// textures, the sides shaded; rendered once here, a bitmap like any other
// image, not drawn live), a tool a pixel sprite drawn here. Icons are large
// and drawn smaller with a smooth filter, so they read clean.

ICON_SIZE :: 128 // (drawn at a fraction of this, smoothed: a clean bitmap, not crunchy)
ICON_SAMPLES :: 4 // per pixel, each way: the silhouette and edges are smooth, each texel stays a flat patch

Item_Icons :: map[game.Item]ui.Icon

// item_icons_init makes an icon for every item. False if the atlas has no
// room for one.
item_icons_init :: proc(icons: ^Item_Icons, ctx: ^ui.Context) -> bool {
	layers: [mesh.Texture][mesh.TEXTURE_SIZE * mesh.TEXTURE_SIZE]mesh.Rgba
	for t in mesh.Texture {mesh.generate_texture(t, layers[t][:])}
	pixels: [ICON_SIZE * ICON_SIZE][4]u8
	for item in game.every_item() {
		info, _ := game.item_info(item)
		if item >= game.MATERIAL_ITEMS && item < game.ARMOR_ITEMS {
			material_sprite(game.Material(item - game.MATERIAL_ITEMS), &pixels)
		} else if tool, is_tool := info.tool.?; is_tool {
			tool_sprite(tool, &pixels)
		} else if armor, is_armor := info.armor.?; is_armor {
			armor_sprite(armor, &pixels)
		} else if info.block == .Poppy || info.block == .Dandelion || info.block == .Tall_Grass {
			block_flat(info.block, &layers, &pixels) // (plants are crossed planes, not cubes)
		} else {
			block_cube(info.block, &layers, &pixels)
		}
		icons[item] = ui.add_icon(ctx, ICON_SIZE, pixels[:]) or_return
	}
	return true
}

@(private = "file")
R :: f32(ICON_SIZE) / 2 - 2 // from the centre to the top corner

@(private = "file")
texel :: proc(
	face: [mesh.TEXTURE_SIZE * mesh.TEXTURE_SIZE]mesh.Rgba,
	u, v: f32,
	shade: f32,
) -> (
	c: [4]u8,
	ok: bool,
) {
	N :: mesh.TEXTURE_SIZE
	if u < 0 || u >= 1 || v < 0 || v >= 1 {return}
	c = face[int(v * N) * N + int(u * N)]
	for i in 0 ..< 3 {c[i] = u8(f32(c[i]) * shade)}
	return c, true
}

// block_cube draws b as a cube seen from a corner: the hexagon of a cube
// whose top face is a rhombus; each pixel is the face it falls in and the
// texel of that face under it.
@(private = "file")
block_cube :: proc(
	b: game.Block,
	layers: ^[mesh.Texture][mesh.TEXTURE_SIZE * mesh.TEXTURE_SIZE]mesh.Rgba,
	pixels: ^[ICON_SIZE * ICON_SIZE][4]u8,
) {
	N :: mesh.TEXTURE_SIZE
	top := layers[mesh.Texture(mesh.block_texture(b, .Pos_Y))]
	left := layers[mesh.Texture(mesh.block_texture(b, .Pos_Z))]
	right := layers[mesh.Texture(mesh.block_texture(b, .Pos_X))]
	centre := f32(ICON_SIZE) / 2
	sample :: proc(top, left, right: [N * N]mesh.Rgba, px, py: f32) -> (c: [4]u8, ok: bool) {
		K :: f32(0.8660254)
		// Top: from the top corner, a along (K, 1/2) R, b along (-K, 1/2) R.
		dx, dy := px / (K * R), (py + R) / (0.5 * R)
		if c, ok = texel(top, (dx + dy) / 2, (dy - dx) / 2, 1); ok {return}
		// Left side: from the left corner, along (K, 1/2) R, down R.
		u := (px + K * R) / (K * R)
		v := (py + 0.5 * R - u * 0.5 * R) / R
		if c, ok = texel(left, u, v, 0.78); ok {return}
		// Right side: from the centre, along (K, -1/2) R, down R.
		u = px / (K * R)
		v = (py + u * 0.5 * R) / R
		return texel(right, u, v, 0.58)
	}
	for y in 0 ..< ICON_SIZE {
		for x in 0 ..< ICON_SIZE {
			// Average the samples of the pixel (colour weighted by coverage).
			sum: [4]f32
			for sy in 0 ..< ICON_SAMPLES {
				for sx in 0 ..< ICON_SAMPLES {
					px := f32(x) + (f32(sx) + 0.5) / ICON_SAMPLES - centre
					py := f32(y) + (f32(sy) + 0.5) / ICON_SAMPLES - centre
					c, ok := sample(top, left, right, px, py)
					if !ok {continue}
					a := f32(c[3])
					sum += {f32(c[0]) * a, f32(c[1]) * a, f32(c[2]) * a, a}
				}
			}
			out: [4]u8
			if sum.a > 0 {
				out = {
					u8(sum.r / sum.a + 0.5),
					u8(sum.g / sum.a + 0.5),
					u8(sum.b / sum.a + 0.5),
					u8(sum.a / (ICON_SAMPLES * ICON_SAMPLES) + 0.5),
				}
			}
			pixels[y * ICON_SIZE + x] = out
		}
	}
}

// block_flat draws b's side texture as it is, each texel ICON_SIZE / 16 times as large.
@(private = "file")
block_flat :: proc(
	b: game.Block,
	layers: ^[mesh.Texture][mesh.TEXTURE_SIZE * mesh.TEXTURE_SIZE]mesh.Rgba,
	pixels: ^[ICON_SIZE * ICON_SIZE][4]u8,
) {
	N :: mesh.TEXTURE_SIZE
	face := layers[mesh.Texture(mesh.block_texture(b, .Pos_X))]
	for y in 0 ..< ICON_SIZE {
		for x in 0 ..< ICON_SIZE {
			pixels[y * ICON_SIZE + x] = face[(y * N / ICON_SIZE) * N + x * N / ICON_SIZE]
		}
	}
}

@(private = "file")
LAUNCHER_ART := [16]string {
	"................",
	"................",
	"................",
	"..oooooooooooo..",
	".oLLLLLLLLLLRRo.",
	".oLGGGGGGGGGRRo.",
	".oGGGGGGGGGGDDo.",
	".oDDDDDDDDDDDDo.",
	"..oooooooooooo..",
	"....oBBo........",
	"....oBBo........",
	"....oBBBo.......",
	".....ooo........",
	"................",
	"................",
	"................",
}

// tool_sprite draws tool's 16 x 16 art, each pixel ICON_SIZE / 16 times as large.
@(private = "file")
tool_sprite :: proc(tool: game.Tool, pixels: ^[ICON_SIZE * ICON_SIZE][4]u8) {
	art: [16]string
	switch tool {
	case .Launcher:
		art = LAUNCHER_ART
	case .Hoe:
		art = HOE_ART
	}
	for y in 0 ..< ICON_SIZE {
		for x in 0 ..< ICON_SIZE {
			c: [4]u8
			switch art[y * 16 / ICON_SIZE][x * 16 / ICON_SIZE] {
			case 'o':
				c = {28, 28, 34, 255}
			case 'L':
				c = {176, 180, 190, 255}
			case 'G':
				c = {128, 133, 144, 255}
			case 'D':
				c = {84, 88, 99, 255}
			case 'R':
				c = {204, 56, 44, 255}
			case 'B':
				c = {120, 78, 44, 255}
			}
			pixels[y * ICON_SIZE + x] = c
		}
	}
}

// ARMOR_ART: 16 x 16 sprites in the armor's colour: M main, h lighter, m
// darker, o outline.
@(private = "file")
ARMOR_ART := [game.Armor][16]string {
	.Cap      = {
		"................",
		"................",
		"................",
		".....oooooo.....",
		"....ohhhhMmo....",
		"...ohhhMMMMmo...",
		"...ohMMMMMMmo...",
		"..ohMMMMMMMMmo..",
		"..oMMMMMMMMMmo..",
		"..ommmmmmmmmmo..",
		"..oooooooooooo..",
		"..oMMMMMMMMMMo..",
		"...oooooooooo...",
		"................",
		"................",
		"................",
	},
	.Tunic    = {
		"................",
		"..oooo....oooo..",
		".ohhMMo..oMMmmo.",
		".ohMMMoooMMMMmo.",
		".oMMMMMMMMMMMmo.",
		".oMMMMMMMMMMMmo.",
		"..ooMMMMMMMMoo..",
		"....oMMMMMMmo...",
		"....oMMMMMMmo...",
		"....ohMMMMMmo...",
		"....oMMMMMMmo...",
		"....oMMMMMMmo...",
		"....ommmmmmmo...",
		".....oooooooo...",
		"................",
		"................",
	},
	.Trousers = {
		"................",
		"................",
		"...oooooooooo...",
		"...ohMMMMMMmo...",
		"...ohMMMMMMmo...",
		"...ohMMMMMMmo...",
		"...ohMMooMMmo...",
		"...ohMMo.oMmo...",
		"...ohMMo.oMmo...",
		"...ohMMo.oMmo...",
		"...ohMMo.oMmo...",
		"...ommmo.ommo...",
		"...oooo...ooo...",
		"................",
		"................",
		"................",
	},
	.Boots    = {
		"................",
		"................",
		"................",
		"................",
		"..ooooo..ooooo..",
		"..ohMMo..ohMMo..",
		"..ohMMo..ohMMo..",
		"..ohMMo..ohMMo..",
		"..ohMMo..ohMMo..",
		".ohMMMoo.ohMMMoo",
		".ohMMMMo.ohMMMMo",
		".ommmmmo.ommmmmo",
		".ooooooo.ooooooo",
		"................",
		"................",
		"................",
	},
}

// armor_sprite draws armor's 16 x 16 art, each pixel ICON_SIZE / 16 times as large.
@(private = "file")
armor_sprite :: proc(armor: game.Armor, pixels: ^[ICON_SIZE * ICON_SIZE][4]u8) {
	main := ARMOR_COLORS[armor]
	shade :: proc(c: [4]u8, k: f32) -> (out: [4]u8) {
		out = {
			u8(min(f32(c[0]) * k, 255)),
			u8(min(f32(c[1]) * k, 255)),
			u8(min(f32(c[2]) * k, 255)),
			255,
		}
		return
	}
	art := ARMOR_ART[armor]
	for y in 0 ..< ICON_SIZE {
		for x in 0 ..< ICON_SIZE {
			c: [4]u8
			switch art[y * 16 / ICON_SIZE][x * 16 / ICON_SIZE] {
			case 'o':
				c = {28, 28, 34, 255}
			case 'M':
				c = main
			case 'h':
				c = shade(main, 1.3)
			case 'm':
				c = shade(main, 0.7)
			}
			pixels[y * ICON_SIZE + x] = c
		}
	}
}

@(private = "file")
HOE_ART := [16]string {
	"................",
	"...........ooo..",
	"..........oGGGo.",
	".........oGGGGo.",
	"........oBoooGo.",
	".......oBo..ooo.",
	"......oBo.......",
	".....oBo........",
	"....oBo.........",
	"...oBo..........",
	"..oBo...........",
	".oBo............",
	".oo.............",
	"................",
	"................",
	"................",
}

@(private = "file")
SEEDS_ART := [16]string {
	"................",
	"................",
	"................",
	"....oo....oo....",
	"...oSSo..oSSo...",
	"...oSSo..oSSo...",
	"....oo....oo....",
	"......oo........",
	".....oSSo.......",
	".....oSSo..oo...",
	"......oo..oSSo..",
	"..........oSSo..",
	"...........oo...",
	"................",
	"................",
	"................",
}

@(private = "file")
WHEAT_ART := [16]string {
	"................",
	"....oo...oo.....",
	"...oWWo.oWWo....",
	"...oWWo.oWWo.oo.",
	"...oWWooWWWooWWo",
	"....oWWWWWoWWWo.",
	".....oGoGoGoGo..",
	"......oGGGGo....",
	".......oGGo.....",
	".......oRRo.....",
	".......oRRo.....",
	"........oo......",
	"................",
	"................",
	"................",
	"................",
}

// material_sprite draws a crop's item: 16 x 16 art, each pixel ICON_SIZE / 16 times as large.
@(private = "file")
material_sprite :: proc(m: game.Material, pixels: ^[ICON_SIZE * ICON_SIZE][4]u8) {
	art: [16]string
	switch m {
	case .Seeds:
		art = SEEDS_ART
	case .Wheat:
		art = WHEAT_ART
	}
	for y in 0 ..< ICON_SIZE {
		for x in 0 ..< ICON_SIZE {
			c: [4]u8
			switch art[y * 16 / ICON_SIZE][x * 16 / ICON_SIZE] {
			case 'o':
				c = {28, 28, 34, 255}
			case 'S':
				c = {196, 164, 96, 255}
			case 'W':
				c = {226, 188, 84, 255}
			case 'G':
				c = {92, 140, 52, 255}
			case 'R':
				c = {170, 60, 50, 255}
			}
			pixels[y * ICON_SIZE + x] = c
		}
	}
}
