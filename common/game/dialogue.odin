package game

// Dialogues (a game's conversations: the sandbox's folk): a pack's small graphs of what a
// person says and what a player may answer (data/dialogues, registry_dialogues.odin). A
// dialogue opens on the first of its openings whose conditions hold; each node is a line
// the person says and up to MAX_REPLIES replies, each offered while its conditions hold
// (a quest under way or on a step, a quest done, what the player carries, a place in its
// logbook, being hurt, a level reached) and what it takes is there (the items, the money); a reply chosen
// does its effects in order (items given and taken, money paid either way, something said
// that a quest's talk step counts, an action of the game's own by name) and goes on to
// its next node or ends the conversation.
//
// Everything here is pure: what is offered and what a reply does are functions of the
// dialogue and of the facts the server hands them (Dialogue_Facts). The server is the
// authority: it asks dialogue_answer whether the reply a player sent is one it is offered
// before doing anything; the client only shows the lines.

MAX_DIALOGUES :: 32 // dialogues a registry holds
MAX_DIALOGUE_NODES :: 32 // nodes of one dialogue
MAX_REPLIES :: 4 // replies of a node
MAX_OPENINGS :: 8 // openings of a dialogue
MAX_CONDITIONS :: 4 // conditions of an opening or a reply
MAX_EFFECTS :: 4 // effects of a reply
DIALOGUE_TITLE_MAX :: 32
DIALOGUE_LINE_MAX :: 320 // a node's line
REPLY_TEXT_MAX :: 80
DIALOGUE_NAME_MAX :: 32 // what a talk effect says, the name of a game's action
MAX_DIALOGUE_PRICE :: 9999 // the most a cost or a pay names

// Condition_Kind: what a condition asks of the player.
Condition_Kind :: enum u8 {
	Quest, // the quest is under way (open, not done)
	Step, // ... and on its step `step` (0: its first)
	Done, // the quest is done
	Have, // it carries `count` of the item
	Found, // its logbook has a place of the kind (and of the name, when one is given)
	Hurt, // its health is below its most
	Level, // its level is `count` or more (game.level_of its experience)
}

Dialogue_Condition :: struct {
	kind:  Condition_Kind,
	quest: int, // Quest, Step, Done: an index in the registry's quests
	step:  int, // Step
	item:  Item, // Have
	count: int, // Have; Level: the level
	place: Logbook_Place_Kind, // Found
	name:  string, // Found ("": any place of the kind)
}

// Effect_Kind: what a reply chosen does, in its order.
Effect_Kind :: enum u8 {
	Give, // `count` of the item into the player's slots (through the item ledger)
	Take, // `count` of the item out of them (offered only while it carries them)
	Cost, // `count` of the game's money from the player (offered only while it has it)
	Pay, // `count` of the game's money to the player
	Talk, // the player said `name`: a quest's talk step of that name counts it
	Game, // the game's own action `name` (open a market, heal, mark a place): the game's to do
}

Dialogue_Effect :: struct {
	kind:  Effect_Kind,
	item:  Item, // Give, Take
	count: int, // Give, Take, Cost, Pay
	name:  string, // Talk, Game
}

Dialogue_Reply :: struct {
	text:       string,
	conditions: []Dialogue_Condition,
	effects:    []Dialogue_Effect,
	next:       int, // the node it goes on to (an index in the dialogue's nodes); -1: it ends
}

Dialogue_Node :: struct {
	id:      string, // its name in its file
	line:    string, // what the person says
	replies: []Dialogue_Reply, // 1 ..= MAX_REPLIES, one always offered
}

Dialogue_Opening :: struct {
	conditions: []Dialogue_Condition,
	node:       int,
}

// Dialogue_Def: a dialogue in the registry: who speaks, as a player reads it where the game
// gives no name of its own, its openings (the last holds always) and its nodes.
Dialogue_Def :: struct {
	id:       string,
	title:    string,
	openings: []Dialogue_Opening,
	nodes:    []Dialogue_Node,
}

// Dialogue_Facts: what the conditions are asked of: the player's quests, slots and
// logbook, the game's money it has, whether it is hurt and its level (the server's, as it
// stands).
Dialogue_Facts :: struct {
	quests:    ^Quest_Log,
	inventory: ^Inventory,
	logbook:   ^Logbook,
	purse:     int,
	hurt:      bool,
	level:     int,
}

// Reply_Set: replies of a node by their index.
Reply_Set :: bit_set[0 ..< MAX_REPLIES;u8]

// dialogue_by_id: a dialogue's index in the registry.
dialogue_by_id :: proc(reg: ^Registry, id: string) -> (int, bool) {
	for d, i in reg.dialogues {if d.id == id {return i, true}}
	return 0, false
}

// dialogue_holds: every condition holds on the facts.
dialogue_holds :: proc(
	reg: ^Registry,
	conditions: []Dialogue_Condition,
	facts: Dialogue_Facts,
) -> bool {
	for &c in conditions {
		switch c.kind {
		case .Quest:
			if !quest_open(reg, facts.quests, c.quest) {return false}
		case .Step:
			if !quest_open(reg, facts.quests, c.quest) ||
			   int(facts.quests.quests[c.quest].step) != c.step {return false}
		case .Done:
			if !quest_done(reg, facts.quests, c.quest) {return false}
		case .Have:
			if inventory_count(facts.inventory, c.item) < c.count {return false}
		case .Found:
			found := false
			for &p in facts.logbook.places[:facts.logbook.place_count] {
				found ||= p.kind == c.place && (c.name == "" || place_name(&p) == c.name)
			}
			if !found {return false}
		case .Hurt:
			if !facts.hurt {return false}
		case .Level:
			if facts.level < c.count {return false}
		}
	}
	return true
}

// dialogue_opening: the node a conversation opens on: the first opening whose conditions
// hold (the last always does).
dialogue_opening :: proc(reg: ^Registry, d: ^Dialogue_Def, facts: Dialogue_Facts) -> int {
	for &o in d.openings {if dialogue_holds(reg, o.conditions, facts) {return o.node}}
	return d.openings[len(d.openings) - 1].node
}

// reply_offered: a reply's conditions hold, the player carries what it takes and has the
// money it costs.
@(private = "file")
reply_offered :: proc(reg: ^Registry, r: ^Dialogue_Reply, facts: Dialogue_Facts) -> bool {
	if !dialogue_holds(reg, r.conditions, facts) {return false}
	cost := 0
	for e in r.effects {
		#partial switch e.kind {
		case .Take:
			if inventory_count(facts.inventory, e.item) < e.count {return false}
		case .Cost:
			cost += e.count
		}
	}
	return cost <= facts.purse
}

// dialogue_offered: the replies of node the player is offered now.
dialogue_offered :: proc(
	reg: ^Registry,
	d: ^Dialogue_Def,
	node: int,
	facts: Dialogue_Facts,
) -> (
	offered: Reply_Set,
) {
	if node < 0 || node >= len(d.nodes) {return}
	for &r, i in d.nodes[node].replies {if reply_offered(reg, &r, facts) {offered += {i}}}
	return
}

// dialogue_answer: the reply the player chose at node, when it is one it is offered now
// (anything else, a reply that is not there or not offered, is refused: false).
dialogue_answer :: proc(
	reg: ^Registry,
	d: ^Dialogue_Def,
	node, reply: int,
	facts: Dialogue_Facts,
) -> (
	^Dialogue_Reply,
	bool,
) {
	if reply < 0 || reply >= MAX_REPLIES {return nil, false}
	if reply not_in dialogue_offered(reg, d, node, facts) {return nil, false}
	return &d.nodes[node].replies[reply], true
}
