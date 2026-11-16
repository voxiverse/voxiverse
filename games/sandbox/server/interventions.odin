package sandbox_server

import "core:encoding/endian"
import "core:fmt"
import "core:hash"
import "core:math"
import "core:strconv"

import "common:game"
import "server:core"

// A world's interventions log: everything a player does that the world's history must carry
// forward (a city founded, a war joined, a crop taught, a well dug), in time order, kept with
// the world (INTERVENTIONS_FILE, its format below; docs/saves.md). The history takes the
// settlements founded (economy.odin: economy_interventions).

// Intervention_Kind is written to disk: append only, never reorder or remove.
Intervention_Kind :: enum u8 {
	Founded_Settlement,
	Built,
	Destroyed,
	Taught,
	Traded,
}

INTERVENTION_DATA :: 16
MAX_ACTOR :: 64 // bytes of an actor's name
MAX_INTERVENTIONS :: 1 << 20 // a world's log; a file with more is refused

Intervention :: struct {
	day:   f64, // world time, in days (common/game/time.odin)
	place: [3]i32, // block position
	kind:  Intervention_Kind,
	actor: string, // owned by the Log
	data:  [INTERVENTION_DATA]u8, // what the kind says
}

// Intervention_Log keeps its interventions in time order (equal days in the order recorded).
Intervention_Log :: struct {
	list: [dynamic]Intervention,
}

interventions_destroy :: proc(l: ^Intervention_Log) {
	for iv in l.list {delete(iv.actor)}
	delete(l.list)
	l^ = {}
}

intervention_valid :: proc(iv: Intervention) -> bool {
	return(
		!math.is_nan(iv.day) &&
		!math.is_inf(iv.day) &&
		iv.day >= 0 &&
		iv.kind <= max(Intervention_Kind) &&
		len(iv.actor) <= MAX_ACTOR \
	)
}

// intervention_record adds iv (its actor copied), after every intervention that is not later than it.
// False, and nothing added, for an invalid one or a full log.
intervention_record :: proc(l: ^Intervention_Log, iv: Intervention) -> bool {
	if !intervention_valid(iv) || len(l.list) >= MAX_INTERVENTIONS {return false}
	at := first_after(l.list[:], iv.day)
	added := iv
	added.actor = clone_string(iv.actor)
	inject_at(&l.list, at, added)
	return true
}

// interventions_since: those on or after day, in order (a view of the log: valid until it changes).
interventions_since :: proc(l: ^Intervention_Log, day: f64) -> []Intervention {
	return l.list[first_from(l.list[:], day):]
}

// interventions_near: those on or after since_day whose place is within radius_blocks
// (Euclidean, inclusive) of place, in order.
interventions_near :: proc(
	l: ^Intervention_Log,
	place: [3]i32,
	radius_blocks: i32,
	since_day: f64,
	allocator := context.allocator,
) -> []Intervention {
	found := make([dynamic]Intervention, allocator)
	if radius_blocks < 0 {return found[:]}
	r2 := i128(radius_blocks) * i128(radius_blocks)
	for iv in interventions_since(l, since_day) {
		dx := i128(iv.place.x) - i128(place.x)
		dy := i128(iv.place.y) - i128(place.y)
		dz := i128(iv.place.z) - i128(place.z)
		if dx * dx + dy * dy + dz * dz <= r2 {append(&found, iv)}
	}
	return found[:]
}

// ---- file ----

INTERVENTIONS_MAGIC :: "VXIV"
INTERVENTIONS_VERSION :: 1
INTERVENTIONS_HEADER :: 12 // magic, version u32, count u32 (little-endian)
INTERVENTION_FIXED :: 8 + 12 + 1 + 1 + INTERVENTION_DATA // day, place, kind, actor length, data

// interventions_encode: header, then per intervention its day (f64 bits), place, kind, actor length,
// actor and data, then the CRC-32 of everything before it.
interventions_encode :: proc(l: ^Intervention_Log, allocator := context.allocator) -> []u8 {
	size := INTERVENTIONS_HEADER + 4
	for iv in l.list {size += INTERVENTION_FIXED + len(iv.actor)}
	out := make([]u8, size, allocator)
	copy(out, INTERVENTIONS_MAGIC)
	endian.put_u32(out[4:], .Little, INTERVENTIONS_VERSION)
	endian.put_u32(out[8:], .Little, u32(len(l.list)))
	at := INTERVENTIONS_HEADER
	for &iv in l.list {
		endian.put_u64(out[at:], .Little, transmute(u64)iv.day)
		for v, i in iv.place {endian.put_u32(out[at + 8 + 4 * i:], .Little, u32(v))}
		out[at + 20] = u8(iv.kind)
		out[at + 21] = u8(len(iv.actor))
		at += 22
		copy(out[at:], iv.actor)
		at += len(iv.actor)
		copy(out[at:], iv.data[:])
		at += INTERVENTION_DATA
	}
	endian.put_u32(out[at:], .Little, hash.crc32(out[:at]))
	return out
}

// interventions_decode reads a file; ok is false for anything damaged: a wrong magic or version, a bad CRC,
// a cut or longer file, an invalid record or records out of time order.
interventions_decode :: proc(data: []u8) -> (l: Intervention_Log, ok: bool) {
	if len(data) < INTERVENTIONS_HEADER + 4 || string(data[:4]) != INTERVENTIONS_MAGIC {return}
	version, _ := endian.get_u32(data[4:], .Little)
	count, _ := endian.get_u32(data[8:], .Little)
	if version != INTERVENTIONS_VERSION || count > MAX_INTERVENTIONS {return}
	end := len(data) - 4
	crc, _ := endian.get_u32(data[end:], .Little)
	if crc != hash.crc32(data[:end]) {return}
	defer if !ok {interventions_destroy(&l)}
	reserve(&l.list, int(count))
	at := INTERVENTIONS_HEADER
	for _ in 0 ..< count {
		if at + 22 > end {return}
		iv: Intervention
		bits, _ := endian.get_u64(data[at:], .Little)
		iv.day = transmute(f64)bits
		for i in 0 ..< 3 {
			v, _ := endian.get_u32(data[at + 8 + 4 * i:], .Little)
			iv.place[i] = i32(v)
		}
		kind := data[at + 20]
		n := int(data[at + 21])
		at += 22
		if kind > u8(max(Intervention_Kind)) ||
		   n > MAX_ACTOR ||
		   at + n + INTERVENTION_DATA > end {return}
		iv.kind = Intervention_Kind(kind)
		iv.actor = clone_string(string(data[at:at + n]))
		at += n
		copy(iv.data[:], data[at:at + INTERVENTION_DATA])
		at += INTERVENTION_DATA
		append(&l.list, iv)
		if !intervention_valid(iv) ||
		   (len(l.list) > 1 && l.list[len(l.list) - 2].day > iv.day) {return}
	}
	if at != end {return}
	return l, true
}

// ---- helpers ----

// first_from: the index of the first intervention with day >= from.
@(private = "file")
first_from :: proc(list: []Intervention, from: f64) -> int {
	lo, hi := 0, len(list)
	for lo < hi {
		mid := (lo + hi) / 2
		if list[mid].day < from {lo = mid + 1} else {hi = mid}
	}
	return lo
}

// first_after: the index of the first intervention with day > day.
@(private = "file")
first_after :: proc(list: []Intervention, day: f64) -> int {
	lo, hi := 0, len(list)
	for lo < hi {
		mid := (lo + hi) / 2
		if list[mid].day <= day {lo = mid + 1} else {hi = mid}
	}
	return lo
}

@(private = "file")
clone_string :: proc(s: string) -> string {
	b := make([]u8, len(s))
	copy(b, s)
	return string(b)
}

// ---- the world's file ----

INTERVENTIONS_FILE :: "interventions.vxi" // the world's file (core.World_File): sandbox.interventions.vxi

// interventions_load reads the log of a world as it opens. A damaged file is moved aside
// (like a damaged region) and the world starts with an empty log; it is never half-read.
interventions_load :: proc(w: ^core.World) {
	data, found := core.world_file_read(w, INTERVENTIONS_FILE)
	if !found {return} 	// none saved (a new world)
	l, ok := interventions_decode(data)
	if !ok {
		core.world_file_aside(w, INTERVENTIONS_FILE)
		return
	}
	world_of(w).interventions = l
}

// interventions_write stages the log when it changed (the save hook calls it).
interventions_write :: proc(w: ^core.World) {
	sw := world_of(w)
	if !sw.interventions_dirty {return}
	data := interventions_encode(&sw.interventions, context.temp_allocator)
	sw.interventions_dirty = !core.world_file_write(w, INTERVENTIONS_FILE, data)
}

// interventions_add adds an intervention to the world's log, to be saved with it.
interventions_add :: proc(w: ^core.World, iv: Intervention) -> bool {
	sw := world_of(w)
	if !intervention_record(&sw.interventions, iv) {return false}
	sw.interventions_dirty = true
	return true
}

// interventions_check: is the file whole? (--check: core.World_File.check)
interventions_check :: proc(data: []u8) -> bool {
	l, ok := interventions_decode(data)
	if ok {interventions_destroy(&l)}
	return ok
}

// interventions_command: `/interventions [radius]`, the world's interventions, newest last
// (no radius: the last 20; a radius in blocks: those within it of the player, the last 20).
interventions_command :: proc(s: ^core.Server, c: ^core.Client, args: []string) -> bool {
	if !core.allowed(s, c, "world.interventions") {
		core.notice(s, c, "You may not list the interventions here")
		return true
	}
	l := &world_of(c.world).interventions
	found := l.list[:]
	if len(args) > 1 {
		core.notice(s, c, "Usage: interventions [radius]")
		return true
	}
	if len(args) == 1 {
		radius, ok := strconv.parse_int(args[0])
		if !ok || radius < 0 || radius > 2 * game.WORLD_LIMIT {
			core.notice(s, c, "Usage: interventions [radius]")
			return true
		}
		p := c.player.position
		place := [3]i32{i32(math.floor(p.x)), i32(math.floor(p.y)), i32(math.floor(p.z))}
		found = interventions_near(l, place, i32(radius), 0, context.temp_allocator)
	}
	if len(found) == 0 {
		core.notice(s, c, "No interventions")
		return true
	}
	for iv in found[max(0, len(found) - 20):] {
		core.notice(
			s,
			c,
			fmt.tprintf(
				"day %.2f %v at %d %d %d by %s",
				iv.day,
				iv.kind,
				iv.place.x,
				iv.place.y,
				iv.place.z,
				iv.actor if iv.actor != "" else "(none)",
			),
		)
	}
	return true
}
