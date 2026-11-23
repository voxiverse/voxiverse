package sandbox_server

import "core:testing"

import "common:game"
import "games:sandbox"
import "server:core"
import "server:playtest"

// The ruined site (ruin.odin) on the sandbox's world: where it stands, built as a player
// comes near; woken at its altar, its fighters locked in with their things kept; its waves
// one after another to the reward; a fighter's death ending its part; two fighting it.

// ruin_reach: the host (and the guest, when there is one) set down inside the ruin, in
// survival, the ruin built round them, each carrying wheat of its own.
@(private = "file")
ruin_reach :: proc(t: ^testing.T, rig: ^Rig, guests := 0) -> bool {
	if !playtest.start(t, rig, GAME, {guests = guests}) {return false}
	s := playtest.srv(rig)
	r := ruin_of(s)
	playtest.step(rig) // (the site worked out)
	if !testing.expect(t, r.placed, "the site was never worked out") {return false}
	if !testing.expect(t, !r.built, "the ruin was built with nobody near") {return false}
	players := []^core.Client{playtest.host(rig), playtest.guest(rig) if guests > 0 else nil}
	for c, i in players {
		if c == nil {continue}
		core.game_mode(s, c, "survival")
		core.item_give(s, c, state(s).wheat, 5)
		core.teleport(s, c, ruin_point(r.site, {RUIN_MID - 3 + i32(i) * 6, RUIN_MID + 3}), {0, 0})
	}
	built :: proc(data: rawptr) -> bool {return ruin_of((^core.Server)(data)).built}
	if !testing.expect(t, playtest.until(rig, built, s, 60), "the ruin was never built") {
		return false
	}
	for c, i in players {
		if c == nil {continue}
		core.teleport(s, c, ruin_point(r.site, {RUIN_MID - 3 + i32(i) * 6, RUIN_MID + 3}), {0, 0})
	}
	playtest.step(rig, 10)
	b, _ := core.block_at(s.home, ruin_altar(r.site))
	return testing.expect_value(t, b, r.altar)
}

// fight_wave_cleared: every creature of the wave out and killed; true once it is held.
@(private = "file")
fight_wave_cleared :: proc(rig: ^Rig) -> bool {
	s := playtest.srv(rig)
	r := ruin_of(s)
	for _ in 0 ..< 60 * game.TICK_RATE {
		if r.phase.now != .Wave {break}
		for r.crowd.foe_count > 0 {
			h, there := core.entity_find(s.home, r.crowd.foes[0].id)
			if !there {
				play_forget(r, r.crowd.foes[0].id)
				continue
			}
			core.entity_harm(s.home, h, {amount = 100_000, kind = .Game})
		}
		playtest.step(rig)
	}
	return r.phase.now == .Break || r.phase.now == .Asleep
}

@(private = "file")
play_forget :: proc(r: ^Ruin, id: u32) {
	for f, i in r.crowd.foes[:r.crowd.foe_count] {
		if f.id != id {continue}
		r.crowd.foes[i] = r.crowd.foes[r.crowd.foe_count - 1]
		r.crowd.foe_count -= 1
		return
	}
}

// fighting_as_told: c is locked in: its own things set aside, in the encounter's mode with
// its kit, the guns tuned to load the ruin's rounds.
@(private = "file")
fighting_as_told :: proc(t: ^testing.T, rig: ^Rig, c: ^core.Client) {
	s := playtest.srv(rig)
	r := ruin_of(s)
	_, aside := c.aside.?
	testing.expect(t, aside, "its things were not set aside")
	testing.expect_value(t, playtest.mode_of(rig, c), sandbox.ENCOUNTER_MODE)
	testing.expect_value(t, core.item_count(c, state(s).wheat), 0)
	pistol, _ := game.registry_item(s.registry, "voxiverse:pistol")
	testing.expect_value(t, core.item_count(c, pistol), 1)
	testing.expect(t, core.item_count(c, r.round) > 0, "no rounds")
	w, _ := game.weapon_of(s.registry, c.mode, pistol)
	testing.expect_value(t, w.ammo, r.round)
	testing.expect(t, ruin_fighting(s, c))
}

// back_as_before: c has its own things again, in survival, nothing set aside, its guns the
// base pack's again (free to reload).
@(private = "file")
back_as_before :: proc(t: ^testing.T, rig: ^Rig, c: ^core.Client) {
	s := playtest.srv(rig)
	pistol, _ := game.registry_item(s.registry, "voxiverse:pistol")
	w, _ := game.weapon_of(s.registry, c.mode, pistol)
	testing.expect_value(t, w.ammo, game.NO_ITEM)
	_, aside := c.aside.?
	testing.expect(t, !aside, "its things are still set aside")
	testing.expect_value(t, playtest.mode_of(rig, c), "voxiverse:survival")
	testing.expect_value(t, core.item_count(c, state(s).wheat), 5)
	testing.expect_value(t, core.item_count(c, ruin_of(s).round), 0)
	testing.expect(t, !ruin_fighting(s, c))
}

// The site is the seed's, the same every time, a walk from the spawn; nothing wakes it
// but its own altar, from inside, in a mode that can be hurt.
@(test)
test_ruin_stands_from_the_seed :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !ruin_reach(t, rig) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	r := ruin_of(s)
	w := s.home
	testing.expect_value(t, ruin_site(w), r.site)
	d := ruin_middle(r.site) - w.spawn.position
	far := d.x * d.x + d.z * d.z
	testing.expectf(
		t,
		far >= 230 * 230 && far <= 300 * 300,
		"the ruin stands %v from the spawn",
		d,
	)
	tower, _ := core.block_at(w, r.site.origin + {1, RUIN_HEIGHT - 2, 1})
	testing.expect_value(t, tower, game.Block.Lamp)

	h := playtest.host(rig)
	altar := ruin_altar(r.site)
	testing.expect(t, ruin_use(s, h, altar + {1, 0, 0}) != "", "a block not the altar woke it")
	core.game_mode(s, h, "creative")
	testing.expect(t, ruin_use(s, h, altar) != "", "it woke for one who cannot be hurt")
	core.game_mode(s, h, "survival")
	inside := h.player.position
	core.teleport(s, h, ruin_point(r.site, {RUIN_MID, RUIN_SIDE + 4}), {0, 0})
	playtest.step(rig, 5)
	testing.expect(t, ruin_use(s, h, altar) != "", "it woke for one outside its walls")
	testing.expect_value(t, r.phase.now, sandbox.Ruin_Phase.Asleep)
	testing.expect_value(t, editing(s, h, altar, r.altar, .Air), "The ruin holds")
	core.teleport(s, h, inside, {0, 0})
	playtest.step(rig, 5)
	testing.expect_value(t, ruin_use(s, h, altar), "")
	testing.expect_value(t, r.phase.now, sandbox.Ruin_Phase.Countdown)
}

// Woken, the fighter is locked in with its things kept; each wave held brings the next and
// rounds; the last held, it has its things back and the altar's reward, and the ward falls.
@(test)
test_ruin_fight_to_the_reward :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !ruin_reach(t, rig) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	r := ruin_of(s)
	w := s.home
	h := playtest.host(rig)
	testing.expect_value(t, ruin_use(s, h, ruin_altar(r.site)), "")
	fighting_as_told(t, rig, h)
	gate := game.Block_Pos{r.site.origin.x + RUIN_MID, r.site.floor + 1, r.site.origin.z}
	ward, _ := core.block_at(w, gate)
	testing.expect_value(t, ward, r.ward)

	// Locked in: out over the wall, it is put back.
	core.teleport(s, h, ruin_point(r.site, {RUIN_MID, -6}), {0, 0})
	playtest.step(rig, 3)
	testing.expect(t, ruin_inside(r.site, h.player.position), "the fighter got out")

	for n in 1 ..= RUIN_WAVES {
		if !testing.expectf(
			t,
			playtest.until_phase(rig, &r.phase, .Wave),
			"wave %d never came",
			n,
		) {
			return
		}
		testing.expect_value(t, r.wave, n)
		rounds := core.item_count(h, r.round)
		if !testing.expectf(t, fight_wave_cleared(rig), "wave %d was never held", n) {return}
		if n < RUIN_WAVES {
			testing.expect_value(t, r.phase.now, sandbox.Ruin_Phase.Break)
			testing.expect_value(t, core.item_count(h, r.round), rounds + RUIN_BREAK_ROUNDS)
			fight := playtest.host_record(rig, sandbox.Ruin_Fight)
			playtest.step(rig, 2)
			fight = playtest.host_record(rig, sandbox.Ruin_Fight)
			testing.expect(t, fight != nil && fight.phase == .Break && int(fight.wave) == n)
		}
	}
	testing.expect_value(t, r.phase.now, sandbox.Ruin_Phase.Asleep)
	back_as_before(t, rig, h)
	ward, _ = core.block_at(w, gate)
	testing.expect_value(t, ward, game.Block.Air)

	// The reward lies on the altar.
	core.teleport(s, h, ruin_point(r.site, {RUIN_MID, RUIN_MID}) + {0, 1, 0}, {0, 0})
	playtest.step(rig, 2 * game.TICK_RATE)
	for item in r.reward {testing.expect_value(t, core.item_count(h, item), 1)}
}

// A fighter who dies is out: the fight with nobody left is over, and the fighter stands
// again at the world's spawn with its own things, in its own mode.
@(test)
test_ruin_death_ends_the_fight :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !ruin_reach(t, rig) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	r := ruin_of(s)
	h := playtest.host(rig)
	testing.expect_value(t, ruin_use(s, h, ruin_altar(r.site)), "")
	if !testing.expect(t, playtest.until_phase(rig, &r.phase, .Wave)) {return}
	playtest.kill(rig, h, nil)
	playtest.step(rig, 2)
	testing.expect_value(t, r.phase.now, sandbox.Ruin_Phase.Asleep)
	testing.expect_value(t, r.crowd.foe_count, 0)
	testing.expect(t, core.respawn(s, h))
	back_as_before(t, rig, h)
	testing.expect(t, !ruin_inside(r.site, h.player.position), "it stood again in the ruin")
}

// Two fight it: both are locked in, one falls and the other holds on to the reward; one who
// was outside when it woke is kept out.
@(test)
test_ruin_two_fight_it :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !ruin_reach(t, rig, guests = 1) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	r := ruin_of(s)
	h, g := playtest.host(rig), playtest.guest(rig)
	testing.expect_value(t, ruin_use(s, g, ruin_altar(r.site)), "")
	fighting_as_told(t, rig, h)
	fighting_as_told(t, rig, g)
	if !testing.expect(t, playtest.until_phase(rig, &r.phase, .Wave)) {return}
	playtest.kill(rig, g, nil)
	playtest.step(rig, 2)
	testing.expect_value(t, r.phase.now, sandbox.Ruin_Phase.Wave)
	testing.expect(t, core.respawn(s, g))
	back_as_before(t, rig, g)

	// The guest walks back in: the ward keeps it out.
	core.teleport(s, g, ruin_point(r.site, {RUIN_MID + 4, RUIN_MID + 4}), {0, 0})
	playtest.step(rig, 3)
	testing.expect(t, !ruin_inside(r.site, g.player.position), "the ward let one in")

	for n in r.wave ..= RUIN_WAVES {
		if n > r.wave && !testing.expect(t, playtest.until_phase(rig, &r.phase, .Wave)) {return}
		if !testing.expectf(t, fight_wave_cleared(rig), "wave %d was never held", n) {return}
	}
	testing.expect_value(t, r.phase.now, sandbox.Ruin_Phase.Asleep)
	back_as_before(t, rig, h)
}

// A fighter who leaves during the fight has its things back when it joins again.
@(test)
test_ruin_gives_back_on_joining :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !ruin_reach(t, rig) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	r := ruin_of(s)
	h := playtest.host(rig)
	testing.expect_value(t, ruin_use(s, h, ruin_altar(r.site)), "")
	ruin_left(s, h) // (as leaving does; the character keeps what is set aside)
	playtest.step(rig, 2)
	testing.expect_value(t, r.phase.now, sandbox.Ruin_Phase.Asleep)
	joined(s, h)
	back_as_before(t, rig, h)
	testing.expect(t, !ruin_inside(r.site, h.player.position), "it joined inside the ruin")
}
