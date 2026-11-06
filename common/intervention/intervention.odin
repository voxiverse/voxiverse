// Package intervention is a world's interventions log: everything a player does that the
// world's history must carry forward (a city founded, a war joined, a crop taught, a well
// dug), in time order, with its file format (`interventions.vxi`, docs/saves.md).
package intervention

import "core:encoding/endian"
import "core:hash"
import "core:math"

// Kind is written to disk: append only, never reorder or remove.
Kind :: enum u8 {
	Founded_Settlement,
	Built,
	Destroyed,
	Taught,
	Traded,
}

DATA_SIZE :: 16
MAX_ACTOR :: 64 // bytes of an actor's name
MAX_INTERVENTIONS :: 1 << 20 // a world's log; a file with more is refused

Intervention :: struct {
	day:   f64, // world time, in days (common/game/time.odin)
	place: [3]i32, // block position
	kind:  Kind,
	actor: string, // owned by the Log
	data:  [DATA_SIZE]u8, // what the kind says
}

// Log keeps its interventions in time order (equal days in the order recorded).
Log :: struct {
	list: [dynamic]Intervention,
}

log_destroy :: proc(l: ^Log) {
	for iv in l.list {delete(iv.actor)}
	delete(l.list)
	l^ = {}
}

valid :: proc(iv: Intervention) -> bool {
	return(
		!math.is_nan(iv.day) &&
		!math.is_inf(iv.day) &&
		iv.day >= 0 &&
		iv.kind <= max(Kind) &&
		len(iv.actor) <= MAX_ACTOR \
	)
}

// record adds iv (its actor copied), after every intervention that is not later than it.
// False, and nothing added, for an invalid one or a full log.
record :: proc(l: ^Log, iv: Intervention) -> bool {
	if !valid(iv) || len(l.list) >= MAX_INTERVENTIONS {return false}
	at := first_after(l.list[:], iv.day)
	added := iv
	added.actor = clone_string(iv.actor)
	inject_at(&l.list, at, added)
	return true
}

// interventions_since: those on or after day, in order (a view of the log: valid until it changes).
interventions_since :: proc(l: ^Log, day: f64) -> []Intervention {
	return l.list[first_from(l.list[:], day):]
}

// interventions_near: those on or after since_day whose place is within radius_blocks
// (Euclidean, inclusive) of place, in order.
interventions_near :: proc(
	l: ^Log,
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

MAGIC :: "VXIV"
VERSION :: 1
HEADER_SIZE :: 12 // magic, version u32, count u32 (little-endian)
FIXED_SIZE :: 8 + 12 + 1 + 1 + DATA_SIZE // day, place, kind, actor length, data

// encode: header, then per intervention its day (f64 bits), place, kind, actor length,
// actor and data, then the CRC-32 of everything before it.
encode :: proc(l: ^Log, allocator := context.allocator) -> []u8 {
	size := HEADER_SIZE + 4
	for iv in l.list {size += FIXED_SIZE + len(iv.actor)}
	out := make([]u8, size, allocator)
	copy(out, MAGIC)
	endian.put_u32(out[4:], .Little, VERSION)
	endian.put_u32(out[8:], .Little, u32(len(l.list)))
	at := HEADER_SIZE
	for &iv in l.list {
		endian.put_u64(out[at:], .Little, transmute(u64)iv.day)
		for v, i in iv.place {endian.put_u32(out[at + 8 + 4 * i:], .Little, u32(v))}
		out[at + 20] = u8(iv.kind)
		out[at + 21] = u8(len(iv.actor))
		at += 22
		copy(out[at:], iv.actor)
		at += len(iv.actor)
		copy(out[at:], iv.data[:])
		at += DATA_SIZE
	}
	endian.put_u32(out[at:], .Little, hash.crc32(out[:at]))
	return out
}

// decode reads a file; ok is false for anything damaged: a wrong magic or version, a bad CRC,
// a cut or longer file, an invalid record or records out of time order.
decode :: proc(data: []u8) -> (l: Log, ok: bool) {
	if len(data) < HEADER_SIZE + 4 || string(data[:4]) != MAGIC {return}
	version, _ := endian.get_u32(data[4:], .Little)
	count, _ := endian.get_u32(data[8:], .Little)
	if version != VERSION || count > MAX_INTERVENTIONS {return}
	end := len(data) - 4
	crc, _ := endian.get_u32(data[end:], .Little)
	if crc != hash.crc32(data[:end]) {return}
	defer if !ok {log_destroy(&l)}
	reserve(&l.list, int(count))
	at := HEADER_SIZE
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
		if kind > u8(max(Kind)) || n > MAX_ACTOR || at + n + DATA_SIZE > end {return}
		iv.kind = Kind(kind)
		iv.actor = clone_string(string(data[at:at + n]))
		at += n
		copy(iv.data[:], data[at:at + DATA_SIZE])
		at += DATA_SIZE
		append(&l.list, iv)
		if !valid(iv) || (len(l.list) > 1 && l.list[len(l.list) - 2].day > iv.day) {return}
	}
	if at != end {return}
	return l, true
}

// ---- helpers ----

// first_from: the index of the first intervention with day >= from.
@(private)
first_from :: proc(list: []Intervention, from: f64) -> int {
	lo, hi := 0, len(list)
	for lo < hi {
		mid := (lo + hi) / 2
		if list[mid].day < from {lo = mid + 1} else {hi = mid}
	}
	return lo
}

// first_after: the index of the first intervention with day > day.
@(private)
first_after :: proc(list: []Intervention, day: f64) -> int {
	lo, hi := 0, len(list)
	for lo < hi {
		mid := (lo + hi) / 2
		if list[mid].day <= day {lo = mid + 1} else {hi = mid}
	}
	return lo
}

@(private)
clone_string :: proc(s: string) -> string {
	b := make([]u8, len(s))
	copy(b, s)
	return string(b)
}
