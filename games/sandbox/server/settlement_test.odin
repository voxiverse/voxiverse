package sandbox_server

import "core:os"
import "core:strings"
import "core:testing"

import "common:game"
import "server:core"
import "server:play"
import "server:playtest"

// A camp on a running sandbox (settlement.odin, folk.odin): set down whole with its people
// at their spots, in the logbook of a player near it, kept with its people, refusing the
// creatures that fight; its people keeping to the camp by day and to their shelters at night
// and in the rain, nobody hurting them, its guard fighting what comes in; its file.

// camp: the survivor on the meadow (survival_test.odin) and a ring camp with the first camp's
// people set down round it by the command, its people thinking (a test world's creatures
// stand still); the camp's index (-1, the test told, when there is none).
camp :: proc(t: ^testing.T, rig: ^Rig, layout := "ring", people := "1") -> int {
	if !survivor(t, rig) {return -1}
	s := playtest.srv(rig)
	ss := settlements_of(s)
	planned :: proc(data: rawptr) -> bool {return settlements_of((^core.Server)(data)).planned}
	if !testing.expect(t, playtest.until(rig, planned, s), "the camps never planned") {return -1}
	before := ss.count
	playtest.say(
		rig,
		strings.concatenate({"settlement ", layout, " ", people}, context.temp_allocator),
	)
	if !testing.expectf(t, ss.count == before + 1, "no camp set down (%d)", ss.count) {return -1}
	i := ss.count - 1
	for h in camp_folk(s, i) {creature(s, s.home, h).still = false}
	return i
}

// camp_folk: camp i's people (the temp allocator), by slot (0: none in it).
camp_folk :: proc(s: ^core.Server, i: int) -> []game.Entity_Handle {
	out := make([]game.Entity_Handle, FOLK_SLOTS, context.temp_allocator)
	st := &settlements_of(s).list[i]
	for h in core.entities_of(s.home, 0, settlement_middle(st), SETTLEMENT_SIDE) {
		if d, _ := person(s, s.home, h);
		   d != nil && int(d.folk.camp) == i + 1 {out[d.folk.slot] = h}
	}
	return out
}

@(test)
test_camp_set_down :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	i := camp(t, rig)
	defer playtest.stop(rig)
	if i < 0 {return}
	s := playtest.srv(rig)
	w := s.home
	h := playtest.host(rig)
	ss := settlements_of(s)
	st := &ss.list[i]
	testing.expect(t, ss.built[i])
	// Its fabricator, its people at their spots with their names, each kind its role's.
	fab := layout_of(st.layout).fabricator
	b, _ := core.block_at(
		w,
		{st.site.origin.x + fab.x, st.site.floor + 1, st.site.origin.z + fab.y},
	)
	testing.expect_value(t, b, state(s).camp_kit.fabricator)
	roles := CAMP_ROLES
	folk := camp_folk(s, i)
	names: [FOLK_SLOTS]u16
	for p, slot in folk {
		if !testing.expectf(t, p != 0, "nobody in slot %d", slot) {continue}
		role, _ := folk_of(s, core.entity_kind(w, p))
		testing.expect_value(t, role, roles[0][slot])
		names[slot] = creature(s, w, p).folk.name
		for j in 0 ..< slot {testing.expect(t, names[j] != names[slot], "two of a name")}
	}
	// Kept: nobody twice, one gone set down again.
	folk_keep(s, w, ss, i)
	testing.expect_value(
		t,
		len(core.entities_of(w, state(s).folk[.Trader], settlement_middle(st), SETTLEMENT_SIDE)),
		1,
	)
	core.entity_gone(w, folk[1])
	folk_keep(s, w, ss, i)
	testing.expect(t, camp_folk(s, i)[1] != 0, "the trader not set down again")
	// In the logbook of the player there, by its name (a find step's place).
	playtest.step(rig, SETTLEMENT_EVERY + 1)
	found := false
	for &p in h.logbook.places[:h.logbook.place_count] {
		found ||= p.kind == .Settlement && game.place_name(&p) == settlement_name(st)
	}
	testing.expect(t, found, "the camp is not in the logbook")
	// A creature that fights does not come by itself near it; one far off, or one that does
	// not fight, does.
	shambler, _ := game.registry_kind(s.registry, "voxiverse:shambler")
	loper, _ := game.registry_kind(s.registry, "sandbox:loper")
	near := core.entity_spawn(w, shambler, settlement_middle(st) + {6, 0, 0}, false)
	far := core.entity_spawn(
		w,
		shambler,
		settlement_middle(st) + {SETTLEMENT_GUARDED + 5, 0, 0},
		false,
	)
	grazer := core.entity_spawn(w, loper, settlement_middle(st) + {6, 0, 0}, false)
	testing.expect(t, !settlement_spawned(s, w, near))
	testing.expect(t, settlement_spawned(s, w, far))
	testing.expect(t, settlement_spawned(s, w, grazer))
}

// By day each keeps to its spot, walking a little round it, all inside the camp; at night
// and in the rain they go into their shelters (the guard keeps the gate).
@(test)
test_folk_keep_to_their_camp :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	i := camp(t, rig)
	defer playtest.stop(rig)
	if i < 0 {return}
	s := playtest.srv(rig)
	w := s.home
	h := playtest.host(rig)
	st := &settlements_of(s).list[i]
	plan := layout_of(st.layout)
	core.teleport(s, h, settlement_middle(st) + {0, 0, 40}, {0, 0}) // (watched by nobody)
	playtest.say(rig, "time set noon")
	for _ in 0 ..< 6 {
		playtest.step(rig, playtest.ticks(10))
		for p, slot in camp_folk(s, i) {
			at := core.entity_pos(w, p)
			testing.expectf(
				t,
				settlement_inside(st, at),
				"slot %d out of its camp at %v",
				slot,
				at,
			)
			d := play.distance_to(at, settlement_point(st, plan.day[slot]))
			testing.expectf(
				t,
				d <= FOLK_WANDER * 1.5 + FOLK_STRAY + 1,
				"slot %d %.1f from its spot",
				slot,
				d,
			)
		}
	}
	sheltered :: proc(
		t: ^testing.T,
		s: ^core.Server,
		i: int,
		st: ^Settlement,
		plan: Layout_Plan,
		why: string,
	) {
		for p, slot in camp_folk(s, i) {
			d := play.distance_to(
				core.entity_pos(s.home, p),
				settlement_point(st, plan.night[slot]),
			)
			testing.expectf(
				t,
				d <= FOLK_STRAY + 0.5,
				"%s: slot %d %.1f from its shelter",
				why,
				slot,
				d,
			)
		}
	}
	playtest.say(rig, "time set midnight")
	testing.expect(t, folk_shelters(w))
	playtest.step(rig, playtest.ticks(20))
	sheltered(t, s, i, st, plan, "at night")
	playtest.say(rig, "time set noon")
	playtest.step(rig, playtest.ticks(20))
	core.world_weather_set(w, .Rain)
	testing.expect(t, folk_shelters(w))
	playtest.step(rig, playtest.ticks(20))
	sheltered(t, s, i, st, plan, "in the rain")
}

// Nobody hurts them; the guard fights a creature that fights which comes into the camp.
@(test)
test_folk_unhurt_and_guarded :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	i := camp(t, rig)
	defer playtest.stop(rig)
	if i < 0 {return}
	s := playtest.srv(rig)
	w := s.home
	h := playtest.host(rig)
	st := &settlements_of(s).list[i]
	folk := camp_folk(s, i)
	before := core.entity_health_of(w, folk[0])
	died := core.entity_harm(w, folk[0], {amount = 1000, kind = .Hit, by = h})
	testing.expect(t, !died)
	testing.expect_value(t, core.entity_health_of(w, folk[0]), before)
	core.game_mode(s, h, "creative") // (the creature leaves it alone, and stands)
	core.teleport(s, h, settlement_middle(st) + {0, 0, 30}, {0, 0})
	playtest.say(rig, "time set noon")
	shambler, _ := game.registry_kind(s.registry, "voxiverse:shambler")
	foe := core.entity_spawn(w, shambler, settlement_point(st, GATE + {0, 4}), false)
	Wait :: struct {
		w:  ^core.World,
		id: u32,
	}
	gone :: proc(data: rawptr) -> bool {
		d := (^Wait)(data)
		_, there := core.entity_find(d.w, d.id)
		return !there
	}
	wait := Wait{w, core.entity_id(w, foe)}
	testing.expect(t, playtest.until(rig, gone, &wait, 30), "the guard never brought it down")
}

// The world's file: before, the camps built, refused when it is not one.
@(test)
test_settlements_file :: proc(t: ^testing.T) {
	ss: Settlements
	testing.expect(t, settlements_decode(&ss, "built 300 -12\n\nbuilt -40 500\n"))
	testing.expect_value(t, ss.unplanned_count, 2)
	testing.expect_value(t, ss.unplanned[1], [2]i32{-40, 500})
	testing.expect(t, !ss.before)
	before: Settlements
	testing.expect(t, settlements_decode(&before, "before\n") && before.before)
	testing.expect(t, !settlements_check(transmute([]u8)string("built 1\n")))
	testing.expect(t, !settlements_check(transmute([]u8)string("razed 1 2\n")))
	testing.expect(
		t,
		!settlements_check(transmute([]u8)string("built 1 2\nbuilt 3 4\nbuilt 5 6\nbuilt 7 8\n")),
	)
}

// Kept with the universe: a camp built is built still when the universe opens again, and
// one not built is not.
@(test)
test_settlements_saved :: proc(t: ^testing.T) {
	dir :: "build/tmp/sandbox_settlements_saved"
	os.remove_all(dir)
	defer os.remove_all(dir)
	middle: [2]i32
	{
		rig := new(Rig)
		defer free(rig)
		if !playtest.start(t, rig, GAME, {save_dir = dir}) {return}
		s := playtest.srv(rig)
		ss := settlements_of(s)
		planned :: proc(data: rawptr) -> bool {return settlements_of((^core.Server)(data)).planned}
		if !testing.expect(t, playtest.until(rig, planned, s)) {playtest.stop(rig); return}
		st := &ss.list[0]
		middle = st.middle
		ss.built[0], ss.dirty = true, true // (as if a player had come near)
		playtest.say(rig, "save")
		playtest.stop(rig)
	}
	rig := new(Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME, {save_dir = dir}) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	ss := settlements_of(s)
	planned :: proc(data: rawptr) -> bool {return settlements_of((^core.Server)(data)).planned}
	testing.expect(t, playtest.until(rig, planned, s))
	testing.expect(t, !ss.before)
	testing.expect_value(t, ss.list[0].middle, middle)
	testing.expect(t, ss.built[0], "the camp built is not built")
	testing.expect(t, !ss.built[1], "a camp not built is built")
}

// A world whose file says it is from before the camps plans none and builds none.
@(test)
test_settlements_before :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	world_of(s.home).settlements = {
		before = true,
	}
	playtest.step(rig, 60)
	ss := settlements_of(s)
	testing.expect(t, !ss.planned && ss.count == 0)
	playtest.say(rig, "settlement ring")
	testing.expect_value(t, ss.count, 1) // (the command's camp still: a developer's)
}
