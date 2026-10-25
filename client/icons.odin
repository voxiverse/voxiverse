package client

import "../game"
import "../ui"
import "./mesh"

// Item icons, made by code at start-up into the UI's atlas: a block's item is
// a small cube seen from a corner (its top and two sides from the block's own
// textures, the sides shaded), a tool a pixel sprite drawn here.

ICON_SIZE :: 32

Item_Icons :: map[game.Item]ui.Icon

// item_icons_init makes an icon for every item. False if the atlas has no
// room for one.
item_icons_init :: proc(icons: ^Item_Icons, ctx: ^ui.Context) -> bool {
	layers: [mesh.Texture][mesh.TEXTURE_SIZE * mesh.TEXTURE_SIZE]mesh.Rgba
	for t in mesh.Texture {mesh.generate_texture(t, layers[t][:])}
	pixels: [ICON_SIZE * ICON_SIZE][4]u8
	for item in game.every_item() {
		info, _ := game.item_info(item)
		if tool, is_tool := info.tool.?; is_tool {
			tool_sprite(tool, &pixels)
		} else if info.block == .Poppy || info.block == .Dandelion || info.block == .Tall_Grass {
			block_flat(info.block, &layers, &pixels) // (plants are crossed planes, not cubes)
		} else {
			block_cube(info.block, &layers, &pixels)
		}
		icons[item] = ui.add_icon(ctx, ICON_SIZE, pixels[:]) or_return
	}
	return true
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
	R :: f32(ICON_SIZE) / 2 - 1 // from the centre to the top corner
	K :: f32(0.8660254) // cos 30 degrees
	N :: mesh.TEXTURE_SIZE
	top := layers[mesh.Texture(mesh.block_texture(b, .Pos_Y))]
	left := layers[mesh.Texture(mesh.block_texture(b, .Pos_Z))]
	right := layers[mesh.Texture(mesh.block_texture(b, .Pos_X))]
	texel :: proc(face: [N * N]mesh.Rgba, u, v: f32, shade: f32) -> (c: [4]u8, ok: bool) {
		if u < 0 || u >= 1 || v < 0 || v >= 1 {return}
		c = face[int(v * N) * N + int(u * N)]
		for i in 0 ..< 3 {c[i] = u8(f32(c[i]) * shade)}
		return c, true
	}
	centre := f32(ICON_SIZE) / 2
	for y in 0 ..< ICON_SIZE {
		for x in 0 ..< ICON_SIZE {
			px, py := f32(x) + 0.5 - centre, f32(y) + 0.5 - centre
			c: [4]u8
			ok: bool
			// Top: from the top corner, a along (K, 1/2) R, b along (-K, 1/2) R.
			dx, dy := px / (K * R), (py + R) / (0.5 * R)
			if c, ok = texel(top, (dx + dy) / 2, (dy - dx) / 2, 1); !ok {
				// Left side: from the left corner, along (K, 1/2) R, down R.
				u := (px + K * R) / (K * R)
				v := (py + 0.5 * R - u * 0.5 * R) / R
				if c, ok = texel(left, u, v, 0.78); !ok {
					// Right side: from the centre, along (K, -1/2) R, down R.
					u = px / (K * R)
					v = (py + u * 0.5 * R) / R
					c, ok = texel(right, u, v, 0.58)
				}
			}
			pixels[y * ICON_SIZE + x] = c if ok else {}
		}
	}
}

// block_flat draws b's side texture as it is, each texel twice as large.
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

// tool_sprite draws tool's 16 x 16 art, each pixel twice as large.
@(private = "file")
tool_sprite :: proc(tool: game.Tool, pixels: ^[ICON_SIZE * ICON_SIZE][4]u8) {
	art: [16]string
	switch tool {
	case .Launcher:
		art = LAUNCHER_ART
	}
	for y in 0 ..< ICON_SIZE {
		for x in 0 ..< ICON_SIZE {
			c: [4]u8
			switch art[y / 2][x / 2] {
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
