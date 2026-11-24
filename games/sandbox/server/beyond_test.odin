package sandbox_server

import "core:log"
import "core:math"
import "core:os"
import "core:testing"

import "common:game"
import "common:starmap"
import "common:worldgen"
import "server:core"
import "server:playtest"

// The gate worlds' places (beyond.odin): planned for many worlds of each class, each clear of
// the arrival gate and its platform, of each other and of the spawn, the same each time from
// the same address; built on a running sandbox as a player comes near, in its logbook,
// humming, its cache's loot the class's, its machines posted; and one who dies on a gate world
// with no outpost standing again before its gate, one who leaves there coming back there.

BEYOND_UNIVERSE :: 4242 // the universe seed the plans are made in

// class_world: the n-th address of class (counting from first), and its land and generator
// as the server makes them in a universe of BEYOND_UNIVERSE (core's world_kind).
@(private = "file")
class_world :: proc(
	reg: ^game.Registry,
	class: worldgen.World_Class,
	first: u64,
) -> (
	a: starmap.Address,
	next: u64,
	gen: worldgen.Generator,
	land: Land,
) {
	k := first
	for {
		a = starmap.address_derive(k)
		k += 1
		if worldgen.world_class(a) == class {break}
	}
	params, _, _ := worldgen.class_params(class, a)
	seed := i64(u64(BEYOND_UNIVERSE) ~ starmap.address_hash(a) * 0x9e37_79b9_7f4a_7c15)
	gen = worldgen.generator_make(.Earth, seed, reg, params)
	land = {.Earth, seed, params, 0}
	return a, k, gen, land
}

// Over sixteen worlds of each class: a landmark in nearly every one and most of its sites, each
// at its distance from the arrival gate, clear of it, its platform and the spawn by
// BEYOND_CLEAR and of each other by BEYOND_APART, a platform in shallow sea; the same plan
// twice from the same address. What planning costs is logged (the land's columns asked).
@(test)
test_beyond_plan_over_many_worlds :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME) {return}
	defer playtest.stop(rig)
	reg := playtest.srv(rig).registry
	WORLDS :: 16
	for class in worldgen.World_Class {
		if class == .None {continue}
		landmarks, sites, samples, most := 0, 0, 0, 0
		next := u64(1)
		for _ in 0 ..< WORLDS {
			a: starmap.Address
			gen: worldgen.Generator
			land: Land
			a, next, gen, land = class_world(reg, class, next)
			spawn := worldgen.spawn_point(&gen)
			b: Beyond
			beyond_plan(&b, &land, &gen, class, a, spawn)
			samples += b.samples
			most = max(most, b.samples)
			gate, has_gate := worldgen.arrival_gate(&gen)
			if !testing.expectf(
				t,
				has_gate,
				"%v %s: no gate",
				class,
				starmap.address_dir(a),
			) {continue}
			lo, hi := worldgen.structure_reach(&gen, gate)
			reach := Footprint{{lo.x, lo.z}, {hi.x, hi.z}}
			middle := [2]f64{f64(lo.x + hi.x) / 2, f64(lo.z + hi.z) / 2}
			for p, i in b.places[:b.count] {
				if p.landmark {landmarks += 1} else {sites += 1}
				testing.expectf(
					t,
					!footprint_meets(p.at, reach, BEYOND_CLEAR - 1),
					"%v: a place on the arrival gate",
					class,
				)
				s := Footprint{{i32(spawn.x), i32(spawn.z)}, {i32(spawn.x), i32(spawn.z)}}
				testing.expectf(
					t,
					!footprint_meets(p.at, s, BEYOND_CLEAR - 1),
					"%v: a place on the spawn",
					class,
				)
				for o in b.places[i + 1:b.count] {
					testing.expectf(
						t,
						!footprint_meets(p.at, o.at, BEYOND_APART - 1),
						"%v: two places meet",
						class,
					)
				}
				d := [2]f64{f64(p.middle.x) - middle.x, f64(p.middle.y) - middle.y}
				r := math.sqrt(d.x * d.x + d.y * d.y)
				near, far := f64(BEYOND_SITE_FROM), f64(BEYOND_SITE_TO)
				if p.landmark {near, far = BEYOND_LANDMARK_FROM, BEYOND_LANDMARK_TO}
				testing.expectf(
					t,
					r >= near - 2 && r <= far + 2,
					"%v: a place %.0f blocks from the gate",
					class,
					r,
				)
				if p.landmark && class == .Ocean {
					testing.expectf(
						t,
						p.floor == land.params.sea_level && p.hi < p.floor,
						"the platform is not in the sea",
					)
				}
			}
			again: Beyond
			land.samples = 0
			beyond_plan(&again, &land, &gen, class, a, spawn)
			testing.expectf(
				t,
				again.places == b.places && again.count == b.count,
				"%v: another plan the second time",
				class,
			)
		}
		testing.expectf(
			t,
			landmarks >= WORLDS - 1,
			"%v: a landmark in %d of %d worlds",
			class,
			landmarks,
			WORLDS,
		)
		testing.expectf(t, sites >= WORLDS, "%v: %d sites in %d worlds", class, sites, WORLDS)
		log.infof(
			"beyond plan class=%v landmarks=%d sites=%d of %d worlds samples avg=%d most=%d",
			class,
			landmarks,
			sites,
			WORLDS,
			samples / WORLDS,
			most,
		)
	}
}

// beyond_session: a universe of the sandbox (g: GAME, named by the caller, whose frame holds
// what its slices point at; in dir, if any), its creatures coming by
// themselves if natural, the local player joined, then gone by /travel to the first world of
// class and standing in creative a little way off its arrival gate; false (the test told)
// when it never was.
@(private = "file")
beyond_session :: proc(
	t: ^testing.T,
	sess: ^core.Session,
	g: core.Game,
	class: worldgen.World_Class,
	natural := false,
	dir := "",
) -> (
	w: ^core.World,
	ok: bool,
) {
	config := core.Config {
		game              = g,
		seed              = BEYOND_UNIVERSE,
		view_radius       = 3,
		view_height       = 2,
		max_players       = 1,
		rules             = game.rules_still(),
		save_dir          = dir,
		no_natural_spawns = !natural,
	}
	if !testing.expect(t, core.session_start(sess, {}, false, with = config), "no server") {return}
	welcomed :: proc(data: rawptr) -> bool {return (^core.Session)(data).mirror.welcomed}
	if _, joined := core.harness_step_until(&sess.h, welcomed, sess, 600);
	   !testing.expect(t, joined, "never joined") {
		return
	}
	s := &sess.h.srv
	c := &s.clients[0]
	a := s.home.address
	for k := u64(1);; k += 1 {
		a = starmap.address_derive(k)
		a.galaxy = s.home.address.galaxy
		if worldgen.world_class(a) == class {break}
	}
	if !testing.expect_value(t, core.travel(s, c, a), "") {return}
	core.harness_step(&sess.h, 2)
	return c.world, true
}

// Planned: its plan, made as the world first ticks.
@(private = "file")
Beyond_Wait :: struct {
	w:     ^core.World,
	index: int,
}

@(private = "file")
place_built :: proc(data: rawptr) -> bool {
	b := (^Beyond_Wait)(data)
	be := beyond_of(b.w)
	return be.planned && b.index < be.count && beyond_built(be, be.places[b.index])
}

// On a moon: its landmark (the keepers' relay) is built as the player comes near, over its
// levelled pad: its relic vault and cache there, humming, in the player's logbook as a
// landmark by name, its two sentries folded at their posts; its cache spills the moon's
// loot beside the remains' own; the plan is remembered in the world's file.
@(test)
test_beyond_moon_relay_built :: proc(t: ^testing.T) {
	g := GAME
	sess := new(core.Session)
	defer free(sess)
	w, ok := beyond_session(t, sess, g, .Moon, natural = true)
	if !ok {return}
	defer core.session_stop(sess)
	s := &sess.h.srv
	c := &s.clients[0]
	be := beyond_of(w)
	core.harness_step(&sess.h, 1)
	if !testing.expect(
		t,
		be.planned && be.count > 0 && be.places[0].landmark,
		"no landmark planned",
	) {return}
	p := be.places[0]
	core.game_mode(s, c, "creative")
	above := [3]f64{f64(p.middle.x) + 0.5, f64(p.floor + 24), f64(p.middle.y) + 0.5}
	core.teleport(s, c, above, {0, -1.5}, flying = true)
	wait := Beyond_Wait{w, 0}
	if _, built := core.harness_step_until(&sess.h, place_built, &wait, 1200);
	   !testing.expect(t, built, "the relay was never built") {
		return
	}
	sv := survival_of(s)
	vaults, caches := 0, 0
	for x in p.at.lo.x ..= p.at.hi.x {
		for z in p.at.lo.y ..= p.at.hi.y {
			for y in p.floor ..= p.floor + 4 {
				b, _ := core.block_at(w, {x, y, z})
				if b == sv.relic_vault {vaults += 1}
				if b == sv.remains_cache {caches += 1}
			}
		}
	}
	testing.expect(t, vaults == 1 && caches == 1, "the relay holds no vault and cache")
	hums := false
	for h in w.hums {hums ||= h.at == {p.middle.x, p.floor + 1, p.middle.y} && h.strength == LANDMARK_HUM}
	testing.expect(t, hums, "the relay does not hum")
	core.teleport(s, c, above - {0, 18, 0}, {0, -1.5}, flying = true)
	core.harness_step(&sess.h, BEYOND_EVERY + 1)
	noted := false
	for &q in c.logbook.places[:c.logbook.place_count] {
		noted ||=
			q.kind == .Landmark && q.world == w.address && game.place_name(&q) == "Keepers' relay"
	}
	testing.expect(t, noted, "the relay is not in the player's logbook")
	centre := [3]f64{f64(p.middle.x) + 0.5, f64(p.floor + 1), f64(p.middle.y) + 0.5}
	testing.expect_value(t, len(core.entities_of(w, state(s).wild[.Sentry], centre, 12)), 2)
	// Its loot: the moon's beside the remains' own.
	moon := 0
	for _ in 0 ..< 40 {
		loot: [MAX_LOOT]game.Stack
		n := remains_loot(sv, &state(s).rng, false, &loot, .Moon)
		testing.expect_value(t, n, 1 + CACHE_ROLLS + 1)
		last := loot[n - 1].item
		for l in CLASS_LOOT[.Moon] {if sv.loot[l.what] == last {moon += 1}}
	}
	testing.expect_value(t, moon, 40)
	testing.expect_value(t, be.built_count, 1)
}

// One who dies on a gate world with no outpost stands again before its arrival gate (the
// death screen says so), not at the world's spawn thousands of blocks off.
@(test)
test_beyond_death_by_the_gate :: proc(t: ^testing.T) {
	g := GAME
	sess := new(core.Session)
	defer free(sess)
	w, ok := beyond_session(t, sess, g, .Temperate)
	if !ok {return}
	defer core.session_stop(sess)
	s := &sess.h.srv
	c := &s.clients[0]
	core.game_mode(s, c, "survival")
	where_, by_gate := gate_respawn(s, w)
	if !testing.expect(t, by_gate, "no gate to stand by") {return}
	testing.expect(t, outpost_respawn_where(s, c) != "", "the death screen says the world's spawn")
	core.damage(s, c, 1000, {kind = .Explosion})
	testing.expect(t, c.dead)
	testing.expect(t, core.respawn(s, c))
	core.harness_step(&sess.h, 60)
	testing.expect(t, c.world == w, "stood again in another world")
	d := c.player.position - where_.position
	testing.expectf(
		t,
		d.x * d.x + d.z * d.z < 4 * 4,
		"stood again at %v, not by the gate %v",
		c.player.position,
		where_.position,
	)
	// On the home world it is the world's spawn as before.
	_, home_gate := gate_respawn(s, s.home)
	testing.expect(t, !home_gate)
}

// One who leaves while on a gate world comes back there, where it was, when the universe
// opens again.
@(test)
test_beyond_left_on_a_gate_world :: proc(t: ^testing.T) {
	g := GAME
	dir := "build/test/beyond_left"
	os.remove_all(dir)
	defer os.remove_all(dir)
	at: [3]f64
	address: starmap.Address
	{
		sess := new(core.Session)
		defer free(sess)
		w, ok := beyond_session(t, sess, g, .Frozen, dir = dir)
		if !ok {return}
		c := &sess.h.srv.clients[0]
		core.harness_step(&sess.h, 60)
		at, address = c.player.position, w.address
		core.session_stop(sess)
	}
	config := core.Config {
		game        = g,
		seed        = BEYOND_UNIVERSE,
		view_radius = 3,
		view_height = 2,
		max_players = 1,
		rules       = game.rules_still(),
		save_dir    = dir,
	}
	sess := new(core.Session)
	defer free(sess)
	if !testing.expect(t, core.session_start(sess, {}, false, with = config), "no server") {return}
	defer core.session_stop(sess)
	welcomed :: proc(data: rawptr) -> bool {return (^core.Session)(data).mirror.welcomed}
	if _, joined := core.harness_step_until(&sess.h, welcomed, sess, 900);
	   !testing.expect(t, joined) {return}
	c := &sess.h.srv.clients[0]
	testing.expect_value(t, c.world.address, address)
	d := c.player.position - at
	testing.expectf(t, d.x * d.x + d.z * d.z < 1, "back at %v, left at %v", c.player.position, at)
}

// The quests through the gate done as a survivor does them, the first hour's behind it: a
// step onto another world, a landmark found there, its rare resource carried, and home again.
@(test)
test_beyond_quests_through_the_gate :: proc(t: ^testing.T) {
	g := GAME
	sess := new(core.Session)
	defer free(sess)
	w, ok := beyond_session(t, sess, g, .Temperate)
	if !ok {return}
	defer core.session_stop(sess)
	s := &sess.h.srv
	c := &s.clients[0]
	core.game_mode(s, c, "survival")
	reg := s.registry
	ours := []string {
		"sandbox:through_the_gate",
		"sandbox:a_far_landmark",
		"sandbox:something_to_bring_back",
		"sandbox:far_game",
		"sandbox:the_way_home",
	}
	quest :: proc(reg: ^game.Registry, id: string) -> int {q, _ := game.quest_by_id(reg, id)
		return q}
	for &def, q in reg.quests {
		mine := false
		for id in ours {mine ||= def.id == id}
		if !mine {c.quests.quests[q] = {u8(len(def.steps)), 0}}
	}
	// Home, then through to the temperate world again: the first step holds.
	testing.expect_value(t, core.travel(s, c, s.home.address), "")
	testing.expect(t, !game.quest_done(reg, &c.quests, quest(reg, "sandbox:through_the_gate")))
	testing.expect_value(t, core.travel(s, c, w.address), "")
	testing.expect(
		t,
		game.quest_done(reg, &c.quests, quest(reg, "sandbox:through_the_gate")),
		"the gate's quest not done",
	)
	amber, _ := game.registry_item(reg, "sandbox:amber")
	core.item_give(s, c, amber, 1)
	core.harness_step(&sess.h, 2)
	testing.expect(
		t,
		game.quest_done(reg, &c.quests, quest(reg, "sandbox:something_to_bring_back")),
		"the resource's quest not done",
	)
	core.logbook_place(s, c, .Landmark, {100, 10, 100}, "Standing ring")
	testing.expect(
		t,
		game.quest_done(reg, &c.quests, quest(reg, "sandbox:a_far_landmark")),
		"the landmark's quest not done",
	)
	testing.expect(t, game.quest_open(reg, &c.quests, quest(reg, "sandbox:the_way_home")))
	testing.expect_value(t, core.travel(s, c, s.home.address), "")
	testing.expect(
		t,
		game.quest_done(reg, &c.quests, quest(reg, "sandbox:the_way_home")),
		"the way home not done",
	)
}
