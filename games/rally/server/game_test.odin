package rally_server

import "core:os"
import "core:testing"

import "common:game"
import "common:protocol"
import "games:rally"
import "server:core"
import "server:playtest"

// Rally on a stepped server: the host (the harness's mirror) and, for the race of two, a
// guest over the harness's network. Racers are moved on the server's side
// (core.teleport), as their own feet would carry them.

Rig :: playtest.Rig

srv :: playtest.srv
host :: playtest.host

// rig_start: Rally (with a guest, or not), the course built and the first race counted.
rig_start :: proc(t: ^testing.T, rig: ^Rig, guests := 0, save_dir := "") -> bool {
	if !playtest.start(
		t,
		rig,
		GAME,
		{guests = guests, save_dir = save_dir, kit = "rocket_launcher 1"},
	) {
		return false
	}
	counting :: proc(data: rawptr) -> bool {return(
			state((^core.Server)(data)).phase.now ==
			.Countdown \
		)}
	ok := playtest.until(rig, counting, srv(rig), 20)
	playtest.step(rig, 3)
	return testing.expect(t, ok, "no race was counted down")
}

until_phase :: proc(rig: ^Rig, p: rally.Phase, seconds := 20.0) -> bool {
	return playtest.until_phase(rig, &state(srv(rig)).phase, p, seconds)
}

// go_to: c stands at gate k (0: the start), and the ticks for the server to see it.
go_to :: proc(rig: ^Rig, c: ^core.Client, k: int) {
	s := srv(rig)
	core.teleport(s, c, place_at(&state(s).course, k, 0), EAST)
	playtest.step(rig, 3)
}

// The course of a seed: the start, every gate in order eastward, the last the finish; every
// gap a running jump (or, under a hook post, a hook's); all of it inside the area built;
// and the same plan for the same seed on both sides.
@(test)
test_rally_course :: proc(t: ^testing.T) {
	for seed in ([]u32{1, 66, 4242}) {
		c := rally.course_plan(seed)
		testing.expect_value(t, c.platforms[0].kind, rally.Platform_Kind.Start)
		gates := 0
		for p, i in c.platforms[:c.count] {
			if p.kind == .Gate || p.kind == .Finish {gates += 1}
			testing.expect(
				t,
				p.lo.x >= AREA.lo.x && p.hi.x <= AREA.hi.x,
				"a platform past the area",
			)
			testing.expect(
				t,
				p.lo.z >= AREA.lo.z && p.hi.z <= AREA.hi.z,
				"a platform past the area",
			)
			if i == 0 {continue}
			gap := p.lo.x - c.platforms[i - 1].hi.x - 1
			hooked := false
			for post in c.posts {hooked ||= post.x != 0 && post.x > c.platforms[i - 1].hi.x && post.x < p.lo.x}
			testing.expectf(t, gap <= 4 || (hooked && gap <= 7), "seed %d: a gap of %d", seed, gap)
		}
		testing.expect_value(t, gates, rally.CHECKPOINTS)
		testing.expect_value(t, c.platforms[c.count - 1].kind, rally.Platform_Kind.Finish)
		for k in 1 ..= rally.CHECKPOINTS {testing.expect(t, c.checkpoints[k].x > c.checkpoints[k - 1].x)}
		testing.expect(
			t,
			seed != 66 || c.hazard_n > 0,
			"the harness's course has no hazard to test",
		)
		again := rally.course_plan(seed)
		testing.expect(t, again == c, "the plan is not the seed's alone")
	}
}

// A race of two: counted down with both on the start (one who steps off is put back);
// on the off, the gates in order: one passed out of order counts for nothing, a fall and a
// hazard send a racer back to its last gate; every gate a split, the last a finish, the
// first finish a personal best and the course record, told to both; when both are in,
// the results, then the next race.
@(test)
test_rally_race :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !rig_start(t, rig, guests = 1) {return}
	defer playtest.stop(rig)
	s := srv(rig)
	d := state(s)
	h, g := host(rig), playtest.guest(rig)
	testing.expect_value(t, d.countdown, rally.COUNTDOWN_MANY)
	b, _ := core.block_at(s.home, {3, rally.TOP, 0})
	testing.expect_value(t, b, d.pad)
	hook, _ := game.registry_item(s.registry, "grappling_hook")
	for c in ([]^core.Client{h, g}) {
		testing.expect_value(t, playtest.mode_of(rig, c), rally.RACER_MODE)
		testing.expect_value(t, game.inventory_held(&c.inventory).item, hook)
		testing.expect(t, rally.at_checkpoint(&d.course, 0, c.player.position), "not on the start")
	}
	go_to(rig, h, 2) // (stepping off before the off: put back)
	testing.expect(t, rally.at_checkpoint(&d.course, 0, h.player.position), "left the start early")

	if !testing.expect(t, until_phase(rig, .Racing), "no off") {return}
	// Gate 2 before gate 1 counts for nothing.
	go_to(rig, h, 2)
	testing.expect_value(t, runner(s, h).next, 1)
	go_to(rig, h, 1)
	testing.expect_value(t, runner(s, h).next, 2)
	testing.expect(t, runner(s, h).splits[1] > 0)
	// A fall: back at gate 1.
	core.teleport(s, h, {40, rally.FALL - 3, 0}, EAST, flying = false)
	playtest.step(rig, 3)
	testing.expect_value(t, runner(s, h).resets, 1)
	testing.expect(
		t,
		rally.at_checkpoint(&d.course, 1, h.player.position),
		"a fall did not send back",
	)
	// A hazard (the guest, on its strip): back at the start.
	if d.course.hazard_n > 0 {
		hz := d.course.hazards[0].lo
		core.teleport(s, g, {f64(hz.x) + 0.5, f64(hz.y) + 1, f64(hz.z) + 0.5}, EAST)
		playtest.step(rig, 3)
		testing.expect_value(t, runner(s, g).resets, 1)
		testing.expect(
			t,
			rally.at_checkpoint(&d.course, 0, g.player.position),
			"a hazard did not send back",
		)
	}
	// The host runs the rest: its splits, then its finish, a course record.
	for k in 2 ..= rally.CHECKPOINTS {go_to(rig, h, k)}
	r := runner(s, h)
	testing.expect_value(t, r.next, rally.CHECKPOINTS + 1)
	testing.expect(t, r.time > 0 && r.time == r.splits[rally.CHECKPOINTS])
	testing.expect_value(t, d.record.ticks, r.time)
	testing.expect_value(t, best_name(&d.record), core.client_name(h))
	testing.expect_value(t, d.phase.now, rally.Phase.Racing) // (the guest is still out)
	playtest.step(rig, 2)
	race := playtest.guest_record(rig, rally.Race)
	testing.expect(t, race != nil && race.record == r.time && race.finished == 1)
	mine := playtest.host_record(rig, rally.Racer, protocol.key_player(core.player_id(s, h)))
	testing.expect(t, mine != nil && mine.best == r.time && mine.next == rally.CHECKPOINTS + 1)
	// The guest finishes, slower: no record; the race is over.
	for k in 1 ..= rally.CHECKPOINTS {go_to(rig, g, k)}
	testing.expect(t, runner(s, g).time > r.time)
	testing.expect_value(t, d.record.ticks, r.time)
	testing.expect_value(t, d.phase.now, rally.Phase.Results)
	if !testing.expect(t, until_phase(rig, .Countdown, rally.RESULTS + 1), "no next race") {return}
	testing.expect_value(t, d.race, 2)
	testing.expect_value(t, runner(s, h).next, 1)
	testing.expect_value(t, len(rig.sess.failures), 0)
}

// Alone, a race counts down the shorter count. The bests are kept with the universe:
// a second run of the course, faster, is told its splits against the first's and becomes
// the best; the record and the bests are there after a restart.
@(test)
test_rally_bests_kept :: proc(t: ^testing.T) {
	dir := "build/test/rally_bests"
	os.remove_all(dir)
	defer os.remove_all(dir)
	rig := new(Rig)
	defer free(rig)
	if !rig_start(t, rig, save_dir = dir) {return}
	s := srv(rig)
	d := state(s)
	h := host(rig)
	testing.expect_value(t, d.countdown, rally.COUNTDOWN)
	run_course :: proc(rig: ^Rig, c: ^core.Client, wait: int) {
		for k in 1 ..= rally.CHECKPOINTS {
			playtest.step(rig, wait)
			go_to(rig, c, k)
		}
	}
	if !testing.expect(t, until_phase(rig, .Racing), "no off") {
		playtest.stop(rig)
		return
	}
	run_course(rig, h, 20)
	first := runner(s, h).time
	testing.expect(t, first > 0, "never finished")
	if !testing.expect(t, until_phase(rig, .Racing, 15), "no second race") {
		playtest.stop(rig)
		return
	}
	run_course(rig, h, 5)
	second := runner(s, h).time
	testing.expect(t, second < first, "the second run was not faster")
	b := kept(s, core.client_name(h))
	testing.expect(t, b != nil && b.ticks == second, "the faster run is not the best")
	testing.expect_value(t, d.record.ticks, second)
	playtest.stop(rig)

	rig^ = {}
	if !playtest.start(t, rig, GAME, {save_dir = dir}) {return}
	defer playtest.stop(rig)
	s = srv(rig)
	testing.expect_value(t, state(s).record.ticks, second)
	b = kept(s, best_name(&state(s).record))
	testing.expect(t, b != nil && b.ticks == second && b.splits[rally.CHECKPOINTS] == second)
}
