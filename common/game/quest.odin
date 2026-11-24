package game

// Quests (the Journal's Quests page, the HUD's tracker): a pack's chains of objectives
// (data/quests, registry_quests.odin), each quest a few steps done in order, each step a
// condition over what the server already knows of a player: what it carries, makes,
// places, breaks, finds (its logbook), kills, uses up, wins, says to someone, an address
// written on a gate, and the kind of world it stands on. A quest opens when the quests it comes after are done, and gives its reward when
// its last step is.
//
// What a character has done of them is its Quest_Log, kept with it (the server's player
// file) and sent to its player (the `quests` record). It changes only by these procs: an
// event noted (quest_note) and the conditions on what it holds (quest_settle), both pure,
// both told only of what happened, so nothing is looked at while nothing happens.

MAX_QUESTS :: 32 // quests a registry holds (a Quest_Log has a place for each)
MAX_QUEST_STEPS :: 8
MAX_QUEST_REWARDS :: 4
MAX_QUEST_AFTER :: 4 // quests one comes after
MAX_QUEST_COUNT :: 999 // the most a step asks for
QUEST_TITLE_MAX :: 48
QUEST_TEXT_MAX :: 240

// Goal: what a step asks of a player.
Goal :: enum u8 {
	Have, // carry `count` of an item (slots, what it wears, the cursor), at once
	Make, // make `count` of an item (a game's crafting: core.quest_note)
	Place, // place `count` blocks of a type
	Break, // break `count` blocks of a type
	Find, // a place of a kind (and of a name, when it names one) in its logbook
	Kill, // kill `count` creatures of a kind
	Use, // use up `count` of a consumable
	Win, // win a game's encounter, by its name (core.quest_note)
	Address, // write an address on a gate (whether or not it opens)
	Talk, // say something to someone, by its name (a game's conversation: core.quest_note)
	Visit, // stand on a world of a kind, by its name (Quest_World: "home", a world class's; none: any world but home)
}

// Objective: a step's condition; which of its fields count is its goal's.
Objective :: struct {
	goal:     Goal,
	item:     Item, // Have, Make, Use
	any_of:   i32, // Have: any items of the item tag of this index + 1, in place of the item (0: the item)
	block:    Block_Type, // Place, Break
	creature: Kind_Id, // Kill
	place:    Logbook_Place_Kind, // Find
	name:     string, // Find: the place's own name ("": any of its kind); Win: the encounter's; Talk: what was said; Visit: the world's kind ("": any but home)
	count:    int, // 1 ..= MAX_QUEST_COUNT
}

// Quest_Way: where a step's place is, for the compass and the map to point at: the nearest
// place of the player's logbook of this kind (and name), in the world it is in. A place
// the logbook does not have is not shown: a way reveals nothing.
Quest_Way :: struct {
	kind: Logbook_Place_Kind,
	name: string, // "": any place of the kind
}

Quest_Step :: struct {
	text:      string, // what to do, as the player reads it
	objective: Objective,
	way:       Maybe(Quest_Way),
}

// Quest_Def: a quest in the registry (registry_quests.odin).
Quest_Def :: struct {
	id:     string,
	title:  string,
	text:   string, // a line or two of why, in the world's voice
	steps:  []Quest_Step, // 1 ..= MAX_QUEST_STEPS
	reward: []Stack, // given when its last step is done
	xp:     u32, // the experience it gives then (its `xp`; skill.odin)
	after:  []int, // the quests (indices in the registry's) done before it opens
}

// Quest_Progress: how far a character is in a quest: the step it is on (len(steps): done)
// and how much of that step's count it has.
Quest_Progress :: struct {
	step:  u8,
	count: u16,
}

// Quest_Log: a character's progress in every quest of the registry, by its index there.
Quest_Log :: struct {
	quests: [MAX_QUESTS]Quest_Progress,
}

// Quest_Set: quests by their index.
Quest_Set :: bit_set[0 ..< MAX_QUESTS;u32]

// Quest_Event: something a player did that a step may count: its goal and what (as the
// Objective's fields), and how many.
Quest_Event :: struct {
	goal:     Goal,
	item:     Item,
	block:    Block, // a state: its type is what counts
	creature: Kind_Id,
	name:     string,
	count:    int,
}

// Quest_World: the world a player stands on as a Visit step names it: QUEST_HOME for the
// universe's home world, else its world class's name (worldgen.CLASS_NAMES, "none" for a
// world of no class); "" while it stands on none. common:game knows no world class: the
// server says the name (core's quest_world).
Quest_World :: string

QUEST_HOME :: "home"

// Quest_Changes: what an event or a settle moved: the steps done, and of them the quests
// finished (whose reward is due).
Quest_Changes :: struct {
	steps: int,
	done:  Quest_Set,
}

// quest_done: q's last step is done.
quest_done :: proc(reg: ^Registry, log: ^Quest_Log, q: int) -> bool {
	return int(log.quests[q].step) >= len(reg.quests[q].steps)
}

// quest_open: q is under way: every quest it comes after is done, and it is not.
quest_open :: proc(reg: ^Registry, log: ^Quest_Log, q: int) -> bool {
	if quest_done(reg, log, q) {return false}
	for a in reg.quests[q].after {if !quest_done(reg, log, a) {return false}}
	return true
}

// quest_step: the step q is on (nil when it is done).
quest_step :: proc(reg: ^Registry, log: ^Quest_Log, q: int) -> ^Quest_Step {
	if quest_done(reg, log, q) {return nil}
	return &reg.quests[q].steps[log.quests[q].step]
}

// quest_counts: whether an event counts for an objective (by its goal and what it names).
quest_counts :: proc(reg: ^Registry, o: ^Objective, e: Quest_Event) -> bool {
	if o.goal != e.goal {return false}
	switch o.goal {
	case .Have, .Make, .Use:
		return o.item == e.item
	case .Place, .Break:
		return block_type_of(&reg.blocks, e.block) == o.block
	case .Kill:
		return o.creature == e.creature
	case .Win, .Talk:
		return o.name == e.name
	case .Address:
		return true
	case .Find, .Visit:
		return false // (the logbook and the world stood on are states: quest_settle)
	}
	return false
}

// quest_holds: whether a step whose condition is a state (Have, Find, Visit) holds on what
// the player carries, its logbook and the world it stands on. False for the others: they
// are events.
quest_holds :: proc(
	reg: ^Registry,
	o: ^Objective,
	inv: ^Inventory,
	book: ^Logbook,
	world: Quest_World,
) -> bool {
	#partial switch o.goal {
	case .Have:
		return quest_carried(reg, o, inv) >= o.count
	case .Find:
		for &p in book.places[:book.place_count] {
			if p.kind == o.place && (o.name == "" || place_name(&p) == o.name) {return true}
		}
	case .Visit:
		if o.name == "" {return world != "" && world != QUEST_HOME}
		return world == o.name
	}
	return false
}

// quest_carried: how much of what a Have step asks the player carries (its item, or any
// items of its tag), as its journal and tracker count it.
quest_carried :: proc(reg: ^Registry, o: ^Objective, inv: ^Inventory) -> int {
	if o.any_of == 0 {return inventory_count(inv, o.item)}
	have := 0
	for m in reg.item_tags[o.any_of - 1].members {have += inventory_count(inv, Item(m))}
	return have
}

// quest_advance: q's step done: on to the next.
@(private = "file")
quest_advance :: proc(reg: ^Registry, log: ^Quest_Log, q: int, changes: ^Quest_Changes) {
	log.quests[q] = {log.quests[q].step + 1, 0}
	changes.steps += 1
	if quest_done(reg, log, q) {changes.done += {q}}
}

// quest_settle: every open quest whose step is a state that holds (it carries what it
// asks, its logbook has the place, it stands on the world) moves on, and on, as far as they
// hold: after an event, a change to what it carries or to its logbook, as it travels and as
// it joins.
quest_settle :: proc(
	reg: ^Registry,
	log: ^Quest_Log,
	inv: ^Inventory,
	book: ^Logbook,
	world: Quest_World,
) -> (
	changes: Quest_Changes,
) {
	for moved := true; moved; {
		moved = false
		for q in 0 ..< min(len(reg.quests), MAX_QUESTS) {
			if !quest_open(reg, log, q) {continue}
			o := &quest_step(reg, log, q).objective
			if !quest_holds(reg, o, inv, book, world) {continue}
			quest_advance(reg, log, q, &changes)
			moved = true // (it may open others, or its next step may hold too)
		}
	}
	return
}

// quest_note: a player did something: it counts for every open quest whose step it is,
// and what then holds moves on (quest_settle).
quest_note :: proc(
	reg: ^Registry,
	log: ^Quest_Log,
	e: Quest_Event,
	inv: ^Inventory,
	book: ^Logbook,
	world: Quest_World,
) -> (
	changes: Quest_Changes,
) {
	if e.count <= 0 {return}
	for q in 0 ..< min(len(reg.quests), MAX_QUESTS) {
		if !quest_open(reg, log, q) {continue}
		o := &quest_step(reg, log, q).objective
		if !quest_counts(reg, o, e) {continue}
		have := int(log.quests[q].count) + e.count
		if have >= o.count {
			quest_advance(reg, log, q, &changes)
		} else {
			log.quests[q].count = u16(have)
		}
	}
	settled := quest_settle(reg, log, inv, book, world)
	changes.steps += settled.steps
	changes.done += settled.done
	return
}

// quest_wants: whether an open quest's step has this goal (a cheap test before an event
// is made).
quest_wants :: proc(reg: ^Registry, log: ^Quest_Log, goal: Goal) -> bool {
	for q in 0 ..< min(len(reg.quests), MAX_QUESTS) {
		if !quest_open(reg, log, q) {continue}
		if quest_step(reg, log, q).objective.goal == goal {return true}
	}
	return false
}

// quest_log_valid: a log as the wire may carry it: no quest the registry lacks begun, no
// step past a quest's last, no count past its step's.
quest_log_valid :: proc(reg: ^Registry, log: ^Quest_Log) -> bool {
	for p, q in log.quests {
		if q >= len(reg.quests) {
			if p != {} {return false}
			continue
		}
		steps := reg.quests[q].steps
		if int(p.step) > len(steps) {return false}
		if int(p.step) < len(steps) && int(p.count) >= steps[p.step].objective.count {return false}
		if int(p.step) == len(steps) && p.count != 0 {return false}
	}
	return true
}

// quest_by_id: a quest's index in the registry.
quest_by_id :: proc(reg: ^Registry, id: string) -> (int, bool) {
	for q, i in reg.quests {if q.id == id {return i, true}}
	return 0, false
}
