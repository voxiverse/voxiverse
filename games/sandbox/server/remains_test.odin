package sandbox_server

import "core:log"
import "core:math"
import "core:os"
import "core:testing"

import "common:game"
import "common:worldgen"
import "server:core"
import "server:play"
import "server:playtest"

// The remains on a running sandbox (remains.odin): the court built round the dead gate as the
// player arrives, the spawn clear and the gate reached from it on foot; a vault built when a
// player comes near, its relic vault inside; the machines the sites keep; what is built remembered
// when the universe opens again; and a universe saved before there were remains given none.

// remains_session: a universe of the sandbox (g: GAME, named by the caller, whose frame holds
// what its slices point at) of seed, its home world Earth itself or one made from the seed,
// the local player joined at its spawn; its creatures coming by themselves if natural; false
// (the test told) when it never was.
@(private = "file")
remains_session :: proc(
	t: ^testing.T,
	sess: ^core.Session,
	g: core.Game,
	seed: i64,
	earth: bool,
	dir := "",
	natural := false,
) -> bool {
	config := core.Config {
		game              = g,
		seed              = seed,
		earth             = earth,
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

// site_built: a step function's test that the remains' site `index` is built.
@(private = "file")
Built_Wait :: struct {
	s:     ^core.Server,
	index: int,
}

@(private = "file")
site_built :: proc(data: rawptr) -> bool {
	b := (^Built_Wait)(data)
	rm := &world_of(b.s.home).remains
	return rm.planned && b.index < rm.count && remains_built(rm, rm.sites[b.index])
}

// walkable: a walker standing in block from reaches block to on foot (a block up at a time,
// down three at most) without leaving the columns of area.
@(private = "file")
walkable :: proc(
	s: ^core.Server,
	w: ^core.World,
	from, to: game.Block_Pos,
	area: Footprint,
) -> bool {
	queue := make([dynamic]game.Block_Pos, context.temp_allocator)
	seen := make(map[game.Block_Pos]bool, context.temp_allocator)
	append(&queue, from)
	seen[from] = true
	for i := 0; i < len(queue); i += 1 {
		p := queue[i]
		if p == to {return true}
		for d in ([4][2]i32{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
			for dy in ([]i32{1, 0, -1, -2, -3}) {
				q := p + {d.x, dy, d.y}
				if q.x < area.lo.x || q.x > area.hi.x || q.z < area.lo.y || q.z > area.hi.y {break}
				if dy == 1 { 	// (a jump: room over the head)
					over, _ := core.block_at(w, p + {0, 2, 0})
					if game.block_collides(&s.registry.blocks, over) {continue}
				}
				if !play.standable(s, w, q) {continue}
				if !seen[q] {
					seen[q] = true
					append(&queue, q)
				}
				break
			}
		}
	}
	return false
}

// A new universe's court is built round its home gate as the player arrives, on Earth and on
// a world of the seed's: the gate as it was and dead, the floor laid, the spawn clear, and the
// gate's front reached from the spawn on foot.
@(test)
test_remains_court_at_spawn :: proc(t: ^testing.T) {
	for run in ([]struct {
			seed:  i64,
			earth: bool,
		}{{33, false}, {7919, false}, {245489, false}, {33, true}, {91, true}}) {
		sess := new(core.Session)
		defer free(sess)
		if !remains_session(t, sess, GAME, run.seed, run.earth) {continue}
		defer core.session_stop(sess)
		s := &sess.h.srv
		w := s.home
		wait := Built_Wait{s, 0}
		_, built := core.harness_step_until(&sess.h, site_built, &wait, 600)
		if !testing.expectf(
			t,
			built,
			"seed %d earth %v: the court was never built",
			run.seed,
			run.earth,
		) {
			continue
		}
		rm := &world_of(w).remains
		court := rm.sites[0]
		home, _ := w.chunks.gen.home.?
		testing.expectf(
			t,
			len(w.gates) == 1 && w.gates[0].phase == .Dead,
			"seed %d earth %v: the gate is not dead",
			run.seed,
			run.earth,
		)
		for u in i32(0) ..< worldgen.GATE_SIZE.x {
			if worldgen.gate_cell(u, 1) != .Frame {continue}
			b, _ := core.block_at(w, worldgen.gate_at(home, u, 1))
			testing.expectf(t, b == .Gate_Ring, "seed %d: the frame at %d is %v", run.seed, u, b)
		}
		c := court_floor(court)
		floor, _ := core.block_at(w, {c.lo.x + 1, court.floor, c.lo.y + 1})
		testing.expectf(
			t,
			floor != .Air && floor != .Grass,
			"seed %d: the floor is %v",
			run.seed,
			floor,
		)
		spawn := w.spawn.position
		x, z := i32(math.floor(spawn.x)), i32(math.floor(spawn.z))
		from, standing := play.ground_at(s, w, x, i32(math.floor(spawn.y)), z, 6)
		if !testing.expectf(
			t,
			standing,
			"seed %d earth %v: nowhere to stand at the spawn %v",
			run.seed,
			run.earth,
			spawn,
		) {
			continue
		}
		front, _ := worldgen.gate_front(home)
		to := game.Block_Pos {
			i32(math.floor(front.x)),
			i32(math.floor(front.y)),
			i32(math.floor(front.z)),
		}
		area := Footprint{court.at.lo - 4, court.at.hi + 4}
		testing.expectf(
			t,
			walkable(s, w, from, to, area),
			"seed %d earth %v: the gate's front %v is not reached on foot from the spawn %v",
			run.seed,
			run.earth,
			to,
			from,
		)
		machines := 0
		for which in ([]Wild{.Sentry, .Tender, .Bulwark}) {
			machines += len(core.entities_of(w, state(s).wild[which], spawn, 64))
		}
		testing.expectf(
			t,
			machines == 0,
			"seed %d: %d machines in a still world",
			run.seed,
			machines,
		)
		log.infof(
			"remains court seed=%d earth=%v floor=%d land %d..%d spawn=%v",
			run.seed,
			run.earth,
			court.floor,
			court.lo,
			court.hi,
			from,
		)
	}
}

// A vault is built when a player comes near it, the survival loop's relic vault in its
// chamber, and goes into the player's logbook; the other scattered sites, out of reach, are
// not built.
@(test)
test_remains_vault_sealed :: proc(t: ^testing.T) {
	sess := new(core.Session)
	defer free(sess)
	if !remains_session(t, sess, GAME, 7919, false) {return}
	defer core.session_stop(sess)
	s := &sess.h.srv
	w := s.home
	rm := &world_of(w).remains
	core.harness_step(&sess.h, 1)
	vault := -1
	for site, i in rm.sites[:rm.count] {if site.kind == .Vault {vault = i}}
	if !testing.expect(t, vault >= 0, "seed 7919 has no vault") {return}
	site := rm.sites[vault]
	c := &s.clients[0]
	core.game_mode(s, c, "creative")
	above := [3]f64{f64(site.middle.x) + 0.5, f64(site.floor + 20), f64(site.middle.y) + 0.5}
	core.teleport(s, c, above, {0, -1.5}, flying = true)
	wait := Built_Wait{s, vault}
	_, built := core.harness_step_until(&sess.h, site_built, &wait, 900)
	if !testing.expect(t, built, "the vault was never built") {return}
	u := [2]i32{i32(site.along.x), i32(site.along.y)}
	at := site.middle - u
	b, _ := core.block_at(w, {at.x, site.floor + 1, at.y})
	testing.expect_value(t, b, state(s).remains_kit.relic_vault)
	core.harness_step(&sess.h, REMAINS_EVERY)
	noted := false
	for &p in c.logbook.places[:c.logbook.place_count] {
		noted ||= p.kind == .Remains && game.place_name(&p) == "Sealed vault"
	}
	testing.expect(t, noted, "the vault is not in the player's logbook")
	door, _ := core.block_at(w, {site.middle.x + 2 * u.x, site.floor + 2, site.middle.y + 2 * u.y})
	testing.expect_value(t, door, state(s).remains_kit.steel)
	far := 0
	for o in rm.sites[:rm.count] {
		d := [2]f64{f64(o.middle.x - site.middle.x), f64(o.middle.y - site.middle.y)}
		if d.x * d.x + d.y * d.y > 400 * 400 && remains_built(rm, o) {far += 1}
	}
	testing.expect_value(t, far, 0)
}

// machines_near: the roster's machines of kind which within radius blocks of p.
@(private = "file")
machines_near :: proc(s: ^core.Server, which: Wild, p: [3]f64, radius: f64) -> int {
	return len(core.entities_of(s.home, state(s).wild[which], p, radius))
}

// In a world whose creatures come by themselves, the court keeps one mender on its floor
// behind the gate and is marked for the watchers; no hostile machine keeps a post within the predators' safe
// distance of the spawn; a vault built far enough from it keeps a sentry asleep in the cut
// before its door.
@(test)
test_remains_keep_their_machines :: proc(t: ^testing.T) {
	sess := new(core.Session)
	defer free(sess)
	if !remains_session(t, sess, GAME, 7919, false, natural = true) {return}
	defer core.session_stop(sess)
	s := &sess.h.srv
	w := s.home
	rm := &world_of(w).remains
	wait := Built_Wait{s, 0}
	_, built := core.harness_step_until(&sess.h, site_built, &wait, 600)
	if !testing.expect(t, built, "the court was never built") {return}
	court := rm.sites[0]
	testing.expect_value(
		t,
		machines_near(s, .Tender, play.place_point(court_tender(court)), REMAINS_AT_POST),
		1,
	)
	middle := [3]f64{f64(court.middle.x) + 0.5, f64(court.floor) + 1, f64(court.middle.y) + 0.5}
	testing.expect(t, remains_near(s, w, middle, 1), "the court is not marked")
	safe := remains_safe(s)
	testing.expect(t, safe >= 64, "the predators' safe distance is not the widest")
	spawn := w.spawn.position
	for which in ([]Wild{.Sentry, .Bulwark}) {
		testing.expect_value(t, machines_near(s, which, spawn, safe), 0)
	}
	vault := -1
	for site, i in rm.sites[:rm.count] {if site.kind == .Vault {vault = i}}
	if !testing.expect(t, vault >= 0, "seed 7919 has no vault") {return}
	site := rm.sites[vault]
	u := [2]i32{i32(site.along.x), i32(site.along.y)}
	door := site.middle + u * 4
	sentry := [3]f64{f64(door.x) + 0.5, f64(site.floor) + 1, f64(door.y) + 0.5}
	d := sentry.xz - spawn.xz
	if !testing.expectf(
		t,
		d.x * d.x + d.y * d.y >= safe * safe,
		"seed 7919's vault is within %v of the spawn",
		safe,
	) {
		return
	}
	c := &s.clients[0]
	core.game_mode(s, c, "creative")
	above := [3]f64{f64(site.middle.x) + 0.5, f64(site.floor + 20), f64(site.middle.y) + 0.5}
	core.teleport(s, c, above, {0, -1.5}, flying = true)
	wait = Built_Wait{s, vault}
	_, built = core.harness_step_until(&sess.h, site_built, &wait, 900)
	if !testing.expect(t, built, "the vault was never built") {return}
	core.harness_step(&sess.h, 2)
	near := core.entities_of(w, state(s).wild[.Sentry], sentry, REMAINS_AT_POST)
	if !testing.expect_value(t, len(near), 1) {return}
	testing.expect_value(t, creature(s, w, near[0]).mind.state, play.Mind_State.Dormant)
}

// What is built is remembered with the world: opened again, the court is not built a second
// time over what became of it.
@(test)
test_remains_remembered :: proc(t: ^testing.T) {
	dir :: "build/tmp/sandbox_remains_saved"
	os.remove_all(dir)
	defer os.remove_all(dir)
	marker: game.Block_Pos
	{
		sess := new(core.Session)
		defer free(sess)
		if !remains_session(t, sess, GAME, 33, false, dir) {return}
		s := &sess.h.srv
		wait := Built_Wait{s, 0}
		_, built := core.harness_step_until(&sess.h, site_built, &wait, 600)
		rm := &world_of(s.home).remains
		testing.expect(t, built, "the court was never built")
		c := court_floor(rm.sites[0])
		marker = {c.lo.x + 1, rm.sites[0].floor, c.lo.y + 1}
		core.set_block(s.home, marker, .Planks, core.game_act(s, s.home, .Structure))
		core.session_stop(sess)
	}
	sess := new(core.Session)
	defer free(sess)
	if !remains_session(t, sess, GAME, 33, false, dir) {return}
	defer core.session_stop(sess)
	s := &sess.h.srv
	rm := &world_of(s.home).remains
	core.harness_step(&sess.h, 120)
	testing.expect(t, !rm.before, "a world of its own taken for one from before the remains")
	testing.expect(
		t,
		rm.planned && remains_built(rm, rm.sites[0]),
		"the court is not known to be built",
	)
	b, _ := core.block_at(s.home, marker)
	testing.expect_value(t, b, game.Block.Planks)
}

// A universe saved before there were remains (assets/fixtures/save-v8) gets none.
@(test)
test_remains_not_in_an_older_universe :: proc(t: ^testing.T) {
	dir :: "build/tmp/sandbox_remains_older"
	os.remove_all(dir)
	defer os.remove_all(dir)
	copy_dir("assets/fixtures/save-v8", dir)
	rig := new(Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME, {save_dir = dir}) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	playtest.step(rig, 120)
	rm := &world_of(s.home).remains
	testing.expect(t, rm.before, "the older world was not taken for one")
	testing.expect_value(t, rm.built_count, 0)
	testing.expect(t, !rm.planned, "remains were planned in it")
}
