package game

// Belts: a block whose entity is a belt (`"entity": {"kind": "belt", "speed": 1.5}`, blocks
// a second, with a `facing` property) carries items the way it faces. Its lane holds at most
// LANE_ITEMS items, front first, each at a point along the block (0: where items come on,
// LANE_END: where they leave), at least LANE_SPACING apart, in the order they came. Each
// tick (lanes_step) every lane moves its items on as far as the one in front lets them,
// then hands its front item, at its end, to the belt it faces when that one has room at its
// start (a corner is a belt facing another way); else the item waits there. One code for
// both sides: the server steps the world's belts, a client the belts it holds between what
// it is told, so items in transit cost no entity and no message while they only move.

LANE_ITEMS :: 4
LANE_END :: 0xFFFF
LANE_SPACING :: 0x4000 // a quarter of a block

Lane_Item :: struct {
	item: Item,
	at:   u16, // 0: the lane's start .. LANE_END: its end
}

Lane :: struct {
	items: [LANE_ITEMS]Lane_Item, // front first
	count: u8,
}

// lane_step_of: a belt's step a tick, in lane units, at speed blocks a second.
lane_step_of :: proc(speed: f32) -> u16 {
	return u16(clamp(speed * 65536 / TICK_RATE, 1, LANE_SPACING))
}

// lane_room: an item may come on at the lane's start.
lane_room :: proc(l: ^Lane) -> bool {
	return l.count == 0 || (l.count < LANE_ITEMS && l.items[l.count - 1].at >= LANE_SPACING)
}

// lane_put: item comes on at the lane's start (false: no room).
lane_put :: proc(l: ^Lane, item: Item) -> bool {
	if !lane_room(l) || item == NO_ITEM {return false}
	l.items[l.count] = {item, 0}
	l.count += 1
	return true
}

// lane_take: the front item leaves the lane, wherever it is along it (false: empty).
lane_take :: proc(l: ^Lane) -> (Item, bool) {
	if l.count == 0 {return NO_ITEM, false}
	item := l.items[0].item
	copy(l.items[:], l.items[1:l.count])
	l.count -= 1
	l.items[l.count] = {}
	return item, true
}

// lane_move: the items move on by step, each as far as the one in front lets it (the front
// one to the end). True if any moved.
lane_move :: proc(l: ^Lane, step: u16) -> (moved: bool) {
	limit := u32(LANE_END)
	for i in 0 ..< int(l.count) {
		it := &l.items[i]
		want := min(u32(it.at) + u32(step), limit)
		if want > u32(it.at) {
			it.at = u16(want)
			moved = true
		}
		limit = u32(it.at) - LANE_SPACING if it.at >= LANE_SPACING else 0
	}
	return
}

// Lane_Find: the belt at p: its lane, its step a tick and the way it carries (false: no belt).
Lane_Find :: #type proc(
	data: rawptr,
	p: Block_Pos,
) -> (
	lane: ^Lane,
	step: u16,
	dir: Block_Pos,
	ok: bool,
)

// Lanes_Stepped: what a tick of the belts did: the lanes that moved or took an item (they
// stay awake), and those that handed one on (the belts feeding them may move again).
Lanes_Stepped :: struct {
	awake: [dynamic]Block_Pos,
	gave:  [dynamic]Block_Pos,
}

// lanes_step: one tick of the belts at `active` (each a belt, in the order to hand on in:
// the same order on every run gives the same world): every lane moves its items, then each
// in turn hands its front item at its end to the belt it faces, if that one has room.
lanes_step :: proc(active: []Block_Pos, find: Lane_Find, data: rawptr, out: ^Lanes_Stepped) {
	for p in active {
		l, step, _, ok := find(data, p)
		if ok && lane_move(l, step) {append(&out.awake, p)}
	}
	for p in active {
		l, _, dir, ok := find(data, p)
		if !ok || l.count == 0 || l.items[0].at != LANE_END {continue}
		next, _, _, has := find(data, p + dir)
		if !has || !lane_room(next) {continue}
		item, _ := lane_take(l)
		lane_put(next, item)
		append(&out.gave, p)
		append(&out.awake, p + dir)
	}
}

// lane_feeders: the belts around p that carry into it (their front items wait for it).
lane_feeders :: proc(p: Block_Pos, find: Lane_Find, data: rawptr) -> (out: [4]Block_Pos, n: int) {
	for d in ([4]Block_Pos{{1, 0, 0}, {-1, 0, 0}, {0, 0, 1}, {0, 0, -1}}) {
		_, _, dir, ok := find(data, p + d)
		if ok && dir == -d {
			out[n] = p + d
			n += 1
		}
	}
	return
}

// lane_stacks: what a lane carries, as stacks of one (the item ledger counts them).
lane_stacks :: proc(l: ^Lane) -> (out: [LANE_ITEMS]Stack) {
	for i in 0 ..< int(l.count) {out[i] = {l.items[i].item, 1, 0, 0}}
	return
}
