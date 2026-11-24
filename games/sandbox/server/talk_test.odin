package sandbox_server

import "core:testing"

import "common:game"
import "games:sandbox"
import "server:core"
import "server:playtest"

// Conversations (talk.odin): a dialogue for every role, naming only the sandbox's actions; a
// conversation begun by using a person, moved on only by a reply the player is offered
// (anything else refused, and nothing of it done), its effects through the ledger and the
// purse, the camp's market opened from its trader and traded in, a place marked, and the
// camps' quests played through their people.

@(test)
test_talk_dialogues :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	kinds := FOLK_KINDS
	for name in kinds {
		_, found := game.dialogue_by_id(s.registry, name)
		testing.expectf(t, found, "no dialogue %s", name)
	}
	actions := TALK_ACTIONS
	for &d in s.registry.dialogues {
		for &n in d.nodes {
			for &r in n.replies {
				for e in r.effects {
					if e.kind != .Game {continue}
					known := false
					for a in actions {known ||= a == e.name}
					testing.expectf(t, known, "%s %s: no action %q", d.id, n.id, e.name)
				}
			}
		}
	}
}

// begin: c uses camp i's person in slot (its client's use), as the hook is told.
@(private = "file")
begin :: proc(t: ^testing.T, rig: ^Rig, i, slot: int) -> u32 {
	s := playtest.srv(rig)
	h := playtest.host(rig)
	p := camp_folk(s, i)[slot]
	core.teleport(s, h, core.entity_pos(s.home, p) + {0, 0, 2}, {0, 0})
	playtest.step(rig, 2)
	testing.expect_value(t, entity_use(s, h, p, {}), "")
	playtest.step(rig, 2)
	return core.entity_id(s.home, p)
}

// say: the host answers with reply i, as its client does.
@(private = "file")
say :: proc(rig: ^Rig, i: int) {
	v := sandbox.Say{u8(i)}
	core.harness_request(playtest.srv(rig), playtest.host(rig), &v)
	playtest.step(rig, 2)
}

@(private = "file")
shown :: proc(rig: ^Rig) -> sandbox.Talk {
	v := playtest.host_record(rig, sandbox.Talk)
	return v^ if v != nil else {}
}

// The server is the authority: a reply that is not there, or not offered (a condition that
// does not hold, a price the purse cannot meet), is refused and nothing of it is done.
@(test)
test_talk_authority :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	i := camp(t, rig)
	defer playtest.stop(rig)
	if i < 0 {return}
	s := playtest.srv(rig)
	h := playtest.host(rig)
	reg := s.registry
	id := begin(t, rig, i, 2) // (the medic)
	ts := talk_seat(s, h)
	testing.expect_value(t, ts.person, id)
	medic := &reg.dialogues[state(s).dialogues[.Medic]]
	testing.expect_value(t, ts.node, game.dialogue_opening(reg, medic, talk_facts(s, h)))
	v := shown(rig)
	testing.expect_value(t, v.person, id)
	testing.expect_value(t, v.camp, settlement_name(&settlements_of(s).list[i]))
	testing.expect_value(t, v.name, person_name(creature(s, s.home, camp_folk(s, i)[2]).folk.name))
	testing.expect(t, 0 not_in v.offered, "healing offered to one not hurt")

	// Not hurt: the healing refused, and paid for nothing.
	cash := trader(s, h).cash
	say(rig, 0)
	testing.expect(t, playtest.told(rig, "You cannot say that now"))
	testing.expect_value(t, trader(s, h).cash, cash)
	say(rig, 7) // (no such reply)
	testing.expect_value(t, trader(s, h).cash, cash)
	testing.expect_value(t, ts.person, id)

	// Hurt, it is offered; done, the health is whole and the purse 3 lighter.
	h.health = 5
	playtest.step(rig, TALK_EVERY)
	testing.expect(t, 0 in shown(rig).offered)
	say(rig, 0)
	testing.expect_value(t, h.health, h.max_health)
	testing.expect_value(t, trader(s, h).cash, cash - 3)

	// Too poor for a dressing: not offered, and a forged answer gives nothing.
	dressing := item_of(t, s, "sandbox:field_dressing")
	ts.node = 0
	trader(s, h).cash = 1
	playtest.step(rig, TALK_EVERY)
	testing.expect(t, 1 not_in shown(rig).offered)
	say(rig, 1)
	testing.expect_value(t, core.item_count(h, dressing), 0)
	testing.expect_value(t, trader(s, h).cash, 1)
	trader(s, h).cash = 5
	say(rig, 1)
	testing.expect_value(t, core.item_count(h, dressing), 1) // (through the ledger)
	testing.expect_value(t, trader(s, h).cash, 3)

	// Leaving ends it; so does walking off.
	say(rig, int(sandbox.TALK_LEAVE))
	testing.expect_value(t, ts.person, 0)
	testing.expect_value(t, shown(rig).person, 0)
	begin(t, rig, i, 2)
	testing.expect(t, ts.person != 0)
	core.teleport(
		s,
		h,
		core.entity_pos(s.home, camp_folk(s, i)[2]) + {0, 0, TALK_RANGE + 4},
		{0, 0},
	)
	playtest.step(rig, 4)
	testing.expect_value(t, ts.person, 0)
	// Talking to one who is not of the camps' people is none of this.
	loper, _ := game.registry_kind(reg, "sandbox:loper")
	other := core.entity_spawn(s.home, loper, h.player.position + {1, 0, 0}, false)
	_, ours := talk_begin(s, h, other)
	testing.expect(t, !ours)
}

// The trader's first reply opens the camp's market, traded in as a town's is while the
// player stands in the camp, and closed when it walks out.
@(test)
test_talk_trader_market :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	i := camp(t, rig)
	defer playtest.stop(rig)
	if i < 0 {return}
	s := playtest.srv(rig)
	h := playtest.host(rig)
	st := &settlements_of(s).list[i]
	begin(t, rig, i, 1)
	say(rig, 0)
	testing.expect_value(t, talk_seat(s, h).person, 0)
	m := playtest.host_record(rig, sandbox.Town_Market)
	if !testing.expect(t, m != nil) {return}
	testing.expect_value(t, m.town, settlement_name(st))
	good := sandbox.Good(0)
	for g in sandbox.Good {if settlements_of(s).markets[i].deals[g] {good = g}}
	cash := trader(s, h).cash
	buy := sandbox.Trade{good, false, 1}
	core.harness_request(s, h, &buy)
	playtest.step(rig, 2)
	testing.expect(t, trader(s, h).cash < cash)
	testing.expect_value(t, trader(s, h).cargo[int(good)], 1)
	testing.expect_value(t, playtest.host_record(rig, sandbox.Town_Market).goods[good].cargo, 1)
	sell := sandbox.Trade{good, true, 5}
	core.harness_request(s, h, &sell)
	playtest.step(rig, 2)
	testing.expect_value(t, trader(s, h).cargo[int(good)], 1) // (refused: it carries one)
	core.teleport(s, h, settlement_middle(st) + {0, 0, 40}, {0, 0})
	playtest.step(rig, playtest.ticks(1.5))
	testing.expect_value(t, playtest.host_record(rig, sandbox.Town_Market).town, "")
}

// A scout sells where the ruin and the camps are: marked in the logbook, and refused (and
// not paid) once known.
@(test)
test_talk_scout_marks :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	i := camp(t, rig, "hamlet", "2")
	defer playtest.stop(rig)
	if i < 0 {return}
	s := playtest.srv(rig)
	h := playtest.host(rig)
	trader(s, h).cash = 30
	begin(t, rig, i, 2) // (the scout)
	say(rig, 1)
	testing.expect_value(t, trader(s, h).cash, 22)
	has :: proc(c: ^core.Client, kind: game.Logbook_Place_Kind) -> int {
		n := 0
		for &p in c.logbook.places[:c.logbook.place_count] {if p.kind == kind {n += 1}}
		return n
	}
	testing.expect_value(t, has(h, .Ruin), 1)
	say(rig, 1)
	testing.expect(t, playtest.told(rig, "You know the way to the ruin already"))
	testing.expect_value(t, trader(s, h).cash, 22)
	before := has(h, .Settlement)
	say(rig, 2)
	testing.expect_value(t, has(h, .Settlement), before + 1)
	testing.expect_value(t, trader(s, h).cash, 18)
}

// The camps' quests through their people: the first hour leads to the nearest camp's elder
// (its beacon heard the call: the camp in the logbook); the medic's hides fetched and handed
// in; the medic's gel carried to the mechanic of another camp.
@(test)
test_talk_quests_played :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	i := camp(t, rig)
	defer playtest.stop(rig)
	if i < 0 {return}
	s := playtest.srv(rig)
	h := playtest.host(rig)
	reg := s.registry
	smoke := quest_of(t, s, LEAD_QUEST)
	for &p, q in h.quests.quests[:smoke] {p.step = u8(len(reg.quests[q].steps))} 	// (the first hour's before it)
	testing.expect(t, game.quest_open(reg, &h.quests, smoke))
	// Away from every camp, knowing none: the nearest planned is put in the logbook.
	core.teleport(s, h, settlement_middle(&settlements_of(s).list[i]) + {0, 0, 60}, {0, 0}, true)
	h.logbook = {}
	playtest.step(rig, SETTLEMENT_EVERY * 2)
	testing.expect(t, playtest.told(rig, "Your beacon picks up a call"))
	lead := false
	for &p in h.logbook.places[:h.logbook.place_count] {
		lead ||=
			p.kind == .Settlement &&
			game.place_name(&p) == settlement_name(&settlements_of(s).list[0])
	}
	testing.expect(t, lead, "the nearest camp is not in the logbook")
	ration := item_of(t, s, "sandbox:trail_ration")
	begin(t, rig, i, 0) // (the elder)
	testing.expect(
		t,
		game.quest_done(reg, &h.quests, smoke),
		"speaking with the elder did not do it",
	)
	testing.expect_value(t, core.item_count(h, ration), 2)
	elder := &reg.dialogues[state(s).dialogues[.Elder]]
	testing.expect_value(t, elder.nodes[talk_seat(s, h).node].id, "welcome")
	say(rig, int(sandbox.TALK_LEAVE))

	// The hides: asked for, carried, handed in.
	hides := quest_of(t, s, "sandbox:hides_for_the_healer")
	testing.expect(t, game.quest_open(reg, &h.quests, hides))
	begin(t, rig, i, 2)
	say(rig, 2) // (help)
	say(rig, 0) // (hides)
	testing.expect_value(t, h.quests.quests[hides].step, 1)
	hide := item_of(t, s, "sandbox:hide")
	core.item_give(s, h, hide, 4)
	playtest.step(rig, 2)
	testing.expect_value(t, h.quests.quests[hides].step, 2)
	say(rig, int(sandbox.TALK_LEAVE))
	begin(t, rig, i, 2)
	medic := &reg.dialogues[state(s).dialogues[.Medic]]
	testing.expect_value(t, medic.nodes[talk_seat(s, h).node].id, "hides_back")
	cash := trader(s, h).cash
	say(rig, 0)
	testing.expect(t, game.quest_done(reg, &h.quests, hides))
	testing.expect_value(t, core.item_count(h, hide), 0)
	testing.expect_value(t, core.item_count(h, item_of(t, s, "sandbox:med_gel")), 2) // (its reward)
	testing.expect_value(t, trader(s, h).cash, cash + 6)

	// The gel: taken from the medic, the mechanic's camp marked, handed to the mechanic.
	run := quest_of(t, s, "sandbox:medicine_run")
	gel := item_of(t, s, "sandbox:med_gel")
	core.item_clear(s, h, gel)
	say(rig, int(sandbox.TALK_LEAVE))
	begin(t, rig, i, 2)
	say(rig, 2)
	say(rig, 1)
	testing.expect_value(t, h.quests.quests[run].step, 1)
	testing.expect_value(t, core.item_count(h, gel), 2)
	say(rig, int(sandbox.TALK_LEAVE))
	core.teleport(s, h, {60.5, 40, 0.5}, {0, 0}, true)
	playtest.step(rig, 4)
	playtest.say(rig, "settlement yard 2")
	j := settlements_of(s).count - 1
	for p in camp_folk(s, j) {if p != 0 {creature(s, s.home, p).still = false}}
	begin(t, rig, j, 0) // (the mechanic)
	mechanic := &reg.dialogues[state(s).dialogues[.Mechanic]]
	testing.expect_value(t, mechanic.nodes[talk_seat(s, h).node].id, "delivery")
	say(rig, 0)
	testing.expect(t, game.quest_done(reg, &h.quests, run))
	testing.expect_value(t, core.item_count(h, gel), 0)
	testing.expect_value(t, core.item_count(h, item_of(t, s, "sandbox:copper_ingot")), 3)
}
