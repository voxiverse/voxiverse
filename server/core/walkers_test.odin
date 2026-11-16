package core

import "core:math"
import "core:testing"

import "common:game"

// The walkers a game steers (walkers.odin), on a stepped server in the flat world (its
// ground is y -1: a walker stands in y 0), with a game whose pack has one steered kind,
// a creep that does not jump.

@(private = "file")
WALKERS_PACK :: `{"format": 1, "namespace": "walkers", "version": "1.0.0", "title": "Walkers", "requires": ["voxiverse"]}`
@(private = "file")
WALKERS_KINDS :: `{
	"creep": {"box": [0.6, 0.9], "health": 5, "hittable": true, "physics": "walker",
	          "walker": {"walk_speed": 4, "run_speed": 4, "jump": 0, "step": 0},
	          "brain": "steered", "model": {"box": [200, 60, 60]}},
	"brute": {"box": [0.8, 1.6], "health": 20, "hittable": true, "physics": "walker",
	          "walker": {"walk_speed": 3, "run_speed": 3, "jump": 1.2, "step": 0},
	          "brain": "steered", "attack": {"damage": 3, "reach": 1, "cooldown": 1},
	          "looks": ["striking"], "model": {"box": [90, 140, 60]}},
	"archer": {"box": [0.6, 1.7], "health": 8, "hittable": true, "physics": "walker",
	          "walker": {"walk_speed": 3, "run_speed": 3, "jump": 1.2, "step": 0},
	          "brain": "steered",
	          "attack": {"damage": 2, "reach": 1, "cooldown": 0.5, "shot": "walkers:bolt"},
	          "model": {"box": [60, 140, 90]}},
	"bolt": {"box": [0.2, 0.2], "physics": "projectile",
	         "projectile": {"speed": 24, "gravity": 0, "life": 3, "explode": 0},
	         "model": "rocket"}
}`

// The ground the tests walk on.
@(private = "file")
GROUND :: Box{{-16, 0, -16}, {24, 3, 16}}

// Rig: the harness and the game's pack files, which live as long as it.
@(private = "file")
Rig :: struct {
	h:     Harness,
	files: [2]game.Pack_File,
}

@(private = "file")
walkers_start :: proc(
	t: ^testing.T,
	rig: ^Rig,
	hooks := Game{},
) -> (
	kind: game.Kind_Id,
	ok: bool,
) {
	h := &rig.h
	rig.files = {
		{"pack.json", transmute([]u8)string(WALKERS_PACK)},
		{"data/entities/creep.json", transmute([]u8)string(WALKERS_KINDS)},
	}
	config := harness_world()
	config.game = hooks
	config.game.info = {
		id   = "walkers",
		name = "Walkers",
	}
	config.game.pack = {"walkers", rig.files[:]}
	if !testing.expect(t, harness_start(h, config)) {return}
	w := h.srv.home
	world_keep(w, {GROUND.lo - {0, 16, 0}, GROUND.hi})
	ready :: proc(data: rawptr) -> bool {
		w := (^World)(data)
		return world_ready(w, {GROUND.lo - {0, 16, 0}, GROUND.hi})
	}
	_, loaded := harness_step_until(h, ready, w, 300)
	if !testing.expect(t, loaded, "the ground never loaded") {return}
	kind, ok = game.registry_kind(h.srv.registry, "walkers:creep")
	testing.expect(t, ok, "no creep in the registry")
	return
}

// wall: blocks x, z from..to, y 0 and 1 (a creep does not climb).
@(private = "file")
wall :: proc(w: ^World, x, z_from, z_to: i32) {
	bulk_edit(
		w,
		{shape = Box{{x, 0, z_from}, {x, 1, z_to}}, op = .Set, block = .Stone},
		world_act(w, .Structure),
	)
}

// walk: steps until the walker arrived (or `most` ticks), and says whether it ever
// stood in a block of the box.
@(private = "file")
walk :: proc(
	h: ^Harness,
	e: game.Entity_Handle,
	avoid: Box,
	most := 600,
) -> (
	arrived, through: bool,
) {
	w := h.srv.home
	for _ in 0 ..< most {
		harness_step(h)
		p := entity_pos(w, e)
		at := game.Block_Pos{floor_i32(p.x), floor_i32(p.y + 0.01), floor_i32(p.z)}
		if box_has(avoid, at) {through = true}
		if entity_arrived(w, e) {return true, through}
	}
	return
}

@(private = "file")
floor_i32 :: proc(x: f64) -> i32 {
	i := i32(x)
	return i - 1 if f64(i) > x else i
}

// A creep follows a route round a wall to its goal, and never through it; a wall built
// across its way while it walks sends it round the new one (the route is searched again,
// once).
@(test)
test_walker_follows_a_route :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	h := &rig.h
	kind, ok := walkers_start(t, rig)
	if !ok {
		harness_stop(h)
		return
	}
	defer harness_stop(h)
	w := h.srv.home
	wall(w, 4, -6, 6)
	route, made := route_make(w, GROUND, {-12, 0, 0}, {20, 0, 0}, kind)
	if !testing.expect(t, made) {return}
	testing.expect(t, route_reaches(w, route, {-12, 0, 0}))
	cost, _ := route_cost(w, route, {-12, 0, 0})
	testing.expectf(t, cost > 33, "the way does not go round the wall: %v", cost)
	e := entity_spawn(w, kind, {-11.5, 0, 0.5}, false)
	if !testing.expect(t, e != 0 && entity_follow(w, e, route)) {return}
	arrived, through := walk(h, e, {{4, 0, -6}, {4, 1, 6}})
	testing.expect(t, arrived, "the creep never arrived")
	testing.expect(t, !through, "the creep walked through the wall")
	p := entity_pos(w, e)
	testing.expectf(t, abs(p.x - 20.5) < 0.7 && abs(p.z - 0.5) < 0.7, "arrived at %v", p)

	// Again from the start; halfway, a second wall goes up across its way.
	e2 := entity_spawn(w, kind, {-11.5, 0, 0.5}, false)
	entity_follow(w, e2, route)
	harness_step(h, 20)
	builds := w.entities.walkers.builds
	wall(w, 12, -16, 8) // (round its end, at z 9 and beyond)
	arrived, through = walk(h, e2, {{12, 0, -16}, {12, 1, 8}})
	testing.expect(t, arrived && !through, "the creep did not go round the new wall")
	testing.expect_value(t, w.entities.walkers.builds, builds + 1)
	route_free(w, route)
	testing.expect(t, !entity_follow(w, e2, route), "followed a route that is gone")
}

// route_would_shut: a block in the last gap of a wall would leave the start with no
// way, as would one that walls a creep in where it stands; elsewhere it would not. Asking
// changes nothing.
@(test)
test_route_would_shut :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	h := &rig.h
	kind, ok := walkers_start(t, rig)
	if !ok {
		harness_stop(h)
		return
	}
	defer harness_stop(h)
	w := h.srv.home
	wall(w, 4, -16, -1) // a wall across the ground with a gap at z 0
	wall(w, 4, 1, 16)
	route, _ := route_make(w, GROUND, {-12, 0, 0}, {20, 0, 0}, kind)
	testing.expect(
		t,
		route_would_shut(w, route, {4, 0, 0}, .Stone),
		"the gap's block did not shut it",
	)
	testing.expect(
		t,
		!route_would_shut(w, route, {8, 0, 3}, .Stone),
		"a block in the open shut it",
	)
	testing.expect(t, route_reaches(w, route, {-12, 0, 0}), "asking shut the way")

	// A creep boxed in on three sides: the fourth would shut its way (not the start's).
	e := entity_spawn(w, kind, {10.5, 0, 10.5}, false)
	entity_follow(w, e, route)
	for p in ([]game.Block_Pos{{9, 0, 10}, {10, 0, 9}, {10, 0, 11}}) {
		bulk_edit(
			w,
			{shape = Box{p, p + {0, 1, 0}}, op = .Set, block = .Stone},
			world_act(w, .Structure),
		)
	}
	testing.expect(t, route_would_shut(w, route, {11, 0, 10}, .Stone), "walled a creep in")
	testing.expect(t, !route_would_shut(w, route, {11, 0, 12}, .Stone))
}

// entity_go: a creep goes to a point by its own path, round a wall; a block put on the
// way it planned makes it plan again, and it does not walk into it.
@(test)
test_walker_goes_to_a_point :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	h := &rig.h
	kind, ok := walkers_start(t, rig)
	if !ok {
		harness_stop(h)
		return
	}
	defer harness_stop(h)
	w := h.srv.home
	wall(w, 0, -4, 4)
	e := entity_spawn(w, kind, {-5.5, 0, 0.5}, false)
	testing.expect(t, entity_go(w, e, {6.5, 0, 0.5}))
	harness_step(h, 3)
	st := entity_steer(w, e)
	if !testing.expect(t, st != nil && st.path.count > 0, "no way planned") {return}
	// A pillar on the planned way, a few steps ahead.
	ahead := st.path.steps[min(st.step + 3, st.path.count - 1)]
	bulk_edit(
		w,
		{shape = Box{ahead, ahead + {0, 1, 0}}, op = .Set, block = .Stone},
		world_act(w, .Structure),
	)
	arrived, through := walk(h, e, {ahead, ahead + {0, 1, 0}})
	testing.expect(t, arrived, "the creep never arrived")
	testing.expect(t, !through, "the creep walked into the pillar")

	// A sheep is no steered walker; standing stops it.
	testing.expect(t, entity_go(w, e, {-5.5, 0, 0.5}))
	entity_stand(w, e)
	harness_step(h, 10)
	testing.expect(t, !entity_arrived(w, e))
	sheep := entity_spawn(w, h.srv.registry.engine.sheep, {0.5, 0, 8.5}, false)
	testing.expect(t, !entity_go(w, sheep, {0.5, 0, 0.5}), "steered a sheep")
}

// entities_of: the creeps near a point, nearest first; one beyond the radius is not
// among them. A game sets a creep's most health (both its health and its most).
@(test)
test_entities_of_and_max_health :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	h := &rig.h
	kind, ok := walkers_start(t, rig)
	if !ok {
		harness_stop(h)
		return
	}
	defer harness_stop(h)
	w := h.srv.home
	far := entity_spawn(w, kind, {9.5, 0, 0.5}, false)
	near := entity_spawn(w, kind, {2.5, 0, 0.5}, false)
	mid := entity_spawn(w, kind, {5.5, 0, 0.5}, false)
	harness_step(h)
	found := entities_of(w, kind, {0.5, 0, 0.5}, 6)
	testing.expect_value(t, len(found), 2)
	if len(found) == 2 {testing.expect(t, found[0] == near && found[1] == mid)}
	testing.expect_value(t, len(entities_of(w, kind, {0.5, 0, 0.5}, 20)), 3)
	_ = far
	testing.expect_value(t, entity_max_health(w, near), 5)
	entity_set_max_health(w, near, 40)
	testing.expect_value(t, entity_health_of(w, near), 40)
	testing.expect_value(t, entity_max_health(w, near), 40)
}

// The walkers' budget scene (`build bench budgets` times it): 200 walkers on one route
// go their way, and every wall that goes up across it has the route searched again.
@(test)
test_budget_walkers_walk :: proc(t: ^testing.T) {
	r, ok := budget_walkers()
	testing.expect(t, ok, "the scene did not start")
	testing.expectf(
		t,
		r.moved >= BUDGET_WALKERS * 9 / 10,
		"only %d walkers went their way",
		r.moved,
	)
	testing.expectf(t, r.builds >= 5, "the route was searched %d times", r.builds)
}

// The fighters' budget scene (`build bench budgets` times it): 150 creatures hunting a
// circling point strike (half as many blows as there are of them, at least: they meet
// as they close in) and do not stand inside each other.
@(test)
test_budget_fighters_fight :: proc(t: ^testing.T) {
	r, ok := budget_fighters()
	testing.expect(t, ok, "the scene did not start")
	testing.expectf(t, r.struck >= BUDGET_FIGHTERS / 2, "only %d blows landed", r.struck)
	testing.expectf(t, r.apart >= BUDGET_FIGHTERS / 2, "only %d stood apart", r.apart)
}

// What the entity hooks were told (the test game's state).
@(private = "file")
Told :: struct {
	hurt, died: int,
	harm:       Entity_Harm, // the last
	dead:       Dead_Entity,
	health:     int, // the hurt one's, when told
}

// An entity's harm goes through entity_harm and the game hears of it: hurt and alive
// (its health already less), then dead (gone, with what and where it was), with what
// did it and who. A blast's harm is the blast's; a game's own is the game's.
@(test)
test_entity_harm_tells_the_game :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	h := &rig.h
	hooks := Game {
		server_state = Told,
		entity_hurt = proc(s: ^Server, w: ^World, e: game.Entity_Handle, harm: Entity_Harm) {
			told := game_state(s, Told)
			told.hurt += 1
			told.harm, told.health = harm, entity_health_of(w, e)
		},
		entity_died = proc(s: ^Server, w: ^World, dead: Dead_Entity, harm: Entity_Harm) {
			told := game_state(s, Told)
			told.died += 1
			told.harm, told.dead = harm, dead
		},
	}
	kind, ok := walkers_start(t, rig, hooks)
	if !ok {
		harness_stop(h)
		return
	}
	defer harness_stop(h)
	s := &h.srv
	w := s.home
	told := game_state(s, Told)
	e := entity_spawn(w, kind, {3.5, 0, 0.5}, false)
	id := entity_id(w, e)

	// The game's tower: hurt, alive.
	testing.expect(t, !entity_harm(w, e, {amount = 2, kind = .Game}))
	testing.expect_value(t, told.hurt, 1)
	testing.expect_value(t, told.health, 3)
	testing.expect_value(t, told.harm.kind, game.Source_Kind.Game)
	testing.expect(t, told.harm.by == nil)

	// A player's blow (the seat stands for a player here) kills it at nought.
	hitter := &s.clients[1]
	testing.expect(t, !entity_attack(w, e, {0, 0, 0.5}, {amount = 1, kind = .Hit, by = hitter}))
	testing.expect(t, entity_attack(w, e, {0, 0, 0.5}, {amount = 5, kind = .Hit, by = hitter}))
	testing.expect_value(t, told.died, 1)
	testing.expect_value(t, told.dead.id, id)
	testing.expect_value(t, told.dead.kind, kind)
	testing.expect(t, told.harm.by == hitter && told.harm.kind == .Hit)
	testing.expect(t, !entity_listed(w, e), "a dead creep is still there")
	testing.expect(t, !entity_harm(w, e, {amount = 1, kind = .Game}), "harmed a dead creep")
	testing.expect_value(t, told.died, 1)

	// A blast nobody set off: the explosion's, by nobody.
	other := entity_spawn(w, kind, {-3.5, 0, 0.5}, false)
	harness_step(h) // (the spatial service has it)
	explode(w, {-3.5, 0.5, 0.5}, 1, 0)
	testing.expect_value(t, told.hurt, 3)
	testing.expect(t, told.harm.kind == .Explosion && told.harm.by == nil)
	testing.expect_value(t, entity_health_of(w, other), 2)
}

// --- Creatures that fight ------------------------------------------------------

// Fight: a test game's record of how its player was hurt and died.
@(private = "file")
Fight :: struct {
	hurt:  int,
	died:  bool,
	harm:  Harm, // the last
	lines: int,
}

@(private = "file")
Fight_Rig :: struct {
	sess:  Session,
	files: [2]game.Pack_File,
}

// fight_start: the walkers' pack in a stepped session whose mirror player (survival)
// stands at the spawn, 0.5 0 0.5, its hurts and death counted.
@(private = "file")
fight_start :: proc(t: ^testing.T, rig: ^Fight_Rig) -> bool {
	rig.files = {
		{"pack.json", transmute([]u8)string(WALKERS_PACK)},
		{"data/entities/creep.json", transmute([]u8)string(WALKERS_KINDS)},
	}
	config := harness_world()
	config.mode = "survival"
	config.game = {
		info = {id = "walkers", name = "Walkers"},
		pack = {"walkers", rig.files[:]},
		server_state = Fight,
		hurt = proc(s: ^Server, c: ^Client, harm: Harm) {
			f := game_state(s, Fight)
			f.hurt += 1
			f.harm = harm
		},
		died = proc(s: ^Server, c: ^Client, harm: Harm) {
			f := game_state(s, Fight)
			f.died, f.harm = true, harm
		},
	}
	if !testing.expect(t, session_start(&rig.sess, {}, false, with = config)) {return false}
	ready :: proc(data: rawptr) -> bool {
		rig := (^Fight_Rig)(data)
		s := &rig.sess.h.srv
		return(
			rig.sess.mirror.welcomed &&
			s.clients[0].state == .Playing &&
			world_ready(s.home, {GROUND.lo - {0, 16, 0}, GROUND.hi}) \
		)
	}
	world_keep(rig.sess.h.srv.home, {GROUND.lo - {0, 16, 0}, GROUND.hi})
	_, ok := harness_step_until(&rig.sess.h, ready, rig, 600)
	return testing.expect(t, ok, "never played")
}

// A brute set on the player (keep 0..reach, strike each tick) walks to it and strikes
// by its kind's numbers, a blow a second, the blows credited to it; the player dies of
// it and the line names it.
@(test)
test_creature_chases_and_strikes :: proc(t: ^testing.T) {
	rig := new(Fight_Rig)
	defer free(rig)
	if !fight_start(t, rig) {
		session_stop(&rig.sess)
		return
	}
	defer session_stop(&rig.sess)
	s := &rig.sess.h.srv
	w := s.home
	c := &s.clients[0]
	brute, _ := game.registry_kind(s.registry, "walkers:brute")
	e := entity_spawn(w, brute, {-9.5, 0, 0.5}, false)
	if !testing.expect(t, e != 0) {return}
	testing.expect_value(t, entity_strike(w, e, c), Strike.Too_Far)
	f := game_state(s, Fight)
	full := c.health
	first := -1
	striking := false
	for tick in 0 ..< 600 {
		if c.dead {break}
		entity_keep(w, e, c.player.position, 0, 0.6)
		if entity_strike(w, e, c) == .Hit && first < 0 {
			first = tick
			testing.expect_value(t, c.health, full - 3)
			testing.expect_value(t, entity_strike(w, e, c), Strike.Not_Ready)
		}
		striking ||= entity_looks(w, s.registry, e) != 0
		harness_step(&rig.sess.h)
	}
	testing.expectf(t, first > 0 && first < 120, "the first blow came at tick %d", first)
	testing.expect(t, striking, "the brute never showed its Striking look")
	testing.expect(t, f.died, "the player never died")
	testing.expect_value(t, f.harm.creature, entity_id(w, e))
	testing.expect_value(t, f.harm.kind, game.Source_Kind.Hit)
	testing.expect_value(t, f.harm.by, (^Client)(nil))
	// The blows were a second apart: the player's 20 health took 7 blows.
	testing.expectf(t, f.hurt == 6, "hurt %d times before dying", f.hurt)
	line := game.death_text(.Hit, "p", attacker_name_of(s, f.harm), "", false)
	testing.expect_value(t, line, "p was beaten by brute")
}

// attacker_name_of: the name a harm's creature goes by (its kind's).
@(private = "file")
attacker_name_of :: proc(s: ^Server, harm: Harm) -> string {
	h, there := entity_find(s.home, harm.creature)
	if !there {return ""}
	return game.kind_name(game.kind_info(s.registry, entity_kind(s.home, h)))
}

// An archer told to keep 5..7 blocks from the player backs away when too near, closes
// in when too far, and its bolts, shot when ready and in sight, hurt the player by its
// attack's damage, credited to it; a wall between them hides the player from it.
@(test)
test_creature_keeps_its_distance_and_shoots :: proc(t: ^testing.T) {
	rig := new(Fight_Rig)
	defer free(rig)
	if !fight_start(t, rig) {
		session_stop(&rig.sess)
		return
	}
	defer session_stop(&rig.sess)
	s := &rig.sess.h.srv
	w := s.home
	c := &s.clients[0]
	archer, _ := game.registry_kind(s.registry, "walkers:archer")
	e := entity_spawn(w, archer, {2.5, 0, 0.5}, false)
	if !testing.expect(t, e != 0) {return}
	distance :: proc(w: ^World, e: game.Entity_Handle, c: ^Client) -> f64 {
		d := entity_pos(w, e) - c.player.position
		return math.sqrt(d.x * d.x + d.z * d.z)
	}
	for _ in 0 ..< 90 {
		entity_keep(w, e, c.player.position, 5, 7)
		harness_step(&rig.sess.h)
	}
	d := distance(w, e, c)
	testing.expectf(t, d >= 4.8 && d <= 7.2, "backed away to %v", d)
	testing.expect(t, entity_arrived(w, e))
	// Shooting from there: the bolts land.
	f := game_state(s, Fight)
	full := c.health
	shots := 0
	for _ in 0 ..< 45 {
		entity_keep(w, e, c.player.position, 5, 7)
		chest := c.player.position + {0, 1, 0}
		if entity_sees(w, e, chest) && entity_shoot(w, e, chest) {shots += 1}
		harness_step(&rig.sess.h)
	}
	testing.expectf(t, shots >= 2 && shots <= 4, "%d shots in 1.5 s at 2 a second", shots)
	testing.expectf(t, c.health <= full - 4, "health %v of %v", c.health, full)
	testing.expect_value(t, f.harm.creature, entity_id(w, e))
	testing.expect_value(t, f.harm.kind, game.Source_Kind.Weapon)
	// A wall between them: it does not see the player.
	p := entity_pos(w, e)
	mid := (p + c.player.position) / 2
	bulk_edit(
		w,
		{shape = Box{{i32(mid.x) - 1, 0, -6}, {i32(mid.x) + 1, 4, 6}}, op = .Set, block = .Stone},
		world_act(w, .Structure),
	)
	harness_step(&rig.sess.h)
	testing.expect(t, !entity_sees(w, e, c.player.position + {0, 1, 0}))
	// Far off: it closes in (round the wall, by its path).
	e2 := entity_spawn(w, archer, {20.5, 0, 0.5}, false)
	for _ in 0 ..< 150 {
		entity_keep(w, e2, c.player.position + {6, 0, 0}, 0, 1)
		harness_step(&rig.sess.h)
	}
	testing.expectf(t, entity_arrived(w, e2), "the archer is at %v", entity_pos(w, e2))
}

// Two walkers put in one place move apart, and one does not stand inside the player.
@(test)
test_walkers_keep_apart :: proc(t: ^testing.T) {
	rig := new(Fight_Rig)
	defer free(rig)
	if !fight_start(t, rig) {
		session_stop(&rig.sess)
		return
	}
	defer session_stop(&rig.sess)
	s := &rig.sess.h.srv
	w := s.home
	c := &s.clients[0]
	brute, _ := game.registry_kind(s.registry, "walkers:brute")
	a := entity_spawn(w, brute, {5.5, 0, 5.5}, false)
	b := entity_spawn(w, brute, {5.5, 0, 5.5}, false)
	inside := entity_spawn(w, brute, c.player.position, false)
	for e in ([]game.Entity_Handle{a, b, inside}) {entity_stand(w, e)}
	harness_step(&rig.sess.h, 30)
	d := entity_pos(w, a) - entity_pos(w, b)
	testing.expectf(t, math.sqrt(d.x * d.x + d.z * d.z) >= 0.7, "a and b %v apart", d)
	d = entity_pos(w, inside) - c.player.position
	testing.expectf(t, math.sqrt(d.x * d.x + d.z * d.z) >= 0.6, "inside the player: %v", d)
}

// An archer told to keep 5..7 blocks from the player, with a wall right behind it, does
// not jump at the wall: it slides along it until it is far enough.
@(test)
test_creature_backs_along_a_wall :: proc(t: ^testing.T) {
	rig := new(Fight_Rig)
	defer free(rig)
	if !fight_start(t, rig) {
		session_stop(&rig.sess)
		return
	}
	defer session_stop(&rig.sess)
	s := &rig.sess.h.srv
	w := s.home
	c := &s.clients[0]
	bulk_edit(
		w,
		{shape = Box{{-14, 0, -3}, {14, 3, -3}}, op = .Set, block = .Stone},
		world_act(w, .Structure),
	)
	archer, _ := game.registry_kind(s.registry, "walkers:archer")
	e := entity_spawn(w, archer, c.player.position + {0, 0, -2}, false)
	if !testing.expect(t, e != 0) {return}
	for _ in 0 ..< 150 {
		entity_keep(w, e, c.player.position, 5, 7)
		harness_step(&rig.sess.h)
	}
	d := entity_pos(w, e) - c.player.position
	testing.expectf(t, math.sqrt(d.x * d.x + d.z * d.z) >= 4.8, "backed only to %v", d)
}

// A gliding walker goes along its points in straight legs at its speed, with no physics:
// over a gap with nothing under it, through a wall in its way; it arrives at the last
// point and stands. Its players are told where it is every GLIDE_SEND_TICKS.
@(test)
test_walker_glides :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	h := &rig.h
	kind, ok := walkers_start(t, rig)
	if !ok {
		harness_stop(h)
		return
	}
	defer harness_stop(h)
	w := h.srv.home
	wall(w, 4, -6, 6)
	// (a hole across its way: walking, it would fall in)
	bulk_edit(
		w,
		{shape = Box{{-6, -3, -2}, {-4, -1, 2}}, op = .Set, block = .Air},
		world_act(w, .Structure),
	)
	e := entity_spawn(w, kind, {-11.5, 0, 0.5}, false)
	if !testing.expect(t, e != 0) {return}
	entity_set_speed(w, e, 6)
	points := []game.Block_Pos{{-1, 0, 0}, {10, 0, 0}, {10, 0, 6}}
	if !testing.expect(t, entity_glide(w, e, points)) {return}
	testing.expect(t, entity_gliding(w, e))
	shown_moves := 0
	last_shown: [3]f64
	for tick in 0 ..< 200 {
		harness_step(h)
		p := entity_pos(w, e)
		testing.expectf(t, abs(p.y) < 1e-9, "tick %d: it left its level: %v", tick, p)
		if at, _, gliding := glide_shown(w, e); gliding && at != last_shown {
			shown_moves += 1
			last_shown = at
		}
		if entity_arrived(w, e) {break}
	}
	testing.expect(t, entity_arrived(w, e), "it never arrived")
	p := entity_pos(w, e)
	testing.expectf(t, abs(p.x - 10.5) < 1e-6 && abs(p.z - 6.5) < 1e-6, "arrived at %v", p)
	// 28 blocks at 6 a second: 4.7 s, 140 ticks; told about a third of them.
	testing.expectf(
		t,
		shown_moves > 30 && shown_moves < 70,
		"its place was told %d times",
		shown_moves,
	)
	harness_step(h, 10)
	testing.expect_value(t, entity_pos(w, e), p)
	// Sent elsewhere by its own path, it walks again.
	testing.expect(t, entity_go(w, e, {12.5, 0, 0.5}))
	testing.expect(t, !entity_gliding(w, e))
}

// The world's speed: at 2 a walker gliding covers twice the ground a tick; paused, none,
// and the game's tick still comes (its records stay); a speed past MAX_SIM_SPEED is refused.
@(test)
test_sim_speed_steps_the_world :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	h := &rig.h
	hooks := Game {
		server_state = int, // (its ticks)
		tick = proc(s: ^Server) {game_state(s, int)^ += 1},
	}
	kind, ok := walkers_start(t, rig, hooks)
	if !ok {
		harness_stop(h)
		return
	}
	defer harness_stop(h)
	s := &h.srv
	w := s.home
	e := entity_spawn(w, kind, {-11.5, 0, 0.5}, false)
	entity_set_speed(w, e, 3)
	entity_glide(w, e, []game.Block_Pos{{20, 0, 0}})
	harness_step(h, 2)
	moved :: proc(h: ^Harness, e: game.Entity_Handle, ticks: int) -> f64 {
		from := entity_pos(h.srv.home, e)
		harness_step(h, ticks)
		return entity_pos(h.srv.home, e).x - from.x
	}
	one := moved(h, e, 10)
	testing.expect(t, sim_speed_set(s, 2))
	harness_step(h, 1)
	two := moved(h, e, 10)
	testing.expectf(t, abs(two - 2 * one) < 1e-6, "at 2: %v, at 1: %v", two, one)
	testing.expect(t, sim_speed_set(s, 0))
	harness_step(h, 1)
	before := game_state(s, int)^
	testing.expect_value(t, moved(h, e, 10), 0)
	testing.expect_value(t, game_state(s, int)^, before + 10)
	testing.expect_value(t, s.sim_steps, 0)
	testing.expect(t, !sim_speed_set(s, MAX_SIM_SPEED + 1))
	testing.expect_value(t, s.sim_speed, 0)
}
