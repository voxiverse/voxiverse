package game

import "core:strings"
import "core:testing"

// A pack's dialogues: read from data/dialogues with every id and node checked, refused with
// where and why, and evaluated purely: which node opens, which replies are offered, and a
// reply that is not offered refused.

DIALOGUE_QUESTS :: `{
	"errand": {"title": "Errand", "steps": [
		{"text": "Agree", "goal": "talk", "name": "testpack:agreed"},
		{"text": "Carry dirt", "goal": "have", "item": "voxiverse:dirt", "count": 3},
		{"text": "Hand it over", "goal": "talk", "name": "testpack:handed"}
	]}
}`

DIALOGUE_PACK :: `{
	"keeper": {
		"title": "Keeper",
		"start": [
			{"if": [{"quest": "testpack:errand", "step": 3}], "go": "back"},
			{"if": [{"done": "testpack:errand"}], "go": "thanks"},
			{"go": "hello"}
		],
		"nodes": {
			"hello": {"text": "Well met.", "replies": [
				{"text": "Any work?", "if": [{"quest": "testpack:errand", "step": 1}], "do": [{"talk": "testpack:agreed"}], "go": "work"},
				{"text": "Mend me (3)", "if": [{"hurt": true}], "do": [{"cost": 3}, {"game": "heal"}], "go": "hello"},
				{"text": "Seen the ruin?", "if": [{"found": "ruin"}], "go": "hello"},
				{"text": "Goodbye"}
			]},
			"work": {"text": "Bring me three dirt.", "replies": [{"text": "I will", "go": "hello"}, {"text": "Is there harder work?", "if": [{"level": 3}], "go": "hello"}]},
			"back": {"text": "Have it?", "replies": [
				{"text": "Here", "do": [{"take": "voxiverse:dirt", "count": 3}, {"talk": "testpack:handed"}, {"pay": 5}, {"give": "voxiverse:stone", "count": 2}]},
				{"text": "Not yet"}
			]},
			"thanks": {"text": "My thanks.", "replies": [{"text": "Bye"}]}
		}
	}
}`

dialogue_registry :: proc(dialogues: string) -> (^Registry, string) {
	reg, errs := build_with(
		pack_of(
			"testpack",
			[]File{{"data/quests/q.json", DIALOGUE_QUESTS}, {"data/dialogues/d.json", dialogues}},
		),
	)
	return reg, errors_text(errs)
}

@(test)
test_dialogues_read :: proc(t: ^testing.T) {
	reg, errs := dialogue_registry(DIALOGUE_PACK)
	testing.expect_value(t, errs, "")
	if reg == nil {return}
	defer registry_destroy(reg)
	testing.expect_value(t, len(reg.dialogues), 1)
	at, found := dialogue_by_id(reg, "testpack:keeper")
	testing.expect(t, found)
	d := &reg.dialogues[at]
	testing.expect_value(t, d.title, "Keeper")
	testing.expect_value(t, len(d.openings), 3)
	testing.expect_value(t, len(d.nodes), 4)
	testing.expect_value(t, d.openings[0].conditions[0].kind, Condition_Kind.Step)
	testing.expect_value(t, d.openings[0].conditions[0].step, 2) // (the third: from 0)
	testing.expect_value(t, d.openings[0].node, 2)
	hello := &d.nodes[0]
	testing.expect_value(t, hello.line, "Well met.")
	testing.expect_value(t, len(hello.replies), 4)
	testing.expect_value(t, hello.replies[0].next, 1)
	testing.expect_value(t, hello.replies[3].next, -1)
	testing.expect_value(t, hello.replies[1].effects[0], Dialogue_Effect{kind = .Cost, count = 3})
	testing.expect_value(t, hello.replies[1].effects[1].name, "heal")
	stone, _ := registry_item(reg, "voxiverse:stone")
	give := d.nodes[2].replies[0].effects[3]
	testing.expect_value(t, give, Dialogue_Effect{kind = .Give, item = stone, count = 2})
	// The registry's hash knows its dialogues.
	quests, _ := build_with(pack_of("testpack", []File{{"data/quests/q.json", DIALOGUE_QUESTS}}))
	defer registry_destroy(quests)
	testing.expect(t, quests.hash != reg.hash)
}

// Every mistake is refused with where and why.
@(test)
test_dialogues_refused :: proc(t: ^testing.T) {
	Case :: struct {
		dialogues: string,
		error:     string,
	}
	one :: proc(replies: string, start := `[{"go": "a"}]`) -> string {
		return strings.concatenate(
			{
				`{"d": {"title": "D", "start": `,
				start,
				`, "nodes": {"a": {"text": "Hi.", "replies": `,
				replies,
				`}}}}`,
			},
			context.temp_allocator,
		)
	}
	cases := []Case {
		{
			`{"d": {"start": [{"go": "a"}], "nodes": {"a": {"text": "Hi.", "replies": [{"text": "Bye"}]}}}}`,
			"a dialogue has a \"title\"",
		},
		{`{"d": {"title": "D", "start": [{"go": "a"}], "nodes": {}}}`, "a dialogue has \"nodes\""},
		{one(`[{"text": "Bye"}]`, `[]`), "a dialogue has a \"start\""},
		{one(`[{"text": "Bye"}]`, `[{"go": "z"}]`), "go names a node of the dialogue, not z"},
		{
			one(`[{"text": "Bye"}]`, `[{"if": [{"hurt": true}], "go": "a"}]`),
			"the last opening has no \"if\"",
		},
		{one(`[]`), "has \"replies\", a list of 1 to 4"},
		{one(`[{"text": "Pay", "do": [{"cost": 2}]}]`), "no reply that is always offered"},
		{one(`[{"text": "Bye", "go": "b"}]`), "go names a node of the dialogue, not b"},
		{
			one(`[{"text": "x", "if": [{"quest": "testpack:nothing"}]}, {"text": "Bye"}]`),
			"\"testpack:nothing\" is not a quest",
		},
		{
			one(
				`[{"text": "x", "if": [{"quest": "testpack:errand", "step": 4}]}, {"text": "Bye"}]`,
			),
			"the quest has 3 steps",
		},
		{
			one(`[{"text": "x", "if": [{"have": "voxiverse:gold"}]}, {"text": "Bye"}]`),
			"\"voxiverse:gold\" is not an item",
		},
		{one(`[{"text": "x", "if": [{"found": "castle"}]}, {"text": "Bye"}]`), "found"},
		{
			one(`[{"text": "x", "if": [{"dance": true}]}, {"text": "Bye"}]`),
			"\"dance\" is not a condition",
		},
		{one(`[{"text": "x", "if": [{"level": 0}]}, {"text": "Bye"}]`), "count is 1..100"},
		{
			one(
				`[{"text": "x", "if": [{"done": "testpack:errand", "have": "voxiverse:dirt"}]}, {"text": "Bye"}]`,
			),
			"alone",
		},
		{one(`[{"text": "x", "do": [{"fly": 1}]}, {"text": "Bye"}]`), "\"fly\" is not an effect"},
		{one(`[{"text": "x", "do": [{"pay": 0}]}, {"text": "Bye"}]`), "count is 1..9999"},
		{one(`[{"text": "x", "do": [{"talk": ""}]}, {"text": "Bye"}]`), "talk is 1 to 32 bytes"},
		{one(`[{"text": "x", "do": [{"talk": "a", "game": "b"}]}, {"text": "Bye"}]`), "alone"},
		{one(`[{"go": "a"}, {"text": "Bye"}]`), "a reply says something"},
		{one(`[{"text": "Bye", "colour": 1}]`), "\"colour\" is not a reply field"},
	}
	for c in cases {
		reg, errs := dialogue_registry(c.dialogues)
		testing.expectf(
			t,
			reg == nil && strings.contains(errs, c.error),
			"%s: %q",
			c.dialogues,
			errs,
		)
		registry_destroy(reg)
	}
}

// The openings in order, the replies offered by their conditions, what they take and what
// they cost; a reply not offered (not there, its condition not holding, too dear) refused.
@(test)
test_dialogue_evaluated :: proc(t: ^testing.T) {
	reg, errs := dialogue_registry(DIALOGUE_PACK)
	testing.expect_value(t, errs, "")
	if reg == nil {return}
	defer registry_destroy(reg)
	at, _ := dialogue_by_id(reg, "testpack:keeper")
	d := &reg.dialogues[at]
	errand, _ := quest_by_id(reg, "testpack:errand")
	dirt, _ := registry_item(reg, "voxiverse:dirt")
	log: Quest_Log
	inv: Inventory
	book: Logbook
	facts := Dialogue_Facts {
		quests    = &log,
		inventory = &inv,
		logbook   = &book,
	}

	// The errand under way on its first step: the work is offered, the mending and the ruin
	// are not.
	testing.expect_value(t, dialogue_opening(reg, d, facts), 0)
	testing.expect_value(t, dialogue_offered(reg, d, 0, facts), Reply_Set{0, 3})
	_, ok := dialogue_answer(reg, d, 0, 1, facts)
	testing.expect(t, !ok, "the mending answered while not hurt")
	_, ok = dialogue_answer(reg, d, 0, 4, facts)
	testing.expect(t, !ok, "a reply that is not there answered")
	_, ok = dialogue_answer(reg, d, 0, -1, facts)
	testing.expect(t, !ok, "a reply that is not there answered")
	r, answered := dialogue_answer(reg, d, 0, 0, facts)
	testing.expect(t, answered && r.next == 1 && r.effects[0].name == "testpack:agreed")

	// Hurt with 2 of the money: still too dear; with 3, offered. The ruin found: its reply.
	facts.hurt, facts.purse = true, 2
	testing.expect_value(t, dialogue_offered(reg, d, 0, facts), Reply_Set{0, 3})
	facts.purse = 3
	logbook_place(&book, .Ruin, {}, {300, 0, 0})
	testing.expect_value(t, dialogue_offered(reg, d, 0, facts), Reply_Set{0, 1, 2, 3})

	// On the third step it opens on the hand-over, offered only with the dirt carried.
	log.quests[errand] = {2, 0}
	testing.expect_value(t, dialogue_opening(reg, d, facts), 2)
	testing.expect_value(t, dialogue_offered(reg, d, 2, facts), Reply_Set{1})
	inventory_add(reg, &inv, {dirt, 3, 0, 0})
	testing.expect_value(t, dialogue_offered(reg, d, 2, facts), Reply_Set{0, 1})
	testing.expect_value(t, dialogue_offered(reg, d, 0, facts), Reply_Set{1, 2, 3}) // (the errand not on its first)

	// The harder work asks a level.
	testing.expect_value(t, dialogue_offered(reg, d, 1, facts), Reply_Set{0})
	facts.level = 3
	testing.expect_value(t, dialogue_offered(reg, d, 1, facts), Reply_Set{0, 1})

	// Done: the thanks; a node that is not there offers nothing.
	log.quests[errand] = {3, 0}
	testing.expect_value(t, dialogue_opening(reg, d, facts), 3)
	testing.expect_value(t, dialogue_offered(reg, d, 9, facts), Reply_Set{})
}
