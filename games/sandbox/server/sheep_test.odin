package sandbox_server

import "core:testing"

import "common:game"
import "games:sandbox"
import "server:core"
import "server:playtest"

// The sheep on a stepped server: the host (the harness's mirror) stands on a meadow of
// grass the test lays at its feet, and the sheep are set beside it.

FIELD :: core.Box{{-12, -1, -12}, {12, -1, 12}} // the meadow's grass (the feet stand at y 0)

Rig :: playtest.Rig

// meadow: the sandbox with the host on a field of grass, cleared above it.
meadow :: proc(t: ^testing.T, rig: ^Rig) -> bool {
	if !playtest.start(t, rig, GAME) {return false}
	s := playtest.srv(rig)
	w := s.home
	g := state(s)
	act := core.game_act(s, w, .Command)
	core.bulk_edit(
		w,
		{shape = core.Box{{-12, -6, -12}, {12, -2, 12}}, op = .Set, block = g.dirt},
		act,
	)
	core.bulk_edit(w, {shape = FIELD, op = .Set, block = g.grass}, act)
	core.bulk_edit(w, {shape = core.Box{{-12, 0, -12}, {12, 8, 12}}, op = .Set, block = .Air}, act)
	core.teleport(s, playtest.host(rig), {0.5, 0, 0.5}, {0, 0})
	playtest.step(rig, 30)
	return true
}

// lay: a sheep at p, with its record.
lay :: proc(rig: ^Rig, p: [3]f64, d: Sheep = {}) -> game.Entity_Handle {
	s := playtest.srv(rig)
	h := core.entity_spawn(s.home, state(s).sheep, p, false)
	if h != 0 {sheep(s, s.home, h)^ = d}
	return h
}

// looks: whether a sheep shows a look, as its players are told.
looks :: proc(rig: ^Rig, h: game.Entity_Handle, name: string) -> bool {
	s := playtest.srv(rig)
	info := game.kind_info(s.registry, state(s).sheep)
	return core.entity_looks(s.home, s.registry, h) & game.kind_look(info, name) != 0
}

// wool_lying: the wool on the ground (any colour).
wool_lying :: proc(rig: ^Rig) -> int {
	s := playtest.srv(rig)
	g := state(s)
	n := 0
	it := core.entities_each(s.home)
	for h in core.entities_next(&it) {
		if core.entity_kind(s.home, h) != s.registry.engine.item {continue}
		st := core.entity_stack(s.home, h)^
		if st.item == g.wool || st.item == g.black_wool {n += st.count}
	}
	return n
}

// Using an adult with no wheat in hand shears it: 1 to 3 wool fall (black ones' black),
// it looks shorn, and the shearing is counted for the player. Shorn, or a lamb, it is
// not sheared again, and the player is told why.
@(test)
test_shearing :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !meadow(t, rig) {playtest.stop(rig); return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	c := playtest.host(rig)
	white := lay(rig, {2.5, 0, 0.5})
	if !testing.expect(t, white != 0) {return}
	playtest.step(rig)
	testing.expect(t, !looks(rig, white, "shorn"))
	core.use_entity(s, c, core.entity_id(s.home, white))
	wool := wool_lying(rig)
	testing.expectf(t, wool >= 1 && wool <= 3, "%d wool fell", wool)
	testing.expect(t, sheep(s, s.home, white).shorn)
	playtest.step(rig)
	testing.expect(t, looks(rig, white, "shorn"), "it does not look shorn")
	testing.expect_value(t, c.stats["sheep.sheared"], 1)
	core.use_entity(s, c, core.entity_id(s.home, white))
	testing.expect_value(t, wool_lying(rig), wool)
	testing.expect(t, playtest.told(rig, "The sheep is shorn"))
	lamb := lay(rig, {0.5, 0, 2.5}, {grows = sandbox.LAMB_TICKS})
	core.use_entity(s, c, core.entity_id(s.home, lamb))
	testing.expect(t, playtest.told(rig, "A lamb has no wool"))
	testing.expect(t, !sheep(s, s.home, lamb).shorn)
}

// Wheat makes two adults ready: they find each other and have a lamb of both that looks
// small, the feeding and the birth are counted, and each waits.
@(test)
test_breeding :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !meadow(t, rig) {playtest.stop(rig); return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	c := playtest.host(rig)
	g := state(s)
	a := lay(rig, {2.5, 0, 0.5}, {genes = sandbox.WOOL_BLACK})
	b := lay(rig, {-1.5, 0, 0.5}, {genes = sandbox.WOOL_BLACK})
	if !testing.expect(t, a != 0 && b != 0) {return}
	core.item_clear(s, c, g.wheat)
	core.item_give(s, c, g.wheat, 2)
	core.hotbar_select(s, c, 0)
	for slot, i in c.inventory.slots {if slot.item == g.wheat {core.hotbar_select(s, c, i)}}
	core.use_entity(s, c, core.entity_id(s.home, a))
	core.use_entity(s, c, core.entity_id(s.home, b))
	testing.expect(t, sheep(s, s.home, a).love > 0 && sheep(s, s.home, b).love > 0, "not ready")
	Lamb :: struct {
		s:    ^core.Server,
		lamb: game.Entity_Handle,
	}
	born := Lamb {
		s = s,
	}
	found :: proc(data: rawptr) -> bool {
		l := (^Lamb)(data)
		it := core.entities_each(l.s.home)
		for h in core.entities_next(&it) {
			if d := sheep(l.s, l.s.home, h); d != nil && d.grows > 0 {l.lamb = h; return true}
		}
		return false
	}
	if !testing.expect(t, playtest.until(rig, found, &born, 30), "no lamb was born") {return}
	d := sheep(s, s.home, born.lamb)
	testing.expect(t, sandbox.genes_black(d.genes), "two black sheep's lamb is not black") // (bar a mutation)
	testing.expect(t, sheep(s, s.home, a).wait > 0 && sheep(s, s.home, b).wait > 0)
	playtest.step(rig)
	testing.expect(t, looks(rig, born.lamb, "lamb"), "the lamb does not look small")
	testing.expect_value(t, s.home.stats["sheep.born"], 1)
	testing.expect_value(t, c.stats["sheep.fed"], 2)
}

// A shorn sheep grazes: in time it eats the grass in front of it (dirt now) and its wool
// is back.
@(test)
test_grazing_grows_wool_back :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !meadow(t, rig) {playtest.stop(rig); return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	h := lay(rig, {6.5, 0, 6.5}, {shorn = true})
	if !testing.expect(t, h != 0) {return}
	Grazer :: struct {
		s: ^core.Server,
		h: game.Entity_Handle,
	}
	gr := Grazer{s, h}
	grown :: proc(data: rawptr) -> bool {
		g := (^Grazer)(data)
		return !sheep(g.s, g.s.home, g.h).shorn
	}
	testing.expect(t, playtest.until(rig, grown, &gr, 120), "it never grazed its wool back")
	dirt := 0
	for z in FIELD.lo.z ..= FIELD.hi.z {
		for x in FIELD.lo.x ..= FIELD.hi.x {
			if b, _ := core.block_at(s.home, {x, -1, z}); b == state(s).dirt {dirt += 1}
		}
	}
	testing.expect(t, dirt >= 1, "no grass was eaten")
}

// A hurt sheep runs from what hurt it.
@(test)
test_a_hurt_sheep_flees :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !meadow(t, rig) {playtest.stop(rig); return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	h := lay(rig, {2.5, 0, 0.5})
	if !testing.expect(t, h != 0) {return}
	playtest.step(rig, 5)
	core.entity_set_max_health(s.home, h, 40)
	core.entity_harm(s.home, h, {amount = 1, kind = .Game, from = {0.5, 0, 0.5}})
	testing.expect_value(t, sheep(s, s.home, h).state, Sheep_State.Flee)
	playtest.step(rig, 60)
	testing.expectf(
		t,
		core.entity_pos(s.home, h).x > 5,
		"it did not run: at %v",
		core.entity_pos(s.home, h),
	)
}

// The host's /sheep sets down a sheep of the looks it names.
@(test)
test_the_sheep_command :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !meadow(t, rig) {playtest.stop(rig); return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	playtest.say(rig, "sheep lamb shorn black")
	found := false
	it := core.entities_each(s.home)
	for h in core.entities_next(&it) {
		if d := sheep(s, s.home, h); d != nil {
			found = true
			testing.expect(t, d.shorn && d.grows > 0 && sandbox.genes_black(d.genes))
			testing.expect(
				t,
				looks(rig, h, "lamb") && looks(rig, h, "shorn") && looks(rig, h, "black"),
			)
		}
	}
	testing.expect(t, found, "no sheep was set down")
	playtest.say(rig, "sheep woolly")
	testing.expect(t, playtest.told(rig, "Usage: sheep"))
}
