package flood_server

import "core:strings"
import "core:testing"

import "common:game"
import "games:flood"
import "server:core"

// Flood on a stepped server with the local player (the harness's mirror client): a round
// is built, counted down and played; the water rises by its rule; a head under water puts
// the player out; the goal wins; the commands start rounds; and the mirror is told.

// Rig: the session and the shortcuts every test takes.
Rig :: struct {
	sess: core.Session,
}

// rig_start: Flood on a stepped server, the player welcomed and the first round placed.
rig_start :: proc(t: ^testing.T, rig: ^Rig) -> bool {
	config := core.harness_world()
	config.game = GAME
	config.kit = "rocket_launcher 1" // (a real world's: the engine's tests fill the hotbar with blocks)
	if !testing.expect(t, core.session_start(&rig.sess, {}, false, with = config)) {return false}
	welcomed :: proc(data: rawptr) -> bool {return (^core.Session)(data).mirror.welcomed}
	_, ok := core.harness_step_until(&rig.sess.h, welcomed, &rig.sess, 600)
	return testing.expect(t, ok, "the player never joined")
}

srv :: proc(rig: ^Rig) -> ^core.Server {return &rig.sess.h.srv}
player :: proc(rig: ^Rig) -> ^core.Client {return &rig.sess.h.srv.clients[0]}

// until_phase steps until the round is in phase (false: not within seconds).
until_phase :: proc(rig: ^Rig, phase: flood.Phase, seconds := 20) -> bool {
	Wait :: struct {
		rig:   ^Rig,
		phase: flood.Phase,
	}
	wait := Wait{rig, phase}
	_, ok := core.harness_step_until(&rig.sess.h, proc(data: rawptr) -> bool {
			w := (^Wait)(data)
			return state(srv(w.rig)).phase == w.phase
		}, &wait, seconds * game.TICK_RATE)
	return ok
}

// until_seconds steps until the phase has run seconds (at most that long: a phase that
// ends first starts the count again).
until_seconds :: proc(rig: ^Rig, seconds: f32) {
	for _ in 0 ..< int(seconds * game.TICK_RATE) + 1 {
		if core_seconds(rig) >= seconds {return}
		core.harness_step(&rig.sess.h)
	}
}

core_seconds :: proc(rig: ^Rig) -> f32 {return seconds(srv(rig))}

// say: the player's command, and the ticks for it to be done.
say :: proc(rig: ^Rig, text: string) {
	core.command(&rig.sess.mirror, text)
	core.harness_step(&rig.sess.h, 2)
}

// told: the server told the player text, at the start of a Notice.
told :: proc(rig: ^Rig, text: string) -> bool {
	for n in rig.sess.mirror.notices {
		if strings.has_prefix(n, text) {return true}
	}
	return false
}

mode_of :: proc(rig: ^Rig) -> string {
	s := srv(rig)
	return s.registry.game_modes[player(rig).mode].id
}

// A round runs through its phases: built and counted down, the player placed as a runner
// with the kit; played while the water rises (baseline: a layer every 2.4 s after the
// grace); the player standing on the floor drowns and is out, watching; with nobody
// left the round is lost and revealed, and the next begins. The mirror is told each step.
@(test)
test_flood_round :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !rig_start(t, rig) {return}
	defer core.session_stop(&rig.sess)
	s := srv(rig)
	f := state(s)
	c := player(rig)
	say(rig, "flood rule baseline")
	testing.expect(t, told(rig, "Flood: new round under baseline"))
	testing.expect_value(t, f.phase, flood.Phase.Countdown)
	testing.expect_value(t, f.rule, flood.Rule.Baseline)
	round := f.round
	if !testing.expect(t, until_phase(rig, .Playing), "the round never started") {return}
	testing.expect(t, f.built)
	testing.expect_value(t, mode_of(rig), flood.RUNNER_MODE)
	launcher, _ := game.registry_item(s.registry, "rocket_launcher")
	testing.expect(t, game.inventory_count(&c.inventory, launcher) == 1, "no kit")
	testing.expect(t, abs(c.player.position.x - flood.SPAWN.x) <= 1.01, "not at the spawn")
	// The arena: bedrock walls, and the goal's lamps where the record says.
	b, _ := core.block_at(s.home, {-1, 50, 10})
	testing.expect_value(t, b, game.Block.Bedrock)
	b, _ = core.block_at(s.home, {f.goal.x + 3, flood.GOAL_Y, f.goal.y + 3})
	testing.expect_value(t, b, game.Block.Lamp)

	// The mirror is told the round.
	core.harness_step(&rig.sess.h, 2)
	r := core.mirror_game_record(&rig.sess.mirror, flood.Round)
	if !testing.expect(t, r != nil, "the mirror was not told the round") {return}
	testing.expect_value(t, r.phase, flood.Phase.Playing)
	testing.expect_value(t, r.round, round)
	testing.expect_value(t, r.players, 1)
	testing.expect_value(t, r.alive, 1)
	testing.expect_value(t, i32(r.goal_x), f.goal.x)

	// Dry through the grace; then the water rises a layer at a time, filling the air.
	until_seconds(rig, flood.GRACE - 0.5)
	testing.expect_value(t, f.level, 0)
	until_seconds(rig, flood.GRACE + flood.RISE_BASELINE + 0.1)
	testing.expect_value(t, f.level, 1)
	testing.expect_value(t, f.level, flood.water_level(.Baseline, core_seconds(rig)))
	b, _ = core.block_at(s.home, {16, 1, 16}) // (the spawn is clear)
	testing.expect_value(t, b, game.Block.Water)
	b, _ = core.block_at(s.home, {16, 2, 16})
	testing.expect_value(t, b, game.Block.Air)

	// At the second layer the head is under: two seconds on, the player is out, watching.
	if !testing.expect(t, until_phase(rig, .Reveal), "the round never ended") {return}
	testing.expect(t, runner(s, c).out)
	testing.expect_value(t, mode_of(rig), flood.OUT_MODE)
	testing.expect(t, c.player.flying, "an out player does not fly")
	testing.expect_value(t, f.result, flood.Result.Lost)
	testing.expect(t, f.level >= 2 && f.level <= 3, "drowned at the wrong height")
	core.harness_step(&rig.sess.h, 2)
	r = core.mirror_game_record(&rig.sess.mirror, flood.Round)
	testing.expect(t, r.out && r.phase == .Reveal && r.result == .Lost && r.alive == 0)

	// The next round places the player again, the launcher in hand whatever it held.
	core.inventory(&rig.sess.mirror, .Select, 0, game.HOTBAR_SLOTS - 1)
	core.harness_step(&rig.sess.h, 2)
	testing.expect_value(t, c.inventory.selected, game.HOTBAR_SLOTS - 1)
	if !testing.expect(t, until_phase(rig, .Countdown), "no next round") {return}
	testing.expect_value(t, f.round, round + 1)
	if !testing.expect(t, until_phase(rig, .Playing), "the next round never started") {return}
	testing.expect(t, !runner(s, c).out)
	testing.expect_value(t, mode_of(rig), flood.RUNNER_MODE)
	testing.expect_value(t, game.inventory_held(&c.inventory).item, launcher)
	core.harness_step(&rig.sess.h, 2)
	testing.expect_value(t, game.inventory_held(&rig.sess.mirror.inventory).item, launcher)
	testing.expect_value(t, f.level, 0)
	testing.expect_value(t, len(rig.sess.failures), 0)
}

// Everyone still in on the goal wins the round.
@(test)
test_flood_goal_wins :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !rig_start(t, rig) {return}
	defer core.session_stop(&rig.sess)
	f := state(srv(rig))
	if !testing.expect(t, until_phase(rig, .Playing), "the round never started") {return}
	say(rig, "flood goal")
	if !testing.expect(
		t,
		until_phase(rig, .Reveal, 5),
		"standing on the goal did not win",
	) {return}
	testing.expect_value(t, f.result, flood.Result.Won)
	testing.expect_value(t, f.made_it, 1)
	testing.expect(t, !runner(srv(rig), player(rig)).out)
}

// /flood says the round; restart and rule start a new one (under the rule named);
// a rule that is none is refused.
@(test)
test_flood_commands :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !rig_start(t, rig) {return}
	defer core.session_stop(&rig.sess)
	f := state(srv(rig))
	if !testing.expect(t, until_phase(rig, .Playing), "the round never started") {return}
	round := f.round
	say(rig, "flood")
	testing.expect(t, told(rig, "Flood round "))
	say(rig, "flood restart")
	testing.expect(t, told(rig, "Flood: new round"))
	testing.expect_value(t, f.round, round + 1)
	testing.expect_value(t, f.phase, flood.Phase.Countdown)
	for rule in flood.Rule {
		say(
			rig,
			strings.concatenate({"flood rule ", flood.RULE_NAMES[rule]}, context.temp_allocator),
		)
		testing.expect_value(t, f.rule, rule)
	}
	testing.expect_value(t, f.round, round + 1 + len(flood.Rule))
	say(rig, "flood rule nonesuch")
	testing.expect(t, told(rig, "Flood rules: baseline tide rot heavy random"))
	testing.expect_value(t, f.round, round + 1 + len(flood.Rule))
	say(rig, "flood rule random")
	testing.expect_value(t, f.forced, nil)
	testing.expect_value(t, f.round, round + 2 + len(flood.Rule))
	say(rig, "flood sideways")
	testing.expect(t, told(rig, "Usage: flood"))
}

// The water's law: dry through the grace; baseline rises a layer every RISE_BASELINE;
// the tide rises overall but falls back between surges; the level stops below the goal.
@(test)
test_flood_water_levels :: proc(t: ^testing.T) {
	for rule in flood.Rule {testing.expect_value(t, flood.water_level(rule, flood.GRACE - 0.01), 0)}
	testing.expect_value(
		t,
		flood.water_level(.Baseline, flood.GRACE + 10 * flood.RISE_BASELINE + 0.01),
		10,
	)
	testing.expect_value(t, flood.water_level(.Baseline, 10_000), flood.WATER_MAX)
	fell, highest := false, i32(0)
	for tenth in 0 ..< 1200 {
		level := flood.water_level(.Tide, flood.GRACE + f32(tenth) / 10)
		fell ||= level < highest
		highest = max(highest, level)
	}
	testing.expect(t, fell, "the tide never fell back")
	rise: f32 = 120.0 / flood.RISE_TIDE // (the net rise over the 120 s looked at)
	testing.expect(t, f32(highest) >= rise - 1, "the tide did not rise overall")
	// A falling tide drains the top layer of the arena.
	rig := new(Rig)
	defer free(rig)
	if !rig_start(t, rig) {return}
	defer core.session_stop(&rig.sess)
	s := srv(rig)
	if !testing.expect(t, until_phase(rig, .Playing), "the round never started") {return}
	water_tick(s, 1)
	water_tick(s, 2)
	b, _ := core.block_at(s.home, {16, 2, 16})
	testing.expect_value(t, b, game.Block.Water)
	water_tick(s, 1)
	testing.expect_value(t, state(s).level, 1)
	b, _ = core.block_at(s.home, {16, 2, 16})
	testing.expect_value(t, b, game.Block.Air)
}

// Rot: a few seconds after the water reaches a layer, its blocks crumble (under the water,
// into water).
@(test)
test_flood_rot :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !rig_start(t, rig) {return}
	defer core.session_stop(&rig.sess)
	s := srv(rig)
	f := state(s)
	say(rig, "flood rule rot")
	if !testing.expect(t, until_phase(rig, .Playing), "the round never started") {return}
	// The floor under the spawn is stone until the water has wet it for a while.
	floor := 0
	for z in i32(12) ..= 20 {
		for x in i32(12) ..= 20 {if b, _ := core.block_at(s.home, {x, 0, z}); b == .Stone {floor += 1}}
	}
	testing.expect_value(t, floor, 81)
	wet := f32(flood.GRACE + flood.RISE_ROT)
	until_seconds(rig, wet + flood.ROT_DELAY - 0.2)
	testing.expect_value(t, f.rotted, 0)
	until_seconds(rig, wet + flood.ROT_DELAY + 1.5) // (before the player drowns, at the second layer)
	testing.expect(t, f.rotted > 0, "nothing crumbled")
	crumbled := 0
	for z in i32(12) ..= 20 {
		for x in i32(12) ..= 20 {if b, _ := core.block_at(s.home, {x, 0, z}); b == .Water {crumbled += 1}}
	}
	testing.expect(
		t,
		crumbled > 0 && crumbled < 81,
		"the floor did not crumble into water, a block at a time",
	)
}

// Heavy: the world's explosions are larger under it (a rocket's blast carves more), and
// as large as ever under any other rule.
@(test)
test_flood_heavy :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !rig_start(t, rig) {return}
	defer core.session_stop(&rig.sess)
	s := srv(rig)
	w := s.home
	// air: the air blocks in the cube of side 15 around p (deep under the arena's floor).
	air :: proc(w: ^core.World, p: game.Block_Pos) -> (n: int) {
		for y in p.y - 7 ..= p.y + 7 {
			for z in p.z - 7 ..= p.z + 7 {
				for x in p.x - 7 ..= p.x + 7 {if b, _ := core.block_at(w, {x, y, z}); b == .Air {n += 1}}
			}
		}
		return
	}
	blast :: proc(s: ^core.Server, p: game.Block_Pos) {
		at := [3]f64{f64(p.x) + 0.5, f64(p.y) + 0.5, f64(p.z) + 0.5}
		core.explode(s.home, at, 4, core.game_act(s, s.home, .Explosion).action)
	}
	say(rig, "flood rule heavy")
	testing.expect_value(t, w.rules.explosion_size, flood.HEAVY_SIZE)
	testing.expect_value(t, w.rules.explosion_throw, flood.HEAVY_THROW)
	// ... changed as Flood's (the journal says who), and the player told.
	setting: core.Action_Info
	for id := w.journal.next_action - 1; id > 0 && setting.system != .Setting; id -= 1 {
		setting, _ = core.action_info(&w.journal, id)
	}
	testing.expect_value(t, setting.kind, game.Actor_Kind.Game)
	testing.expect_value(t, setting.actor, "flood")
	testing.expect_value(t, setting.command, "rule explosion_throw 2")
	testing.expect_value(t, rig.sess.mirror.rules.explosion_size, flood.HEAVY_SIZE)
	if !testing.expect(t, until_phase(rig, .Playing), "the round never started") {return}
	heavy_at, plain_at := game.Block_Pos{8, -8, 8}, game.Block_Pos{24, -8, 24}
	testing.expect_value(t, air(w, heavy_at) + air(w, plain_at), 0)
	blast(s, heavy_at)
	say(rig, "flood rule baseline")
	testing.expect_value(t, w.rules.explosion_size, 1)
	testing.expect_value(t, w.rules.explosion_throw, 1)
	blast(s, plain_at)
	heavy, plain := air(w, heavy_at), air(w, plain_at)
	testing.expectf(
		t,
		plain > 200 && heavy > 4 * plain,
		"carved %d under heavy, %d under baseline",
		heavy,
		plain,
	)
}
