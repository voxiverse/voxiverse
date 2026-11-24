package sandbox_server

import "core:math"
import "core:strings"

import "common:base"
import "common:game"
import "server:core"
import "server:play"

// The camps' people (settlement.odin): FOLK_SLOTS to a camp, each a kind of the pack's by
// its role (pack/data/entities/folk.json: sandbox:trader, mechanic, medic, scout, elder,
// guard), kept with the world. Which roles a camp has is its number's (CAMP_ROLES, nearest
// first): every camp a trader and a guard, the nearest an elder and the medic, the next the
// mechanic and a scout, the third an elder and a scout, so an errand from the medic to the
// mechanic crosses between camps. Each has a name from the camp's seed (person_name), its
// record on its entity (Creature.folk).
//
// Their minds (folk_think, server/play's minds): each keeps to its spot of the camp's layout
// by day, standing and now and then walking a little round it, and goes into its shelter at
// night or in the rain (the guards stand their watch at the gate whatever the hour); a
// player who comes near is watched, and one it talks with (talk.odin) is faced. A guard
// fights a creature that fights which comes into the camp. Nobody can hurt them
// (folk_harming): a blow, a shot or a blast does nothing to them. In a world whose creatures
// do not come by themselves (the scenes, the benchmarks) they stand still at their spots.

Role :: enum u8 {
	Trader,
	Mechanic,
	Medic,
	Scout,
	Elder,
	Guard,
}

FOLK_KINDS :: [Role]string {
	.Trader   = "sandbox:trader",
	.Mechanic = "sandbox:mechanic",
	.Medic    = "sandbox:medic",
	.Scout    = "sandbox:scout",
	.Elder    = "sandbox:elder",
	.Guard    = "sandbox:guard",
}

// CAMP_ROLES: the people of each camp, by its number (nearest first), slot by slot: its
// own, its trader, its third, its guard (Layout_Plan's slots).
CAMP_ROLES :: [SETTLEMENTS][FOLK_SLOTS]Role {
	{.Elder, .Trader, .Medic, .Guard},
	{.Mechanic, .Trader, .Scout, .Guard},
	{.Elder, .Trader, .Scout, .Guard},
}

FOLK_NEAR :: 32 // blocks: a player this near has a person think every tick
FOLK_WATCH :: 5 // ... this near is watched
FOLK_WANDER :: 3 // blocks a person walks round its day spot, at most, each way
FOLK_STRAY :: 1.5 // blocks past that it may stand before it walks back
FOLK_FOE :: SETTLEMENT_MID + 6 // blocks from the camp's middle within which a guard fights
FOLK_EYE :: 1.6
NIGHT_FROM :: 0.78 // a time of day from which the people shelter ...
NIGHT_UNTIL :: 0.22 // ... until this one
RAIN_SHELTER :: 0.3 // rain this hard sends them in

// Folk_Tag: who a person is: its camp (its number + 1; 0: not one of the camps' people), its
// slot there and its name (person_name).
Folk_Tag :: struct {
	camp: u8,
	slot: u8,
	name: u16,
}

// folk_start: the people's kinds, from the session's registry (the game's start).
folk_start :: proc(s: ^core.Server) -> bool {
	g := state(s)
	names := FOLK_KINDS
	for name, role in names {g.folk[role] = game.registry_kind(s.registry, name) or_return}
	return true
}

// folk_of: which role a kind is.
folk_of :: proc(s: ^core.Server, kind: game.Kind_Id) -> (Role, bool) {
	if kind == 0 {return {}, false}
	for k, role in state(s).folk {if k == kind {return role, true}}
	return {}, false
}

// person: a person's record and its camp (nil: not one of the camps' people, or its camp
// is not this world's).
person :: proc(
	s: ^core.Server,
	w: ^core.World,
	h: game.Entity_Handle,
) -> (
	^Creature,
	^Settlement,
) {
	if w != s.home {return nil, nil}
	if _, ours := folk_of(s, core.entity_kind(w, h)); !ours {return nil, nil}
	d := creature(s, w, h)
	ss := settlements_of(s)
	if d == nil || d.folk.camp == 0 || int(d.folk.camp) > ss.count {return nil, nil}
	return d, &ss.list[d.folk.camp - 1]
}

// folk_keep: camp i's people at their spots, each set down where it is missing (none of its
// kind of that camp and slot near), facing the camp's middle, standing still where creatures
// do not come by themselves.
folk_keep :: proc(s: ^core.Server, w: ^core.World, ss: ^Settlements, i: int) {
	st := &ss.list[i]
	roles := CAMP_ROLES
	plan := layout_of(st.layout)
	for slot in 0 ..< FOLK_SLOTS {
		role := roles[st.roles][slot]
		kind := state(s).folk[role]
		here := false
		for h in core.entities_of(w, kind, settlement_middle(st), SETTLEMENT_SIDE) {
			d := creature(s, w, h)
			here ||= d != nil && int(d.folk.camp) == i + 1 && int(d.folk.slot) == slot
		}
		if here {continue}
		at := settlement_point(st, plan.day[slot])
		h := core.entity_spawn(w, kind, at, false)
		if h == 0 {continue}
		d := creature(s, w, h)
		d.folk = {u8(i + 1), u8(slot), person_name_index(st.seed, slot)}
		d.mind.home, d.mind.settled = play.block_of(at), true
		d.still = s.config.no_natural_spawns
		to := settlement_middle(st) - at
		core.entity_set_look(w, h, f32(math.atan2(-to.x, -to.z)), 0)
	}
}

// folk_shelters: whether the people go in: at night, or in the rain.
folk_shelters :: proc(w: ^core.World) -> bool {
	t := game.time_of_day(w.clock)
	return t >= NIGHT_FROM || t < NIGHT_UNTIL || core.world_weather(w).rain >= RAIN_SHELTER
}

// folk_spot: where a person keeps now: its shelter at night or in the rain (a guard its
// post), else its day spot.
folk_spot :: proc(w: ^core.World, st: ^Settlement, role: Role, slot: u8) -> [3]f64 {
	plan := layout_of(st.layout)
	if role != .Guard && folk_shelters(w) {return settlement_point(st, plan.night[slot])}
	return settlement_point(st, plan.day[slot])
}

// folk_think: one person's tick (the think hook), unless it stands still for a picture.
folk_think :: proc(s: ^core.Server, w: ^core.World, role: Role, h: game.Entity_Handle) {
	d, st := person(s, w, h)
	if d == nil || d.still {return}
	m := &d.mind
	pos := core.entity_pos(w, h)
	near := seen(s, w, pos, FOLK_NEAR)
	if !play.mind_due(s, w, h, m, near != nil) {return}
	m.timer -= 1
	if c := talker(s, w, h); c != nil {
		core.entity_stand(w, h)
		play.face(w, h, c.player.position + {0, FOLK_EYE, 0}, FOLK_EYE, 0.3)
		play.mind_set(m, .Watch, game.TICK_RATE)
		return
	}
	if role == .Guard {
		if foe := camp_foe(s, w, st); foe != 0 {
			play.mind_set(m, .Fight, game.TICK_RATE)
			a, _ := game.kind_info(s.registry, core.entity_kind(w, h)).attack.?
			play.fight(w, h, foe, a.reach)
			return
		}
	}
	spot := folk_spot(w, st, role, d.folk.slot)
	m.home = play.block_of(spot)
	inside := role != .Guard && folk_shelters(w)
	range := 0.0 if inside || role == .Guard else f64(FOLK_WANDER)
	away := play.distance_to(pos, spot)
	r := &state(s).rng
	switch {
	case away > range + FOLK_STRAY:
		if m.state != .Return || m.timer <= 0 || core.entity_arrived(w, h) {
			core.entity_set_speed(w, h, 0)
			core.entity_go(w, h, spot)
			play.mind_set(m, .Return, game.TICK_RATE * 10)
		}
	case near != nil && play.distance_to(pos, near.player.position) <= FOLK_WATCH:
		if m.state != .Watch {core.entity_stand(w, h)}
		play.face(w, h, near.player.position + {0, FOLK_EYE, 0}, FOLK_EYE)
		play.mind_set(m, .Watch, game.TICK_RATE)
	case inside || range == 0:
		if m.state != .Rest {core.entity_stand(w, h)}
		play.mind_set(m, .Rest, game.TICK_RATE)
	case m.state == .Wander:
		if core.entity_arrived(w, h) || m.timer <= 0 {
			core.entity_stand(w, h)
			play.mind_set(m, .Idle, i32(base.rng_int_range(r, 60, 180)))
		}
	case m.timer <= 0:
		play.wander(w, h, r, spot, range)
		play.mind_set(m, .Wander, game.TICK_RATE * 6)
	case m.state != .Idle:
		core.entity_stand(w, h)
		play.mind_set(m, .Idle, i32(base.rng_int_range(r, 60, 180)))
	}
}

// camp_foe: a creature that fights (not one of the people) within FOLK_FOE blocks of the
// camp's middle (0: none), the nearest.
camp_foe :: proc(s: ^core.Server, w: ^core.World, st: ^Settlement) -> game.Entity_Handle {
	for h in core.entities_of(w, 0, settlement_middle(st), FOLK_FOE) {
		kind := core.entity_kind(w, h)
		info := game.kind_info(s.registry, kind)
		if info == nil || core.entity_health_of(w, h) <= 0 {continue}
		if _, fights := info.attack.?; !fights {continue}
		if _, folk := folk_of(s, kind); folk {continue}
		return h
	}
	return 0
}

// folk_harming: nobody hurts the camps' people (the harming hook): any harm to one is none.
folk_harming :: proc(s: ^core.Server, hm: ^core.Harming) {
	if hm.entity == 0 || hm.world == nil {return}
	if _, ours := folk_of(s, core.entity_kind(hm.world, hm.entity)); ours {hm.amount = 0}
}

// ---- names ----

// Two halves of a person's name, and of a camp's: our own, put together by a seed.
@(rodata)
NAME_FIRST := [?]string {
	"Ta",
	"Or",
	"Ma",
	"Se",
	"Bri",
	"I",
	"Ke",
	"Ny",
	"Pe",
	"Ru",
	"We",
	"Da",
	"Ha",
	"Jo",
	"Li",
	"Ve",
	"Ca",
	"Fen",
	"Gi",
	"Lo",
}
@(rodata)
NAME_LAST := [?]string {
	"vi",
	"ren",
	"ro",
	"lka",
	"nn",
	"dra",
	"sh",
	"la",
	"ll",
	"mo",
	"nna",
	"ce",
	"le",
	"ry",
	"sk",
	"be",
	"t",
	"ra",
	"mi",
	"dde",
}
@(rodata)
CAMP_FIRST := [?]string {
	"Ash",
	"Brack",
	"Cinder",
	"Dun",
	"Ember",
	"Fallow",
	"Gale",
	"Hearth",
	"Kettle",
	"Lumen",
	"Marrow",
	"Nettle",
	"Pike",
	"Quill",
	"Rust",
	"Salt",
	"Thorn",
	"Wick",
	"Yew",
	"Copper",
}
@(rodata)
CAMP_LAST := [?]string {
	" Hollow",
	" Rest",
	" Reach",
	" Crossing",
	" Fold",
	" Watch",
	" Haven",
	" Stead",
}

// person_name_index: the name of a camp's person in a slot (an index into the names, no two
// alike in a camp).
person_name_index :: proc(seed: u64, slot: int) -> u16 {
	n := u16(len(NAME_FIRST) * len(NAME_LAST))
	r := base.rng_make(seed ~ 0x9e3f_00d1)
	taken: [FOLK_SLOTS]u16
	for i in 0 ..= slot {
		taken[i] = u16(base.rng_int_max(&r, int(n)))
		for j in 0 ..< i {if taken[j] == taken[i] {taken[i] = (taken[i] + 1) % n}}
	}
	return taken[slot]
}

// person_name: the name an index makes.
person_name :: proc(index: u16) -> string {
	i := int(index)
	return strings.concatenate(
		{NAME_FIRST[i % len(NAME_FIRST)], NAME_LAST[(i / len(NAME_FIRST)) % len(NAME_LAST)]},
		context.temp_allocator,
	)
}

// camp_name: a camp's name from its seed.
camp_name :: proc(seed: u64) -> string {
	r := base.rng_make(seed ~ 0xca4d_5eed)
	first := CAMP_FIRST[base.rng_int_max(&r, len(CAMP_FIRST))]
	last := CAMP_LAST[base.rng_int_max(&r, len(CAMP_LAST))]
	return strings.concatenate({first, last}, context.temp_allocator)
}
