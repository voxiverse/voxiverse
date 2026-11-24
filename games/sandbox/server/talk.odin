package sandbox_server

import "core:fmt"
import "core:math"

import "common:base"
import "common:game"
import "games:sandbox"
import "server:core"
import "server:play"

// Conversations with the camps' people (folk.odin), as their pack's dialogues say
// (pack/data/dialogues: one a role, sandbox:<role>; the engine's game.Dialogue_Def). Using
// a person (the right button) begins one: the dialogue opens on its first opening that holds
// for the player, and beginning notes the dialogue's id as said (a quest's talk step of that
// name counts it). The player is put its sandbox.Talk; its client part shows the line and
// the replies offered, and sends a sandbox.Say with the one chosen. The server is the
// authority: a reply is done only when game.dialogue_answer says the player is offered it
// now, and a reply whose action of the game's cannot be done (talk_can) is refused with why
// before anything of it is done. A reply's effects are done in order: items given and taken
// through the item ledger, silver (the trader's purse, trader.odin) paid either way,
// something said noted for the quests, and the sandbox's own actions (talk_do): the camp's
// market opened, the player healed, a place marked in its logbook (the nearest remains, the
// ruin or a camp it has not found; the mechanic's camp, for an errand there). A conversation ends with
// a reply that goes nowhere, when the player leaves it, walks off (TALK_RANGE), dies or the
// person is gone.
//
// Each camp's trader keeps a market of its own (Camp_Market): some of the goods, each at a
// price and a stock of the camp's seed, which trades move as a town's do; it is shown and
// traded through the towns' market (trader.odin's sandbox.Town_Market and sandbox.Trade)
// while the player stands in the camp, and is not saved (a session opens with it stocked).

TALK_RANGE :: 6 // blocks from the person within which a conversation goes on
TALK_EVERY :: 10 // ticks between two looks at what a talking player is offered
CAMP_GOODS :: 5 // goods a camp's trader deals in
CAMP_STEP :: 0.03 // a unit traded moves a camp's price by this share

// Talk_Seat: the conversation a player is in (person 0: none), and the camp whose market it
// opened (its number + 1; 0: none).
Talk_Seat :: struct {
	person:   u32,
	dialogue: int,
	node:     int,
	camp:     int,
	market:   int,
}

talk_seat :: proc(s: ^core.Server, c: ^core.Client) -> ^Talk_Seat {return &ruin_seat(s, c).talk}

// talk_start: the dialogue of each role, from the session's registry (the game's start).
talk_start :: proc(s: ^core.Server) -> bool {
	g := state(s)
	names := FOLK_KINDS
	for name, role in names {g.dialogues[role] = game.dialogue_by_id(s.registry, name) or_return}
	return true
}

// talk_facts: what a dialogue's conditions ask of c.
talk_facts :: proc(s: ^core.Server, c: ^core.Client) -> game.Dialogue_Facts {
	return {
		quests = &c.quests,
		inventory = &c.inventory,
		logbook = &c.logbook,
		purse = int(math.floor(trader(s, c).cash)),
		hurt = !c.dead && c.health < c.max_health,
		level = game.level_of(s.registry, c.stats["xp"] or_else 0),
	}
}

// talker: the player talking with person h (nil: none).
talker :: proc(s: ^core.Server, w: ^core.World, h: game.Entity_Handle) -> ^core.Client {
	id := core.entity_id(w, h)
	for &c in s.clients {
		if c.state == .Playing && c.world == w && talk_seat(s, &c).person == id {return &c}
	}
	return nil
}

// talk_begin: c used person h (the entity_use hook): a conversation begins, unless h is not
// one of the camps' people ("": nothing to say, the hook goes on).
talk_begin :: proc(
	s: ^core.Server,
	c: ^core.Client,
	h: game.Entity_Handle,
) -> (
	refusal: string,
	ours: bool,
) {
	w := c.world
	d, st := person(s, w, h)
	if d == nil {return "", false}
	role, _ := folk_of(s, core.entity_kind(w, h))
	if o := talker(s, w, h); o != nil && o != c {
		return fmt.tprintf("%s is talking with %s", person_name(d.folk.name), core.client_name(o)),
			true
	}
	ts := talk_seat(s, c)
	at := state(s).dialogues[role]
	dlg := &s.registry.dialogues[at]
	ts^ = {
		person   = core.entity_id(w, h),
		dialogue = at,
		node     = game.dialogue_opening(s.registry, dlg, talk_facts(s, c)),
		camp     = int(d.folk.camp) - 1,
		market   = ts.market,
	}
	_ = st
	core.quest_note(s, c, {goal = .Talk, name = dlg.id, count = 1})
	talk_put(s, c)
	return "", true
}

// talk_put: what c is shown of its conversation (none when it is in none).
talk_put :: proc(s: ^core.Server, c: ^core.Client) {
	ts := talk_seat(s, c)
	v: sandbox.Talk
	if ts.person != 0 {
		if h, found := core.entity_find(c.world, ts.person); found {
			d, st := person(s, c.world, h)
			if d != nil {
				dlg := &s.registry.dialogues[ts.dialogue]
				v = {
					person   = ts.person,
					name     = person_name(d.folk.name),
					camp     = settlement_name(st),
					dialogue = u8(ts.dialogue),
					node     = u8(ts.node),
					offered  = game.dialogue_offered(s.registry, dlg, ts.node, talk_facts(s, c)),
				}
			}
		}
	}
	core.game_put(s, c, &v)
}

// talk_end: c's conversation is over.
talk_end :: proc(s: ^core.Server, c: ^core.Client) {
	ts := talk_seat(s, c)
	if ts.person == 0 {return}
	ts.person = 0
	talk_put(s, c)
}

// talk_say: c answered (its sandbox.Say): the reply done when it is one c is offered, its
// effects in order, then on to its node or the end. Anything else is refused, and nothing
// of it is done.
talk_say :: proc(s: ^core.Server, c: ^core.Client, say: sandbox.Say) {
	ts := talk_seat(s, c)
	if ts.person == 0 {return}
	if say.reply == sandbox.TALK_LEAVE || !talk_near(s, c) {
		talk_end(s, c)
		return
	}
	dlg := &s.registry.dialogues[ts.dialogue]
	r, offered := game.dialogue_answer(s.registry, dlg, ts.node, int(say.reply), talk_facts(s, c))
	if !offered {
		core.notice(s, c, "You cannot say that now")
		talk_put(s, c)
		return
	}
	for e in r.effects {
		if e.kind != .Game {continue}
		if why := talk_can(s, c, e.name); why != "" {
			core.notice(s, c, why)
			talk_put(s, c)
			return
		}
	}
	rec := trader(s, c)
	for e in r.effects {
		switch e.kind {
		case .Give:
			if given := core.item_give(s, c, e.item, e.count); given < e.count {
				core.item_drop(s, c.world, c.player.position, {e.item, e.count - given, 0, 0})
			}
		case .Take:
			core.item_take(s, c, e.item, e.count)
		case .Cost:
			rec.cash -= f64(e.count)
		case .Pay:
			rec.cash += f64(e.count)
			core.notice(s, c, fmt.tprintf("+%d silver", e.count))
		case .Talk:
			core.quest_note(s, c, {goal = .Talk, name = e.name, count = 1})
		case .Game:
			talk_do(s, c, e.name)
		}
	}
	if ts.person == 0 {return} 	// (an action ended it: the market opened)
	if r.next < 0 {
		talk_end(s, c)
		return
	}
	ts.node = r.next
	talk_put(s, c)
}

// talk_near: c can still talk with the person it talks with: alive, both in the world, the
// person within TALK_RANGE.
talk_near :: proc(s: ^core.Server, c: ^core.Client) -> bool {
	ts := talk_seat(s, c)
	if c.dead || c.state != .Playing {return false}
	h, found := core.entity_find(c.world, ts.person)
	if !found {return false}
	return play.distance_to(core.entity_pos(c.world, h), c.player.position) <= TALK_RANGE
}

// talk_tick: each talking player's conversation ended when it can no longer go on, and what
// it is offered looked at again (what it carries, its purse, its quests change).
talk_tick :: proc(s: ^core.Server) {
	for &c in s.clients {
		if c.state != .Playing {continue}
		ts := talk_seat(s, &c)
		if ts.market != 0 && c.world.params.planet == 0 && s.tick % game.TICK_RATE == 0 {
			market_update(s, &c) // (the towns' look does it on the planet: economy_tick)
		}
		if ts.person == 0 {continue}
		if !talk_near(s, &c) {
			talk_end(s, &c)
		} else if (s.tick + u64(core.player_id(s, &c))) % TALK_EVERY == 0 {
			talk_put(s, &c)
		}
	}
}

// TALK_ACTIONS: the sandbox's actions a dialogue's `game` effect may name.
TALK_ACTIONS :: [?]string {
	"market",
	"heal",
	"mark_remains",
	"mark_ruin",
	"mark_settlement",
	"mark_mechanic",
	"mark_delve",
}

// talk_can: why the game's action cannot be done for c now ("": it can).
talk_can :: proc(s: ^core.Server, c: ^core.Client, action: string) -> string {
	switch action {
	case "market":
		if talk_seat(s, c).camp < 0 {return "There is nothing to trade here"}
	case "heal":
		if c.health >= c.max_health {return "You are not hurt"}
	case "mark_remains":
		if _, found := unknown_remains(s, c);
		   !found {return "There are no remains I know of that you have not seen"}
	case "mark_ruin":
		if !ruin_of(s).placed || c.world != s.home {return "I know of no ruin here"}
		for &p in c.logbook.places[:c.logbook.place_count] {
			if p.kind == .Ruin {return "You know the way to the ruin already"}
		}
	case "mark_settlement":
		if _, found := unknown_settlement(s, c); !found {return "You know every camp I know"}
	case "mark_mechanic":
	case "mark_delve":
		if _, found := unknown_delve(s, c);
		   !found {return "I know of no sunken stair you have not seen"}
	case:
		return fmt.tprintf("Nobody here can %s", action)
	}
	return ""
}

// talk_do: the game's action for c (talk_can said it can).
talk_do :: proc(s: ^core.Server, c: ^core.Client, action: string) {
	switch action {
	case "market":
		ts := talk_seat(s, c)
		ts.market = ts.camp + 1
		talk_end(s, c)
		market_ask(s, c)
	case "heal":
		core.heal_player(c, c.max_health)
		core.notice(s, c, "Your wounds are dressed")
	case "mark_remains":
		site, _ := unknown_remains(s, c)
		at := [3]i32{site.middle.x, site.floor + 1, site.middle.y}
		core.logbook_place(s, c, .Remains, at, REMAIN_NAMES[site.kind])
		talk_marked(s, c, REMAIN_NAMES[site.kind], at)
	case "mark_ruin":
		at := ruin_altar(ruin_of(s).site)
		core.logbook_place(s, c, .Ruin, {at.x, at.y, at.z})
		talk_marked(s, c, "The ruin", {at.x, at.y, at.z})
	case "mark_settlement":
		st, _ := unknown_settlement(s, c)
		core.logbook_place(s, c, .Settlement, settlement_place(st), settlement_name(st))
		talk_marked(s, c, settlement_name(st), settlement_place(st))
	case "mark_mechanic":
		// (the camp whose people have the mechanic: CAMP_ROLES' second; known or not)
		ss := settlements_of(s)
		if c.world != s.home || ss.count < 2 {return}
		st := &ss.list[1]
		core.logbook_place(s, c, .Settlement, settlement_place(st), settlement_name(st))
	case "mark_delve":
		d, _ := unknown_delve(s, c)
		at := [3]i32{d.site.middle.x, d.site.floor + 1, d.site.middle.y}
		core.logbook_place(s, c, .Remains, at, DELVE_STAIR)
		talk_marked(s, c, DELVE_STAIR, at)
	}
}

@(private = "file")
talk_marked :: proc(s: ^core.Server, c: ^core.Client, name: string, at: [3]i32) {
	d := [3]f64{f64(at.x), f64(at.y), f64(at.z)} - c.player.position
	core.notice(
		s,
		c,
		fmt.tprintf(
			"%s marked in your journal: %.0f blocks %s",
			name,
			math.sqrt(d.x * d.x + d.z * d.z),
			compass_word(d),
		),
	)
}

// logbook_has: c's logbook has a place of kind within game.PLACE_SAME blocks of at (in its
// world).
@(private = "file")
logbook_has :: proc(c: ^core.Client, kind: game.Logbook_Place_Kind, at: [3]i32) -> bool {
	for &p in c.logbook.places[:c.logbook.place_count] {
		d := p.at - at
		if p.kind == kind &&
		   p.world == c.world.address &&
		   d.x * d.x + d.z * d.z <= game.PLACE_SAME * game.PLACE_SAME {return true}
	}
	return false
}

// unknown_remains: the scattered remains site nearest c (not the court, not the road) its
// logbook lacks.
unknown_remains :: proc(s: ^core.Server, c: ^core.Client) -> (site: Remain, found: bool) {
	if c.world != s.home {return}
	rm := &world_of(s.home).remains
	best := max(f64)
	for r in rm.sites[:rm.count] {
		if r.kind == .Court || r.kind == .Road {continue}
		at := [3]i32{r.middle.x, r.floor + 1, r.middle.y}
		if logbook_has(c, .Remains, at) {continue}
		if d := play.distance_to({f64(at.x), 0, f64(at.z)}, c.player.position); d < best {
			best, site, found = d, r, true
		}
	}
	return
}

// unknown_settlement: the camp nearest c its logbook lacks.
unknown_settlement :: proc(s: ^core.Server, c: ^core.Client) -> (^Settlement, bool) {
	if c.world != s.home {return nil, false}
	ss := settlements_of(s)
	best, found := max(f64), -1
	for i in 0 ..< ss.count {
		st := &ss.list[i]
		if logbook_has(c, .Settlement, settlement_place(st)) {continue}
		if d := play.distance_to(settlement_middle(st), c.player.position);
		   d < best {best, found = d, i}
	}
	if found < 0 {return nil, false}
	return &ss.list[found], true
}

// ---- a camp's market ----

// Camp_Market: what a camp's trader deals in, at what price (silver a unit) and with how
// many units in stock.
Camp_Market :: struct {
	deals: [sandbox.Good]bool,
	price: [sandbox.Good]f32,
	stock: [sandbox.Good]f32,
}

// market_stock: a camp's market as a session opens it, from the camp's seed: CAMP_GOODS of
// the goods, each priced within a quarter of its base price and 6 to 20 units in stock.
market_stock :: proc(m: ^Camp_Market, seed: u64) {
	m^ = {}
	r := base.rng_make(seed ~ 0x3a7c_e7a1)
	goods: [len(sandbox.Good)]sandbox.Good
	for &g, i in goods {g = sandbox.Good(i)}
	for i := len(goods) - 1; i > 0; i -= 1 {
		j := base.rng_int_max(&r, i + 1)
		goods[i], goods[j] = goods[j], goods[i]
	}
	base_price := sandbox.BASE_PRICE
	for g in goods[:CAMP_GOODS] {
		m.deals[g] = true
		m.price[g] = base_price[g] * f32(0.75 + 0.5 * base.rng_f64(&r))
		m.stock[g] = f32(base.rng_int_range(&r, 6, 21))
	}
}

// camp_market_here: the camp whose market c opened, while it stands in it (-1: none; one it
// walked out of is closed).
camp_market_here :: proc(s: ^core.Server, c: ^core.Client) -> int {
	ts := talk_seat(s, c)
	if ts.market == 0 {return -1}
	i := ts.market - 1
	if settlement_at(s, c.world, c.player.position) != i {
		ts.market = 0
		return -1
	}
	return i
}

// camp_market_view: what c sees of camp i's market.
camp_market_view :: proc(s: ^core.Server, c: ^core.Client, i: int) -> sandbox.Town_Market {
	ss := settlements_of(s)
	m := &ss.markets[i]
	rec := trader(s, c)
	v := sandbox.Town_Market {
		town = settlement_name(&ss.list[i]),
		cash = rec.cash,
	}
	for g in sandbox.Good {
		e := &v.goods[g]
		e.age = 0 // (seen here, now)
		e.cargo = rec.cargo[int(g)]
		if !m.deals[g] {
			e.age = -1
			continue
		}
		e.deals, e.price, e.stock = true, m.price[g], m.stock[g]
	}
	return v
}

// camp_trade: c buys or sells quantity units of a good at camp i's market: whole or refused.
camp_trade :: proc(s: ^core.Server, c: ^core.Client, i: int, t: sandbox.Trade) -> sandbox.Refusal {
	m := &settlements_of(s).markets[i]
	rec := trader(s, c)
	g, q := t.good, t.quantity
	if !(q > 0) || q > sandbox.MAX_TRADE_QUANTITY {return .Bad_Quantity}
	if !m.deals[g] {return .No_Market}
	base_price := sandbox.BASE_PRICE
	if t.sell {
		if rec.cargo[int(g)] < q {return .No_Cargo}
		rec.cargo[int(g)] -= q
		rec.cash += f64(m.price[g] * (1 - sandbox.SPREAD) * q)
		m.stock[g] += q
		m.price[g] = max(m.price[g] * (1 - CAMP_STEP * q), base_price[g] * sandbox.PRICE_FLOOR)
	} else {
		cost := f64(m.price[g] * (1 + sandbox.SPREAD) * q)
		if m.stock[g] < q {return .No_Stock}
		if cost > rec.cash {return .No_Cash}
		rec.cash -= cost
		rec.cargo[int(g)] += q
		m.stock[g] -= q
		m.price[g] = min(m.price[g] * (1 + CAMP_STEP * q), base_price[g] * sandbox.PRICE_CEILING)
	}
	return .None
}
