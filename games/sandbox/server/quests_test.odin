package sandbox_server

import "core:strings"
import "core:testing"

import "common:game"
import "common:worldgen"
import "games:sandbox"
import "server:core"
import "server:playtest"

// The quests (pack/data/quests: the first hour's, first_hour.json, and the camps' people's,
// folk.json; README.md "Quests"): every one can be done in the world the sandbox makes, from
// real ids, in an order that never asks for what an earlier step did not give the means to,
// a talk step said in a conversation a dialogue offers on that step; and on a stepped
// server, what a survivor does moves them on, gives their rewards and is kept with the
// character.

// quest_of: a quest's index in the session's registry by id.
quest_of :: proc(t: ^testing.T, s: ^core.Server, id: string) -> int {
	q, ok := game.quest_by_id(s.registry, id)
	testing.expectf(t, ok, "no quest %s", id)
	return q
}

// before: the steps done before step k of quest q: the steps of every quest it comes after
// (as far back as they go) and its own before k.
@(private = "file")
before :: proc(reg: ^game.Registry, q, k: int) -> []^game.Quest_Step {
	out := make([dynamic]^game.Quest_Step, context.temp_allocator)
	for &st in reg.quests[q].steps[:k] {append(&out, &st)}
	seen := make([]bool, len(reg.quests), context.temp_allocator)
	stack := make([dynamic]int, context.temp_allocator)
	append(&stack, ..reg.quests[q].after)
	for len(stack) > 0 {
		a := pop(&stack)
		if seen[a] {continue}
		seen[a] = true
		for &st in reg.quests[a].steps {append(&out, &st)}
		append(&stack, ..reg.quests[a].after)
	}
	return out[:]
}

// tool_before: an earlier step made a tool that gathers at tier or more (tier 0: hands).
@(private = "file")
tool_before :: proc(reg: ^game.Registry, earlier: []^game.Quest_Step, tier: u8) -> bool {
	if tier == 0 {return true}
	for st in earlier {
		if st.objective.goal != .Make {continue}
		info, _ := game.item_info(reg, st.objective.item)
		if info.gather.tier >= tier {return true}
	}
	return false
}

// least_tier: the least tier of tool that gets item from a block of the world (0 when one
// gives it to hands, or no block does: it comes another way).
@(private = "file")
least_tier :: proc(reg: ^game.Registry, item: game.Item) -> u8 {
	least := u8(255)
	for name in WORLD_BLOCKS {
		b, _ := game.registry_block(reg, name)
		if game.block_drop(reg, b) == item {least = min(least, game.block_tier(reg, b))}
	}
	return 0 if least == 255 else least
}

// talk_said: a reply of a dialogue says name, offered on step k of quest q (its conditions
// name no other step of q), taking only what can be come by; or a dialogue of the camps'
// people's roles is named so (a conversation with one begun says it).
@(private = "file")
talk_said :: proc(reg: ^game.Registry, had: map[game.Item]bool, name: string, q, k: int) -> bool {
	kinds := FOLK_KINDS
	for kind in kinds {if kind == name {return true}}
	for &d in reg.dialogues {
		for &n in d.nodes {
			for &r in n.replies {
				says := false
				for e in r.effects {says ||= e.kind == .Talk && e.name == name}
				if !says {continue}
				fits := true
				for c in r.conditions {
					if (c.kind == .Step || c.kind == .Quest) && c.quest == q {
						fits &&= c.kind == .Quest || c.step == k
					}
				}
				for e in r.effects {fits &&= e.kind != .Take || had[e.item]}
				if fits {return true}
			}
		}
	}
	return false
}

// The chain: 18 to 24 quests (the first hour's and the camps'), one open at the start, each opened in turn as the ones before
// are done (none left waiting for ever), and every step one a survivor can do with what it
// has by then: an item it can come by (made by a recipe of the sandbox's, at a fabricator
// only once one stands), a block of the world broken with a tool of its tier made before, a
// creature that comes or keeps a post, a place the game notes in the logbook, the ruin's
// fight; and each reward an item of the pack's, in a stack.
@(test)
test_quests_chain :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	reg := s.registry
	testing.expectf(
		t,
		len(reg.quests) >= 26 && len(reg.quests) <= game.MAX_QUESTS,
		"%d quests",
		len(reg.quests),
	)

	// No deadlock: done one open quest at a time, all of them are done.
	log: game.Quest_Log
	open_at_start := 0
	for q in 0 ..< len(reg.quests) {if game.quest_open(reg, &log, q) {open_at_start += 1}}
	testing.expect_value(t, open_at_start, 1)
	testing.expect_value(t, reg.quests[0].id, "sandbox:waking")
	for round := 0; round < len(reg.quests); round += 1 {
		opened := -1
		for q in 0 ..< len(reg.quests) {if game.quest_open(reg, &log, q) {opened = q; break}}
		if !testing.expectf(t, opened >= 0, "nothing open after %d done", round) {break}
		log.quests[opened].step = u8(len(reg.quests[opened].steps))
	}
	for q in 0 ..< len(reg.quests) {
		testing.expectf(t, game.quest_done(reg, &log, q), "%s never opens", reg.quests[q].id)
	}

	had := obtainable(t, s)
	fabricator, _ := game.registry_item(reg, sandbox.FABRICATOR)
	for &def, q in reg.quests {
		for &st, k in def.steps {
			o := &st.objective
			earlier := before(reg, q, k)
			where_ := strings.concatenate({def.id, ": ", st.text}, context.temp_allocator)
			switch o.goal {
			case .Have, .Use:
				// (any of a tag: each of its items, every one had)
				items := []game.Item{o.item}
				if o.any_of > 0 {
					members := reg.item_tags[o.any_of - 1].members
					items = make([]game.Item, len(members), context.temp_allocator)
					for m, i in members {items[i] = game.Item(m)}
				}
				for item in items {
					testing.expectf(
						t,
						had[item],
						"%s: nothing yields %s",
						where_,
						game.item_id(reg, item),
					)
					testing.expectf(
						t,
						tool_before(reg, earlier, least_tier(reg, item)),
						"%s: no tool of its tier made before",
						where_,
					)
				}
				if o.goal == .Use {
					info, _ := game.item_info(reg, o.item)
					_, consumable := info.consume.?
					testing.expectf(t, consumable, "%s: not a thing to use up", where_)
				}
			case .Make:
				made := false
				for &r in reg.recipes {
					station, ours := sandbox.recipe_station(&r)
					if !ours || r.output.item != o.item {continue}
					all := true
					needs, _, n := game.recipe_needs(&r)
					for i in 0 ..< n {all &&= had[needs[i].item]}
					stands := station == .Hand
					for e in earlier {
						stands ||=
							(e.objective.goal == .Make || e.objective.goal == .Have) &&
							e.objective.item == fabricator
					}
					made ||= all && stands
				}
				testing.expectf(t, made, "%s: no recipe makes it where it stands then", where_)
			case .Place:
				first := game.Block(reg.blocks.types[o.block].first_state)
				item, placeable := game.registry_item(reg, game.block_id(reg, first))
				testing.expectf(t, placeable && had[item], "%s: nothing yields the block", where_)
			case .Break:
				found := false
				for name in WORLD_BLOCKS {
					b, _ := game.registry_block(reg, name)
					if game.block_type_of(&reg.blocks, b) != o.block {continue}
					found = true
					testing.expectf(
						t,
						tool_before(reg, earlier, game.block_tier(reg, b)),
						"%s: no tool of its tier made before",
						where_,
					)
				}
				testing.expectf(t, found, "%s: not a block of the world", where_)
			case .Kill:
				info := game.kind_info(reg, o.creature)
				_, comes := info.spawn.?
				posted := false // (the remains', the ruin's and the delves' posts)
				for id in ([]string{"sandbox:sentry", "sandbox:bulwark", "sandbox:scuttler", "sandbox:spire", "sandbox:carapace"}) {
					posted ||= info.id == id
				}
				testing.expectf(t, info.hittable && (comes || posted), "%s: never met", where_)
			case .Find:
				named := o.name == DELVE_STAIR
				for name in REMAIN_NAMES {named ||= name != "" && name == o.name}
				testing.expectf(
					t,
					(o.place == .Ruin && (o.name == "" || o.name == DELVE_DEEP)) ||
					(o.place == .Settlement && o.name == "") ||
					(o.place == .Landmark && o.name == "") ||
					(o.place == .Remains && named),
					"%s: no place the sandbox notes",
					where_,
				)
			case .Win:
				testing.expectf(
					t,
					o.name == RUIN_ENCOUNTER || o.name == BOSS_ENCOUNTER,
					"%s: no fight the sandbox has",
					where_,
				)
			case .Address:
			case .Visit:
				class, known := worldgen.class_by_name(o.name)
				testing.expectf(
					t,
					o.name == "" || o.name == game.QUEST_HOME || (known && class != .None),
					"%s: no kind of world is called %q",
					where_,
					o.name,
				)
			case .Talk:
				testing.expectf(
					t,
					talk_said(reg, had, o.name, q, k),
					"%s: no conversation says it on this step",
					where_,
				)
			}
			if way, has := st.way.?; has {
				named := way.name == "" || way.name == DELVE_STAIR || way.name == DELVE_DEEP
				for name in REMAIN_NAMES {named ||= name != "" && name == way.name}
				testing.expectf(t, named, "%s: its way names no place there is", where_)
			}
		}
		for r in def.reward {
			testing.expectf(
				t,
				game.item_valid(reg, r.item) && r.count <= game.item_stack_size(reg, r.item),
				"%s: a reward of %d %s",
				def.id,
				r.count,
				game.item_id(reg, r.item),
			)
		}
	}
}

// Played: what a survivor carries, makes, kills, uses and finds moves its quests on, each
// step in turn; a quest done gives its reward and opens the next; the player is told by the
// quests record. A player in creative counts for nothing.
@(test)
test_quests_played :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !survivor(t, rig) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	h := playtest.host(rig)
	reg := s.registry
	waking, edge := quest_of(t, s, "sandbox:waking"), quest_of(t, s, "sandbox:edge_and_point")
	fibre, flint := item_of(t, s, "sandbox:fibre"), item_of(t, s, "sandbox:flint")
	log_item, cord := item_of(t, s, "voxiverse:log"), item_of(t, s, "sandbox:cord")

	// In creative nothing counts.
	core.game_mode(s, h, "creative")
	core.item_give(s, h, fibre, 6)
	playtest.step(rig, 2)
	testing.expect_value(t, h.quests.quests[waking], game.Quest_Progress{})
	core.game_mode(s, h, "survival")
	core.item_clear(s, h, fibre)
	playtest.step(rig, 2)

	// Carrying: five fibre are not six.
	core.item_give(s, h, fibre, 5)
	playtest.step(rig, 2)
	testing.expect_value(t, h.quests.quests[waking].step, 0)
	core.item_give(s, h, fibre, 1)
	playtest.step(rig, 2)
	testing.expect_value(t, h.quests.quests[waking].step, 1)
	core.item_give(s, h, flint, 5)
	core.item_give(s, h, log_item, 4)
	playtest.step(rig, 2)
	testing.expect(t, game.quest_done(reg, &h.quests, waking), "waking not done")
	testing.expect_value(t, core.item_count(h, cord), 2) // (its reward)
	testing.expect(t, game.quest_open(reg, &h.quests, edge), "edge_and_point not open")
	playtest.step(rig, 4)
	testing.expect_value(t, rig.sess.mirror.quests, h.quests) // (the player is told)

	// Making: planks by hand count as they are made.
	ask := sandbox.Craft{recipe_of(t, s, "sandbox:planks")}
	core.harness_request(s, h, &ask)
	playtest.step(rig, playtest.ticks(1))
	testing.expect_value(t, h.quests.quests[edge], game.Quest_Progress{1, 0})

	// Killing: a loper brought down by the player, not by anyone else.
	meat := quest_of(t, s, "sandbox:meat_and_hide")
	for &p, q in h.quests.quests[:len(reg.quests)] {
		if q < meat {p.step = u8(len(reg.quests[q].steps))} 	// (the ones before it done)
	}
	loper, _ := game.registry_kind(reg, "sandbox:loper")
	w := s.home
	other := core.entity_spawn(w, loper, {4.5, 0, 4.5}, false)
	core.entity_harm(w, other, {amount = 100, kind = .Game})
	testing.expect_value(t, h.quests.quests[meat], game.Quest_Progress{})
	prey := core.entity_spawn(w, loper, {4.5, 0, 4.5}, false)
	core.entity_harm(w, prey, {amount = 100, kind = .Hit, by = h})
	testing.expect_value(t, h.quests.quests[meat], game.Quest_Progress{1, 0})

	// Using up: a trail ration eaten (once it is the step).
	ration := item_of(t, s, "sandbox:trail_ration")
	h.quests.quests[meat].step = 2
	for st in h.inventory.slots {if !game.stack_empty(st) {core.item_clear(s, h, st.item)}}
	core.item_give(s, h, ration, 2)
	core.hotbar_select(s, h, 0)
	testing.expect_value(t, core.item_consume(s, h), "")
	testing.expect(t, game.quest_done(reg, &h.quests, meat), "meat_and_hide not done")
	playtest.step(rig, 2)
	vest := item_of(t, s, "sandbox:padded_vest")
	testing.expect_value(t, core.item_count(h, vest), 1)

	// Finding: the ruin noted in the logbook moves its step on; an encounter won, the next.
	ruin := quest_of(t, s, "sandbox:the_ruin_wakes")
	for &p, q in h.quests.quests[:len(reg.quests)] {
		if q < ruin {p.step = u8(len(reg.quests[q].steps))}
	}
	core.logbook_place(s, h, .Ruin, {300, 0, 0})
	testing.expect_value(t, h.quests.quests[ruin], game.Quest_Progress{1, 0})
	core.quest_note(s, h, {goal = .Win, name = "sandbox:somewhere_else", count = 1})
	testing.expect_value(t, h.quests.quests[ruin], game.Quest_Progress{1, 0})
	core.quest_note(s, h, {goal = .Win, name = RUIN_ENCOUNTER, count = 1})
	testing.expect(t, game.quest_done(reg, &h.quests, ruin), "the_ruin_wakes not done")
}

// Kept with the character: its file names the quests begun by id with their step and count
// (a member a reader of format 7 from before skips); read back, it is the same log. A file
// from before has none, a quest the pack no longer has is left out, and a step or a count
// past what the quest has now is cut to it.
@(test)
test_quests_saved :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	reg := s.registry
	waking, turf := quest_of(t, s, "sandbox:waking"), quest_of(t, s, "sandbox:under_the_turf")
	edge := quest_of(t, s, "sandbox:edge_and_point")
	r: core.Player_Record
	r.quests.quests[waking] = {3, 0}
	r.quests.quests[edge] = {1, 1}
	r.quests.quests[turf] = {0, 0}
	text := string(core.player_json(reg, &r, nil))
	testing.expectf(
		t,
		strings.contains(text, `"quests"`) && strings.contains(text, `"sandbox:edge_and_point"`),
		"%s",
		text,
	)
	testing.expect(t, !strings.contains(text, "under_the_turf"), "a quest not begun is written")
	back, ok := core.player_parse(reg, transmute([]u8)text, nil)
	testing.expect(t, ok)
	testing.expect_value(t, back.quests, r.quests)

	older := `{"format": 7, "position": [0, 10, 0], "look": [0, 0], "items": []}`
	none, read := core.player_parse(reg, transmute([]u8)older, nil)
	testing.expect(t, read)
	testing.expect_value(t, none.quests, game.Quest_Log{})

	changed := `{"format": 7, "position": [0, 10, 0], "look": [0, 0], "items": [], "quests": [
		{"id": "sandbox:gone", "step": 1},
		{"id": "sandbox:waking", "step": 9},
		{"id": "sandbox:edge_and_point", "step": 0, "count": 50}]}`
	cut, cut_read := core.player_parse(reg, transmute([]u8)changed, nil)
	testing.expect(t, cut_read)
	testing.expect_value(t, cut.quests.quests[waking], game.Quest_Progress{3, 0})
	testing.expect_value(t, cut.quests.quests[edge], game.Quest_Progress{0, 3}) // (planks: 4 asked)
	testing.expect(t, game.quest_log_valid(reg, &cut.quests))
}
