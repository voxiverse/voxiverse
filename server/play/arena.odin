package play

import "common:game"
import "server:core"

// Arena: a walled ground a game builds its rounds on, whole again from a template each
// round (a seed's layout: game.template_make, game.template_fill), so a round begins
// as it was laid out whatever the last one's blasts carved. Its inside is size blocks
// from origin (x and z, and y up from the floor's layer, origin.y), walled round with
// wall from depth blocks under the floor to wall_top, with under below the inside, so a
// blast through the floor finds stone, not the open flat world. An open arena has no
// walls and nothing under it: the template is the whole of it (a course in the sky).
Arena :: struct {
	origin:   [3]i32, // the inside's lowest corner: its floor's layer
	size:     [3]i32, // the inside, floor to sky (the template's size)
	wall_top: i32, // the walls' top layer (y)
	depth:    i32, // layers of `under` beneath the inside (and of wall)
	wall:     game.Block, // (zero: bedrock)
	under:    game.Block, // (zero: stone)
	open:     bool, // no walls, nothing under: the template alone (wall_top, depth unused)
}

// arena_area: the arena's whole box, walls and what is under it: what the game keeps
// loaded (core.world_keep) and builds in.
arena_area :: proc(a: Arena) -> core.Box {
	if a.open {return arena_inside(a)}
	return {a.origin - {1, a.depth, 1}, {a.origin.x + a.size.x, a.wall_top, a.origin.z + a.size.z}}
}

// arena_inside: the inside, floor to sky.
arena_inside :: proc(a: Arena) -> core.Box {
	return {a.origin, a.origin + a.size - 1}
}

// arena_build: the walls, what is under the floor and the template's blocks pasted over
// the inside, through the edit journal as the game's; false (nothing built) while the
// area is not all loaded, unless force (the game waited long enough: what is there is
// built). loaded says whether all of it was.
arena_build :: proc(
	s: ^core.Server,
	w: ^core.World,
	a: Arena,
	t: ^game.Template,
	force: bool,
) -> (
	built, loaded: bool,
) {
	area := arena_area(a)
	loaded = core.world_ready(w, area)
	if !loaded && !force {return false, false}
	assert(t.size == a.size, "the arena's template is not its inside's size")
	act := core.game_act(s, w, .Structure)
	inside := arena_inside(a)
	if a.open {
		core.bulk_edit(w, {shape = inside, op = .Paste, template = t, partial = true}, act)
		return true, loaded
	}
	wall := a.wall if a.wall != .Air else .Bedrock
	under := a.under if a.under != .Air else .Stone
	lo, hi := area.lo, area.hi
	walls := [4]core.Box {
		{{lo.x, lo.y, lo.z}, {lo.x, hi.y, hi.z}},
		{{hi.x, lo.y, lo.z}, {hi.x, hi.y, hi.z}},
		{{lo.x + 1, lo.y, lo.z}, {hi.x - 1, hi.y, lo.z}},
		{{lo.x + 1, lo.y, hi.z}, {hi.x - 1, hi.y, hi.z}},
	}
	for box in walls {
		core.bulk_edit(w, {shape = box, op = .Set, block = wall, partial = true}, act)
	}
	if a.depth > 0 {
		below := core.Box{{lo.x + 1, lo.y, lo.z + 1}, {hi.x - 1, a.origin.y - 1, hi.z - 1}}
		core.bulk_edit(w, {shape = below, op = .Set, block = under, partial = true}, act)
	}
	core.bulk_edit(w, {shape = inside, op = .Paste, template = t, partial = true}, act)
	return true, loaded
}

// arena_holds: p (a player's feet) is inside the arena's walls, at most `above` blocks
// over their top and `below` blocks under its floor.
arena_holds :: proc(a: Arena, p: [3]f64, above := 0.0, below := 0.0) -> bool {
	lo, hi := a.origin, a.origin + a.size
	top := f64(hi.y - 1) if a.open else f64(a.wall_top)
	return(
		p.x >= f64(lo.x) &&
		p.z >= f64(lo.z) &&
		p.x < f64(hi.x) &&
		p.z < f64(hi.z) &&
		p.y >= f64(lo.y) - below &&
		p.y <= top + above \
	)
}
