package play

import "core:math"

import "common:game"
import "server:core"

// look_at: the look (yaw, pitch) of eyes at `from` turned to `to`, as core.teleport
// takes it.
look_at :: proc(from, to: [3]f64) -> [2]f32 {
	d := to - from
	yaw := math.atan2(-d.x, -d.z)
	pitch := math.atan2(d.y, math.sqrt(d.x * d.x + d.z * d.z))
	return {f32(yaw), f32(pitch)}
}

// WATCH_SEATS: watchers float side by side along a line, each at its seat's place on it.
WATCH_SEATS :: 16

// watch: c watches what the game is doing rather than playing it (out of a round, come
// in during one, between matches): in mode (one that flies and is not hurt: the game's
// pack's), flying at `at`, looking at `look` (a point), its seat's place along x
// `spacing` blocks from its neighbours', so watchers do not float inside each other.
watch :: proc(s: ^core.Server, c: ^core.Client, mode: string, at, look: [3]f64, spacing := 2.0) {
	core.game_mode(s, c, mode)
	seat := f64(core.player_id(s, c) % WATCH_SEATS)
	place := at + {(seat - (WATCH_SEATS - 1) / 2.0) * spacing, 0, 0}
	core.teleport(s, c, place, look_at(place, look), flying = true)
}

// hold: c holds the item (by its id, "voxiverse:rocket_launcher") from its hotbar, as if
// it chose that slot; false when it has none there.
hold :: proc(s: ^core.Server, c: ^core.Client, item: string) -> bool {
	id, known := game.registry_item(s.registry, item)
	if !known {return false}
	for st, slot in c.inventory.slots[:game.HOTBAR_SLOTS] {
		if st.item == id {return core.hotbar_select(s, c, slot)}
	}
	return false
}
