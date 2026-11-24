package sandbox_server

import "core:testing"

import "common:game"
import "server:core"
import "server:play"
import "server:playtest"

// The roster (wild.odin) on the meadow of the sheep's tests (sheep_test.odin): what its
// pack says of each kind, and each kind's mind with the host near it.

// wild_lay: a creature of the roster at p, as one that came there by itself begins.
wild_lay :: proc(rig: ^Rig, which: Wild, p: [3]f64) -> game.Entity_Handle {
	s := playtest.srv(rig)
	h := core.entity_spawn(s.home, state(s).wild[which], p, false)
	if h != 0 {wild_begin(s, s.home, which, h)}
	return h
}

// wild_mind: a creature's mind.
wild_mind :: proc(rig: ^Rig, h: game.Entity_Handle) -> ^play.Mind {
	s := playtest.srv(rig)
	return &creature(s, s.home, h).mind
}

// wild_looks: whether a creature of the roster shows a look, as its players are told.
wild_looks :: proc(rig: ^Rig, h: game.Entity_Handle, name: string) -> bool {
	s := playtest.srv(rig)
	info := game.kind_info(s.registry, core.entity_kind(s.home, h))
	return core.entity_looks(s.home, s.registry, h) & game.kind_look(info, name) != 0
}

// stand: the host stands at p, in a mode.
stand :: proc(rig: ^Rig, p: [3]f64, mode := "survival") {
	s := playtest.srv(rig)
	c := playtest.host(rig)
	core.game_mode(s, c, mode)
	core.teleport(s, c, p, {0, 0})
	playtest.step(rig, 2)
}

// off: blocks between a creature and the host, across.
off :: proc(rig: ^Rig, h: game.Entity_Handle) -> f64 {
	s := playtest.srv(rig)
	return play.distance_to(core.entity_pos(s.home, h), playtest.host(rig).player.position)
}

// Every kind of the roster is in the game's pack as its mind needs it: the game's brain,
// a model of parts, drops of items the pack has; the posted machines (the remains', the
// delves') kept with the world and coming only where they are posted, the custodian set
// down by its delve each session and so not kept; the others coming by themselves at their
// hours and in their places, the predators clear of the world's spawn.
@(test)
test_the_roster_is_in_the_pack :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	g := state(s)
	DAY :: bit_set[Wild] {
		.Loper,
		.Twitchet,
		.Wheelwing,
		.Domeback,
		.Hacklebird,
		.Snouter,
		.Longstrider,
		.Watcher,
	}
	NIGHT :: bit_set[Wild]{.Barbcaster, .Duskrunner, .Cragmaul}
	POSTED :: bit_set[Wild]{.Sentry, .Tender, .Bulwark, .Scuttler, .Spire, .Carapace}
	for kind, which in g.wild {
		info := game.kind_info(s.registry, kind)
		if !testing.expectf(t, info != nil, "%v is not in the pack", which) {continue}
		testing.expectf(
			t,
			info.brain == .Game && info.model == .Parts,
			"%v: brain %v, model %v",
			which,
			info.brain,
			info.model,
		)
		testing.expectf(t, len(info.drops) > 0, "%v leaves nothing", which)
		for d in info.drops {testing.expectf(t, d.item != game.NO_ITEM, "%v drops %s", which, d.name)}
		rule, comes := info.spawn.?
		if which == .Custodian {
			testing.expectf(t, !comes && !info.saved, "%v comes by itself, or is kept", which)
			continue
		}
		if which in POSTED {
			testing.expectf(t, !comes && info.saved, "%v comes by itself, or is not kept", which)
			continue
		}
		if !testing.expectf(t, comes, "%v never comes", which) {continue}
		if which in DAY {
			testing.expectf(
				t,
				core.spawn_hours(rule.day, 0.5) && !core.spawn_hours(rule.day, 0),
				"%v is no day creature",
				which,
			)
		}
		if which in NIGHT {
			testing.expectf(
				t,
				core.spawn_hours(rule.day, 0) && !core.spawn_hours(rule.day, 0.5),
				"%v is no night creature",
				which,
			)
			testing.expectf(
				t,
				rule.safe >= 48,
				"%v comes within %d of the spawn",
				which,
				rule.safe,
			)
		}
	}
	pit := game.kind_info(s.registry, g.wild[.Pitmaw]).spawn.? or_else {}
	fin := game.kind_info(s.registry, g.wild[.Glassfin]).spawn.? or_else {}
	testing.expect_value(t, pit.place, game.Spawn_Place.Cave)
	testing.expect_value(t, fin.place, game.Spawn_Place.Water)
	testing.expect(t, core.spawn_hours(pit.day, 0) && core.spawn_hours(pit.day, 0.5))
	giant := game.kind_info(s.registry, g.wild[.Longstrider]).spawn.? or_else {}
	testing.expect_value(t, giant.cap, 1)
}

// A loper's herd runs together from a player who comes near one of them, and comes to a
// stand again.
@(test)
test_a_herd_runs_together :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !meadow(t, rig) {playtest.stop(rig); return}
	defer playtest.stop(rig)
	stand(rig, {-8.5, 0, 0.5})
	herd: [3]game.Entity_Handle
	for &h, i in herd {h = wild_lay(rig, .Loper, {2.5 + f64(i) * 1.5, 0, 2.5})}
	playtest.step(rig, 10)
	for h in herd {testing.expect(t, wild_mind(rig, h).state != .Flee, "it ran from nobody")}
	stand(rig, {2.5, 0, 6})
	playtest.step(rig, 2)
	for h in herd {testing.expect_value(t, wild_mind(rig, h).state, play.Mind_State.Flee)}
	playtest.step(rig, 3 * game.TICK_RATE)
	for h in herd {testing.expectf(t, off(rig, h) > 6, "one stayed %v off", off(rig, h))}
	stand(rig, {-30.5, 0, -30.5}) // (in the world's loaded ground, far from the herd)
	playtest.step(rig, 6 * game.TICK_RATE)
	for h in herd {testing.expect(t, wild_mind(rig, h).state != .Flee, "it ran on with nobody near")}
}

// A twitchet freezes, ears up, at a player 9 blocks off and bolts from one within 5.
@(test)
test_a_twitchet_freezes_then_bolts :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !meadow(t, rig) {playtest.stop(rig); return}
	defer playtest.stop(rig)
	h := wild_lay(rig, .Twitchet, {0.5, 0, -6.5})
	stand(rig, {0.5, 0, 1.5})
	playtest.step(rig, 10)
	testing.expect_value(t, wild_mind(rig, h).state, play.Mind_State.Watch)
	testing.expect(t, wild_looks(rig, h, "watch"), "its ears are not up")
	stand(rig, {0.5, 0, -3})
	playtest.step(rig, 2 * game.TICK_RATE)
	testing.expect_value(t, wild_mind(rig, h).state, play.Mind_State.Flee)
	testing.expectf(t, off(rig, h) > 6, "it is %v off", off(rig, h))
}

// A wheelwing takes off from a player who comes near, flies (never into a block, and
// showing its wings spread), and comes down again on open ground once left alone.
@(test)
test_a_bird_takes_off_and_comes_down :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !meadow(t, rig) {playtest.stop(rig); return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	w := s.home
	h := wild_lay(rig, .Wheelwing, {0.5, 0, -5.5})
	stand(rig, {0.5, 0, 6.5})
	playtest.step(rig, 10)
	testing.expect_value(t, wild_mind(rig, h).state, play.Mind_State.Rest)
	stand(rig, {0.5, 0, -1.5})
	highest := 0.0
	for _ in 0 ..< 4 * game.TICK_RATE {
		playtest.step(rig)
		p := core.entity_pos(w, h)
		highest = max(highest, p.y)
		if !testing.expectf(
			t,
			play.medium_has(s, w, play.block_of(p), false),
			"it flew into a block at %v",
			p,
		) {return}
	}
	testing.expectf(t, highest > 3, "it rose to %v", highest)
	testing.expect(t, wild_looks(rig, h, "flee"), "its wings are not spread")
	stand(rig, {0.5, 0, 30.5})
	landed := false
	for _ in 0 ..< 60 * game.TICK_RATE {
		playtest.step(rig)
		if wild_mind(rig, h).state == .Rest {
			landed = true
			break
		}
	}
	testing.expect(t, landed, "it never came down")
	testing.expect(
		t,
		play.standable(s, w, play.block_of(core.entity_pos(w, h))),
		"it came down on nothing",
	)
}

// A hacklebird warns (its crest and ruff up) a player near its ground and stands; it
// attacks one who comes within 5, and a creative player is never warned.
@(test)
test_a_hacklebird_warns_then_attacks :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !meadow(t, rig) {playtest.stop(rig); return}
	defer playtest.stop(rig)
	c := playtest.host(rig)
	stand(rig, {0.5, 0, 7.5}, "creative")
	h := wild_lay(rig, .Hacklebird, {0.5, 0, 0.5})
	playtest.step(rig, game.TICK_RATE)
	testing.expect(t, wild_mind(rig, h).state != .Warn, "it warned a creative player")
	stand(rig, {0.5, 0, 7.5})
	health := c.health
	playtest.step(rig, game.TICK_RATE)
	testing.expect_value(t, wild_mind(rig, h).state, play.Mind_State.Warn)
	testing.expect(t, wild_looks(rig, h, "warn"), "its crest is down")
	playtest.step(rig, 2 * game.TICK_RATE)
	testing.expect_value(t, c.health, health)
	stand(rig, {0.5, 0, 3.5})
	playtest.step(rig, 5 * game.TICK_RATE)
	testing.expect(t, c.health < health, "it never attacked")
}

// A pitmaw lies buried until a player comes within 5 blocks, rises (a moment to see it),
// and bites.
@(test)
test_a_pitmaw_rises_from_the_ground :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !meadow(t, rig) {playtest.stop(rig); return}
	defer playtest.stop(rig)
	c := playtest.host(rig)
	stand(rig, {0.5, 0, 9.5})
	h := wild_lay(rig, .Pitmaw, {0.5, 0, 0.5})
	playtest.step(rig, game.TICK_RATE)
	testing.expect(t, wild_looks(rig, h, "hidden"), "it is not buried")
	stand(rig, {0.5, 0, 3})
	playtest.step(rig, 5)
	testing.expect_value(t, wild_mind(rig, h).state, play.Mind_State.Wake)
	testing.expect(t, wild_looks(rig, h, "wake"), "it rises unseen")
	health := c.health
	playtest.step(rig, 5 * game.TICK_RATE)
	testing.expect(t, c.health < health, "it never bit")
}

// A sentry posted at remains sleeps folded until a player comes within 10 blocks of its
// post, wakes, shoots, and folds again at its post, whole, once the player has gone. A
// second post of its kind there sets nothing down.
@(test)
test_a_sentry_wakes_at_its_post :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !meadow(t, rig) {playtest.stop(rig); return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	w := s.home
	c := playtest.host(rig)
	stand(rig, {0.5, 0, 11.5})
	h := remains_post(s, w, .Sentry, {0, 0, -2})
	if !testing.expect(t, h != 0) {return}
	testing.expect_value(t, remains_post(s, w, .Sentry, {1, 0, -2}), game.Entity_Handle(0))
	playtest.step(rig, game.TICK_RATE)
	testing.expect_value(t, wild_mind(rig, h).state, play.Mind_State.Dormant)
	testing.expect(t, wild_looks(rig, h, "dormant"), "it is not folded")
	core.entity_harm(w, h, {amount = 4, kind = .Game, from = {0.5, 0, 11.5}})
	testing.expect_value(t, core.entity_health_of(w, h), 22) // (asleep, half gets through)
	testing.expect_value(t, wild_mind(rig, h).state, play.Mind_State.Wake)
	stand(rig, {0.5, 0, 5.5})
	health := c.health
	playtest.step(rig, 8 * game.TICK_RATE)
	testing.expect(t, c.health < health, "it never shot")
	stand(rig, {0.5, 0, 30.5})
	playtest.step(rig, 20 * game.TICK_RATE)
	testing.expect_value(t, wild_mind(rig, h).state, play.Mind_State.Dormant)
	testing.expect_value(t, core.entity_health_of(w, h), core.entity_max_health(w, h))
	back := play.distance_to(core.entity_pos(w, h), {0.5, 0, -1.5})
	testing.expectf(t, back < 1.5, "it sleeps %v from its post", back)
}

// A domeback shuts itself in its shell when hurt, and then only a quarter of a blow gets
// through; a creature that dies leaves its drops.
@(test)
test_a_domeback_shuts_in_and_the_dead_leave_their_drops :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !meadow(t, rig) {playtest.stop(rig); return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	w := s.home
	h := wild_lay(rig, .Domeback, {3.5, 0, 0.5})
	core.entity_harm(w, h, {amount = 4, kind = .Game, from = {0.5, 0, 0.5}})
	testing.expect_value(t, core.entity_health_of(w, h), 16)
	playtest.step(rig)
	testing.expect(t, wild_looks(rig, h, "hidden"), "it is not shut in")
	core.entity_harm(w, h, {amount = 8, kind = .Game, from = {0.5, 0, 0.5}})
	testing.expect_value(t, core.entity_health_of(w, h), 14)

	loper := wild_lay(rig, .Loper, {-3.5, 0, 0.5})
	testing.expect(t, core.entity_harm(w, loper, {amount = 50, kind = .Game}), "it lived")
	playtest.step(rig)
	meat, _ := game.registry_item(s.registry, "sandbox:raw_meat")
	hide, _ := game.registry_item(s.registry, "sandbox:hide")
	found := [2]int{}
	it := core.entities_each(w)
	for e in core.entities_next(&it) {
		if core.entity_kind(w, e) != s.registry.engine.item {continue}
		st := core.entity_stack(w, e)^
		if st.item == meat {found[0] += st.count}
		if st.item == hide {found[1] += st.count}
	}
	testing.expectf(
		t,
		found[0] >= 1 && found[0] <= 2 && found[1] >= 1 && found[1] <= 2,
		"it left %v",
		found,
	)
}

// A watcher keeps a player in sight from a distance, then rises and goes; a mender hovers
// about its remains and minds no one.
@(test)
test_the_machines_that_fly :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !meadow(t, rig) {playtest.stop(rig); return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	w := s.home
	c := playtest.host(rig)
	stand(rig, {0.5, 0, 0.5})
	tender := wild_lay(rig, .Tender, {6.5, 0, 6.5})
	watcher := wild_lay(rig, .Watcher, {-6.5, 2, 0.5})
	id := core.entity_id(w, watcher)
	wild_mind(rig, watcher).timer = 8 * game.TICK_RATE
	health := c.health
	held := 0
	for i in 0 ..< 8 * game.TICK_RATE {
		playtest.step(rig)
		if _, there := core.entity_find(w, id); there && i > 4 * game.TICK_RATE {
			d := off(rig, watcher)
			if d >= 5 && d <= 24 {held += 1}
		}
		p := core.entity_pos(w, tender)
		if !testing.expectf(
			t,
			play.medium_has(s, w, play.block_of(p), false),
			"the mender went into a block at %v",
			p,
		) {return}
	}
	testing.expectf(
		t,
		held > 2 * game.TICK_RATE,
		"the watcher kept its distance for %d ticks",
		held,
	)
	gone := false
	for _ in 0 ..< 25 * game.TICK_RATE {
		playtest.step(rig)
		if _, there := core.entity_find(w, id); !there {
			gone = true
			break
		}
	}
	testing.expect(t, gone, "the watcher never went")
	testing.expect_value(t, c.health, health)
	testing.expect(t, wild_mind(rig, tender).state != .Flee, "the mender fled from nobody")
}

// What comes by itself is refused round a player who has WILD_MOST creatures near, a
// barbcaster away from the water and a watcher away from the remains.
@(test)
test_what_may_come_by_itself :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !meadow(t, rig) {playtest.stop(rig); return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	w := s.home
	g := state(s)
	come :: proc(s: ^core.Server, w: ^core.World, which: Wild, p: [3]f64) -> bool {
		h := core.entity_spawn(w, state(s).wild[which], p, true)
		ok := wild_spawned(s, w, which, h)
		if !ok {core.entity_gone(w, h)}
		return ok
	}
	testing.expect(
		t,
		!come(s, w, .Barbcaster, {4.5, 0, 4.5}),
		"a barbcaster came away from the water",
	)
	core.bulk_edit(
		w,
		{shape = core.Box{{8, -1, 8}, {9, -1, 9}}, op = .Set, block = .Water},
		core.game_act(s, w, .Command),
	)
	playtest.step(rig)
	testing.expect(
		t,
		come(s, w, .Barbcaster, {6.5, 0, 6.5}),
		"a barbcaster did not come by the water",
	)
	testing.expect(t, !come(s, w, .Watcher, {2.5, 0, 2.5}), "a watcher came away from the remains")
	remains_mark(s, {0.5, 0, 40.5})
	testing.expect(t, come(s, w, .Watcher, {2.5, 0, 2.5}), "a watcher did not come by the remains")
	for i in 0 ..< WILD_MOST - 2 {
		core.entity_spawn(w, g.wild[.Twitchet], {-10.5 + f64(i % 8), 0, -10.5 + f64(i / 8)}, true)
	}
	testing.expect(t, !come(s, w, .Loper, {0.5, 0, 6.5}), "a loper came into a crowd")
}

// `/creatures all still` sets the whole roster down in a row, standing still.
@(test)
test_the_roster_lines_up :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !meadow(t, rig) {playtest.stop(rig); return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	w := s.home
	playtest.say(rig, "creatures all still")
	playtest.step(rig, 2 * game.TICK_RATE) // (the fliers rise to where they hold)
	n := 0
	at: [len(Wild)][3]f64
	it := core.entities_each(w)
	for h in core.entities_next(&it) {
		which, ours := wild_of(s, core.entity_kind(w, h))
		if !ours {continue}
		testing.expectf(t, creature(s, w, h).still, "%v does not stand still", which)
		at[which] = core.entity_pos(w, h)
		n += 1
	}
	testing.expect_value(t, n, len(Wild))
	playtest.step(rig, 2 * game.TICK_RATE)
	it = core.entities_each(w)
	for h in core.entities_next(&it) {
		which, ours := wild_of(s, core.entity_kind(w, h))
		if !ours {continue}
		moved := play.distance_to(core.entity_pos(w, h), at[which])
		testing.expectf(t, moved < 0.1, "%v moved %v", which, moved)
	}
	playtest.say(rig, "creatures zoo")
	testing.expect(t, playtest.told(rig, "Usage: creatures"))
}

// wild_run: the roster's creatures on the meadow with the host walking among them, for
// ticks; where each stands at the end.
@(private = "file")
wild_run :: proc(t: ^testing.T, ticks: int) -> (at: [8][3]f64, ok: bool) {
	rig := new(Rig)
	defer free(rig)
	if !meadow(t, rig) {
		playtest.stop(rig)
		return
	}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	kinds := [8]Wild {
		.Loper,
		.Loper,
		.Loper,
		.Twitchet,
		.Wheelwing,
		.Domeback,
		.Hacklebird,
		.Snouter,
	}
	hs: [8]game.Entity_Handle
	for which, i in kinds {hs[i] = wild_lay(rig, which, {-8.5 + f64(i) * 2.5, 0, -4.5})}
	for i in 0 ..< ticks {
		if i % game.TICK_RATE == 0 {stand(rig, {-9.5 + f64(i / game.TICK_RATE % 20), 0, 4.5})}
		playtest.step(rig)
	}
	for h, i in hs {
		if _, there := core.entity_find(s.home, core.entity_id(s.home, h));
		   there {at[i] = core.entity_pos(s.home, h)}
	}
	return at, true
}

// The creatures' minds are the same in every run of a universe (its seed's randomness).
@(test)
test_the_roster_is_deterministic :: proc(t: ^testing.T) {
	a, a_ok := wild_run(t, 15 * game.TICK_RATE)
	b, b_ok := wild_run(t, 15 * game.TICK_RATE)
	if !testing.expect(t, a_ok && b_ok) {return}
	testing.expect_value(t, a, b)
	moved := false
	for p in a {if p.z != -4.5 {moved = true}}
	testing.expect(t, moved, "nothing moved")
}
