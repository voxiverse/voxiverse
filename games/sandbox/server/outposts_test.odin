package sandbox_server

import "core:os"
import "core:testing"

import "common:game"
import "games:sandbox"
import "server:core"
import "server:playtest"

// Outposts: a beacon placed makes one (its placer's respawn), taken down unmakes it; only
// its placer may take it down; nothing hostile comes by itself near one; a death stands its
// player there; the world keeps them and the character its respawn through a restart.

// place_beacon: the host places a beacon at `at` (the block and the game told, as a player's
// edit is told).
place_beacon :: proc(rig: ^Rig, at: game.Block_Pos) {
	s := playtest.srv(rig)
	g := survival_of(s)
	core.set_block(s.home, at, g.beacon, core.game_act(s, s.home, .Command))
	outposts_changed(
		s,
		s.home,
		{area = {at, at}, old = .Air, new = g.beacon, by = playtest.host(rig)},
	)
}

@(test)
test_outpost_respawn_and_removal :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !survivor(t, rig) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	h := playtest.host(rig)
	at := game.Block_Pos{9, 0, 9}
	place_beacon(rig, at)
	o := outposts_of(s.home)
	testing.expect_value(t, o.count, 1)
	testing.expect(t, playtest.told(rig, "Outpost made: you will stand here again after a death"))
	playtest.step(rig, SURVIVAL_EVERY + 1)
	shown := playtest.host_record(rig, sandbox.Survival)
	if testing.expect(t, shown != nil && shown.count == 1) {
		testing.expect_value(t, shown.outposts[0], sandbox.Outpost_Line{{9, 0, 9}, true, true})
	}

	// A death stands it on the beacon.
	core.teleport(s, h, {-8.5, 0, -8.5}, {0, 0})
	playtest.step(rig, 10)
	playtest.kill(rig, h, nil)
	testing.expect(t, core.respawn(s, h))
	playtest.step(rig, 20)
	p := h.player.position
	testing.expectf(t, abs(p.x - 9.5) < 1 && abs(p.z - 9.5) < 1, "stood at %v, not the outpost", p)

	// Taken down: no outpost, and the next death is at the world's spawn.
	g := survival_of(s)
	core.set_block(s.home, at, .Air, core.game_act(s, s.home, .Command))
	outposts_changed(s, s.home, {area = {at, at}, old = g.beacon, new = .Air, by = h})
	testing.expect_value(t, o.count, 0)
	_, has := outpost_home(s, h)
	testing.expect(t, !has, "a respawn at a beacon that is gone")
}

// A beacon is its placer's to take down; another player is told whose it is.
@(test)
test_outpost_belongs_to_its_placer :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME, {guests = 1}) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	g := survival_of(s)
	at := game.Block_Pos{3, 0, 3}
	place_beacon(rig, at)
	guest := playtest.guest(rig)
	why := outpost_editing(s, guest, at, g.beacon, .Air)
	testing.expectf(t, why != "", "the guest took the host's beacon down")
	testing.expect_value(t, outpost_editing(s, playtest.host(rig), at, g.beacon, .Air), "")
	// Using it makes it the guest's respawn too (everyone on the server may use one).
	testing.expect_value(t, outpost_use(s, guest, at), "")
	_, has := outpost_home(s, guest)
	testing.expect(t, has)
}

// Nothing hostile comes by itself within OUTPOST_RADIUS of a beacon, the home world's
// predators and guards (wild.odin) as much as the night's shamblers; outside it, and a
// creature that does not fight (a sheep), comes as ever.
@(test)
test_outpost_keeps_creatures_off :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !meadow(t, rig) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	w := s.home
	place_beacon(rig, {0, 0, 0})
	shambler, _ := game.registry_kind(s.registry, "voxiverse:shambler")
	near := core.entity_spawn(w, shambler, {10.5, 0, 10.5}, true)
	far := core.entity_spawn(w, shambler, {sandbox.OUTPOST_RADIUS + 10.5, 0, 0.5}, true)
	lamb := core.entity_spawn(w, state(s).sheep, {5.5, 0, 5.5}, true)
	if !testing.expect(t, near != 0 && far != 0 && lamb != 0) {return}
	testing.expect(t, !spawned(s, w, near), "a shambler came by itself beside a beacon")
	testing.expect(t, spawned(s, w, far), "a shambler was kept off far from any beacon")
	testing.expect(t, spawned(s, w, lamb), "a sheep was kept off")
	groups := WILD_GROUPS
	for group in groups {
		if group.name != "predators" && group.name != "guards" {continue}
		for which in group.kinds {
			h := core.entity_spawn(w, state(s).wild[which], {-12.5, 0, 8.5}, true)
			if !testing.expectf(t, h != 0, "no %v set down", which) {continue}
			testing.expectf(t, !spawned(s, w, h), "a %v came by itself beside a beacon", which)
		}
	}
}

// The outposts file: written and read back the same; a cut file or a bad CRC is refused.
// Through a restart the world keeps its outposts and the character its respawn.
@(test)
test_outposts_saved :: proc(t: ^testing.T) {
	o: Outposts
	testing.expect(t, outpost_add(&o, {1, -2, 3}, "ana"))
	testing.expect(t, outpost_add(&o, {-40, 60, 7}, "bo"))
	data := outposts_encode(&o, context.temp_allocator)
	back, ok := outposts_decode(data)
	testing.expect(t, ok)
	testing.expect_value(t, back.count, 2)
	testing.expect_value(t, back.list[1].at, game.Block_Pos{-40, 60, 7})
	testing.expect_value(t, outpost_owner(&back.list[0]), "ana")
	_, ok = outposts_decode(data[:len(data) - 1])
	testing.expect(t, !ok, "a cut file read")
	bad := make([]u8, len(data), context.temp_allocator)
	copy(bad, data)
	bad[13] ~= 1
	_, ok = outposts_decode(bad)
	testing.expect(t, !ok, "a bad CRC read")

	dir :: "build/tmp/sandbox_outposts_saved"
	os.remove_all(dir)
	defer os.remove_all(dir)
	rig := new(Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME, {save_dir = dir}) {return}
	place_beacon(rig, {5, 0, 5})
	playtest.say(rig, "save")
	playtest.stop(rig)
	again := new(Rig)
	defer free(again)
	if !playtest.start(t, again, GAME, {save_dir = dir}) {return}
	defer playtest.stop(again)
	s := playtest.srv(again)
	testing.expect_value(t, outposts_of(s.home).count, 1)
	place, has := outpost_home(s, playtest.host(again))
	testing.expect(t, has, "the character's respawn was not kept")
	testing.expect_value(t, place.position, [3]f64{5.5, 1, 5.5})
}
