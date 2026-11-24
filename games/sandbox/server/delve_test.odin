package sandbox_server

import "core:log"
import "core:os"
import "core:testing"

import "common:game"
import "server:core"
import "server:play"

// A delve on a running sandbox (delve.odin, delve_boss.odin): built when a player comes near
// its stair head, as drawn; noted in the logbook; its blocks held but its caches; its traps,
// its locked door and its caches' loot; the custodian's fight won (its phases, its casing,
// its calls, the seal and the vault), lost by a death and by leaving the hall, and a server
// stopped mid-fight finding no seal and no fight.

DELVE_SEED :: 7919

// delve_session: a universe of the sandbox (g: GAME, named by the caller, whose frame holds
// what its slices point at) of seed (a world of the seed's), the local player joined at its
// spawn; false (the test told) when it never was.
@(private = "file")
delve_session :: proc(
	t: ^testing.T,
	sess: ^core.Session,
	g: core.Game,
	seed: i64,
	dir := "",
	natural := false,
) -> bool {
	config := core.Config {
		game              = g,
		seed              = seed,
		view_radius       = 3,
		view_height       = 2,
		max_players       = 1,
		rules             = game.rules_still(),
		save_dir          = dir,
		no_natural_spawns = !natural,
	}
	if !testing.expect(t, core.session_start(sess, {}, false, with = config), "no server") {
		return false
	}
	welcomed :: proc(data: rawptr) -> bool {return (^core.Session)(data).mirror.welcomed}
	_, ok := core.harness_step_until(&sess.h, welcomed, sess, 600)
	return testing.expect(t, ok, "the player never joined")
}

// delve_reached: the session's first delve, made ready with its player flying over its stair
// head (nil, the test told, when it never was).
@(private = "file")
delve_reached :: proc(t: ^testing.T, sess: ^core.Session) -> ^Delve {
	s := &sess.h.srv
	planned :: proc(data: rawptr) -> bool {
		s := (^core.Server)(data)
		return delves_of(s).planned
	}
	_, ok := core.harness_step_until(&sess.h, planned, s, 600)
	dv := delves_of(s)
	if !testing.expect(t, ok && dv.count > 0, "no delve was planned") {return nil}
	d := &dv.all[0]
	c := &s.clients[0]
	core.game_mode(s, c, "creative")
	m := d.site.middle
	above := [3]f64{f64(m.x) + 0.5, f64(d.site.floor + 12), f64(m.y) + 0.5}
	core.teleport(s, c, above, {0, -1.5}, flying = true)
	ready :: proc(data: rawptr) -> bool {
		s := (^core.Server)(data)
		return delves_of(s).all[0].ready
	}
	_, ok = core.harness_step_until(&sess.h, ready, s, 2400)
	if !testing.expect(t, ok, "the delve was never built and made ready") {return nil}
	return d
}

// fighter: the player, in survival and whole, set down in the custodian's hall facing it.
@(private = "file")
fighter :: proc(s: ^core.Server, d: ^Delve) -> ^core.Client {
	c := &s.clients[0]
	core.game_mode(s, c, "survival")
	core.heal_player(c, 1000)
	post := boss_post_point(d)
	door := boss_toward_door(d)
	at := post + {door.x * 3, 0, door.y * 3}
	core.teleport(s, c, at, play.look_at(at, post))
	return c
}

// first_of: the first block of the drawing that is `block`, in the world (false: none).
@(private = "file")
first_of :: proc(s: ^core.Server, d: ^Delve, block: game.Block) -> (game.Block_Pos, bool) {
	t := delve_cells(s, d)
	for c, i in t.cells {
		if c != u16(block) {continue}
		n := i32(i)
		l := [3]i32{n % t.size.x, n / (t.size.x * t.size.z), (n / t.size.x) % t.size.z}
		return d.origin + l, true
	}
	return {}, false
}

// blasted: what a blast of size 3 at `at` changed: the blocks within 4 of it that are not as
// they were (the temp allocator).
blasted :: proc(w: ^core.World, at: game.Block_Pos) -> []game.Block_Pos {
	R :: 4
	before := make(map[game.Block_Pos]game.Block, context.temp_allocator)
	for y in i32(-R) ..= R {
		for z in i32(-R) ..= R {
			for x in i32(-R) ..= R {
				b, _ := core.block_at(w, at + {x, y, z})
				before[at + {x, y, z}] = b
			}
		}
	}
	center := [3]f64{f64(at.x) + 0.5, f64(at.y) + 0.5, f64(at.z) + 0.5}
	core.explode(w, center, 3, core.world_act(w, .Explosion).action)
	changed := make([dynamic]game.Block_Pos, context.temp_allocator)
	for p, b in before {
		if now, _ := core.block_at(w, p); now != b {append(&changed, p)}
	}
	return changed[:]
}

// A blast carves the rock round a delve but none of its blocks: not its shells, not its
// caches, not its vault's ward, so nobody blows a way into the custodian's vault or round its
// seal (game.odin's kept, the blasting hook).
@(test)
test_delve_kept_from_blasts :: proc(t: ^testing.T) {
	sess := new(core.Session)
	defer free(sess)
	if !delve_session(t, sess, GAME, DELVE_SEED) {return}
	defer core.session_stop(sess)
	s := &sess.h.srv
	w := s.home
	d := delve_reached(t, sess)
	if d == nil {return}
	k := &delves_of(s).kit
	cells := delve_cells(s, d)
	ward := boss_ward_box(d)
	shaft := d.origin + {d.plan.entry.x + 2, d.plan.depths[0].floor + 10, d.plan.entry.y}
	carved := 0
	for at in ([]game.Block_Pos{(ward.lo + ward.hi) / 2, shaft}) {
		for p in blasted(w, at) {
			if !delve_within(d, p) {continue}
			cell := game.template_cell(&cells, delve_local(d, p), 0)
			testing.expectf(t, cell == game.VOID, "a blast broke the delve's block at %v", p)
			if cell == game.VOID {carved += 1}
		}
	}
	testing.expect(t, carved > 0, "no blast carved the rock round the delve")
	for y in ward.lo.y ..= ward.hi.y {
		for z in ward.lo.z ..= ward.hi.z {
			for x in ward.lo.x ..= ward.hi.x {
				b, _ := core.block_at(w, {x, y, z})
				testing.expectf(
					t,
					b == k.ward,
					"the vault's ward blown at %v",
					game.Block_Pos{x, y, z},
				)
			}
		}
	}
	if cache, ok := first_of(s, d, k.cache); testing.expect(t, ok, "no cache") {
		testing.expect(t, blasting(s, w, cache, k.cache) == false, "a blast may break a cache")
	}
	// Nor a relic vault or a remains cache anywhere (a gate world's landmark's): a hand opens
	// them with the tool they ask.
	rk := &state(s).remains_kit
	testing.expect(
		t,
		!blasting(s, w, {0, 200, 0}, rk.relic_vault),
		"a blast may open a relic vault",
	)
	testing.expect(t, !blasting(s, w, {0, 200, 0}, rk.remains_cache), "a blast may open a cache")
	testing.expect(t, blasting(s, w, {0, 200, 0}, .Stone), "a blast may not carve stone")
}

// A logbook from before delves had a place kind of their own (a stair head kept as remains,
// the third depth as a ruin, by their names) has them as delves once its player joins.
@(test)
test_delve_logbook_mends_old_places :: proc(t: ^testing.T) {
	sess := new(core.Session)
	defer free(sess)
	if !delve_session(t, sess, GAME, DELVE_SEED) {return}
	defer core.session_stop(sess)
	s := &sess.h.srv
	c := &s.clients[0]
	game.logbook_place(&c.logbook, .Remains, c.world.address, {700, 60, 20}, DELVE_STAIR)
	game.logbook_place(&c.logbook, .Ruin, c.world.address, {700, 30, 40}, DELVE_DEEP)
	game.logbook_place(&c.logbook, .Remains, c.world.address, {-300, 60, 20}, "Fallen tower")
	delve_joined(s, c)
	kinds: [3]game.Logbook_Place_Kind
	for &p in c.logbook.places[:c.logbook.place_count] {
		switch game.place_name(&p) {
		case DELVE_STAIR:
			kinds[0] = p.kind
		case DELVE_DEEP:
			kinds[1] = p.kind
		case "Fallen tower":
			kinds[2] = p.kind
		}
	}
	testing.expect_value(t, kinds, [3]game.Logbook_Place_Kind{.Delve, .Delve, .Remains})
}

@(test)
test_delve_built_as_drawn :: proc(t: ^testing.T) {
	sess := new(core.Session)
	defer free(sess)
	if !delve_session(t, sess, GAME, DELVE_SEED) {return}
	defer core.session_stop(sess)
	s := &sess.h.srv
	w := s.home
	d := delve_reached(t, sess)
	if d == nil {return}
	k := &delves_of(s).kit
	// Every block it draws is in the world (but the vault's ward and the seal, which the
	// fight keeps).
	cells := delve_cells(s, d)
	wrong := 0
	for c, i in cells.cells {
		if c == game.VOID {continue}
		n := i32(i)
		l := [3]i32 {
			n % cells.size.x,
			n / (cells.size.x * cells.size.z),
			(n / cells.size.x) % cells.size.z,
		}
		b, _ := core.block_at(w, d.origin + l)
		if u16(b) != c {wrong += 1}
	}
	testing.expectf(t, wrong == 0, "%d blocks are not as drawn", wrong)
	testing.expect_value(t, world_of(w).delves.count, 1)
	hums := false
	for h in w.hums {hums ||= h.at == {d.site.middle.x, d.site.floor + 1, d.site.middle.y}}
	testing.expect(t, hums, "the stair head does not hum")
	_, there := core.entity_find(w, d.fight.boss)
	testing.expect(t, there, "no custodian at its post")
	c := &s.clients[0]
	core.harness_step(&sess.h, DELVE_EVERY)
	noted := false
	for &p in c.logbook.places[:c.logbook.place_count] {
		noted ||= p.kind == .Delve && game.place_name(&p) == DELVE_STAIR
	}
	testing.expect(t, noted, "the stair head is not in the logbook")
	// Its blocks are held, but a cache; the rock round it and its air are the players'.
	wall := d.origin + {d.plan.entry.x + 2, d.plan.depths[0].floor + 10, d.plan.entry.y}
	b, _ := core.block_at(w, wall)
	testing.expect(t, delve_kept(s, c.world, wall, b) != "", "a shaft's wall is not held")
	if cache, ok := first_of(s, d, k.cache); testing.expect(t, ok, "no cache") {
		testing.expect_value(t, delve_kept(s, c.world, cache, k.cache), "")
	}
	rock := d.origin - {1, 0, 1}
	testing.expect_value(t, delve_kept(s, c.world, rock, .Stone), "")
	// A locked door: refused without a key, opened (all of it) by one, which is spent.
	if door, ok := first_of(s, d, k.door); testing.expect(t, ok, "no locked door") {
		testing.expect(t, machine_use(s, c, door) != "", "a door opened without a key")
		core.item_give(s, c, delves_of(s).key, 1)
		testing.expect_value(t, machine_use(s, c, door), "")
		testing.expect_value(t, core.item_count(c, delves_of(s).key), 0)
		left := 0
		for o in ([]game.Block_Pos{door, door + {0, 1, 0}, door + {0, 2, 0}}) {
			if at, _ := core.block_at(w, o); at == k.door {left += 1}
		}
		testing.expect_value(t, left, 0)
	}
	// A cache spills what its depth holds.
	if cache, ok := first_of(s, d, k.cache); ok {
		before := len(core.entities_of(w, s.registry.engine.item, play.place_point(cache), 3))
		delve_spill(s, w, cache)
		after := len(core.entities_of(w, s.registry.engine.item, play.place_point(cache), 3))
		testing.expect(t, after > before, "a cache spilled nothing")
	}
	// The traps hurt whoever steps on them, in survival.
	core.game_mode(s, c, "survival")
	if plate, ok := first_of(s, d, k.plate); ok {
		core.heal_player(c, 1000)
		at := play.place_point(plate + {0, 1, 0})
		core.teleport(s, c, at, {0, 0})
		core.harness_step(&sess.h, PLATE_DELAY + 4)
		testing.expectf(
			t,
			c.health < c.max_health,
			"a trip plate's darts missed (health %v)",
			c.health,
		)
	}
	if grid, ok := first_of(s, d, k.grid); ok {
		core.heal_player(c, 1000)
		at := play.place_point(grid + {0, 1, 0})
		core.teleport(s, c, at, {0, 0})
		core.harness_step(&sess.h, game.TICK_RATE + 2)
		testing.expectf(
			t,
			c.health < c.max_health,
			"a charged grating did not shock (health %v)",
			c.health,
		)
	}
}

@(test)
test_delve_custodian_fight_won :: proc(t: ^testing.T) {
	sess := new(core.Session)
	defer free(sess)
	if !delve_session(t, sess, GAME, DELVE_SEED) {return}
	defer core.session_stop(sess)
	s := &sess.h.srv
	w := s.home
	d := delve_reached(t, sess)
	if d == nil {return}
	k := &delves_of(s).kit
	f := &d.fight
	h, _ := core.entity_find(w, f.boss)
	most := core.entity_max_health(w, h)
	// Asleep, it takes no harm.
	core.entity_harm(w, h, {amount = 50, kind = .Game})
	testing.expect_value(t, core.entity_health_of(w, h), most)
	c := fighter(s, d)
	core.harness_step(&sess.h, 2)
	if !testing.expect(t, f.on, "the fight did not begin") {return}
	seal := boss_seal_box(d)
	b, _ := core.block_at(w, seal.lo)
	testing.expect_value(t, b, k.ward)
	ward, _ := core.block_at(w, boss_ward_box(d).lo)
	testing.expect_value(t, ward, k.ward)
	// Shut, its casing lets half through in the first phase; open, half as much again.
	core.harness_step(&sess.h, BOSS_WAKE + 1)
	core.heal_player(c, 1000)
	f.step = .Fighting
	core.entity_harm(w, h, {amount = 40, kind = .Game})
	testing.expect_value(t, core.entity_health_of(w, h), most - 20)
	f.step, f.timer = .Venting, 100
	core.entity_harm(w, h, {amount = 40, kind = .Game})
	testing.expect_value(t, core.entity_health_of(w, h), most - 80)
	f.step = .Fighting
	// Its phases by its health: the second calls scuttlers.
	phases := BOSS_PHASES
	core.entity_harm(
		w,
		h,
		{amount = 2 * (core.entity_health_of(w, h) - most * 6 / 10), kind = .Game},
	)
	core.heal_player(c, 1000)
	core.harness_step(&sess.h, 1)
	testing.expect_value(t, f.phase, 1)
	f.summon_due = 1
	core.harness_step(&sess.h, 2)
	testing.expect(t, f.add_count > 0, "it called no scuttlers")
	adds := f.adds
	add_count := f.add_count
	core.entity_harm(
		w,
		h,
		{
			amount = int(f32(core.entity_health_of(w, h) - most * 3 / 10) / phases[1].shut) + 1,
			kind = .Game,
		},
	)
	core.heal_player(c, 1000)
	core.harness_step(&sess.h, 1)
	testing.expect_value(t, f.phase, 2)
	// A slam hurts the fighter near it.
	core.heal_player(c, 1000)
	f.step, f.timer = .Charging, 1
	core.harness_step(&sess.h, 2)
	testing.expectf(t, c.health < c.max_health, "the slam missed (health %v)", c.health)
	testing.expect_value(t, f.step, Boss_Step.Venting)
	// Its death wins: the seal and the vault's ward fall, its reward drops in the vault, its
	// scuttlers are gone.
	core.heal_player(c, 1000)
	core.entity_harm(w, h, {amount = 10000, kind = .Game})
	core.harness_step(&sess.h, 1)
	testing.expect(t, !f.on && f.won, "the fight was not won")
	b, _ = core.block_at(w, seal.lo)
	testing.expect_value(t, b, game.Block.Air)
	ward, _ = core.block_at(w, boss_ward_box(d).lo)
	testing.expect_value(t, ward, game.Block.Air)
	reward := len(core.entities_of(w, s.registry.engine.item, boss_vault_point(d), 2))
	testing.expect(t, reward >= len(BOSS_REWARD), "the vault gave nothing")
	for id in adds[:add_count] {
		_, still := core.entity_find(w, id)
		testing.expect(t, !still, "a scuttler it called outlived it")
	}
	log.infof("delve fight won: %d stacks in the vault", reward)
}

@(test)
test_delve_fight_lost_and_restarted :: proc(t: ^testing.T) {
	dir :: "build/tmp/sandbox_delve_saved"
	os.remove_all(dir)
	defer os.remove_all(dir)
	{
		sess := new(core.Session)
		defer free(sess)
		if !delve_session(t, sess, GAME, DELVE_SEED, dir) {return}
		s := &sess.h.srv
		w := s.home
		d := delve_reached(t, sess)
		if d == nil {
			core.session_stop(sess)
			return
		}
		f := &d.fight
		k := &delves_of(s).kit
		// A death loses it: the seal falls, the custodian stands whole at its post again.
		c := fighter(s, d)
		core.harness_step(&sess.h, 2)
		testing.expect(t, f.on, "the fight did not begin")
		h, _ := core.entity_find(w, f.boss)
		core.harness_step(&sess.h, BOSS_WAKE + 1)
		f.step = .Fighting
		core.entity_harm(w, h, {amount = 100, kind = .Game})
		core.damage(s, c, 1000, {kind = .Fall})
		core.harness_step(&sess.h, 1)
		testing.expect(t, !f.on && !f.won, "a death did not lose the fight")
		b, _ := core.block_at(w, boss_seal_box(d).lo)
		testing.expect_value(t, b, game.Block.Air)
		h, _ = core.entity_find(w, f.boss)
		testing.expect_value(t, core.entity_health_of(w, h), core.entity_max_health(w, h))
		respawned :: proc(data: rawptr) -> bool {return !(^core.Client)(data).dead}
		core.respawn(s, c)
		core.harness_step_until(&sess.h, respawned, c, 120)
		// Leaving the hall (a recall) loses it too.
		c = fighter(s, d)
		core.harness_step(&sess.h, 2)
		testing.expect(t, f.on, "the fight did not begin again")
		head := game.Block_Pos{d.site.middle.x + 3, d.site.floor + 1, d.site.middle.y}
		core.teleport(s, c, play.place_point(head), {0, 0})
		core.harness_step(&sess.h, 1)
		testing.expect(t, !f.on, "leaving the hall did not end the fight")
		// The server stops mid-fight, its seal up.
		c = fighter(s, d)
		core.harness_step(&sess.h, 2)
		testing.expect(t, f.on, "the fight did not begin a third time")
		b, _ = core.block_at(w, boss_seal_box(d).lo)
		testing.expect_value(t, b, k.ward)
		core.session_stop(sess)
	}
	sess := new(core.Session)
	defer free(sess)
	if !delve_session(t, sess, GAME, DELVE_SEED, dir) {return}
	defer core.session_stop(sess)
	s := &sess.h.srv
	w := s.home
	ready :: proc(data: rawptr) -> bool {
		dv := delves_of((^core.Server)(data))
		return dv.count > 0 && dv.all[0].ready
	}
	_, ok := core.harness_step_until(&sess.h, ready, s, 2400)
	if !testing.expect(t, ok, "the delve was not made ready again") {return}
	d := &delves_of(s).all[0]
	core.harness_step(&sess.h, 2)
	c := &s.clients[0]
	testing.expect(t, d.built && !d.fight.on, "a fight outlived its session")
	b, _ := core.block_at(w, boss_seal_box(d).lo)
	testing.expect_value(t, b, game.Block.Air)
	testing.expect(t, !boss_in_hall(d, c.player.position), "the player was left in the hall")
	h, there := core.entity_find(w, d.fight.boss)
	testing.expect(
		t,
		there && core.entity_health_of(w, h) == core.entity_max_health(w, h),
		"no custodian whole at its post",
	)
	testing.expect_value(
		t,
		len(core.entities_of(w, state(s).wild[.Custodian], boss_post_point(d), 12)),
		1,
	)
}

// The world's file: what it reads, and what it refuses.
@(test)
test_delve_file :: proc(t: ^testing.T) {
	rec: Delve_Record
	testing.expect(t, delves_decode(&rec, "before\nbuilt 10 -20\n"))
	testing.expect(t, rec.before && rec.count == 1 && rec.built[0] == {10, -20})
	testing.expect(t, !delves_check(transmute([]u8)string("built 1\n")), "a cut line was taken")
	testing.expect(
		t,
		!delves_check(transmute([]u8)string("dug 1 2\n")),
		"an unknown line was taken",
	)
}
