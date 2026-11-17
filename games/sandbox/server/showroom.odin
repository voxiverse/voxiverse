package sandbox_server

import "core:fmt"
import "core:strconv"
import "core:strings"

import "common:game"
import "server:core"

// The showroom: every material of one family (game.MATERIALS) set up to look at, each as a
// wall three blocks square, eight to a row, the rows one above another like a gallery's,
// on a floor with a walkway in front. `/showroom <family> [x y z]` builds it with its
// lowest left corner at x y z (the player's feet by default), over what was there: for
// looking at the kit in the world, under its light (screenshots: docs/packs.md,
// "Materials").

SHOWROOM_ROW :: 8 // walls in a row
SHOWROOM_STEP :: 4 // blocks from one wall to the next, across and up
SHOWROOM_VIEW :: 30 // blocks of floor in front of the walls

// showroom_command: `/showroom <family> [x y z]` (the bulk edit permission).
showroom_command :: proc(s: ^core.Server, c: ^core.Client, args: []string) -> bool {
	USAGE :: "Usage: showroom <stone|wood|metal|built|domestic|natural|fantasy> [x y z]"
	if !core.allowed(s, c, "world.edit.bulk") {
		core.notice(s, c, "You may not build here")
		return true
	}
	if len(args) != 1 && len(args) != 4 {
		core.notice(s, c, USAGE)
		return true
	}
	family: game.Material_Family
	found := false
	for f in game.Material_Family {
		if strings.to_lower(fmt.tprintf("%v", f), context.temp_allocator) == args[0] {
			family, found = f, true
		}
	}
	if !found {
		core.notice(s, c, USAGE)
		return true
	}
	at := game.Block_Pos {
		i32(c.player.position.x),
		i32(c.player.position.y),
		i32(c.player.position.z),
	}
	if len(args) == 4 {
		for k in 0 ..< 3 {
			n, ok := strconv.parse_int(args[k + 1])
			if !ok {
				core.notice(s, c, USAGE)
				return true
			}
			at[k] = i32(n)
		}
	}
	built, missing := showroom_build(s, c.world, family, at)
	if built < 0 {
		core.notice(s, c, "The showroom's ground is not loaded; go nearer")
		return true
	}
	core.notice(s, c, fmt.tprintf("Showroom of %d materials at %d %d %d", built, at.x, at.y, at.z))
	if missing != "" {core.notice(s, c, fmt.tprintf("No block of %s", missing))}
	return true
}

// showroom_build sets the showroom of a family up at `at`: built, the materials shown (-1:
// its ground is not loaded), and the first that has no block of the sandbox's.
showroom_build :: proc(
	s: ^core.Server,
	w: ^core.World,
	family: game.Material_Family,
	at: game.Block_Pos,
) -> (
	built: int,
	missing: string,
) {
	n := 0
	for m in game.MATERIALS {if m.family == family {n += 1}}
	rows := (n + SHOWROOM_ROW - 1) / SHOWROOM_ROW
	width := i32(SHOWROOM_ROW * SHOWROOM_STEP)
	height := i32(rows * SHOWROOM_STEP)
	// The floor and the clear air over it reach SHOWROOM_VIEW in front of the walls: room to
	// stand back and see them all.
	area := core.Box{at + {-2, -1, -2}, at + {width + 1, height + 8, SHOWROOM_VIEW}}
	if !core.world_ready(w, area) {return -1, ""}
	act := core.game_act(s, w, .Command)
	set :: proc(w: ^core.World, lo, hi: game.Block_Pos, b: game.Block, act: core.Act) {
		core.bulk_edit(w, {shape = core.Box{lo, hi}, op = .Set, block = b}, act)
	}
	floor, _ := game.registry_block(s.registry, "sandbox:concrete_tiles")
	set(w, area.lo + {0, 1, 0}, area.hi, .Air, act)
	set(w, area.lo, {area.hi.x, area.lo.y, area.hi.z}, floor, act)
	k := 0
	for m in game.MATERIALS {
		if m.family != family {continue}
		b, ok := game.registry_block(s.registry, fmt.tprintf("sandbox:%s", m.name))
		if !ok {
			if missing == "" {missing = m.name}
			continue
		}
		lo :=
			at + {i32(k % SHOWROOM_ROW) * SHOWROOM_STEP, i32(k / SHOWROOM_ROW) * SHOWROOM_STEP, 0}
		set(w, lo, lo + {2, 2, 0}, b, act)
		k += 1
	}
	return k, missing
}
