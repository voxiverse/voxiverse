package game

import "core:strings"
import "core:testing"

// A pack's quests: read from data/quests with every id checked, and moved on only by what a
// player does (quest_note) and what it holds (quest_settle).

QUEST_PACK :: `{
	"first": {"title": "First", "text": "Why it matters.", "steps": [
		{"text": "Carry dirt", "goal": "have", "item": "voxiverse:dirt", "count": 3},
		{"text": "Place stone", "goal": "place", "block": "voxiverse:stone", "count": 2},
		{"text": "Find the ruin", "goal": "find", "place": "ruin"}
	], "reward": [{"item": "voxiverse:stone", "count": 5}]},
	"second": {"title": "Second", "after": ["testpack:first"], "steps": [
		{"text": "Strike down a dummy", "goal": "kill", "creature": "voxiverse:dummy", "way": {"place": "remains", "name": "Old wall"}},
		{"text": "Break stone", "goal": "break", "block": "voxiverse:stone"},
		{"text": "Make planks", "goal": "make", "item": "voxiverse:planks", "count": 8},
		{"text": "Use dirt", "goal": "use", "item": "voxiverse:dirt"},
		{"text": "Win the trial", "goal": "win", "name": "testpack:trial"},
		{"text": "Write an address", "goal": "address"},
		{"text": "Tell the keeper", "goal": "talk", "name": "testpack:keeper"}
	]},
	"aside": {"title": "Aside", "steps": [{"text": "Find the old wall", "goal": "find", "place": "remains", "name": "Old wall"}]},
	"camp": {"title": "Camp", "after": ["testpack:aside"], "steps": [{"text": "Find a camp", "goal": "find", "place": "settlement"}]}
}`

quest_registry :: proc(t: ^testing.T, quests: string) -> (^Registry, string) {
	reg, errs := build_with(
		pack_of(
			"testpack",
			[]File {
				{"data/quests/q.json", quests},
				{
					"data/item_tags/t.json",
					`{"shiny": {"values": ["voxiverse:glass", "voxiverse:planks"]}}`,
				},
			},
		),
	)
	return reg, errors_text(errs)
}

way_is :: proc(way: Maybe(Quest_Way), want: Quest_Way) -> bool {
	got, has := way.?
	return has && got == want
}

@(test)
test_quests_read :: proc(t: ^testing.T) {
	reg, errs := quest_registry(t, QUEST_PACK)
	testing.expect_value(t, errs, "")
	if reg == nil {return}
	defer registry_destroy(reg)
	testing.expect_value(t, len(reg.quests), 4)
	first, _ := quest_by_id(reg, "testpack:first")
	second, _ := quest_by_id(reg, "testpack:second")
	aside, _ := quest_by_id(reg, "testpack:aside")
	q := &reg.quests[second]
	testing.expect_value(t, q.title, "Second")
	testing.expect_value(t, len(q.after), 1)
	testing.expect_value(t, q.after[0], first)
	testing.expect_value(t, len(q.steps), 7)
	dummy, _ := registry_kind(reg, "voxiverse:dummy")
	testing.expect_value(t, q.steps[0].objective.goal, Goal.Kill)
	testing.expect_value(t, q.steps[0].objective.creature, dummy)
	testing.expect(t, way_is(q.steps[0].way, {.Remains, "Old wall"}))
	stone, _ := registry_block(reg, "voxiverse:stone")
	testing.expect_value(t, q.steps[1].objective.block, block_type_of(&reg.blocks, stone))
	testing.expect_value(t, q.steps[2].objective.count, 8)
	testing.expect_value(t, q.steps[4].objective.name, "testpack:trial")
	testing.expect_value(t, q.steps[6].objective.goal, Goal.Talk)
	testing.expect_value(t, q.steps[6].objective.name, "testpack:keeper")
	camp, _ := quest_by_id(reg, "testpack:camp")
	testing.expect(t, way_is(reg.quests[camp].steps[0].way, {.Settlement, ""}))
	// A find step points at the place it asks for.
	testing.expect(t, way_is(reg.quests[aside].steps[0].way, {.Remains, "Old wall"}))
	testing.expect(t, way_is(reg.quests[first].steps[2].way, {.Ruin, ""}))
	item, _ := registry_item(reg, "voxiverse:stone")
	testing.expect_value(t, reg.quests[first].reward[0], Stack{item, 5, 0, 0})
	// The registry's hash knows its quests.
	base, _ := build_with()
	defer registry_destroy(base)
	testing.expect(t, base.hash != reg.hash)
}

// Every mistake is refused with where and why: an id nobody has, a goal missing or
// unknown, a field its goal does not take, a count on a step that counts once, a circle of
// quests each after the next.
@(test)
test_quests_refused :: proc(t: ^testing.T) {
	Case :: struct {
		quests: string,
		error:  string,
	}
	cases := []Case {
		{
			`{"a": {"title": "A", "steps": [{"text": "x", "goal": "have", "item": "voxiverse:nothing"}]}}`,
			"\"voxiverse:nothing\" is not an item",
		},
		{
			`{"a": {"title": "A", "steps": [{"text": "x", "goal": "make", "item": "#testpack:shiny"}]}}`,
			"only a have step names an item tag",
		},
		{
			`{"a": {"title": "A", "steps": [{"text": "x", "goal": "have", "item": "#testpack:nothing"}]}}`,
			"testpack:nothing",
		},
		{
			`{"a": {"title": "A", "steps": [{"text": "x", "goal": "visit", "name": "home", "count": 2}]}}`,
			"a visit step counts once",
		},
		{
			`{"a": {"title": "A", "steps": [{"text": "x", "goal": "visit", "item": "voxiverse:dirt"}]}}`,
			"a visit step names maybe the world's kind",
		},
		{
			`{"a": {"title": "A", "steps": [{"text": "x", "item": "voxiverse:dirt"}]}}`,
			"a step has a \"goal\"",
		},
		{`{"a": {"title": "A", "steps": [{"text": "x", "goal": "dance"}]}}`, "goal"},
		{
			`{"a": {"title": "A", "steps": [{"text": "x", "goal": "make", "block": "voxiverse:stone"}]}}`,
			"a make step names an \"item\"",
		},
		{
			`{"a": {"title": "A", "steps": [{"text": "x", "goal": "kill", "creature": "voxiverse:unicorn"}]}}`,
			"\"voxiverse:unicorn\" is not an entity kind",
		},
		{
			`{"a": {"title": "A", "steps": [{"text": "x", "goal": "find", "place": "ruin", "count": 2}]}}`,
			"a find step counts once",
		},
		{
			`{"a": {"title": "A", "steps": [{"text": "x", "goal": "address", "colour": 1}]}}`,
			"\"colour\" is not a step field",
		},
		{
			`{"a": {"title": "A", "steps": [{"text": "x", "goal": "talk", "name": "a:b", "count": 2}]}}`,
			"a talk step counts once",
		},
		{
			`{"a": {"title": "A", "steps": [{"text": "x", "goal": "talk"}]}}`,
			"a talk step names what is said",
		},
		{`{"a": {"title": "A", "steps": []}}`, "a quest has \"steps\""},
		{`{"a": {"steps": [{"text": "x", "goal": "address"}]}}`, "a quest has a \"title\""},
		{
			`{"a": {"title": "A", "after": ["testpack:b"], "steps": [{"text": "x", "goal": "address"}]}, "b": {"title": "B", "after": ["testpack:a"], "steps": [{"text": "x", "goal": "address"}]}}`,
			"comes after itself",
		},
		{
			`{"a": {"title": "A", "after": ["testpack:z"], "steps": [{"text": "x", "goal": "address"}]}}`,
			"\"testpack:z\" is not a quest",
		},
		{
			`{"a": {"title": "A", "steps": [{"text": "x", "goal": "address"}], "reward": [{"item": "voxiverse:dirt", "count": 0}]}}`,
			"count is 1..999",
		},
	}
	for c in cases {
		reg, errs := quest_registry(t, c.quests)
		testing.expectf(t, reg == nil && strings.contains(errs, c.error), "%s: %q", c.quests, errs)
		registry_destroy(reg)
	}
}

// Each step counts what happens while it is the step, in order; a state (what it carries,
// its logbook) moves it on as it holds; the quest after opens when the one before is done,
// and the quests done are told (their reward is due).
@(test)
test_quest_conditions :: proc(t: ^testing.T) {
	reg, errs := quest_registry(t, QUEST_PACK)
	testing.expect_value(t, errs, "")
	if reg == nil {return}
	defer registry_destroy(reg)
	first, _ := quest_by_id(reg, "testpack:first")
	second, _ := quest_by_id(reg, "testpack:second")
	aside, _ := quest_by_id(reg, "testpack:aside")
	dirt, _ := registry_item(reg, "voxiverse:dirt")
	planks, _ := registry_item(reg, "voxiverse:planks")
	stone, _ := registry_block(reg, "voxiverse:stone")
	grass, _ := registry_block(reg, "voxiverse:grass")
	dummy, _ := registry_kind(reg, "voxiverse:dummy")
	log: Quest_Log
	inv: Inventory
	book: Logbook

	testing.expect(t, quest_open(reg, &log, first) && quest_open(reg, &log, aside))
	testing.expect(t, !quest_open(reg, &log, second), "open before the quest it comes after")
	testing.expect(t, quest_wants(reg, &log, .Have) && !quest_wants(reg, &log, .Kill))
	// Carrying two dirt is not three; a third is.
	inventory_add(reg, &inv, {dirt, 2, 0, 0})
	testing.expect_value(t, quest_settle(reg, &log, &inv, &book, QUEST_HOME), Quest_Changes{})
	inventory_add(reg, &inv, {dirt, 1, 0, 0})
	testing.expect_value(
		t,
		quest_settle(reg, &log, &inv, &book, QUEST_HOME),
		Quest_Changes{steps = 1},
	)
	testing.expect_value(t, log.quests[first], Quest_Progress{1, 0})
	// Stone placed counts; grass does not, nor a break of stone.
	testing.expect_value(
		t,
		quest_note(reg, &log, {goal = .Place, block = grass, count = 1}, &inv, &book, QUEST_HOME),
		Quest_Changes{},
	)
	testing.expect_value(
		t,
		quest_note(reg, &log, {goal = .Break, block = stone, count = 1}, &inv, &book, QUEST_HOME),
		Quest_Changes{},
	)
	testing.expect_value(
		t,
		quest_note(reg, &log, {goal = .Place, block = stone, count = 1}, &inv, &book, QUEST_HOME),
		Quest_Changes{},
	)
	testing.expect_value(t, log.quests[first], Quest_Progress{1, 1})
	// The ruin already in the logbook: the place step done as the one before it is.
	logbook_place(&book, .Ruin, {}, {40, 0, 40})
	changes := quest_note(
		reg,
		&log,
		{goal = .Place, block = stone, count = 1},
		&inv,
		&book,
		QUEST_HOME,
	)
	testing.expect_value(t, changes, Quest_Changes{steps = 2, done = {first}})
	testing.expect(t, quest_done(reg, &log, first) && quest_open(reg, &log, second))
	testing.expect(t, quest_step(reg, &log, first) == nil)

	// The second quest: each event in its turn; the old wall found settles the quest aside
	// whatever the event.
	testing.expect_value(
		t,
		quest_note(reg, &log, {goal = .Break, block = stone, count = 1}, &inv, &book, QUEST_HOME),
		Quest_Changes{},
	)
	testing.expect_value(
		t,
		quest_note(
			reg,
			&log,
			{goal = .Kill, creature = dummy, count = 1},
			&inv,
			&book,
			QUEST_HOME,
		),
		Quest_Changes{steps = 1},
	)
	testing.expect_value(
		t,
		quest_note(reg, &log, {goal = .Break, block = stone, count = 1}, &inv, &book, QUEST_HOME),
		Quest_Changes{steps = 1},
	)
	testing.expect_value(
		t,
		quest_note(reg, &log, {goal = .Make, item = planks, count = 4}, &inv, &book, QUEST_HOME),
		Quest_Changes{},
	)
	logbook_place(&book, .Remains, {}, {90, 0, 0}, "Old wall")
	changes = quest_note(
		reg,
		&log,
		{goal = .Make, item = planks, count = 4},
		&inv,
		&book,
		QUEST_HOME,
	)
	testing.expect_value(t, changes, Quest_Changes{steps = 2, done = {aside}})
	testing.expect_value(
		t,
		quest_note(reg, &log, {goal = .Use, item = planks, count = 1}, &inv, &book, QUEST_HOME),
		Quest_Changes{},
	)
	testing.expect_value(
		t,
		quest_note(reg, &log, {goal = .Use, item = dirt, count = 1}, &inv, &book, QUEST_HOME),
		Quest_Changes{steps = 1},
	)
	testing.expect_value(
		t,
		quest_note(
			reg,
			&log,
			{goal = .Win, name = "testpack:other", count = 1},
			&inv,
			&book,
			QUEST_HOME,
		),
		Quest_Changes{},
	)
	testing.expect_value(
		t,
		quest_note(
			reg,
			&log,
			{goal = .Win, name = "testpack:trial", count = 1},
			&inv,
			&book,
			QUEST_HOME,
		),
		Quest_Changes{steps = 1},
	)
	testing.expect_value(
		t,
		quest_note(reg, &log, {goal = .Address, count = 1}, &inv, &book, QUEST_HOME),
		Quest_Changes{steps = 1},
	)
	// Something said counts by what it was.
	testing.expect_value(
		t,
		quest_note(
			reg,
			&log,
			{goal = .Talk, name = "testpack:stranger", count = 1},
			&inv,
			&book,
			QUEST_HOME,
		),
		Quest_Changes{},
	)
	testing.expect_value(
		t,
		quest_note(
			reg,
			&log,
			{goal = .Talk, name = "testpack:keeper", count = 1},
			&inv,
			&book,
			QUEST_HOME,
		),
		Quest_Changes{steps = 1, done = {second}},
	)
	// A camp found: the quest after the one aside, open now, settles.
	camp, _ := quest_by_id(reg, "testpack:camp")
	testing.expect(t, quest_open(reg, &log, camp))
	logbook_place(&book, .Settlement, {}, {400, 0, 0}, "Ember Hollow")
	testing.expect_value(
		t,
		quest_settle(reg, &log, &inv, &book, QUEST_HOME),
		Quest_Changes{steps = 1, done = {camp}},
	)
	for q in 0 ..< len(reg.quests) {testing.expect(t, quest_done(reg, &log, q))}
	// Done is done: nothing counts any more.
	testing.expect_value(
		t,
		quest_note(
			reg,
			&log,
			{goal = .Talk, name = "testpack:keeper", count = 1},
			&inv,
			&book,
			QUEST_HOME,
		),
		Quest_Changes{},
	)
	testing.expect(t, quest_log_valid(reg, &log))
}

// What the wire may carry: no step past a quest's last, no count past its step's, nothing
// begun of a quest the registry lacks.
@(test)
test_quest_log_valid :: proc(t: ^testing.T) {
	reg, errs := quest_registry(t, QUEST_PACK)
	testing.expect_value(t, errs, "")
	if reg == nil {return}
	defer registry_destroy(reg)
	second, _ := quest_by_id(reg, "testpack:second")
	log: Quest_Log
	testing.expect(t, quest_log_valid(reg, &log))
	log.quests[second] = {2, 7}
	testing.expect(t, quest_log_valid(reg, &log))
	log.quests[second] = {2, 8}
	testing.expect(t, !quest_log_valid(reg, &log), "a count as big as its step's")
	log.quests[second] = {7, 0}
	testing.expect(t, quest_log_valid(reg, &log))
	log.quests[second] = {8, 0}
	testing.expect(t, !quest_log_valid(reg, &log), "past the last step")
	log.quests[second] = {}
	log.quests[len(reg.quests)] = {1, 0}
	testing.expect(t, !quest_log_valid(reg, &log), "a quest the registry lacks")
}

// A visit step holds while the player stands on a world of its kind ("home", a class's;
// none: any world but home), as the server names it; a have step of an item tag counts any
// of its items together.
@(test)
test_quest_visit_and_any_of :: proc(t: ^testing.T) {
	QUESTS :: `{
		"away": {"title": "Away", "steps": [
			{"text": "Step through", "goal": "visit"},
			{"text": "Find the jungle", "goal": "visit", "name": "jungle"},
			{"text": "Bring something shiny", "goal": "have", "item": "#testpack:shiny", "count": 3},
			{"text": "Go home", "goal": "visit", "name": "home"}
		]}
	}`
	reg, errs := quest_registry(t, QUESTS)
	testing.expect_value(t, errs, "")
	if reg == nil {return}
	defer registry_destroy(reg)
	away, _ := quest_by_id(reg, "testpack:away")
	testing.expect_value(t, reg.quests[away].steps[2].objective.any_of, 1)
	glass, _ := registry_item(reg, "voxiverse:glass")
	planks, _ := registry_item(reg, "voxiverse:planks")
	log: Quest_Log
	inv: Inventory
	book: Logbook
	testing.expect_value(t, quest_settle(reg, &log, &inv, &book, QUEST_HOME), Quest_Changes{})
	testing.expect_value(t, quest_settle(reg, &log, &inv, &book, ""), Quest_Changes{})
	testing.expect_value(
		t,
		quest_settle(reg, &log, &inv, &book, "ocean"),
		Quest_Changes{steps = 1},
	)
	testing.expect_value(t, quest_settle(reg, &log, &inv, &book, "ocean"), Quest_Changes{})
	testing.expect_value(
		t,
		quest_settle(reg, &log, &inv, &book, "jungle"),
		Quest_Changes{steps = 1},
	)
	inventory_add(reg, &inv, {glass, 2, 0, 0})
	o := &reg.quests[away].steps[2].objective
	testing.expect_value(t, quest_carried(reg, o, &inv), 2)
	testing.expect_value(t, quest_settle(reg, &log, &inv, &book, "jungle"), Quest_Changes{})
	inventory_add(reg, &inv, {planks, 1, 0, 0})
	testing.expect_value(t, quest_carried(reg, o, &inv), 3)
	testing.expect_value(
		t,
		quest_settle(reg, &log, &inv, &book, "jungle"),
		Quest_Changes{steps = 1},
	)
	testing.expect_value(
		t,
		quest_settle(reg, &log, &inv, &book, QUEST_HOME),
		Quest_Changes{steps = 1, done = {away}},
	)
}
