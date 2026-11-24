package game

import "core:fmt"

// Dialogues in the registry (dialogue.odin): data/dialogues/<name>.json, one object a
// dialogue,
//
//	{"medic": {"title": "Medic",
//	           "start": [{"if": [{"quest": "sandbox:hides", "step": 3}], "go": "hides"}, {"go": "hello"}],
//	           "nodes": {"hello": {"text": "Sit. Where does it hurt?", "replies": [
//	               {"text": "Patch me up (3 silver)", "if": [{"hurt": true}],
//	                "do": [{"cost": 3}, {"game": "heal"}], "go": "hello"},
//	               {"text": "Goodbye"}]}}}}
//
// Its `title` (who speaks, as a player reads it), its `start`, the openings in order (each
// an `if` and the node it goes to; the last has no `if`, so a conversation always opens),
// and its `nodes` in order, each a line (`text`) and 1 to 4 `replies`, each a `text`, maybe
// an `if` (conditions, all of which hold), a `do` (effects, in order) and a `go` (the node
// it goes on to; none: the conversation ends). One reply of every node has no `if`, takes
// nothing and costs nothing, so the player can always answer. A condition is one of
// {"quest": <id>} (under way), {"quest": <id>, "step": n} (under way on its step n, 1 its
// first), {"done": <id>}, {"have": <item>, "count": n}, {"found": <place kind>, "name": <its
// name>}, {"hurt": true} and {"level": n} (the player's level n or more); an effect one of {"give": <item>, "count": n}, {"take": <item>,
// "count": n}, {"cost": n}, {"pay": n}, {"talk": <name>} and {"game": <name>}. Dialogues are
// read after the quests, so every id they name is checked.

@(private)
DIALOGUE_FIELDS := []string{"title", "start", "nodes", "override"}
@(private = "file")
NODE_FIELDS := []string{"text", "replies"}
@(private = "file")
REPLY_FIELDS := []string{"text", "if", "do", "go"}
@(private = "file")
CONDITION_NAMES := []string{"quest", "done", "have", "found", "hurt", "level"}
@(private = "file")
EFFECT_NAMES := []string{"give", "take", "cost", "pay", "talk", "game"}

// read_dialogues: the dialogues (after the quests they may name).
@(private)
read_dialogues :: proc(b: ^Reg_Build, reg: ^Registry) {
	defs := b.defs[.Dialogue][:]
	if len(defs) > MAX_DIALOGUES {
		fail(
			b,
			-1,
			"",
			0,
			0,
			fmt.aprintf("%d dialogues; the limit is %d", len(defs), MAX_DIALOGUES),
		)
		return
	}
	for text, at in b.index[.Dialogue] {reg.ids[.Dialogue][text] = u32(at)}
	reg.dialogues = make([]Dialogue_Def, len(defs))
	for &m, i in defs {reg.dialogues[i] = read_dialogue(b, reg, &m)}
}

@(private = "file")
read_dialogue :: proc(b: ^Reg_Build, reg: ^Registry, m: ^Merged_Def) -> Dialogue_Def {
	d := Dialogue_Def {
		id = m.id,
	}
	if f := field_of(m, "title"); f == nil {
		fail(b, m.pack, m.file, m.line, m.column, "a dialogue has a \"title\"")
	} else {
		d.title = dialogue_string(b, f, f.value, "title", DIALOGUE_TITLE_MAX)
	}
	// The nodes' names first, so a reply may go on to a node further down.
	nodes := field_of(m, "nodes")
	if nodes == nil ||
	   nodes.value.kind != .Object ||
	   len(nodes.value.members) < 1 ||
	   len(nodes.value.members) > MAX_DIALOGUE_NODES {
		fail(
			b,
			m.pack,
			m.file,
			m.line,
			m.column,
			fmt.aprintf(
				"a dialogue has \"nodes\", an object of 1 to %d nodes by name",
				MAX_DIALOGUE_NODES,
			),
		)
		return d
	}
	names := make([]string, len(nodes.value.members))
	for e, i in nodes.value.members {names[i] = e.key}
	d.nodes = make([]Dialogue_Node, len(names))
	for e, i in nodes.value.members {d.nodes[i] = read_node(b, reg, nodes, e.key, e.value, names)}

	start := field_of(m, "start")
	if start == nil ||
	   start.value.kind != .Array ||
	   len(start.value.items) < 1 ||
	   len(start.value.items) > MAX_OPENINGS {
		fail(
			b,
			m.pack,
			m.file,
			m.line,
			m.column,
			fmt.aprintf(
				"a dialogue has a \"start\", a list of 1 to %d {\"if\": [...], \"go\": \"<node>\"}",
				MAX_OPENINGS,
			),
		)
		return d
	}
	openings := make([dynamic]Dialogue_Opening)
	for v, k in start.value.items {
		if v.kind != .Object {
			fail_field(b, start, v, "an opening is {\"if\": [...], \"go\": \"<node>\"}")
			continue
		}
		o := Dialogue_Opening {
			node = -1,
		}
		has_if := false
		for e in v.members {
			switch e.key {
			case "if":
				o.conditions = read_conditions(b, reg, start, e.value)
				has_if = true
			case "go":
				o.node = node_named(b, start, e.value, names)
			case:
				fail_field(
					b,
					start,
					e.value,
					fmt.aprintf(
						"\"%s\" is not an opening field%s",
						e.key,
						suggestion(e.key, []string{"if", "go"}),
					),
				)
			}
		}
		if o.node < 0 {
			fail_field(b, start, v, "an opening names the node it goes to: \"go\"")
			continue
		}
		if k == len(start.value.items) - 1 && has_if {
			fail_field(b, start, v, "the last opening has no \"if\": a conversation always opens")
		}
		append(&openings, o)
	}
	d.openings = openings[:]
	return d
}

@(private = "file")
read_node :: proc(
	b: ^Reg_Build,
	reg: ^Registry,
	f: ^Def_Field,
	name: string,
	v: Json_Value,
	names: []string,
) -> Dialogue_Node {
	n := Dialogue_Node {
		id = name,
	}
	if v.kind != .Object {
		fail_field(b, f, v, "a node is {\"text\": \"...\", \"replies\": [...]}")
		return n
	}
	replies: Json_Value
	for e in v.members {
		switch e.key {
		case "text":
			n.line = dialogue_string(b, f, e.value, "text", DIALOGUE_LINE_MAX)
		case "replies":
			replies = e.value
		case:
			fail_field(
				b,
				f,
				e.value,
				fmt.aprintf("\"%s\" is not a node field%s", e.key, suggestion(e.key, NODE_FIELDS)),
			)
		}
	}
	if n.line ==
	   "" {fail_field(b, f, v, fmt.aprintf("node \"%s\" says something: \"text\"", name))}
	if replies.kind != .Array || len(replies.items) < 1 || len(replies.items) > MAX_REPLIES {
		fail_field(
			b,
			f,
			v,
			fmt.aprintf("node \"%s\" has \"replies\", a list of 1 to %d", name, MAX_REPLIES),
		)
		return n
	}
	out := make([dynamic]Dialogue_Reply)
	free_way := false
	for rv in replies.items {
		r, ok := read_reply(b, reg, f, rv, names)
		if !ok {continue}
		append(&out, r)
		costs := false
		for e in r.effects {costs ||= e.kind == .Take || e.kind == .Cost}
		free_way ||= len(r.conditions) == 0 && !costs
	}
	n.replies = out[:]
	if !free_way && len(out) == len(replies.items) {
		fail_field(
			b,
			f,
			v,
			fmt.aprintf(
				"node \"%s\" has no reply that is always offered (no \"if\", nothing taken, nothing costed): the player could not answer",
				name,
			),
		)
	}
	return n
}

@(private = "file")
read_reply :: proc(
	b: ^Reg_Build,
	reg: ^Registry,
	f: ^Def_Field,
	v: Json_Value,
	names: []string,
) -> (
	r: Dialogue_Reply,
	ok: bool,
) {
	if v.kind != .Object {
		fail_field(
			b,
			f,
			v,
			"a reply is {\"text\": \"...\", \"if\": [...], \"do\": [...], \"go\": \"<node>\"}",
		)
		return
	}
	errors := len(b.errs)
	r.next = -1
	for e in v.members {
		switch e.key {
		case "text":
			r.text = dialogue_string(b, f, e.value, "text", REPLY_TEXT_MAX)
		case "if":
			r.conditions = read_conditions(b, reg, f, e.value)
		case "do":
			r.effects = read_effects(b, reg, f, e.value)
		case "go":
			r.next = node_named(b, f, e.value, names)
		case:
			fail_field(
				b,
				f,
				e.value,
				fmt.aprintf(
					"\"%s\" is not a reply field%s",
					e.key,
					suggestion(e.key, REPLY_FIELDS),
				),
			)
		}
	}
	if r.text == "" &&
	   len(b.errs) == errors {fail_field(b, f, v, "a reply says something: \"text\"")}
	return r, len(b.errs) == errors
}

// read_conditions: a list of conditions, each an object of one kind (CONDITION_NAMES).
@(private = "file")
read_conditions :: proc(
	b: ^Reg_Build,
	reg: ^Registry,
	f: ^Def_Field,
	v: Json_Value,
) -> []Dialogue_Condition {
	if v.kind != .Array || len(v.items) < 1 || len(v.items) > MAX_CONDITIONS {
		fail_field(b, f, v, fmt.aprintf("if is a list of 1 to %d conditions", MAX_CONDITIONS))
		return nil
	}
	out := make([dynamic]Dialogue_Condition)
	for cv in v.items {
		if cv.kind != .Object || len(cv.members) == 0 {
			fail_field(
				b,
				f,
				cv,
				"a condition is an object: {\"quest\": \"<id>\"}, {\"have\": \"<item>\"}...",
			)
			continue
		}
		c: Dialogue_Condition
		c.count = 1
		kind := -1
		for e in cv.members {
			switch e.key {
			case "quest", "done":
				kind = 0 if e.key == "quest" else 1
				if e.value.kind != .String {
					fail_field(b, f, e.value, fmt.aprintf("%s names a quest by id", e.key))
				} else if at, found := ref_index(b, .Quest, e.value.s, f, e.value); found {
					c.quest = at
				}
			case "have":
				kind = 2
				c.item = dialogue_item(b, reg, f, e.value)
			case "found":
				kind = 3
				c.place = Logbook_Place_Kind(choice_of(b, f, e.value, "found", PLACE_NAMES, 0))
			case "level":
				kind = 5
				c.count = dialogue_count(b, f, e.value, MAX_LEVEL)
			case "hurt":
				kind = 4
				if e.value.kind != .Bool || !e.value.b {fail_field(b, f, e.value, "hurt is true")}
			case "step":
				if e.value.kind != .Int || e.value.i < 1 || e.value.i > MAX_QUEST_STEPS {
					fail_field(b, f, e.value, fmt.aprintf("step is 1..%d", MAX_QUEST_STEPS))
				} else {
					c.step = int(e.value.i)
				}
			case "count":
				c.count = dialogue_count(b, f, e.value, MAX_QUEST_COUNT)
			case "name":
				c.name = dialogue_string(b, f, e.value, "name", PLACE_NAME_MAX)
			case:
				fail_field(
					b,
					f,
					e.value,
					fmt.aprintf(
						"\"%s\" is not a condition%s",
						e.key,
						suggestion(e.key, CONDITION_NAMES),
					),
				)
			}
		}
		// What each kind takes beside itself, and nothing else.
		extra := len(cv.members) - 1
		switch kind {
		case 0:
			c.kind = .Quest
			if c.step > 0 {
				c.kind = .Step
				c.step -= 1
				extra -= 1
				if len(reg.quests) > c.quest && c.step >= len(reg.quests[c.quest].steps) {
					fail_field(
						b,
						f,
						cv,
						fmt.aprintf("the quest has %d steps", len(reg.quests[c.quest].steps)),
					)
				}
			}
		case 1:
			c.kind = .Done
		case 2:
			c.kind = .Have
			if field_in(cv, "count") {extra -= 1}
		case 3:
			c.kind = .Found
			if field_in(cv, "name") {extra -= 1}
		case 4:
			c.kind = .Hurt
		case 5:
			c.kind = .Level
		case:
			fail_field(b, f, cv, "a condition is one of quest, done, have, found, hurt or level")
			continue
		}
		if extra != 0 {
			fail_field(
				b,
				f,
				cv,
				"a condition is one of quest (and step), done, have (and count), found (and name), hurt or level, alone",
			)
			continue
		}
		append(&out, c)
	}
	return out[:]
}

// read_effects: a list of effects, each an object of one kind (EFFECT_NAMES).
@(private = "file")
read_effects :: proc(
	b: ^Reg_Build,
	reg: ^Registry,
	f: ^Def_Field,
	v: Json_Value,
) -> []Dialogue_Effect {
	if v.kind != .Array || len(v.items) < 1 || len(v.items) > MAX_EFFECTS {
		fail_field(b, f, v, fmt.aprintf("do is a list of 1 to %d effects", MAX_EFFECTS))
		return nil
	}
	out := make([dynamic]Dialogue_Effect)
	for ev in v.items {
		if ev.kind != .Object || len(ev.members) == 0 {
			fail_field(
				b,
				f,
				ev,
				"an effect is an object: {\"give\": \"<item>\", \"count\": 1}, {\"talk\": \"<name>\"}...",
			)
			continue
		}
		e := Dialogue_Effect {
			count = 1,
		}
		kind := -1
		for m in ev.members {
			switch m.key {
			case "give", "take":
				kind = int(Effect_Kind.Give if m.key == "give" else Effect_Kind.Take)
				e.item = dialogue_item(b, reg, f, m.value)
			case "cost", "pay":
				kind = int(Effect_Kind.Cost if m.key == "cost" else Effect_Kind.Pay)
				e.count = dialogue_count(b, f, m.value, MAX_DIALOGUE_PRICE)
			case "talk", "game":
				kind = int(Effect_Kind.Talk if m.key == "talk" else Effect_Kind.Game)
				e.name = dialogue_string(b, f, m.value, m.key, DIALOGUE_NAME_MAX)
			case "count":
				e.count = dialogue_count(b, f, m.value, MAX_QUEST_COUNT)
			case:
				fail_field(
					b,
					f,
					m.value,
					fmt.aprintf(
						"\"%s\" is not an effect%s",
						m.key,
						suggestion(m.key, EFFECT_NAMES),
					),
				)
			}
		}
		if kind < 0 {
			fail_field(b, f, ev, "an effect is one of give, take, cost, pay, talk or game")
			continue
		}
		e.kind = Effect_Kind(kind)
		counted := e.kind == .Give || e.kind == .Take
		if len(ev.members) != (2 if counted && field_in(ev, "count") else 1) {
			fail_field(
				b,
				f,
				ev,
				"an effect is one of give or take (and count), cost, pay, talk or game, alone",
			)
			continue
		}
		append(&out, e)
	}
	return out[:]
}

@(private = "file")
field_in :: proc(v: Json_Value, key: string) -> bool {
	for m in v.members {if m.key == key {return true}}
	return false
}

@(private = "file")
node_named :: proc(b: ^Reg_Build, f: ^Def_Field, v: Json_Value, names: []string) -> int {
	if v.kind == .String {
		for n, i in names {if n == v.s {return i}}
	}
	got := v.s if v.kind == .String else "a non-string"
	fail_field(
		b,
		f,
		v,
		fmt.aprintf("go names a node of the dialogue, not %s%s", got, suggestion(got, names)),
	)
	return -1
}

@(private = "file")
dialogue_string :: proc(
	b: ^Reg_Build,
	f: ^Def_Field,
	v: Json_Value,
	name: string,
	most: int,
) -> string {
	if v.kind != .String || v.s == "" || len(v.s) > most {
		fail_field(b, f, v, fmt.aprintf("%s is 1 to %d bytes", name, most))
		return ""
	}
	return v.s
}

@(private = "file")
dialogue_count :: proc(b: ^Reg_Build, f: ^Def_Field, v: Json_Value, most: int) -> int {
	if v.kind != .Int || v.i < 1 || v.i > i64(most) {
		fail_field(b, f, v, fmt.aprintf("count is 1..%d", most))
		return 1
	}
	return int(v.i)
}

@(private = "file")
dialogue_item :: proc(b: ^Reg_Build, reg: ^Registry, f: ^Def_Field, v: Json_Value) -> Item {
	if v.kind != .String {
		fail_field(b, f, v, "an item is named by its id")
		return NO_ITEM
	}
	item, known := registry_item(reg, v.s)
	if !known {
		fail_field(b, f, v, fmt.aprintf("\"%s\" is not an item", v.s))
		return NO_ITEM
	}
	return item
}
