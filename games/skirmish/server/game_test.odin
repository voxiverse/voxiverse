package skirmish_server

import "core:math"
import "core:strings"
import "core:testing"

import "common:game"
import "common:protocol"
import "games:skirmish"
import "server:core"
import "server:playtest"

// Skirmish on the stepped server: a match laid out and begun with the host's side and the
// computer's; workers gather; a building is put up and trains a unit at its cost within
// supply; a block of soldiers ordered to a point arrives around it; an order for another
// side's unit is refused; armies fight by themselves and the larger wins; the fog sends an
// enemy only once a unit of the side sees it; a side whose headquarters and production fall
// loses the match; the computer builds and attacks; two players play two sides.

@(private = "file")
playing :: proc(t: ^testing.T, rig: ^playtest.Rig, o := playtest.Options{}) -> bool {
	if !playtest.start(t, rig, GAME, o) {return false}
	g := state(playtest.srv(rig))
	return testing.expect(
		t,
		playtest.until_phase(rig, &g.phase, .Playing, 60),
		"the match never began",
	)
}

// own: the side's entities of the game's of a role (and a unit or a building).
@(private = "file")
own :: proc(
	s: ^core.Server,
	team: u8,
	role: Role,
	unit := skirmish.Unit.Worker,
	building := skirmish.Building.Headquarters,
) -> []game.Entity_Handle {
	out := make([dynamic]game.Entity_Handle, context.temp_allocator)
	it := core.entities_each(s.home)
	for h in core.entities_next(&it) {
		m := mind(s.home, h)
		if m == nil || m.role != role || core.entity_team(s.home, h) != team {continue}
		if role == .Unit && m.unit != unit {continue}
		if role == .Building && m.building != building {continue}
		append(&out, h)
	}
	return out[:]
}

@(private = "file")
ids_of :: proc(s: ^core.Server, units: []game.Entity_Handle) -> (o: skirmish.Order) {
	for h in units[:min(len(units), skirmish.MAX_ORDER_IDS)] {
		o.ids[o.count] = core.entity_id(s.home, h)
		o.count += 1
	}
	return
}

@(test)
test_workers_gather_and_the_stock_rises :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	defer playtest.stop(rig)
	if !playing(t, rig) {return}
	s := playtest.srv(rig)
	side := side_of(s, playtest.host(rig))
	if !testing.expect(t, side != nil && side.team == 1, "the host plays no side") {return}
	workers := own(s, 1, .Unit, .Worker)
	testing.expect_value(t, len(workers), skirmish.START_WORKERS)
	node := node_nearest(s, core.entity_pos(s.home, workers[0]), .Ore, 40)
	if !testing.expect(t, node != 0, "no outcrop near the base") {return}
	before := side.stock[.Ore]
	o := ids_of(s, workers)
	o.kind, o.target = .Gather, core.entity_id(s.home, node)
	core.harness_request(s, playtest.host(rig), &o)
	playtest.step(rig, playtest.ticks(30))
	testing.expectf(t, side.stock[.Ore] > before, "the ore did not rise: %d", side.stock[.Ore])
	left := mind(s.home, node)
	testing.expect(t, left == nil || left.left < skirmish.NODE_ORE, "the outcrop gave nothing")
	// The economy record says it.
	eco := playtest.host_record(rig, skirmish.Economy)
	testing.expect(t, eco != nil && int(eco.stock[.Ore]) == side.stock[.Ore])
}

@(test)
test_a_building_is_put_up_and_trains_within_supply :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	defer playtest.stop(rig)
	if !playing(t, rig) {return}
	s := playtest.srv(rig)
	c := playtest.host(rig)
	side := side_of(s, c)
	side.stock = {
		.Ore  = 1000,
		.Wood = 1000,
	}
	workers := own(s, 1, .Unit, .Worker)
	o := ids_of(s, workers[:2])
	o.kind, o.building = .Build, .Barracks
	at, found := computer_site(s, side, .Barracks)
	if !testing.expect(t, found, "no site for a barracks") {return}
	o.at = {i16(at.x), 0, i16(at.y)}
	core.harness_request(s, c, &o)
	testing.expect_value(t, side.stock[.Wood], 1000 - skirmish.BUILDINGS[.Barracks].cost[.Wood])
	barracks := own(s, 1, .Building, building = .Barracks)
	if !testing.expect_value(t, len(barracks), 1) {return}
	b := barracks[0]
	put_up :: proc(data: rawptr) -> bool {
		rig := (^playtest.Rig)(data)
		s := playtest.srv(rig)
		bs := own(s, 1, .Building, building = .Barracks)
		return len(bs) == 1 && mind(s.home, bs[0]).built
	}
	if !testing.expect(
		t,
		playtest.until(rig, put_up, rig, 60),
		"the barracks was never put up",
	) {return}
	// A soldier, paid for when queued, out within the supply.
	ore := side.stock[.Ore]
	tr := skirmish.Train{core.entity_id(s.home, b), .Soldier}
	core.harness_request(s, c, &tr)
	testing.expect_value(t, side.stock[.Ore], ore - skirmish.UNITS[.Soldier].cost[.Ore])
	trained :: proc(data: rawptr) -> bool {
		s := playtest.srv((^playtest.Rig)(data))
		return len(own(s, 1, .Unit, .Soldier)) == 1
	}
	testing.expect(t, playtest.until(rig, trained, rig, 20), "no soldier came")
	testing.expect(t, side.supply <= side.cap)
	// A full house trains no more: with the supply at its cap, a soldier ready to come out
	// waits.
	units_tick(s)
	for i in 0 ..< side.cap - side.supply {
		unit_spawn(
			s,
			side,
			.Soldier,
			{side.start.x + 4 + i32(i), skirmish.GROUND, side.start.y + 8},
		)
	}
	units_tick(s)
	testing.expect_value(t, side.supply, side.cap)
	soldiers := len(own(s, 1, .Unit, .Soldier))
	bm := mind(s.home, b)
	bm.queue[0], bm.queued, bm.training = .Soldier, 1, u16(train_ticks(.Soldier))
	playtest.step(rig, 5)
	testing.expect_value(t, len(own(s, 1, .Unit, .Soldier)), soldiers)
	testing.expect_value(t, bm.queued, 1)
}

@(test)
test_a_box_of_soldiers_arrives_around_its_point :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	defer playtest.stop(rig)
	if !playing(t, rig) {return}
	s := playtest.srv(rig)
	side := side_of(s, playtest.host(rig))
	soldiers := make([dynamic]game.Entity_Handle, context.temp_allocator)
	for i in 0 ..< 16 {
		p := game.Block_Pos {
			side.start.x + 4 + i32(i % 4),
			skirmish.GROUND,
			side.start.y + 6 + i32(i / 4),
		}
		append(&soldiers, unit_spawn(s, side, .Soldier, p))
	}
	goal := [2]i32{side.start.x + 20, side.start.y + 6}
	o := ids_of(s, soldiers[:])
	o.kind, o.at = .Move, {i16(goal.x), skirmish.GROUND, i16(goal.y)}
	core.harness_request(s, playtest.host(rig), &o)
	there :: proc(data: rawptr) -> bool {
		s := playtest.srv((^playtest.Rig)(data))
		for h in own(s, 1, .Unit, .Soldier) {if !mind(s.home, h).arrived {return false}}
		return true
	}
	testing.expect(t, playtest.until(rig, there, rig, 40), "the soldiers never all arrived")
	near := 0
	for h, i in soldiers {
		p := core.entity_pos(s.home, h)
		if math.abs(p.x - f64(goal.x)) < 6 && math.abs(p.z - f64(goal.y)) < 6 {near += 1}
		for other in soldiers[i + 1:] {
			q := core.entity_pos(s.home, other)
			testing.expect(
				t,
				math.abs(p.x - q.x) + math.abs(p.z - q.z) > 0.5,
				"two soldiers on one spot",
			)
		}
	}
	testing.expect_value(t, near, len(soldiers))
}

@(test)
test_an_order_for_another_sides_unit_is_refused :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	defer playtest.stop(rig)
	if !playing(t, rig) {return}
	s := playtest.srv(rig)
	theirs := own(s, 2, .Unit, .Worker)
	if !testing.expect(t, len(theirs) > 0) {return}
	before := core.entity_pos(s.home, theirs[0])
	o := ids_of(s, theirs[:1])
	o.kind, o.at = .Move, {10, skirmish.GROUND, 10}
	core.harness_request(s, playtest.host(rig), &o)
	testing.expect(t, playtest.told(rig, "1 of those are not yours to command"), "not told")
	testing.expect(
		t,
		mind(s.home, theirs[0]).order != .Move,
		"the computer's worker took the host's order",
	)
	_ = before
}

@(test)
test_armies_fight_and_the_larger_wins :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	defer playtest.stop(rig)
	if !playing(t, rig) {return}
	s := playtest.srv(rig)
	g := state(s)
	g.sides[1].human, g.sides[1].computer.wave = false, 1000 // (the computer holds its army)
	a, b := &g.sides[0], &g.sides[1]
	mid := [2]i32{MID - 30, MID + 30} // (the low ground of a corner, clear of the bases)
	for i in 0 ..< 9 {
		unit_spawn(s, a, .Soldier, {mid.x + i32(i % 3), skirmish.GROUND, mid.y - 4 + i32(i / 3)})
	}
	for i in 0 ..< 3 {
		unit_spawn(s, b, .Soldier, {mid.x + i32(i), skirmish.GROUND, mid.y + 4})
	}
	over :: proc(data: rawptr) -> bool {
		s := playtest.srv((^playtest.Rig)(data))
		return len(own(s, 2, .Unit, .Soldier)) == 0
	}
	testing.expect(t, playtest.until(rig, over, rig, 60), "the fight never ended")
	testing.expect(t, len(own(s, 1, .Unit, .Soldier)) > 0, "the larger army fell too")
	testing.expect(t, a.killed >= 3, "the kills were not counted")
}

@(test)
test_the_fog_sends_a_foe_only_once_seen :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	defer playtest.stop(rig)
	if !playing(t, rig) {return}
	s := playtest.srv(rig)
	c := playtest.host(rig)
	g := state(s)
	g.sides[1].computer.wave = 1000
	foe := unit_spawn(s, &g.sides[1], .Soldier, {MID, skirmish.GROUND, 8})
	scout := unit_spawn(s, &g.sides[0], .Archer, {12, skirmish.GROUND, MID + 20})
	playtest.step(rig, 10)
	id := core.entity_id(s.home, foe)
	testing.expect(t, !core.entity_known(c, id), "told of a foe no unit of its side sees")
	testing.expect(
		t,
		playtest.host_record(rig, skirmish.Unit_Record, protocol.key_entity(id)) == nil,
	)
	// The scout set by it: it is seen, and told.
	core.entity_go(s.home, scout, {MID - 3, f64(skirmish.GROUND), 8})
	mind(s.home, scout).order = .Move
	core.entity_set_pos(s.home, scout, {MID - 4, f64(skirmish.GROUND), 9})
	playtest.step(rig, 10)
	testing.expect(t, core.entity_known(c, id), "not told of the foe its archer sees")
}

@(test)
test_a_side_that_loses_its_headquarters_and_production_loses :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	defer playtest.stop(rig)
	if !playing(t, rig) {return}
	s := playtest.srv(rig)
	g := state(s)
	// The computer's headquarters falls (it has nothing else that trains yet).
	for h in own(s, 2, .Building, building = .Headquarters) {
		core.entity_harm(s.home, h, {amount = 100_000, kind = .Game})
	}
	testing.expect(t, playtest.until_phase(rig, &g.phase, .Results, 5), "the match did not end")
	testing.expect_value(t, g.winner, 1)
	testing.expect(t, g.sides[1].lost)
	playtest.step(rig, 3)
	m := playtest.host_record(rig, skirmish.Match)
	testing.expect(t, m != nil && m.phase == .Results && m.winner == 1)
	testing.expect_value(t, wins_of(g, core.client_name(playtest.host(rig))), 1)
	// Its blocks came down with it.
	corner := skirmish.building_corner(.Headquarters, g.sides[1].start)
	b, _ := core.block_at(s.home, {corner.x, skirmish.GROUND, corner.y})
	testing.expect_value(t, b, game.Block.Air)
	// A new match follows.
	testing.expect(t, playtest.until_phase(rig, &g.phase, .Playing, 40), "no new match")
	testing.expect_value(t, g.match, 2)
}

@(test)
test_the_computer_builds_and_attacks :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	defer playtest.stop(rig)
	if !playing(t, rig) {return}
	s := playtest.srv(rig)
	g := state(s)
	ai := &g.sides[1]
	ai.stock = {
		.Ore  = 3000,
		.Wood = 3000,
	} // (to see it through its build in a short test)
	ai.computer.wave = 3
	built :: proc(data: rawptr) -> bool {
		s := playtest.srv((^playtest.Rig)(data))
		for h in own(s, 2, .Building, building = .Barracks) {if mind(s.home, h).built {return true}}
		return false
	}
	testing.expect(t, playtest.until(rig, built, rig, 120), "the computer never put up a barracks")
	attacked :: proc(data: rawptr) -> bool {
		s := playtest.srv((^playtest.Rig)(data))
		return state(s).sides[1].computer.waves > 0
	}
	testing.expect(t, playtest.until(rig, attacked, rig, 120), "the computer never attacked")
	moving := 0
	for u in skirmish.Unit {
		if u == .Worker {continue}
		for h in own(s, 2, .Unit, u) {if mind(s.home, h).order == .Attack_Move {moving += 1}}
	}
	testing.expect(t, moving >= 3, "its wave is not on the move")
	testing.expect(
		t,
		len(own(s, 2, .Unit, .Worker)) >= skirmish.START_WORKERS,
		"it trained no workers",
	)
}

@(test)
test_two_players_play_two_sides :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	defer playtest.stop(rig)
	if !playing(t, rig, {guests = 1}) {return}
	s := playtest.srv(rig)
	// (the guest may have come after the first match began: a new one takes both)
	playtest.say(rig, "skirmish restart")
	g := state(s)
	testing.expect(t, playtest.until_phase(rig, &g.phase, .Playing, 60))
	host, guest := playtest.host(rig), playtest.guest(rig)
	a, b := side_of(s, host), side_of(s, guest)
	if !testing.expect(t, a != nil && b != nil, "a player plays no side") {return}
	testing.expect(t, a.team != b.team && a.human && b.human)
	testing.expect_value(t, core.client_team(host), a.team)
	testing.expect_value(t, core.client_team(guest), b.team)
	// Each is told its own economy, and both sides on the board.
	playtest.step(rig, 5)
	eco := playtest.guest_record(rig, skirmish.Economy)
	testing.expect(t, eco != nil && eco.team == b.team)
	// The guest may not order the host's workers.
	theirs := own(s, a.team, .Unit, .Worker)
	o := ids_of(s, theirs)
	o.kind, o.at = .Move, {10, skirmish.GROUND, 10}
	core.harness_request(s, guest, &o)
	testing.expect(t, playtest.guest_told(rig, "4 of those are not yours to command"))
}

// The settings and every player's wins are kept with the universe and read back.
@(test)
test_settings_and_wins_are_kept :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	defer playtest.stop(rig)
	if !playtest.start(t, rig, GAME) {return}
	s := playtest.srv(rig)
	g := state(s)
	g.settings.sides, g.settings.wave = 3, 9
	wins_add(g, "ana")
	wins_add(g, "ana")
	wins_add(g, "bo")
	out := strings.builder_make(context.temp_allocator)
	save(s, &out)
	g.settings, g.wins = skirmish.DEFAULT_SETTINGS, {}
	testing.expect(t, load(s, strings.to_string(out)))
	testing.expect_value(t, g.settings.sides, 3)
	testing.expect_value(t, g.settings.wave, 9)
	testing.expect_value(t, wins_of(g, "ana"), 2)
	testing.expect_value(t, wins_of(g, "bo"), 1)
	testing.expect(t, !load(s, "wins = -1 cy"), "a count out of bounds")
}
