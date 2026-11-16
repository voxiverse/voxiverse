package horde_server

import "core:os"
import "core:testing"

import "common:game"
import "common:protocol"
import "games:horde"
import "server:core"
import "server:playtest"

// Horde on a stepped server with two survivors: the host (the harness's mirror) and a
// guest over the harness's network. The creatures are killed on the server's side, as a
// shot would (core.entity_harm, credited to a survivor).

Rig :: playtest.Rig

srv :: playtest.srv
host :: playtest.host
guest :: proc(rig: ^Rig) -> ^core.Client {return playtest.guest(rig)}

// rig_start: Horde with a guest, the first run's yard built and counted down. (Not the
// engine's tests' kit, a hotbar of blocks the survivor's kit could not join: a Horde
// world gives none of its own.)
rig_start :: proc(t: ^testing.T, rig: ^Rig, save_dir := "") -> bool {
	o := playtest.Options {
		guests   = 1,
		save_dir = save_dir,
		kit      = "rocket_launcher 1",
	}
	if !playtest.start(t, rig, GAME, o) {return false}
	built :: proc(data: rawptr) -> bool {return state((^core.Server)(data)).built}
	ok := playtest.until(rig, built, srv(rig), 20)
	playtest.step(rig, 3) // (the survivors placed)
	return testing.expect(t, ok, "the yard was never built")
}

until_phase :: proc(rig: ^Rig, p: horde.Phase, seconds := 30.0) -> bool {
	return playtest.until_phase(rig, &state(srv(rig)).phase, p, seconds)
}

// clear_wave: every creature of the wave out and killed by c; true once the wave is held.
clear_wave :: proc(rig: ^Rig, c: ^core.Client) -> bool {
	s := srv(rig)
	d := state(s)
	for _ in 0 ..< 60 * game.TICK_RATE {
		if d.phase.now != .Wave {break}
		for d.foe_count > 0 {
			h, there := core.entity_find(s.home, d.foes[0].id)
			if !there {
				foe_forget(s, d.foes[0].id)
				continue
			}
			core.entity_harm(s.home, h, {amount = 100_000, kind = .Weapon, by = c})
		}
		playtest.step(rig)
	}
	return d.phase.now == .Break
}

// A run: the yard built (its walls, the shop's counter), both survivors placed with the
// pistol and rounds, the first wave out of the lairs; kills pay their killer; the wave
// held, the shop opens; the next wave comes when the break is over.
@(test)
test_horde_waves :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !rig_start(t, rig) {return}
	defer playtest.stop(rig)
	s := srv(rig)
	d := state(s)
	h, g := host(rig), guest(rig)
	b, _ := core.block_at(s.home, {-1, 5, 10})
	testing.expect_value(t, b, game.Block.Bedrock)
	b, _ = core.block_at(s.home, horde.SHOP)
	testing.expect_value(t, b, d.shop)
	pistol, _ := game.registry_item(s.registry, "horde:pistol")
	for c in ([]^core.Client{h, g}) {
		testing.expect_value(t, playtest.mode_of(rig, c), horde.SURVIVOR_MODE)
		testing.expect_value(t, game.inventory_held(&c.inventory).item, pistol)
		testing.expect(t, core.item_count(c, d.round) > 0, "no rounds to start with")
		testing.expect_value(t, survivor(s, c).coins, horde.DEFAULT_SETTINGS.coins)
	}
	testing.expect(t, h.player.position != g.player.position, "both stand in one place")

	// The first wave: its creatures come out of the lairs one by one.
	if !testing.expect(t, until_phase(rig, .Wave), "no first wave") {return}
	testing.expect_value(t, d.wave, 1)
	playtest.step(rig, 2 * game.TICK_RATE)
	testing.expect_value(t, d.foe_count + waiting(d), horde.wave_size(1))
	testing.expect(t, d.foe_count >= 3, "the creatures did not come out")
	news := playtest.guest_record(rig, horde.Run)
	testing.expect(t, news != nil && news.phase == .Wave && news.wave == 1)

	// The host kills them all: each pays its bounty; the wave is held, the shop opens.
	if !testing.expect(t, clear_wave(rig, h), "the wave was never held") {return}
	shamblers := horde.wave_plan(1).count[.Shambler]
	testing.expect_value(t, survivor(s, h).kills, shamblers)
	testing.expect_value(
		t,
		survivor(s, h).coins,
		horde.DEFAULT_SETTINGS.coins + shamblers * horde.FOES[.Shambler].bounty,
	)
	testing.expect_value(t, survivor(s, g).coins, horde.DEFAULT_SETTINGS.coins)
	testing.expect_value(t, d.best, 1)
	playtest.step(rig, 2)
	mine := playtest.host_record(rig, horde.Survivor, protocol.key_player(core.player_id(s, h)))
	testing.expect(t, mine != nil && int(mine.kills) == shamblers)

	// The break runs out: the second wave, skitters with the shamblers.
	playtest.until_seconds(rig, &d.phase, f64(d.settings.break_for) + 0.1)
	testing.expect_value(t, d.phase.now, horde.Phase.Wave)
	testing.expect_value(t, d.wave, 2)
	testing.expect(t, horde.wave_plan(2).count[.Skitter] > 0)
	testing.expect_value(t, len(rig.sess.failures), 0)
}

// A survivor who dies in a wave is down: it watches, flying and unharmed, until the wave
// is held, then stands again with the kit. When every survivor is down at once the run is
// over, and the best wave is kept with the universe.
@(test)
test_horde_down_and_over :: proc(t: ^testing.T) {
	dir := "build/test/horde_best"
	os.remove_all(dir)
	defer os.remove_all(dir)
	rig := new(Rig)
	defer free(rig)
	if !rig_start(t, rig, dir) {return}
	s := srv(rig)
	d := state(s)
	h, g := host(rig), guest(rig)
	if !testing.expect(t, until_phase(rig, .Wave), "no first wave") {
		playtest.stop(rig)
		return
	}
	testing.expect_value(t, playtest.kill(rig, g, nil), core.Damage_Result.Killed)
	testing.expect(t, survivor(s, g).down)
	playtest.step(rig, 2 * game.TICK_RATE) // (back by itself, to watch)
	testing.expect(t, !g.dead)
	testing.expect_value(t, playtest.mode_of(rig, g), horde.WATCHER_MODE)
	testing.expect(t, g.player.flying, "a watcher does not fly")
	testing.expect_value(t, d.phase.now, horde.Phase.Wave) // (the host still stands)
	testing.expect(t, clear_wave(rig, h), "the wave was never held")
	playtest.step(rig, 2)
	testing.expect(t, !survivor(s, g).down, "still down after the wave")
	testing.expect_value(t, playtest.mode_of(rig, g), horde.SURVIVOR_MODE)

	// Two waves held; in the third both go down: the run is over at two.
	playtest.say(rig, "horde wave")
	testing.expect(t, clear_wave(rig, h), "the second wave was never held")
	playtest.say(rig, "horde wave")
	testing.expect_value(t, d.wave, 3)
	playtest.kill(rig, g, nil)
	testing.expect_value(t, d.phase.now, horde.Phase.Wave)
	playtest.kill(rig, h, nil)
	playtest.step(rig)
	testing.expect_value(t, d.phase.now, horde.Phase.Over)
	testing.expect_value(t, d.best, 2)
	testing.expect_value(t, d.foe_count, 0)
	playtest.step(rig, 2)
	over := playtest.guest_record(rig, horde.Run)
	testing.expect(t, over != nil && over.phase == .Over && over.best == 2, "the end was not told")
	// The next run begins on a new yard.
	seed := d.seed
	if !testing.expect(t, until_phase(rig, .Countdown, horde.OVER + 2), "no next run") {
		playtest.stop(rig)
		return
	}
	testing.expect_value(t, d.run, 2)
	testing.expect(t, d.seed != seed, "the same yard again")
	playtest.stop(rig)

	// The best is kept with the universe.
	rig^ = {}
	if !playtest.start(t, rig, GAME, {save_dir = dir}) {return}
	defer playtest.stop(rig)
	testing.expect_value(t, state(srv(rig)).best, 2)
}

// The shop: open between waves, at the counter, for those who can pay: rounds, a medkit,
// then the rifle and the shotgun, each gun dearer; refused otherwise, and told why. Its
// prices are the admin's settings.
@(test)
test_horde_shop :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !rig_start(t, rig) {return}
	defer playtest.stop(rig)
	s := srv(rig)
	d := state(s)
	h := host(rig)
	r := survivor(s, h)
	core.teleport(s, h, {6.5, 1, 18.5}, {0, 0})
	testing.expect(t, !buy(s, h, .Rounds), "bought away from the counter")
	playtest.step(rig, 2)
	testing.expect(t, playtest.told(rig, "Horde: go to the shop"))
	playtest.say(rig, "horde shop")
	testing.expect(t, at_shop(h), "/horde shop is not at the counter")
	rounds := core.item_count(h, d.round)
	testing.expect(t, buy(s, h, .Rounds))
	testing.expect_value(t, core.item_count(h, d.round), rounds + horde.ROUNDS_PACK)
	testing.expect_value(t, r.coins, horde.DEFAULT_SETTINGS.coins - horde.DEFAULT_SETTINGS.rounds)
	testing.expect(t, !buy(s, h, .Gun), "a gun bought with too few coins")
	playtest.step(rig, 2)
	testing.expect(t, playtest.told(rig, "Horde: a gun costs"))
	playtest.say(rig, "horde purse 200")
	testing.expect(t, buy(s, h, .Gun))
	rifle, _ := game.registry_item(s.registry, "horde:rifle")
	testing.expect_value(t, game.inventory_held(&h.inventory).item, rifle)
	paid := r.coins
	testing.expect(t, buy(s, h, .Gun))
	testing.expect_value(t, paid - r.coins, horde.DEFAULT_SETTINGS.gun * 3 / 2)
	testing.expect(t, !buy(s, h, .Gun), "a third gun")
	playtest.step(rig, 2)
	testing.expect(t, playtest.told(rig, "Horde: you have every gun"))
	h.health = 3
	testing.expect(t, buy(s, h, .Medkit))
	testing.expect_value(t, h.health, f32(3 + horde.MEDKIT_HEAL))

	// The settings: an admin's, in their bounds.
	playtest.say(rig, "horde rounds 5")
	testing.expect_value(t, d.settings.rounds, 5)
	playtest.say(rig, "horde rounds 5000")
	testing.expect_value(t, d.settings.rounds, 5)
	// In a wave the shop is shut.
	playtest.say(rig, "horde wave")
	testing.expect(t, !buy(s, h, .Rounds), "bought in a wave")
	playtest.step(rig, 2)
	testing.expect(t, playtest.told(rig, "Horde: the shop opens between waves"))
}

// A creature goes for the nearest survivor standing and hurts it; a spitter keeps its
// distance and spits.
@(test)
test_horde_creatures_hunt :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !rig_start(t, rig) {return}
	defer playtest.stop(rig)
	s := srv(rig)
	d := state(s)
	h, g := host(rig), guest(rig)
	if !testing.expect(t, until_phase(rig, .Wave), "no wave") {return}
	d.coming = {} // (only the test's creatures)
	foes_clear(s)
	core.teleport(s, g, {4.5, 1, 30.5}, {0, 0}) // (far: the host is the nearest)
	at := h.player.position + {4, 0, 0}
	testing.expect(t, foe_spawn(s, .Shambler, at) != 0)
	before := h.health
	playtest.step(rig, 6 * game.TICK_RATE)
	testing.expect(t, h.health < before, "the shambler never struck")
	foes_clear(s)
	h.health = h.max_health
	testing.expect(t, foe_spawn(s, .Spitter, h.player.position + {9, 0, 0}) != 0)
	before = h.health
	playtest.step(rig, 6 * game.TICK_RATE)
	testing.expect(t, h.health < before, "the spitter never spat")
	sp, there := core.entity_find(s.home, d.foes[0].id)
	if testing.expect(t, there) {
		dd := core.entity_pos(s.home, sp) - h.player.position
		testing.expectf(t, dd.x * dd.x + dd.z * dd.z > 9, "the spitter came within %v", dd)
	}
}

// The waves: bigger as they go, new kinds joining, the matriarch every fifth.
@(test)
test_horde_wave_plans :: proc(t: ^testing.T) {
	for n in 1 ..= 12 {
		p := horde.wave_plan(n)
		testing.expect_value(t, p.count[.Matriarch], 1 if n % horde.BOSS_EVERY == 0 else 0)
		if n > 1 {testing.expect(t, horde.wave_size(n) > horde.wave_size(n - 1))}
	}
	testing.expect_value(t, horde.wave_plan(1).count[.Skitter], 0)
	testing.expect(t, horde.wave_plan(4).count[.Hulk] > 0)
}
