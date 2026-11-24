package sandbox_server

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import "common:game"
import "games:sandbox"
import "server:core"
import "server:playtest"

// A survivor's levels and skills (pack/data/levels, pack/data/skills; README.md "Levels and
// skills") on a stepped server: what earns experience and what does not, the skills learnt
// and unlearnt, every skill changing the rule it names, and both kept with the character.

// skill_of: a skill's index in the session's registry by id.
skill_of :: proc(t: ^testing.T, s: ^core.Server, id: string) -> int {
	at, ok := game.skill_by_id(s.registry, id)
	testing.expectf(t, ok, "no skill %s", id)
	return at
}

// xp: the host's experience.
@(private = "file")
xp :: proc(c: ^core.Client) -> u64 {return c.stats["xp"] or_else 0}

// Earned: a kill by the creature's threat, a place found by its kind, a creature met, a
// thing made the first time (not the second), an encounter won, a quest done and a sheep
// sheared each give what the curve or the quest says; a level comes at its total and the
// player is told. In creative, and for a watcher, nothing does.
@(test)
test_progression_earned :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !survivor(t, rig) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	h := playtest.host(rig)
	reg := s.registry
	p := &reg.progression
	w := s.home
	loper, _ := game.registry_kind(reg, "sandbox:loper")
	cragmaul, _ := game.registry_kind(reg, "sandbox:cragmaul")
	twitchet, _ := game.registry_kind(reg, "sandbox:twitchet")
	cord := item_of(t, s, "sandbox:cord")
	testing.expect(t, game.progression_on(reg))

	// Creative earns nothing (nor would a watcher: what counts is a survivor's).
	{
		mode := "creative"
		core.game_mode(s, h, mode)
		prey := core.entity_spawn(w, loper, {4.5, 0, 4.5}, false)
		core.entity_harm(w, prey, {amount = 100, kind = .Hit, by = h})
		core.logbook_place(s, h, .Ruin, {300, 0, 0})
		core.quest_note(s, h, {goal = .Make, item = cord, count = 2})
		core.quest_note(s, h, {goal = .Win, name = RUIN_ENCOUNTER, count = 1})
		core.stat_count(s, h, "sheep.sheared")
		testing.expectf(t, xp(h) == 0, "%s earned %d", mode, xp(h))
	}
	core.game_mode(s, h, "survival")
	h.logbook = {}
	core.counter_set(&h.stats, "items.made.sandbox:cord", 0)
	playtest.step(rig, 4) // (what is in view now is met: its experience is not counted below)

	// A kill: the curve's kill for each point of the creature's threat.
	before := xp(h)
	prey := core.entity_spawn(w, loper, {4.5, 0, 4.5}, false)
	core.entity_harm(w, prey, {amount = 100, kind = .Hit, by = h})
	testing.expect_value(t, xp(h) - before, u64(p.xp[.Kill]) * 1)
	big := core.entity_spawn(w, cragmaul, {4.5, 0, 4.5}, false)
	core.entity_harm(w, big, {amount = 1000, kind = .Hit, by = h})
	testing.expect_value(t, xp(h) - before, u64(p.xp[.Kill]) * 9)
	other := core.entity_spawn(w, loper, {4.5, 0, 4.5}, false)
	core.entity_harm(w, other, {amount = 100, kind = .Game}) // (nobody's kill)
	testing.expect_value(t, xp(h) - before, u64(p.xp[.Kill]) * 9)

	// A place found: by its kind (an outpost is made, not found: none), once.
	before = xp(h)
	core.logbook_place(s, h, .Ruin, {300, 0, 0})
	core.logbook_place(s, h, .Ruin, {301, 0, 0}) // (the same place)
	core.logbook_place(s, h, .Outpost, {40, 0, 0})
	testing.expect_value(t, xp(h) - before, u64(p.find[.Ruin]))

	// A creature met: one in view for the first time.
	before = xp(h)
	pos := h.player.position
	core.entity_spawn(w, twitchet, pos + {3, 0, 0}, false)
	playtest.step(rig, 4)
	testing.expect_value(t, xp(h) - before, u64(p.xp[.Meet]))

	// Made: the first time only.
	before = xp(h)
	core.quest_note(s, h, {goal = .Make, item = cord, count = 2})
	core.quest_note(s, h, {goal = .Make, item = cord, count = 2})
	testing.expect_value(t, xp(h) - before, u64(p.xp[.Make]))
	testing.expect_value(t, h.stats["items.made.sandbox:cord"], 4)

	// Won, a game's statistic, a quest done.
	before = xp(h)
	core.quest_note(s, h, {goal = .Win, name = RUIN_ENCOUNTER, count = 1})
	testing.expect_value(t, xp(h) - before, u64(p.xp[.Win]))
	before = xp(h)
	core.stat_count(s, h, "sheep.sheared")
	testing.expect_value(t, xp(h) - before, 5)
	waking := quest_of(t, s, "sandbox:waking")
	before = xp(h)
	core.item_give(s, h, item_of(t, s, "sandbox:fibre"), 6)
	core.item_give(s, h, item_of(t, s, "sandbox:flint"), 5)
	core.item_give(s, h, item_of(t, s, "voxiverse:log"), 4)
	playtest.step(rig, 2)
	testing.expect(t, game.quest_done(reg, &h.quests, waking), "waking not done")
	testing.expect_value(t, xp(h) - before, u64(reg.quests[waking].xp))
	testing.expect(t, reg.quests[waking].xp > 0, "the quest gives none")

	// The level is the curve's and kept as the counter; the player is told its experience.
	testing.expect_value(t, h.stats["level"], u64(game.level_of(reg, xp(h))))
	testing.expect(t, h.stats["level"] >= 2, "no level gained")
	playtest.step(rig, 4)
	testing.expect_value(t, u64(rig.sess.mirror.progress.xp), xp(h))
}

// Learnt and unlearnt: /skill names a rank more of a skill (by id or by name) while the
// points last and its branch has had what it needs spent; each refusal says why; /skill
// reset unlearns them all, only by an outpost beacon. The player is told its ranks.
@(test)
test_skills_learnt :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !survivor(t, rig) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	h := playtest.host(rig)
	quick := skill_of(t, s, "sandbox:quick_hands")
	footing := skill_of(t, s, "sandbox:sure_footing")
	playtest.say(rig, "skill quick_hands")
	testing.expect(t, playtest.told(rig, "&cYou have too few skill points"))
	core.counter_set(&h.stats, "xp", game.level_floor(s.registry, 4)) // (three points)
	playtest.say(rig, "skill sure_footing")
	testing.expect(t, playtest.told(rig, "&cSpend more points in its branch first"))
	playtest.say(rig, "skill sandbox:quick_hands")
	testing.expect(t, playtest.told(rig, "Quick Hands: rank 1 of 3"))
	playtest.say(rig, "skill quick_hands")
	playtest.say(rig, "skill sure_footing")
	testing.expect(t, playtest.told(rig, "Sure Footing: rank 1 of 2"))
	playtest.say(rig, "skill quick_hands")
	testing.expect(t, playtest.told(rig, "&cYou have too few skill points"))
	playtest.say(rig, "skill flying")
	testing.expect(t, playtest.told(rig, "&cNo skill flying"))
	testing.expect_value(t, h.skills.ranks[quick], 2)
	testing.expect_value(t, h.skills.ranks[footing], 1)
	playtest.step(rig, 4)
	testing.expect_value(t, rig.sess.mirror.progress.skills, h.skills)

	// Unlearnt: only within reach of a beacon.
	playtest.say(rig, "skill reset")
	testing.expect(
		t,
		playtest.told(rig, "&cStand within 6 blocks of an outpost beacon to unlearn your skills"),
	)
	testing.expect(
		t,
		playtest.told(rig, "&cStand within 6 blocks of an outpost beacon to unlearn your skills"),
	)
	testing.expect_value(t, h.skills.ranks[quick], 2)
	beacon, _ := game.registry_block(s.registry, "sandbox:outpost_beacon")
	p := h.player.position
	at := game.Block_Pos{i32(p.x) + 3, i32(p.y), i32(p.z)}
	core.set_block(s.home, at, beacon, core.game_act(s, s.home, .Command))
	playtest.say(rig, "skill reset")
	testing.expect(t, playtest.told(rig, "Your skills are unlearnt: 3 points to spend"))
	testing.expect_value(t, h.skills, game.Skill_Ranks{})
}

// Every skill changes the rule it names, through the server's own path: for each skill of
// the sheet, the rule measured with none of it and with every rank differs. A skill whose
// effect nothing reads fails here, and an effect added without a probe does not compile.
@(test)
test_skills_change_their_rules :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !survivor(t, rig) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	h := playtest.host(rig)
	playtest.step(rig, 200) // (past the regeneration's delay)
	Probe :: proc(t: ^testing.T, rig: ^Rig) -> f32
	probes := [game.Skill_Effect]Probe {
		.Break_Speed = probe_break,
		.Yield_Chance = probe_yield,
		.Drop_Chance = probe_drops,
		.Max_Health = probe_max_health,
		.Defence = proc(t: ^testing.T, rig: ^Rig) -> f32 {return probe_harm(rig, .Command)},
		.Fall_Guard = proc(t: ^testing.T, rig: ^Rig) -> f32 {return probe_harm(rig, .Fall)},
		.Regen = probe_regen,
		.Consume_Strength = probe_consume,
		.Melee_Damage = probe_melee,
		.Reload_Time = probe_reload,
		.Spread = probe_spread,
		.Craft_Time = probe_craft_time,
		.Craft_Yield = probe_craft_yield,
	}
	testing.expect_value(t, len(s.registry.skills), 13)
	for &def, i in s.registry.skills {
		h.skills = {}
		without := probes[def.effect](t, rig)
		h.skills.ranks[i] = u8(def.ranks)
		with := probes[def.effect](t, rig)
		h.skills = {}
		testing.expectf(
			t,
			with != without,
			"%s changes nothing: %v with and without",
			def.id,
			with,
		)
	}
}

// probe_break: the ticks the server holds a stone's break to with a flint pick.
@(private = "file")
probe_break :: proc(t: ^testing.T, rig: ^Rig) -> f32 {
	s, h := playtest.srv(rig), playtest.host(rig)
	stone, _ := game.registry_block(s.registry, "stone")
	pick := game.Stack{item_of(t, s, "sandbox:flint_pick"), 1, 0, 0}
	return f32(game.break_ticks(s.registry, &h.world.rules, stone, pick, {}, &h.skills))
}

// probe_yield: the raw copper twelve copper ores broken with a copper pick leave.
@(private = "file")
probe_yield :: proc(t: ^testing.T, rig: ^Rig) -> f32 {
	s, h := playtest.srv(rig), playtest.host(rig)
	empty_hands(s, h)
	core.item_give(s, h, item_of(t, s, "sandbox:copper_pick"), 1)
	core.hotbar_select(s, h, 0)
	copper, _ := game.registry_block(s.registry, "copper_ore")
	raw := game.block_drop(s.registry, copper)
	at := game.Block_Pos{1, 0, 0}
	for _ in 0 ..< 12 {
		core.set_block(s.home, at, copper, core.game_act(s, s.home, .Command))
		break_at(rig, at)
	}
	return f32(core.item_count(h, raw))
}

// probe_drops: the stacks forty of the first creature whose drop is less than sure leave,
// each killed by the host.
@(private = "file")
probe_drops :: proc(t: ^testing.T, rig: ^Rig) -> f32 {
	s, h := playtest.srv(rig), playtest.host(rig)
	w := s.home
	kind: game.Kind_Id
	for &info, i in s.registry.kinds {
		for d in info.drops {if d.chance < 0.6 && kind == 0 {kind = game.Kind_Id(i + 1)}}
	}
	testing.expect(t, kind != 0, "no creature leaves anything by chance")
	at := [3]f64{20.5, 0, 20.5}
	for _ in 0 ..< 40 {
		prey := core.entity_spawn(w, kind, at, false)
		core.entity_harm(w, prey, {amount = 10_000, kind = .Hit, by = h})
	}
	n := 0
	for e in core.entities_of(w, s.registry.engine.item, at, 4) {
		n += 1
		core.entity_gone(w, e)
	}
	return f32(n)
}

@(private = "file")
probe_max_health :: proc(t: ^testing.T, rig: ^Rig) -> f32 {
	playtest.step(rig, 1)
	return playtest.host(rig).max_health
}

// probe_harm: the health ten points of harm of a kind take.
@(private = "file")
probe_harm :: proc(rig: ^Rig, kind: game.Source_Kind) -> f32 {
	s, h := playtest.srv(rig), playtest.host(rig)
	h.protected_until = 0
	h.health = h.max_health
	core.damage(s, h, 10, {kind = kind})
	taken := h.max_health - h.health
	h.health = h.max_health
	return taken
}

// probe_regen: the health a second of regeneration gives.
@(private = "file")
probe_regen :: proc(t: ^testing.T, rig: ^Rig) -> f32 {
	h := playtest.host(rig)
	h.health, h.last_damage, h.effect = 1, 0, {}
	playtest.step(rig, int(game.TICK_RATE))
	return h.health - 1
}

// probe_consume: what a field dressing heals.
@(private = "file")
probe_consume :: proc(t: ^testing.T, rig: ^Rig) -> f32 {
	s, h := playtest.srv(rig), playtest.host(rig)
	empty_hands(s, h)
	core.item_give(s, h, item_of(t, s, "sandbox:field_dressing"), 1)
	core.hotbar_select(s, h, 0)
	h.health, h.effect = 1, {}
	testing.expect_value(t, core.item_consume(s, h), "")
	healed := h.health - 1
	h.health = h.max_health
	return healed
}

// probe_melee: what a machete's swing takes from a longstrider in front of the host.
@(private = "file")
probe_melee :: proc(t: ^testing.T, rig: ^Rig) -> f32 {
	s, h := playtest.srv(rig), playtest.host(rig)
	w := s.home
	giant, _ := game.registry_kind(s.registry, "sandbox:longstrider")
	machete := item_of(t, s, "sandbox:machete")
	info, _ := game.item_info(s.registry, machete)
	h.look = {0, 0} // (facing -z)
	e := core.entity_spawn(w, giant, h.player.position + {0, 0, -2.2}, false)
	health := core.entity_health_of(w, e)
	h.swing_due = 0
	core.swing(s, h, {machete, 1, 0, 0}, info.melee.?)
	taken := health - core.entity_health_of(w, e)
	core.entity_gone(w, e)
	return f32(taken)
}

// weapon_in_hand: the base pack's shotgun (it reloads and spreads its shots) in the host's
// hand, empty, with its ammunition carried.
@(private = "file")
weapon_in_hand :: proc(t: ^testing.T, rig: ^Rig) {
	s, h := playtest.srv(rig), playtest.host(rig)
	empty_hands(s, h)
	gun := item_of(t, s, "voxiverse:shotgun")
	w, ok := game.weapon_of(s.registry, h.mode, gun)
	testing.expect(
		t,
		ok && w.spread > 0 && w.reload_time > 0,
		"the shotgun neither reloads nor spreads",
	)
	core.item_give(s, h, gun, 1)
	core.hotbar_select(s, h, 0)
	h.inventory.slots[0].ammo = 0
	if w.ammo != game.NO_ITEM {core.item_give(s, h, w.ammo, 10)}
}

// probe_reload: the ticks a reload takes.
@(private = "file")
probe_reload :: proc(t: ^testing.T, rig: ^Rig) -> f32 {
	s, h := playtest.srv(rig), playtest.host(rig)
	weapon_in_hand(t, rig)
	h.reload_until = 0
	testing.expect(t, core.weapon_reload(s, h), "no reload")
	ticks := f32(h.reload_until - s.tick)
	h.reload_until = 0
	return ticks
}

// probe_spread: the cone the server casts a shot's rays in.
@(private = "file")
probe_spread :: proc(t: ^testing.T, rig: ^Rig) -> f32 {
	weapon_in_hand(t, rig)
	_, info, _, _ := core.held_weapon(playtest.srv(rig), playtest.host(rig))
	return info.spread
}

// probe_craft_time: the ticks planks take to make by hand.
@(private = "file")
probe_craft_time :: proc(t: ^testing.T, rig: ^Rig) -> f32 {
	s, h := playtest.srv(rig), playtest.host(rig)
	empty_hands(s, h)
	core.item_give(s, h, item_of(t, s, "voxiverse:log"), 4)
	ask := sandbox.Craft{recipe_of(t, s, "sandbox:planks")}
	craft_ask(s, h, ask)
	ss := seat_survival(s, h)
	ticks := f32(ss.done - s.tick)
	craft_left(s, h)
	return ticks
}

// probe_craft_yield: the planks forty makings of the recipe give.
@(private = "file")
probe_craft_yield :: proc(t: ^testing.T, rig: ^Rig) -> f32 {
	s, h := playtest.srv(rig), playtest.host(rig)
	empty_hands(s, h)
	planks := recipe_of(t, s, "sandbox:planks")
	out := s.registry.recipes[planks].output.item
	made := fmt.tprintf("items.made.%s", game.item_name(s.registry, out))
	before := h.stats[made]
	for _ in 0 ..< 40 {
		ss := seat_survival(s, h)
		ss.making, ss.began, ss.done = int(planks) + 1, s.tick, s.tick
		survival_tick(s)
		core.item_clear(s, h, out) // (room for the next)
	}
	return f32(h.stats[made] - before)
}

@(private = "file")
empty_hands :: proc(s: ^core.Server, h: ^core.Client) {
	for st in h.inventory.slots {if !game.stack_empty(st) {core.item_clear(s, h, st.item)}}
}

// Kept with the character: its file names the skills learnt by id with their rank (a
// member a reader of format 7 from before skips); read back, they are the same ranks. A
// file from before has none, a skill the pack no longer has is left out and a rank past a
// skill's is cut to it. Its experience is its counter, kept as every counter is.
@(test)
test_skills_saved :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	reg := s.registry
	quick, hardy := skill_of(t, s, "sandbox:quick_hands"), skill_of(t, s, "sandbox:hardy")
	r: core.Player_Record
	r.skills.ranks[quick] = 2
	r.skills.ranks[hardy] = 3
	r.stats = make(core.Counters, context.temp_allocator)
	r.stats["xp"] = 480
	text := string(core.player_json(reg, &r, nil))
	testing.expectf(
		t,
		strings.contains(text, `"skills"`) && strings.contains(text, `"sandbox:quick_hands"`),
		"%s",
		text,
	)
	testing.expect(t, !strings.contains(text, "sure_footing"), "a skill not learnt is written")
	back, ok := core.player_parse(reg, transmute([]u8)text, nil)
	testing.expect(t, ok)
	testing.expect_value(t, back.skills, r.skills)
	testing.expect_value(t, back.stats["xp"], 480)
	core.counters_free(&back.stats)

	older := `{"format": 7, "position": [0, 10, 0], "look": [0, 0], "items": []}`
	none, read := core.player_parse(reg, transmute([]u8)older, nil)
	testing.expect(t, read)
	testing.expect_value(t, none.skills, game.Skill_Ranks{})

	changed := `{"format": 7, "position": [0, 10, 0], "look": [0, 0], "items": [], "skills": [
		{"id": "sandbox:gone", "rank": 1},
		{"id": "sandbox:hardy", "rank": 9}]}`
	cut, cut_read := core.player_parse(reg, transmute([]u8)changed, nil)
	testing.expect(t, cut_read)
	testing.expect_value(t, cut.skills.ranks[hardy], 3)
	testing.expect(t, game.skill_ranks_valid(reg, &cut.skills))
}

// The skill ids named outside the pack are the pack's: every `/skill <id>` of the image
// scenes, and every id of the README's skill table (which names each skill of the pack).
@(test)
test_skill_ids_named_are_real :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME) {return}
	defer playtest.stop(rig)
	reg := playtest.srv(rig).registry
	known :: proc(reg: ^game.Registry, id: string) -> bool {
		_, found := game.skill_by_id(reg, id)
		for &def in reg.skills {found ||= strings.has_suffix(def.id, strings.concatenate({":", id}, context.temp_allocator))}
		return found
	}
	scenes, read := os.read_entire_file(
		"assets/baselines/images/scenes.txt",
		context.temp_allocator,
	)
	testing.expect(t, read == nil, "cannot read the scenes")
	for line in strings.split_lines(string(scenes), context.temp_allocator) {
		for command in strings.split(line, ";", context.temp_allocator) {
			fields := strings.fields(command, context.temp_allocator)
			if len(fields) < 2 || fields[0] != "/skill" || fields[1] == "reset" {continue}
			testing.expectf(
				t,
				known(reg, fields[1]),
				"a scene learns a skill %s the pack has not",
				fields[1],
			)
		}
	}
	readme, ok := os.read_entire_file_from_path("games/sandbox/README.md", context.temp_allocator)
	testing.expect(t, ok == nil, "cannot read the README")
	named := 0
	for line in strings.split_lines(string(readme), context.temp_allocator) {
		if !strings.has_prefix(line, "| `sandbox:") {continue}
		id := line[3:]
		id = id[:strings.index_byte(id, '`')]
		if _, is_skill := game.skill_by_id(reg, id); !is_skill {
			_, is_quest := game.quest_by_id(reg, id)
			testing.expectf(t, is_quest, "the README names a skill %s the pack has not", id)
			continue
		}
		named += 1
	}
	testing.expect_value(t, named, len(reg.skills))
}
