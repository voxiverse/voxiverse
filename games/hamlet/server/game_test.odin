package hamlet_server

import "core:os"
import "core:path/filepath"
import "core:testing"

import "games:hamlet"
import "server:core"
import "server:playtest"

// Hamlet on a stepped server: the host (the harness's mirror, a planner over the
// village) and, for the tests of two, a guest over the harness's network with the
// default role. Every change goes through the requests, as the toolbar's would.

Rig :: playtest.Rig

// rig_start: Hamlet on a stepped server (with a guest, for the tests of two, who holds
// the default role), the village's land built and the players in it.
rig_start :: proc(t: ^testing.T, rig: ^Rig, guest := false, dir := "") -> bool {
	o := playtest.Options {
		guests   = 1 if guest else 0,
		listen   = true,
		save_dir = dir,
		plain    = true,
	}
	if !playtest.start(t, rig, GAME, o) {return false}
	running :: proc(data: rawptr) -> bool {return state((^core.Server)(data)).phase == .Running}
	ok := playtest.until(rig, running, srv(rig), 40)
	return testing.expect(t, ok, "the village's land was never built")
}

rig_stop :: playtest.stop
srv :: playtest.srv
host :: playtest.host
step :: playtest.step

ROAD_Z :: hamlet.MAP / 2
ROAD_FROM :: hamlet.MAP / 2 - 11
ROAD_TO :: hamlet.MAP / 2 + 10

// main_road: a road across the open middle of the map (no trees or rocks there).
main_road :: proc(rig: ^Rig, c: ^core.Client = nil) {
	r := hamlet.Lay_Road{{ROAD_FROM, ROAD_Z}, {ROAD_TO, ROAD_Z}}
	core.harness_request(srv(rig), c if c != nil else host(rig), &r)
}

// place: kind built on the south side of the main road, at the first x from `from`
// where the map's rules and the blocks allow it; its structure (-1: nowhere).
place :: proc(rig: ^Rig, kind: hamlet.Kind, from := i32(ROAD_FROM), c: ^core.Client = nil) -> int {
	s := srv(rig)
	t := state(s)
	for x in from ..< ROAD_TO - 4 {
		at := [2]i32{x, ROAD_Z + 1}
		if _, refusal := fit(s, kind, at, 0, {.Grass}); refusal != "" {continue}
		b := hamlet.Build{kind, {i16(at.x), i16(at.y)}, 0}
		core.harness_request(s, c if c != nil else host(rig), &b)
		if k := int(t.owner[at.y][at.x]); k >= 0 && t.structures[k].kind == kind {return k}
		return -1
	}
	return -1
}

// zone_north: the tiles north of the main road zoned for homes.
zone_north :: proc(rig: ^Rig) {
	z := hamlet.Zone{{ROAD_FROM, ROAD_Z - 3}, {ROAD_TO, ROAD_Z - 1}, false}
	core.harness_request(srv(rig), host(rig), &z)
}

count_kind :: proc(t: ^Town, kind: hamlet.Kind) -> (n: int) {
	for st in t.structures[:t.count] {if st.used && st.kind == kind {n += 1}}
	return
}

// A road dragged across the map is laid whole: every tile of it a road, its blocks
// gravel, and one end reaches the other along it.
@(test)
test_road_drag_lays_a_connected_road :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !rig_start(t, rig) {rig_stop(rig); return}
	defer rig_stop(rig)
	s := srv(rig)
	town := state(s)
	r := hamlet.Lay_Road{{ROAD_FROM, ROAD_Z}, {ROAD_FROM + 6, ROAD_Z + 5}}
	core.harness_request(s, host(rig), &r)
	for p in hamlet.road_path({ROAD_FROM, ROAD_Z}, {ROAD_FROM + 6, ROAD_Z + 5}) {
		testing.expect_value(t, town.tiles[p.y][p.x], hamlet.Tile.Road)
		b, _ := core.block_at(s.home, {p.x, hamlet.ground_top(&town.ground, p.x, p.y), p.y})
		testing.expect_value(t, b, town.road)
	}
	tiles, ok := way(town, {ROAD_FROM, ROAD_Z}, {ROAD_FROM + 6, ROAD_Z + 5})
	testing.expect(t, ok, "the road's ends are not joined")
	testing.expect_value(t, len(tiles), 12)
}

// A building that touches no road is refused, and the stock is as it was; by the road
// it is built and paid for.
@(test)
test_building_off_road_is_refused_and_free :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !rig_start(t, rig) {rig_stop(rig); return}
	defer rig_stop(rig)
	s := srv(rig)
	town := state(s)
	before := town.stock
	b := hamlet.Build{.Well, {ROAD_FROM, ROAD_Z + 4}, 0}
	core.harness_request(s, host(rig), &b)
	testing.expect_value(t, count_kind(town, .Well), 0)
	testing.expect_value(t, town.stock, before)
	main_road(rig)
	testing.expect(t, place(rig, .Well) >= 0, "no well by the road")
	testing.expect_value(
		t,
		town.stock[.Stone],
		before[.Stone] - hamlet.KINDS_INFO[.Well].cost[.Stone],
	)
}

// Zoned land by a road with a well near, wood and stone in stock: a house grows, and
// people move in.
@(test)
test_zone_grows_a_house_and_people_come :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !rig_start(t, rig) {rig_stop(rig); return}
	defer rig_stop(rig)
	s := srv(rig)
	town := state(s)
	main_road(rig)
	testing.expect(t, place(rig, .Well) >= 0, "no well")
	zone_north(rig)
	core.sim_speed_set(s, 4)
	step(rig, 120)
	testing.expect(t, count_kind(town, .House) >= 1, "no house grew")
	testing.expect(t, town.population >= 1, "nobody came")
	// They live in the house and stand on the road.
	for h in citizens(s) {
		c := citizen(s, h)
		testing.expect_value(t, town.structures[c.home].kind, hamlet.Kind.House)
		testing.expect_value(t, town.tiles[c.at.y][c.at.x], hamlet.Tile.Road)
	}
}

// town_working: a road, a well, zoned homes, a farm and a storehouse; people come.
town_working :: proc(t: ^testing.T, rig: ^Rig) -> bool {
	main_road(rig)
	ok := place(rig, .Well) >= 0
	ok &&= place(rig, .Farm) >= 0
	ok &&= place(rig, .Storehouse) >= 0
	zone_north(rig)
	core.sim_speed_set(srv(rig), 4)
	step(rig, 150)
	return testing.expect(t, ok && state(srv(rig)).population > 0, "the village did not start")
}

// A citizen takes a job at the farm, works a shift and brings the food to the storehouse.
@(test)
test_citizen_works_and_goods_reach_the_store :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !rig_start(t, rig) {rig_stop(rig); return}
	defer rig_stop(rig)
	s := srv(rig)
	town := state(s)
	if !town_working(t, rig) {return}
	food := town.stock[.Food]
	farmers, delivered := 0, false
	for _ in 0 ..< 400 {
		before := town.stock[.Food]
		step(rig)
		if town.stock[.Food] > before {delivered = true}
	}
	for h in citizens(s) {
		c := citizen(s, h)
		if c.job >= 0 && town.structures[c.job].kind == .Farm {farmers += 1}
	}
	testing.expect(t, farmers > 0, "nobody works the farm")
	testing.expect(t, delivered, "no food reached the storehouse")
	testing.expectf(
		t,
		town.delivered[.Food] > 0,
		"delivered %v (stock %d, was %d)",
		town.delivered,
		town.stock[.Food],
		food,
	)
}

// With no food and no farm, people go hungry and leave.
@(test)
test_starvation_makes_people_leave :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !rig_start(t, rig) {rig_stop(rig); return}
	defer rig_stop(rig)
	s := srv(rig)
	town := state(s)
	main_road(rig)
	place(rig, .Well)
	zone_north(rig)
	core.sim_speed_set(s, 4)
	step(rig, 150)
	if !testing.expect(t, town.population > 0, "nobody came") {return}
	town.stock[.Food] = 0
	step(rig, 3 * hamlet.DAY_STEPS / 4 + 10)
	testing.expect_value(t, town.population, 0)
}

// The village after a save and a restart is the one saved: its tiles, structures,
// stock, day, people and their homes and jobs; and the people stand in the world where
// they were, going where they went, without being made again.
@(test)
test_town_survives_a_restart :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "hamlet_restart"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	saved := new(Town)
	defer free(saved)
	Kept :: struct {
		id:       u32,
		citizen:  Citizen,
		position: [3]f64,
		arrived:  bool,
	}
	kept := make([dynamic]Kept)
	defer delete(kept)
	{
		rig := new(Rig)
		defer free(rig)
		if !rig_start(t, rig, dir = dir) {rig_stop(rig); return}
		if !town_working(t, rig) {rig_stop(rig); return}
		step(rig, 20)
		core.sim_speed_set(srv(rig), 0) // (paused: what is kept is what the snapshot holds)
		step(rig)
		saved^ = state(srv(rig))^
		s := srv(rig)
		for h in citizens(s) {
			append(
				&kept,
				Kept {
					core.entity_id(s.home, h),
					citizen(s, h)^,
					core.entity_pos(s.home, h),
					core.entity_arrived(s.home, h),
				},
			)
		}
		rig_stop(rig) // (the last save: this tick's)
	}
	rig := new(Rig)
	defer free(rig)
	if !rig_start(t, rig, dir = dir) {rig_stop(rig); return}
	defer rig_stop(rig)
	s := srv(rig)
	town := state(s)
	testing.expect(t, town.tiles == saved.tiles, "the map's tiles differ")
	testing.expect_value(t, town.count, saved.count)
	for st, k in town.structures[:town.count] {
		o := saved.structures[k]
		testing.expect_value(t, st.used, o.used)
		testing.expect_value(t, st.kind, o.kind)
		testing.expect_value(t, st.at, o.at)
		testing.expect_value(t, st.floor, o.floor)
		testing.expect_value(t, st.workers, o.workers)
		testing.expect_value(t, st.people, o.people)
	}
	testing.expect_value(t, town.stock, saved.stock)
	testing.expect_value(t, town.day, saved.day)
	testing.expect_value(t, town.population, saved.population)
	testing.expect_value(t, s.sim_speed, 0)
	testing.expect(t, len(kept) > 0, "nobody lived in the village")
	walking := 0
	for k in kept {
		h, ok := core.entity_find(s.home, k.id)
		if !testing.expectf(t, ok, "citizen %d was not kept", k.id) {continue}
		testing.expect_value(t, citizen(s, h)^, k.citizen)
		d := core.entity_pos(s.home, h) - k.position
		testing.expectf(t, d.x * d.x + d.y * d.y + d.z * d.z < 1e-6, "citizen %d moved", k.id)
		if !k.arrived {
			walking += 1
			testing.expectf(t, !core.entity_arrived(s.home, h), "citizen %d stopped", k.id)
		}
	}
	// On its way again: a step later the walkers move from where they stood.
	core.sim_speed_set(s, 2)
	step(rig, 2)
	if walking > 0 {
		moved := 0
		for k in kept {
			if h, ok := core.entity_find(s.home, k.id);
			   ok && core.entity_pos(s.home, h) != k.position {moved += 1}
		}
		testing.expect(t, moved > 0, "nobody went on")
	}
}

// Two players build the same village: the guest lays the road and a farm, the host a
// well; both are there.
@(test)
test_two_players_build_together :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !rig_start(t, rig, guest = true) {rig_stop(rig); return}
	defer rig_stop(rig)
	s := srv(rig)
	town := state(s)
	g := playtest.guest(rig)
	main_road(rig, g)
	testing.expect_value(t, town.tiles[ROAD_Z][ROAD_FROM], hamlet.Tile.Road)
	testing.expect(t, place(rig, .Farm, c = g) >= 0, "the guest's farm")
	testing.expect(t, place(rig, .Well) >= 0, "the host's well")
	step(rig, 2)
	testing.expect_value(t, count_kind(town, .Farm), 1)
	testing.expect_value(t, count_kind(town, .Well), 1)
}

// A player without hamlet.demolish cannot take a building down; the host can, and gets
// half its cost back.
@(test)
test_demolish_needs_the_permission :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !rig_start(t, rig, guest = true) {rig_stop(rig); return}
	defer rig_stop(rig)
	s := srv(rig)
	town := state(s)
	main_road(rig)
	k := place(rig, .Storehouse)
	if !testing.expect(t, k >= 0, "no storehouse") {return}
	at := town.structures[k].at
	d := hamlet.Demolish{{i16(at.x), i16(at.y)}}
	core.harness_request(s, playtest.guest(rig), &d)
	testing.expect_value(t, count_kind(town, .Storehouse), 1)
	wood := town.stock[.Wood]
	core.harness_request(s, host(rig), &d)
	testing.expect_value(t, count_kind(town, .Storehouse), 0)
	testing.expect_value(
		t,
		town.stock[.Wood],
		wood + hamlet.KINDS_INFO[.Storehouse].cost[.Wood] / 2,
	)
	testing.expect_value(t, town.tiles[at.y][at.x], hamlet.Tile.Grass)
}
