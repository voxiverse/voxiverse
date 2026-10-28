package server

import "core:fmt"
import "core:strconv"

import "../base"
import "../common/game"

// World editing's selection (docs/plan.md M19, commands): each player's two
// corners, kept here (all world changes are the server's), set with /pos1
// and /pos2 (the block the player looks at, or coordinates) and cleared with
// /sel; /fill, /replace, /sphere and /structure act on it when not given
// coordinates. The client is told it (Selection) to draw its box.

SELECTION_REACH :: 128 // blocks: how far /pos1 and /pos2 see

// selection_set sets c's selection and tells c.
selection_set :: proc(s: ^Server, c: ^Client, corners: [2]Maybe(game.Block_Pos)) {
	c.selection = corners
	selection := game.Selection{corners}
	state_put(s, c, .Selection, &selection)
}

// selection_box: c's selection, if both corners are set.
selection_box :: proc(c: ^Client) -> (box: Box, ok: bool) {
	a := c.selection[0].? or_return
	b := c.selection[1].? or_return
	return Box{a, b}, true
}

// aimed_block: the block c looks at, within reach (worked out here, from
// the player's eye and look, as the client's crosshair does).
aimed_block :: proc(c: ^Client, reach: f64) -> (game.Block_Pos, bool) {
	eye := game.player_eye(c.player)
	yaw, pitch := f64(c.look[0]), f64(c.look[1])
	dir := [3]f64 {
		-base.sin(yaw) * base.cos(pitch),
		base.sin(pitch),
		-base.cos(yaw) * base.cos(pitch),
	}
	hit, found := game.raycast(
		game.Block_Query{&c.world.chunks, chunks_block, &c.world.server.registry.blocks},
		eye,
		dir,
		reach,
	)
	return hit.block, found
}

// admin_corner: /pos1 and /pos2: the aimed block, or x y z.
@(private)
admin_corner :: proc(s: ^Server, c: ^Client, args: []string, i: int) -> bool {
	p: game.Block_Pos
	switch len(args) {
	case 0:
		found: bool
		if p, found = aimed_block(c, SELECTION_REACH); !found {
			notice(s, c, fmt.tprintf("&cLook at a block (within %d)", SELECTION_REACH))
			return true
		}
	case 3:
		n: [3]i32
		for a, k in args {
			v, ok := strconv.parse_int(a)
			if !ok || abs(v) >= game.WORLD_LIMIT {return false}
			n[k] = i32(v)
		}
		p = n
	case:
		return false
	}
	corners := c.selection
	corners[i] = p
	selection_set(s, c, corners)
	notice(s, c, fmt.tprintf("pos%d %d %d %d", i + 1, p.x, p.y, p.z))
	return true
}
