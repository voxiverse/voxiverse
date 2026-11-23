package sandbox_server

import "core:encoding/endian"
import "core:fmt"
import "core:hash"

import "common:game"
import "common:starmap"
import "games:sandbox"
import "server:core"

// Outposts (README.md, "Gathering, crafting and outposts"): a beacon (sandbox:outpost_beacon)
// placed anywhere makes one. Its placer stands there again after a death (its respawn,
// kept with its character, and in its logbook); any player may make it theirs by using the
// beacon. No hostile
// creature comes by itself within OUTPOST_RADIUS of one (the spawned hook refuses it, as a
// spawn rule's `safe` does round the world's spawn), whoever is near. Only its placer may
// take it down. Each world keeps its outposts (OUTPOSTS_FILE).

MAX_OWNER :: 32 // bytes of a placer's name kept

// Outpost: a beacon of the world's: where it stands and who placed it.
Outpost :: struct {
	at:        game.Block_Pos,
	owner:     [MAX_OWNER]u8,
	owner_len: u8,
}

outpost_owner :: proc(o: ^Outpost) -> string {return string(o.owner[:o.owner_len])}

// Outposts: a world's outposts, in the order placed.
Outposts :: struct {
	list:  [sandbox.MAX_OUTPOSTS]Outpost,
	count: int,
	dirty: bool, // changed since its file was staged
}

// Outpost_Home: where a character stands again after a death: an outpost of a world (none
// set: the world's spawn). Kept in its record (Trader_Record.home).
Outpost_Home :: struct {
	set:   bool,
	world: starmap.Address,
	at:    [3]i32,
}

outposts_of :: proc(w: ^core.World) -> ^Outposts {return &world_of(w).outposts}

outpost_find :: proc(o: ^Outposts, at: game.Block_Pos) -> int {
	for i in 0 ..< o.count {if o.list[i].at == at {return i}}
	return -1
}

// outpost_add: a beacon placed at `at` by `owner`; false when the world keeps as many as
// it may.
outpost_add :: proc(o: ^Outposts, at: game.Block_Pos, owner: string) -> bool {
	if outpost_find(o, at) >= 0 {return true}
	if o.count >= len(o.list) {return false}
	p := &o.list[o.count]
	p^ = {
		at = at,
	}
	p.owner_len = u8(copy(p.owner[:], owner))
	o.count += 1
	o.dirty = true
	return true
}

outpost_remove :: proc(o: ^Outposts, at: game.Block_Pos) {
	i := outpost_find(o, at)
	if i < 0 {return}
	copy(o.list[i:o.count - 1], o.list[i + 1:o.count])
	o.count -= 1
	o.dirty = true
}

// outpost_guards: a point lies within OUTPOST_RADIUS of one of the world's beacons
// (horizontally).
outpost_guards :: proc(o: ^Outposts, p: [3]f64) -> bool {
	r :: f64(sandbox.OUTPOST_RADIUS)
	for i in 0 ..< o.count {
		a := o.list[i].at
		dx, dz := p.x - (f64(a.x) + 0.5), p.z - (f64(a.z) + 0.5)
		if dx * dx + dz * dz < r * r {return true}
	}
	return false
}

// outpost_spawned: a hostile creature (its kind fights) coming by itself near an outpost
// is refused (the spawned hook).
outpost_spawned :: proc(s: ^core.Server, w: ^core.World, h: game.Entity_Handle) -> bool {
	kind := core.entity_kind(w, h)
	if kind == 0 || int(kind) > len(s.registry.kinds) {return true}
	if _, fights := s.registry.kinds[kind - 1].attack.?; !fights {return true}
	return !outpost_guards(outposts_of(w), core.entity_pos(w, h))
}

// outpost_editing: a beacon is its placer's to take down, and a world takes no more than
// it keeps.
outpost_editing :: proc(
	s: ^core.Server,
	c: ^core.Client,
	at: game.Block_Pos,
	old, new: game.Block,
) -> string {
	beacon := survival_of(s).beacon
	o := outposts_of(c.world)
	if new == beacon && o.count >= len(o.list) {
		return fmt.tprintf("This world keeps %d outposts at most", len(o.list))
	}
	if old == beacon && new != beacon {
		if i := outpost_find(o, at); i >= 0 && outpost_owner(&o.list[i]) != core.client_name(c) {
			return fmt.tprintf("This beacon is %s's", outpost_owner(&o.list[i]))
		}
	}
	return ""
}

// outposts_changed: a beacon placed makes an outpost (its placer's respawn), one gone
// unmakes it; a cache or vault broken open spills (survival.odin).
outposts_changed :: proc(s: ^core.Server, w: ^core.World, change: core.Block_Change) {
	g := survival_of(s)
	o := outposts_of(w)
	if change.bulk {
		// A blast or a command: any beacon in its box that is gone.
		for i := o.count - 1; i >= 0; i -= 1 {
			a := o.list[i].at
			lo, hi := change.area.lo, change.area.hi
			if a.x < lo.x ||
			   a.y < lo.y ||
			   a.z < lo.z ||
			   a.x > hi.x ||
			   a.y > hi.y ||
			   a.z > hi.z {continue}
			if b, ok := core.block_at(w, a); ok && b != g.beacon {outpost_remove(o, a)}
		}
		return
	}
	at := change.area.lo
	switch {
	case change.new == g.beacon:
		owner := core.client_name(change.by) if change.by != nil else ""
		if !outpost_add(o, at, owner) || change.by == nil {return}
		outpost_make_home(s, change.by, w, at)
		core.logbook_place(s, change.by, .Outpost, {at.x, at.y, at.z})
		core.notice(s, change.by, "Outpost made: you will stand here again after a death")
	case change.old == g.beacon:
		outpost_remove(o, at)
	case change.by != nil && change.old == g.remains_cache:
		remains_spill(s, w, at, false)
	case change.by != nil && change.old == g.relic_vault:
		remains_spill(s, w, at, true)
	}
}

outpost_make_home :: proc(s: ^core.Server, c: ^core.Client, w: ^core.World, at: game.Block_Pos) {
	trader(s, c).home = {true, w.address, {at.x, at.y, at.z}}
}

// outpost_use: a beacon used (machine_use) becomes the user's respawn.
outpost_use :: proc(s: ^core.Server, c: ^core.Client, at: game.Block_Pos) -> string {
	if outpost_find(outposts_of(c.world), at) < 0 {return "This beacon is dark"}
	outpost_make_home(s, c, c.world, at)
	core.logbook_place(s, c, .Outpost, {at.x, at.y, at.z})
	core.notice(s, c, "You will stand at this outpost again after a death")
	return ""
}

// outpost_home: where c's outpost would stand it (on its beacon); false with none, or
// one whose beacon is gone from a world that is open (then it is forgotten).
outpost_home :: proc(s: ^core.Server, c: ^core.Client) -> (core.Place, bool) {
	home := &trader(s, c).home
	if !home.set {return {}, false}
	at := game.Block_Pos{home.at.x, home.at.y, home.at.z}
	for w in s.worlds {
		if w.address != home.world {continue}
		if outpost_find(outposts_of(w), at) < 0 {
			home^ = {}
			core.notice(s, c, "Your outpost is gone")
			return {}, false
		}
	}
	return {home.world, {f64(at.x) + 0.5, f64(at.y) + 1, f64(at.z) + 0.5}, {}}, true
}

// outpost_respawned: one who died stands at its outpost, when it has one.
outpost_respawned :: proc(s: ^core.Server, c: ^core.Client) {
	place, ok := outpost_home(s, c)
	if !ok {return}
	if why := core.go_to(s, c, place); why != "" {core.notice(s, c, why)}
}

// outposts_shown: the outposts of c's world, as c is shown them.
outposts_shown :: proc(s: ^core.Server, c: ^core.Client, out: ^sandbox.Survival) {
	o := outposts_of(c.world)
	home := trader(s, c).home
	name := core.client_name(c)
	for i in 0 ..< o.count {
		a := o.list[i].at
		out.outposts[i] = {
			at   = {a.x, a.y, a.z},
			mine = outpost_owner(&o.list[i]) == name,
			home = home.set && home.world == c.world.address && home.at == [3]i32{a.x, a.y, a.z},
		}
	}
	out.count = u8(o.count)
}

// outposts_command: `/outposts`: the world's outposts, who placed each and which is yours.
outposts_command :: proc(s: ^core.Server, c: ^core.Client) -> bool {
	o := outposts_of(c.world)
	if o.count == 0 {
		core.notice(s, c, "This world has no outposts")
		return true
	}
	shown: sandbox.Survival
	outposts_shown(s, c, &shown)
	for i in 0 ..< o.count {
		a := o.list[i].at
		mark := " (your respawn)" if shown.outposts[i].home else ""
		core.notice(
			s,
			c,
			fmt.tprintf(
				"Outpost at %d %d %d, %s's%s",
				a.x,
				a.y,
				a.z,
				outpost_owner(&o.list[i]),
				mark,
			),
		)
	}
	return true
}

// ---- the world's file ----

OUTPOSTS_FILE :: "outposts.vxo" // sandbox.outposts.vxo
OUTPOSTS_MAGIC :: "VXOP"
OUTPOSTS_VERSION :: 1

// outposts_encode: "VXOP", version, count (u32 each), per outpost its place (3 x i32), the
// placer's name (u8 length, bytes), then the CRC-32 of everything before (little-endian).
outposts_encode :: proc(o: ^Outposts, allocator := context.allocator) -> []u8 {
	size := 12 + 4
	for i in 0 ..< o.count {size += 13 + int(o.list[i].owner_len)}
	out := make([]u8, size, allocator)
	copy(out, OUTPOSTS_MAGIC)
	endian.put_u32(out[4:], .Little, OUTPOSTS_VERSION)
	endian.put_u32(out[8:], .Little, u32(o.count))
	at := 12
	for i in 0 ..< o.count {
		p := &o.list[i]
		for v, k in ([3]i32{p.at.x, p.at.y, p.at.z}) {endian.put_u32(out[at + 4 * k:], .Little, u32(v))}
		out[at + 12] = p.owner_len
		at += 13
		at += copy(out[at:], outpost_owner(p))
	}
	endian.put_u32(out[at:], .Little, hash.crc32(out[:at]))
	return out
}

// outposts_decode: false for anything damaged (a wrong magic or version, a bad CRC, a cut
// or longer file, more outposts than a world keeps, a name too long).
outposts_decode :: proc(data: []u8) -> (o: Outposts, ok: bool) {
	if len(data) < 16 || string(data[:4]) != OUTPOSTS_MAGIC {return}
	version, _ := endian.get_u32(data[4:], .Little)
	count, _ := endian.get_u32(data[8:], .Little)
	if version != OUTPOSTS_VERSION || count > sandbox.MAX_OUTPOSTS {return}
	end := len(data) - 4
	crc, _ := endian.get_u32(data[end:], .Little)
	if crc != hash.crc32(data[:end]) {return}
	at := 12
	for i in 0 ..< int(count) {
		if at + 13 > end {return}
		p := &o.list[i]
		v: [3]i32
		for k in 0 ..< 3 {
			u, _ := endian.get_u32(data[at + 4 * k:], .Little)
			v[k] = i32(u)
		}
		p.at = {v.x, v.y, v.z}
		n := int(data[at + 12])
		at += 13
		if n > MAX_OWNER || at + n > end {return}
		p.owner_len = u8(copy(p.owner[:], data[at:at + n]))
		at += n
	}
	if at != end {return}
	o.count = int(count)
	return o, true
}

// outposts_load: a world's outposts as it opens; a damaged file is moved aside and the
// world keeps none (the beacons stand, dark, until placed again).
outposts_load :: proc(w: ^core.World) {
	data, found := core.world_file_read(w, OUTPOSTS_FILE)
	if !found {return}
	o, ok := outposts_decode(data)
	if !ok {
		core.world_file_aside(w, OUTPOSTS_FILE)
		return
	}
	outposts_of(w)^ = o
}

// outposts_write: the world's outposts staged in the save when they changed.
outposts_write :: proc(w: ^core.World) {
	o := outposts_of(w)
	if !o.dirty {return}
	o.dirty = !core.world_file_write(w, OUTPOSTS_FILE, outposts_encode(o, context.temp_allocator))
}

// outposts_check: whether the file reads (voxiverse-server --check).
outposts_check :: proc(data: []u8) -> bool {
	_, ok := outposts_decode(data)
	return ok
}
