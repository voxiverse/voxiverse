package game

import "core:fmt"

// Quests in the registry (quest.odin): data/quests/<name>.json, one object a quest,
//
//	{"first_tool": {"title": "Edge and Point", "text": "...", "after": ["sandbox:waking"],
//	                "steps": [{"text": "Make a flint pick", "goal": "make", "item": "sandbox:flint_pick"}],
//	                "reward": [{"item": "sandbox:field_dressing", "count": 2}]}}
//
// A step is its `text`, its `goal` (have, make, place, break, find, kill, use, win, address,
// talk) with what the goal names (`item` for have, make and use; `block` for place and break;
// `creature` for kill; `place` (a logbook place's kind) and maybe `name` for find; `name`
// (the encounter's) for win, (what is said: a dialogue's or a reply's) for talk), a `count` (1 when none) and maybe a `way`, {"place": <kind>,
// "name": <its name>}: the place the compass points at while it is the step. A find step
// points at the place it asks for. Quests are read after everything they name, so every
// id is checked; one quest may come after another (`after`) but never round in a circle.

@(private)
QUEST_FIELDS := []string{"title", "text", "after", "steps", "reward", "xp", "override"}
@(private)
STEP_FIELDS := []string {
	"text",
	"goal",
	"item",
	"block",
	"creature",
	"place",
	"name",
	"count",
	"way",
}
@(private)
GOAL_NAMES := []string {
	"have",
	"make",
	"place",
	"break",
	"find",
	"kill",
	"use",
	"win",
	"address",
	"talk",
} // (by Goal)
@(private)
PLACE_NAMES := []string{"gate", "ruin", "town", "outpost", "beacon", "remains", "settlement"} // (by Logbook_Place_Kind)

// read_quests: the quests (after every kind they may name), and that none comes after
// itself by any way round.
@(private)
read_quests :: proc(b: ^Reg_Build, reg: ^Registry) {
	defs := b.defs[.Quest][:]
	if len(defs) > MAX_QUESTS {
		fail(b, -1, "", 0, 0, fmt.aprintf("%d quests; the limit is %d", len(defs), MAX_QUESTS))
		return
	}
	for text, at in b.index[.Quest] {reg.ids[.Quest][text] = u32(at)}
	reg.quests = make([]Quest_Def, len(defs))
	for &m, i in defs {reg.quests[i] = read_quest(b, reg, &m)}
	// No circle: a quest's `after`, followed as far as it goes, never comes back to it.
	for &m, i in defs {
		seen := make([]bool, len(defs), context.temp_allocator)
		stack := make([dynamic]int, context.temp_allocator)
		append(&stack, ..reg.quests[i].after)
		for len(stack) > 0 {
			at := pop(&stack)
			if at == i {
				fail(
					b,
					m.pack,
					m.file,
					m.line,
					m.column,
					fmt.aprintf("\"%s\" comes after itself (its `after` leads back to it)", m.id),
				)
				break
			}
			if seen[at] {continue}
			seen[at] = true
			append(&stack, ..reg.quests[at].after)
		}
	}
}

@(private = "file")
read_quest :: proc(b: ^Reg_Build, reg: ^Registry, m: ^Merged_Def) -> Quest_Def {
	q := Quest_Def {
		id = m.id,
	}
	q.title = quest_text(b, m, "title", QUEST_TITLE_MAX, true)
	q.text = quest_text(b, m, "text", QUEST_TEXT_MAX, false)
	q.xp = u32(rd_int(b, m, "xp", 0, 0, MAX_XP))
	if f := field_of(m, "after"); f != nil {
		if f.value.kind != .Array || len(f.value.items) > MAX_QUEST_AFTER {
			fail_field(
				b,
				f,
				f.value,
				fmt.aprintf("after is a list of at most %d quest ids", MAX_QUEST_AFTER),
			)
		} else {
			after := make([dynamic]int)
			for e in f.value.items {
				if e.kind != .String {
					fail_field(b, f, e, "after names quests by id")
				} else if at, ok := ref_index(b, .Quest, e.s, f, e); ok {
					append(&after, at)
				}
			}
			q.after = after[:]
		}
	}
	f := field_of(m, "steps")
	if f == nil ||
	   f.value.kind != .Array ||
	   len(f.value.items) < 1 ||
	   len(f.value.items) > MAX_QUEST_STEPS {
		fail(
			b,
			m.pack,
			m.file,
			m.line,
			m.column,
			fmt.aprintf("a quest has \"steps\", a list of 1 to %d steps", MAX_QUEST_STEPS),
		)
		return q
	}
	steps := make([dynamic]Quest_Step)
	for e in f.value.items {
		if step, ok := read_step(b, reg, f, e); ok {append(&steps, step)}
	}
	q.steps = steps[:]
	if rf := field_of(m, "reward"); rf != nil {
		if rf.value.kind != .Array || len(rf.value.items) > MAX_QUEST_REWARDS {
			fail_field(
				b,
				rf,
				rf.value,
				fmt.aprintf(
					"reward is a list of at most %d {\"item\": ..., \"count\": ...}",
					MAX_QUEST_REWARDS,
				),
			)
			return q
		}
		reward := make([dynamic]Stack)
		for e in rf.value.items {
			if e.kind != .Object {
				fail_field(b, rf, e, "a reward is {\"item\": \"<id>\", \"count\": 1}")
				continue
			}
			st := Stack {
				count = 1,
			}
			for em in e.members {
				switch em.key {
				case "item":
					st.item = quest_item(b, reg, rf, em.value)
				case "count":
					st.count = quest_count(b, rf, em.value)
				case:
					fail_field(
						b,
						rf,
						em.value,
						fmt.aprintf(
							"\"%s\" is not a reward field%s",
							em.key,
							suggestion(em.key, []string{"item", "count"}),
						),
					)
				}
			}
			if st.item == NO_ITEM {
				fail_field(b, rf, e, "a reward names its \"item\"")
				continue
			}
			append(&reward, st)
		}
		q.reward = reward[:]
	}
	return q
}

// read_step: one of a quest's steps; false when it is not one (the error said why).
@(private = "file")
read_step :: proc(
	b: ^Reg_Build,
	reg: ^Registry,
	f: ^Def_Field,
	v: Json_Value,
) -> (
	step: Quest_Step,
	ok: bool,
) {
	if v.kind != .Object {
		fail_field(b, f, v, "a step is {\"text\": ..., \"goal\": ..., ...}")
		return
	}
	errors := len(b.errs)
	o := &step.objective
	o.count = 1
	has: bit_set[Step_Field]
	for e in v.members {
		switch e.key {
		case "text":
			if e.value.kind != .String || e.value.s == "" || len(e.value.s) > QUEST_TEXT_MAX {
				fail_field(b, f, e.value, fmt.aprintf("text is 1 to %d bytes", QUEST_TEXT_MAX))
			} else {
				step.text = e.value.s
			}
		case "goal":
			o.goal = Goal(choice_of(b, f, e.value, "goal", GOAL_NAMES, 0))
			has += {.Goal}
		case "item":
			o.item = quest_item(b, reg, f, e.value)
			has += {.Item}
		case "block":
			if e.value.kind != .String {
				fail_field(b, f, e.value, "block is a block id")
			} else if at, known := registry_block(reg, e.value.s); known {
				o.block = block_type_of(&reg.blocks, at)
				has += {.Block}
			} else {
				fail_field(b, f, e.value, fmt.aprintf("\"%s\" is not a block", e.value.s))
			}
		case "creature":
			if e.value.kind != .String {
				fail_field(b, f, e.value, "creature is an entity kind's id")
			} else if kind, known := registry_kind(reg, e.value.s); known {
				o.creature = kind
				has += {.Creature}
			} else {
				fail_field(b, f, e.value, fmt.aprintf("\"%s\" is not an entity kind", e.value.s))
			}
		case "place":
			o.place = Logbook_Place_Kind(choice_of(b, f, e.value, "place", PLACE_NAMES, 0))
			has += {.Place}
		case "name":
			if e.value.kind != .String || e.value.s == "" || len(e.value.s) > PLACE_NAME_MAX {
				fail_field(b, f, e.value, fmt.aprintf("name is 1 to %d bytes", PLACE_NAME_MAX))
			} else {
				o.name = e.value.s
				has += {.Name}
			}
		case "count":
			o.count = quest_count(b, f, e.value)
		case "way":
			step.way = quest_way(b, f, e.value)
		case:
			fail_field(
				b,
				f,
				e.value,
				fmt.aprintf("\"%s\" is not a step field%s", e.key, suggestion(e.key, STEP_FIELDS)),
			)
		}
	}
	if step.text == "" &&
	   len(b.errs) == errors {fail_field(b, f, v, "a step says what to do: \"text\"")}
	if .Goal not_in has {
		fail_field(
			b,
			f,
			v,
			"a step has a \"goal\": have, make, place, break, find, kill, use, win, address or talk",
		)
		return
	}
	// What the goal names, and nothing it does not.
	wants: bit_set[Step_Field]
	switch o.goal {
	case .Have, .Make, .Use:
		wants = {.Item}
	case .Place, .Break:
		wants = {.Block}
	case .Kill:
		wants = {.Creature}
	case .Find:
		wants = {.Place}
		if .Name in has {wants += {.Name}}
		if step.way == nil {step.way = Quest_Way{o.place, o.name}}
	case .Win, .Talk:
		wants = {.Name}
	case .Address:
	}
	if has - {.Goal} != wants {
		fail_field(
			b,
			f,
			v,
			fmt.aprintf("a %s step names %s", GOAL_NAMES[o.goal], GOAL_WANTS[o.goal]),
		)
		return
	}
	if (o.goal == .Find || o.goal == .Win || o.goal == .Address || o.goal == .Talk) &&
	   o.count != 1 {
		fail_field(b, f, v, fmt.aprintf("a %s step counts once", GOAL_NAMES[o.goal]))
		return
	}
	return step, len(b.errs) == errors
}

// Step_Field: what a step names beside its text, count and way.
@(private = "file")
Step_Field :: enum u8 {
	Goal,
	Item,
	Block,
	Creature,
	Place,
	Name,
}

@(private = "file")
GOAL_WANTS := [Goal]string {
	.Have    = "an \"item\" (and a \"count\")",
	.Make    = "an \"item\" (and a \"count\")",
	.Use     = "an \"item\" (and a \"count\")",
	.Place   = "a \"block\" (and a \"count\")",
	.Break   = "a \"block\" (and a \"count\")",
	.Kill    = "a \"creature\" (and a \"count\")",
	.Find    = "a \"place\" (a logbook place's kind) and maybe its \"name\"",
	.Win     = "the encounter's \"name\"",
	.Address = "nothing more",
	.Talk    = "what is said: its \"name\"",
}

@(private = "file")
quest_text :: proc(
	b: ^Reg_Build,
	m: ^Merged_Def,
	name: string,
	most: int,
	needed: bool,
) -> string {
	f := field_of(m, name)
	if f == nil {
		if needed {fail(b, m.pack, m.file, m.line, m.column, fmt.aprintf("a quest has a \"%s\"", name))}
		return ""
	}
	if f.value.kind != .String || f.value.s == "" || len(f.value.s) > most {
		fail_field(b, f, f.value, fmt.aprintf("%s is 1 to %d bytes", name, most))
		return ""
	}
	return f.value.s
}

@(private = "file")
quest_item :: proc(b: ^Reg_Build, reg: ^Registry, f: ^Def_Field, v: Json_Value) -> Item {
	if v.kind != .String {
		fail_field(b, f, v, "item is an item id")
		return NO_ITEM
	}
	item, known := registry_item(reg, v.s)
	if !known {
		fail_field(b, f, v, fmt.aprintf("\"%s\" is not an item", v.s))
		return NO_ITEM
	}
	return item
}

@(private = "file")
quest_count :: proc(b: ^Reg_Build, f: ^Def_Field, v: Json_Value) -> int {
	if v.kind != .Int || v.i < 1 || v.i > MAX_QUEST_COUNT {
		fail_field(b, f, v, fmt.aprintf("count is 1..%d", MAX_QUEST_COUNT))
		return 1
	}
	return int(v.i)
}

@(private = "file")
quest_way :: proc(b: ^Reg_Build, f: ^Def_Field, v: Json_Value) -> Maybe(Quest_Way) {
	if v.kind != .Object {
		fail_field(b, f, v, "way is {\"place\": \"<kind>\", \"name\": \"<its name>\"}")
		return nil
	}
	way: Quest_Way
	placed := false
	for e in v.members {
		switch e.key {
		case "place":
			way.kind = Logbook_Place_Kind(choice_of(b, f, e.value, "place", PLACE_NAMES, 0))
			placed = true
		case "name":
			if e.value.kind != .String || e.value.s == "" || len(e.value.s) > PLACE_NAME_MAX {
				fail_field(b, f, e.value, fmt.aprintf("name is 1 to %d bytes", PLACE_NAME_MAX))
			} else {
				way.name = e.value.s
			}
		case:
			fail_field(
				b,
				f,
				e.value,
				fmt.aprintf(
					"\"%s\" is not a way field%s",
					e.key,
					suggestion(e.key, []string{"place", "name"}),
				),
			)
		}
	}
	if !placed {
		fail_field(b, f, v, "a way names its \"place\"")
		return nil
	}
	return way
}
