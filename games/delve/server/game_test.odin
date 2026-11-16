package delve_server

import "core:os"
import "core:path/filepath"
import "core:testing"

import "common:game"
import "games:delve"
import "server:core"

// Delve on a stepped server: the host (the harness's mirror, on the local pipe, standing
// still where it is put) and, for the test of two, a guest over the harness's network.
// Creatures are made where a test wants them (foe_spawn), and blows are struck through
// the engine's own swing, as a click's would be.

Rig :: struct {
	sess:  core.Session,
	guest: core.Harness_Player,
	with:  bool, // the guest joined
}

rig_start :: proc(t: ^testing.T, rig: ^Rig, guest := false, dir := "") -> bool {
	config := core.harness_world()
	config.game = GAME
	config.listen = true
	config.kit = ""
	config.save_dir = dir
	if !testing.expect(t, core.session_start(&rig.sess, {}, false, with = config)) {return false}
	if guest {
		core.harness_player_join(&rig.sess.h, &rig.guest, "guest")
		rig.with = true
	}
	ready :: proc(data: rawptr) -> bool {
		rig := (^Rig)(data)
		s := &rig.sess.h.srv
		if !rig.sess.mirror.welcomed ||
		   s.clients[0].state != .Playing ||
		   state(s).phase == .Building {
			return false
		}
		if rig.with {
			g := core.harness_player_client(&rig.guest)
			return g != nil && g.state == .Playing
		}
		return true
	}
	_, ok := core.harness_step_until(&rig.sess.h, ready, rig, 900)
	if ok {step(rig, 2)} 	// (the delvers placed: enter's teleport)
	return testing.expect(t, ok, "the dungeon was never built, or the delvers never came")
}

rig_stop :: proc(rig: ^Rig) {
	core.session_stop(&rig.sess)
	if rig.with {core.harness_player_free(&rig.guest)}
}

srv :: proc(rig: ^Rig) -> ^core.Server {return &rig.sess.h.srv}
host :: proc(rig: ^Rig) -> ^core.Client {return &rig.sess.h.srv.clients[0]}
step :: proc(rig: ^Rig, n := 1) {core.harness_step(&rig.sess.h, n)}

// clear_room: the start room with no creature in it but those the test makes (none is
// made there; the corridors' may wander in, so all of them sleep far off: gone).
clear_dungeon :: proc(s: ^core.Server) {
	d := state(s)
	for d.foe_count > 0 {
		if h, there := core.entity_find(s.home, d.foes[0].id); there {core.entity_gone(s.home, h)}
		foe_forget(s, d.foes[0].id)
	}
	d.warden = 0
}

// The dungeon is one piece: from the start room a walker reaches the warden's room and
// every other, at every depth; the warden's room is not the start.
@(test)
test_dungeon_is_connected :: proc(t: ^testing.T) {
	plan := new(delve.Dungeon)
	defer free(plan)
	for depth in 1 ..= 6 {
		for seed in u32(1) ..= 25 {
			delve.dungeon_plan(plan, seed * 7919, depth)
			size := delve.dungeon_size(plan)
			testing.expect(t, plan.boss != plan.start)
			testing.expect_value(t, plan.room_count, plan.grid.x * plan.grid.y)
			// A flood over the open floor from the start room's middle.
			seen := make([]bool, int(size.x * size.y), context.temp_allocator)
			queue := make([dynamic][2]i32, context.temp_allocator)
			from := delve.room_middle(plan.rooms[plan.start].area)
			append(&queue, from)
			seen[from.y * size.x + from.x] = true
			for i := 0; i < len(queue); i += 1 {
				p := queue[i]
				for dir in ([4][2]i32{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
					n := p + dir
					if n.x < 0 || n.y < 0 || n.x >= size.x || n.y >= size.y {continue}
					if seen[n.y * size.x + n.x] || !delve.dungeon_open(plan, n.x, n.y) {continue}
					seen[n.y * size.x + n.x] = true
					append(&queue, n)
				}
			}
			for room, r in plan.rooms[:plan.room_count] {
				m := delve.room_middle(room.area)
				testing.expectf(
					t,
					seen[m.y * size.x + m.x],
					"depth %d seed %d: room %d cut off",
					depth,
					seed,
					r,
				)
			}
		}
	}
}

// A husk made near a delver notices it, walks up and strikes; the blow is the husk's
// (credited to it) and lands on the delver.
@(test)
test_creature_notices_chases_and_hurts :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !rig_start(t, rig) {
		rig_stop(rig)
		return
	}
	defer rig_stop(rig)
	s := srv(rig)
	clear_dungeon(s)
	c := host(rig)
	full := c.health
	start := c.player.position
	h := foe_spawn(s, .Husk, start + {3, 0, 0}, false)
	if !testing.expect(t, h != 0) {return}
	id := core.entity_id(s.home, h)
	woke, hurt := false, false
	for _ in 0 ..< 240 {
		step(rig)
		woke ||= foe_of(s, id).awake
		if c.health < full {
			hurt = true
			break
		}
	}
	testing.expect(t, woke, "the husk never noticed the delver")
	testing.expect(t, hurt, "the husk never hurt the delver")
	p := core.entity_pos(s.home, h)
	testing.expectf(
		t,
		flat_distance(p, start) < 2,
		"the husk struck from %v blocks",
		flat_distance(p, start),
	)
}

// A spitter made two blocks from a delver in a big room backs off to its band and spits
// from there.
@(test)
test_spitter_keeps_its_distance :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !rig_start(t, rig) {
		rig_stop(rig)
		return
	}
	defer rig_stop(rig)
	s := srv(rig)
	clear_dungeon(s)
	c := host(rig)
	// In the dungeon's biggest room, where there is room to keep away.
	d := state(s)
	big := 0
	area :: proc(a: delve.Area) -> i32 {return min(a.hi.x - a.lo.x, a.hi.y - a.lo.y)}
	for room, i in d.plan.rooms[:d.plan.room_count] {
		if area(room.area) > area(d.plan.rooms[big].area) {big = i}
	}
	core.teleport(s, c, room_point(d.plan.rooms[big].area), {0, 0}, flying = false)
	step(rig, 2)
	full := c.health
	h := foe_spawn(s, .Spitter, c.player.position + {0, 0, 2}, false)
	if !testing.expect(t, h != 0) {return}
	near := max(f64)
	far: f64
	for i in 0 ..< 240 {
		step(rig)
		if i < 90 {continue}
		dist := flat_distance(core.entity_pos(s.home, h), c.player.position)
		near, far = min(near, dist), max(far, dist)
	}
	info := delve.FOES[.Spitter]
	testing.expectf(
		t,
		near >= f64(info.keep[0]) - 0.6 && far <= f64(info.keep[1]) + 0.6,
		"the spitter kept %v..%v blocks",
		near,
		far,
	)
	testing.expect(t, c.health < full, "the spitter's spit never landed")
}

// A delver's sword swing: the sword's 4, times its level's 1.2 and its roll's 1.5 (a
// critical hit doubles that), on a husk of 12.
@(test)
test_melee_kills_by_the_weapons_numbers :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !rig_start(t, rig) {
		rig_stop(rig)
		return
	}
	defer rig_stop(rig)
	s := srv(rig)
	d := state(s)
	clear_dungeon(s)
	c := host(rig)
	seat(s, c).level = 3
	c.inventory.slots[0] = {d.weapons[.Sword], 1, 0, delve.loot_data(.Rare, 50)}
	core.hotbar_select(s, c, 0)
	c.look = {0, 0}
	h := foe_spawn(s, .Husk, c.player.position + {0, 0, -1.6}, false)
	if !testing.expect(t, h != 0) {return}
	core.entity_stand(s.home, h)
	id := core.entity_id(s.home, h)
	health := core.entity_health_of(s.home, h)
	testing.expect_value(t, health, 12)
	held := game.inventory_held(&c.inventory)
	info, _ := game.item_info(s.registry, held.item)
	melee, _ := info.melee.?
	testing.expect_value(t, core.swing(s, c, held, melee), 1)
	// 4 x 1.2 x 1.5 = 7.2: 7 taken; a critical 14 kills.
	_, alive := core.entity_find(s.home, id)
	if alive {
		testing.expect_value(t, core.entity_health_of(s.home, h), 12 - 7)
	}
	for _ in 0 ..< 4 {
		if _, there := core.entity_find(s.home, id); !there {break}
		step(rig, 15)
		core.entity_set_pos(s.home, h, c.player.position + {0, 0, -1.6})
		core.swing(s, c, game.inventory_held(&c.inventory), melee)
	}
	_, alive = core.entity_find(s.home, id)
	testing.expect(t, !alive, "the husk lived through two swings")
	testing.expect_value(t, seat(s, c).kills, 1)
	testing.expect_value(t, seat(s, c).xp, delve.FOES[.Husk].xp)
}

// Experience levels a delver: its most health rises by the level's, and it is told.
@(test)
test_experience_levels_the_delver :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !rig_start(t, rig) {
		rig_stop(rig)
		return
	}
	defer rig_stop(rig)
	s := srv(rig)
	c := host(rig)
	most := c.max_health
	gain(s, c, delve.xp_to_next(1) + delve.xp_to_next(2) + 5)
	step(rig, 2)
	testing.expect_value(t, seat(s, c).level, 3)
	testing.expect_value(t, seat(s, c).xp, 5)
	testing.expect_value(t, c.max_health, most + delve.level_health(3))
	hero := core.mirror_game_record(&rig.sess.mirror, delve.Hero, game.key_player(0))
	if testing.expect(t, hero != nil) {testing.expect_value(t, hero.level, 3)}
}

// A delver who dies wakes in the start room, its experience towards the next level and
// half its coins gone, its level kept.
@(test)
test_death_respawns_at_the_start :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !rig_start(t, rig) {
		rig_stop(rig)
		return
	}
	defer rig_stop(rig)
	s := srv(rig)
	d := state(s)
	c := host(rig)
	seat(s, c).level, seat(s, c).xp = 2, 30
	core.item_give(s, c, d.coin, 40)
	far := room_point(d.plan.rooms[d.plan.boss].area)
	core.teleport(s, c, far, {0, 0}, flying = false)
	step(rig, 2)
	core.damage(s, c, 1000, {kind = .Command})
	testing.expect(t, c.dead)
	step(rig, 3 * game.TICK_RATE)
	core.respawn_ask(s, c)
	step(rig, 2)
	testing.expect(t, !c.dead)
	testing.expectf(
		t,
		flat_distance(c.player.position, start_point(s)) < 1,
		"woke at %v",
		c.player.position,
	)
	testing.expect_value(t, seat(s, c).level, 2)
	testing.expect_value(t, seat(s, c).xp, 0)
	testing.expect_value(t, core.item_count(c, d.coin), 20)
	testing.expect_value(t, seat(s, c).deaths, 1)
}

// Loot: a weapon dropped with its roll is picked up by walking over it, and after a
// save and a restart the delver still has it, roll and all, and its level.
@(test)
test_loot_keeps_its_roll_through_a_save :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "delve_loot"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	data: u32
	{
		rig := new(Rig)
		defer free(rig)
		if !rig_start(t, rig, dir = dir) {
			rig_stop(rig)
			return
		}
		s := srv(rig)
		d := state(s)
		clear_dungeon(s)
		c := host(rig)
		data = delve.loot_data(.Fabled, 71)
		core.item_drop(s, s.home, c.player.position + {0.4, 0.5, 0}, {d.weapons[.Axe], 1, 0, data})
		step(rig, 60)
		found := false
		for st in c.inventory.slots {found ||= st.item == d.weapons[.Axe] && st.data == data}
		testing.expect(t, found, "the axe was not picked up with its roll")
		seat(s, c).level = 4
		rig_stop(rig)
	}
	rig := new(Rig)
	defer free(rig)
	if !rig_start(t, rig, dir = dir) {
		rig_stop(rig)
		return
	}
	defer rig_stop(rig)
	s := srv(rig)
	c := host(rig)
	found := false
	for st in c.inventory.slots {found ||= st.item == state(s).weapons[.Axe] && st.data == data}
	testing.expect(t, found, "the axe's roll did not come back")
	testing.expect_value(t, seat(s, c).level, 4)
}

// The warden's death opens the way down; a delver stepping on it takes everyone to the
// next dungeon, deeper, whose creatures are tougher.
@(test)
test_the_warden_opens_the_way_down :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !rig_start(t, rig) {
		rig_stop(rig)
		return
	}
	defer rig_stop(rig)
	s := srv(rig)
	d := state(s)
	c := host(rig)
	testing.expect_value(t, d.depth, 1)
	h, there := core.entity_find(s.home, d.warden)
	if !testing.expect(t, there, "no warden") {return}
	warden_health := core.entity_max_health(s.home, h)
	core.entity_harm(s.home, h, {amount = 10000, kind = .Game, by = c})
	testing.expect_value(t, d.phase, delve.Phase.Open)
	e := exit_area(s)
	b, _ := core.block_at(s.home, e.lo)
	testing.expect_value(t, b, d.exit)
	core.teleport(s, c, {f64(e.lo.x) + 1.5, 0, f64(e.lo.z) + 1.5}, {0, 0}, flying = false)
	_, down := core.harness_step_until(&rig.sess.h, proc(data: rawptr) -> bool {
			return(
				state(srv((^Rig)(data))).depth == 2 &&
				state(srv((^Rig)(data))).phase == .Delving \
			)
		}, rig, 900)
	if !testing.expect(t, down, "never went down") {return}
	step(rig, 2)
	testing.expectf(
		t,
		flat_distance(c.player.position, start_point(s)) < 1,
		"the delver is at %v",
		c.player.position,
	)
	if w2, ok := core.entity_find(s.home, d.warden); testing.expect(t, ok) {
		testing.expect(
			t,
			core.entity_max_health(s.home, w2) > warden_health,
			"the deeper warden is no tougher",
		)
	}
	testing.expect_value(t, seat(s, c).best, 2)
}

// Two delvers share the dungeon: both are told each other's progress, both stand in the
// start room, and a kill near both gives both its experience.
@(test)
test_two_delvers_share_it :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !rig_start(t, rig, guest = true) {
		rig_stop(rig)
		return
	}
	defer rig_stop(rig)
	s := srv(rig)
	clear_dungeon(s)
	c := host(rig)
	g := core.harness_player_client(&rig.guest)
	testing.expect(
		t,
		flat_distance(g.player.position, start_point(s)) < 1,
		"the guest is not in the start room",
	)
	h := foe_spawn(s, .Biter, c.player.position + {1, 0, 0}, false)
	core.entity_harm(s.home, h, {amount = 1000, kind = .Game, by = c})
	step(rig, 3)
	testing.expect_value(t, seat(s, c).xp, delve.FOES[.Biter].xp)
	testing.expect_value(t, seat(s, g).xp, delve.FOES[.Biter].xp)
	testing.expect_value(t, seat(s, c).kills, 1)
	theirs := core.harness_player_record(&rig.guest, delve.Hero, game.key_player(0))
	if testing.expect(t, theirs != nil, "the guest was not told the host's progress") {
		testing.expect_value(t, theirs.kills, 1)
	}
}
