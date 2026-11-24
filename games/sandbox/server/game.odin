package sandbox_server

import "common:base"
import "common:game"
import "common:starmap"
import "common:worldgen"
import "games:sandbox"
import "server:core"

// Sandbox's server part (the game: games/sandbox): it chooses the world the engine runs,
// keeps its sheep (sheep.odin: their minds, shearing and feeding, their statistics) and the
// economy of a world built on the planet (economy.odin: its towns' markets; trader.odin: the
// player as a trader; interventions.odin: what players did that the world's history carries
// forward), lets the base pack's hostile creatures out at night (danger.odin) and keeps the
// home world's ruined site, where Horde's waves are fought (ruin.odin), the remains round
// its home gate that lead there (remains.odin) and the delves under it, where the keepers'
// custodian is fought (delve.odin, delve_boss.odin). The rest of that world
// (worlds and gates, climate, farming) is the engine's, chosen by the config.

GAME :: core.Game {
	info           = sandbox.INFO,
	kinds          = sandbox.KINDS,
	pack           = sandbox.PACK,
	server_state   = Sandbox,
	client_state   = Ruin_Seat,
	entity_data    = Creature,
	character_data = Trader_Record,
	world_state    = Sandbox_World,
	world_files    = {
		{name = ECONOMY_FILE, check = economy_check},
		{name = INTERVENTIONS_FILE, check = interventions_check},
		{name = REMAINS_FILE, check = remains_check},
		{name = OUTPOSTS_FILE, check = outposts_check},
		{name = SETTLEMENTS_FILE, check = settlements_check},
		{name = DELVE_FILE, check = delves_check},
		{name = BEYOND_FILE, check = beyond_check},
	},
	stats          = {
		{name = "sheep.sheared", kind = .Count, xp = 5},
		{name = "sheep.fed", kind = .Count, xp = 2},
		{name = "sheep.born", kind = .Count},
	},
	configure      = configure,
	start          = start,
	stop           = stop,
	tick           = tick,
	think          = think,
	spawned        = spawned,
	joined         = joined,
	left           = left,
	died           = ruin_died,
	hurt           = mood_hurt,
	respawned      = respawned,
	respawn_where  = outpost_respawn_where,
	action         = action,
	request        = request,
	entity_use     = entity_use,
	entity_hurt    = entity_hurt,
	entity_died    = entity_died,
	harming        = harming,
	editing        = editing,
	blasting       = blasting,
	block_changed  = block_changed,
	picking        = ruin_picking,
	dropping       = ruin_dropping,
	machine_use    = machine_use,
	command        = command,
	world_opened   = world_opened,
	world_closed   = world_closed,
	world_save     = world_save,
}

// Sandbox: the session's state: the creatures' randomness and the registry's names they
// use, the remains the machines keep to, the ruined site, and what the remains are built
// of.
Sandbox :: struct {
	rng:              base.Rng,
	sheep:            game.Kind_Id,
	wild:             [Wild]game.Kind_Id, // the roster's kinds (wild.odin)
	marked:           [MAX_MARKED][3]f64, // the home world's remains marked (remains_machines.odin)
	marked_count:     int,
	grass, dirt:      game.Block,
	wheat:            game.Item,
	wool, black_wool: game.Item,
	placed:           int, // sheep the command has set down (each a little further along)
	ruin:             Ruin, // (ruin.odin)
	remains_kit:      Remains_Kit, // (remains.odin)
	survival:         Survival_State, // crafting, the Use action, the remains' loot (survival.odin)
	folk:             [Role]game.Kind_Id, // the camps' people's kinds (folk.odin)
	dialogues:        [Role]int, // ... and their dialogues (talk.odin)
	camp_kit:         Camp_Kit, // what the camps are built of (settlement_build.odin)
	camp_cells:       [MAX_SETTLEMENTS][dynamic]u16, // each home camp's blocks as built, once asked (settlement_kept)
	delves:           Delves, // (delve.odin)
	kept:             Kept, // the areas kept loaded (site.odin)
}

state :: proc(s: ^core.Server) -> ^Sandbox {return core.game_state(s, Sandbox)}

// start: the names the creatures, the ruin and the remains use, from the session's
// registry; the creatures' randomness from the universe's seed.
start :: proc(s: ^core.Server) -> bool {
	g := state(s)
	reg := s.registry
	g.rng = base.rng_make(u64(s.config.seed) ~ 0x5ee9_5ee9)
	g.sheep = game.registry_kind(reg, sandbox.SHEEP_KIND) or_return
	g.grass = game.registry_block(reg, "grass") or_return
	g.dirt = game.registry_block(reg, "dirt") or_return
	g.wheat = game.registry_item(reg, "wheat") or_return
	g.wool = game.item_of_block(reg, game.registry_block(reg, "wool") or_return)
	g.black_wool = game.item_of_block(reg, game.registry_block(reg, "black_wool") or_return)
	wild_start(s) or_return
	survival_start(s) or_return
	folk_start(s) or_return
	talk_start(s) or_return
	camp_kit_start(s) or_return
	return ruin_start(s) && remains_start(s) && delve_start(s)
}

// stop: what the survival loop and the delves allocated (survival.odin, delve.odin).
stop :: proc(s: ^core.Server) {
	survival_stop(s)
	delve_stop(s)
	settlement_stop(s)
}

// tick: the economy (economy.odin), the night's creatures (danger.odin), the ruined site
// (ruin.odin), the remains (remains.odin: planned once the ruin is placed), the camps
// (settlement.odin: planned once the remains are), the delves (delve.odin: planned once the
// camps are), the gate worlds' places (beyond.odin), the areas they keep loaded (site.odin),
// the conversations with the camps'
// people (talk.odin) and the players' crafting (survival.odin).
tick :: proc(s: ^core.Server) {
	economy_tick(s)
	danger_tick(s)
	ruin_tick(s)
	remains_tick(s)
	settlements_tick(s)
	delve_tick(s)
	beyond_tick(s)
	keeps_update(s)
	talk_tick(s)
	survival_tick(s)
	mood_tick(s)
}

// left: one fighting at the ruin is out (ruin.odin); what it was making is given back
// (survival.odin); its conversation ends (talk.odin).
left :: proc(s: ^core.Server, c: ^core.Client) {
	talk_seat(s, c)^ = {}
	ruin_left(s, c)
	craft_left(s, c)
}

// respawned: one who fell in the ruin has its things back (ruin.odin); one with an outpost
// stands there (outposts.odin).
respawned :: proc(s: ^core.Server, c: ^core.Client) {
	ruin_respawned(s, c)
	outpost_respawned(s, c)
}

// machine_use: an outpost's beacon makes the user's respawn there (outposts.odin); a delve's
// locked door opens to a key (delve.odin); the ruin's altar wakes it (ruin.odin).
machine_use :: proc(s: ^core.Server, c: ^core.Client, at: game.Block_Pos) -> string {
	b, _ := core.block_at(c.world, at)
	if b == survival_of(s).beacon {return outpost_use(s, c, at)}
	if b == delves_of(s).kit.door {return delve_door_use(s, c, at)}
	return ruin_use(s, c, at)
}

// block_changed: beacons placed and taken down, remains broken open (outposts.odin).
block_changed :: proc(s: ^core.Server, w: ^core.World, change: core.Block_Change) {
	outposts_changed(s, w, change)
}

// joined: a new trader's purse (trader.odin); one who left a fight at the ruin gets its
// things back (ruin.odin); one in a delve's boss's chamber with no fight on is set down
// outside it (delve.odin).
joined :: proc(s: ^core.Server, c: ^core.Client) {
	trader_joined(s, c)
	ruin_joined(s, c)
	delve_joined(s, c)
}

// kept: why the block of w at `at` is not to be changed from old to new, by a player's hand
// or a blast ("": it may be). The one rule for both (editing, blasting): the ruin's blocks
// (ruin.odin), a built delve's as drawn but its caches, which a hand may break open and a
// blast may not (delve.odin), and a camp's as built (settlement.odin); what a player set
// down in a delve's or a camp's air is its own. And on any world a remains cache or a sealed
// relic vault (the remains', a gate world's landmark's and site's) is broken open by a hand
// with the tool it asks, never by a blast, which would open it past the drill and spill
// nothing.
kept :: proc(
	s: ^core.Server,
	w: ^core.World,
	at: game.Block_Pos,
	old, new: game.Block,
	blast := false,
) -> string {
	k := &state(s).remains_kit
	if blast && (old == k.remains_cache || old == k.relic_vault) {return "It is sealed"}
	if why := ruin_kept(s, w, at); why != "" {return why}
	if why := delve_kept(s, w, at, old, blast); why != "" {return why}
	return settlement_kept(s, w, at, old)
}

// editing: what the sandbox keeps (kept) is not the players'; a beacon is its placer's to
// take down (outposts.odin).
editing :: proc(
	s: ^core.Server,
	c: ^core.Client,
	at: game.Block_Pos,
	old, new: game.Block,
) -> string {
	if why := kept(s, c.world, at, old, new); why != "" {return why}
	return outpost_editing(s, c, at, old, new)
}

// blasting: no blast breaks what the sandbox keeps (kept): the ruin, its ward, a delve's
// shells, seal and vault ward, a camp, a cache or a relic vault anywhere.
blasting :: proc(s: ^core.Server, w: ^core.World, at: game.Block_Pos, old: game.Block) -> bool {
	return kept(s, w, at, old, .Air, blast = true) == ""
}

// entity_died: a creature of the ruin's fight leaves its crowd (ruin.odin); a delve's
// custodian killed wins its fight (delve_boss.odin).
entity_died :: proc(
	s: ^core.Server,
	w: ^core.World,
	dead: core.Dead_Entity,
	harm: core.Entity_Harm,
) {
	ruin_entity_died(s, w, dead)
	boss_entity_died(s, w, dead)
}

// KIT: what a player new to a sandbox universe is given: one field dressing, and
// nothing else (the base pack's survival kit is emptied by the pack's
// game_modes/survival.json; blocks come from creative's catalog, or in survival from what
// is gathered and made: survival.odin). A universe keeps the kit it was made with
// (universe.cfg).
KIT :: "sandbox:field_dressing 1"

// configure: a new world is made by the Earth generator (continents, biomes, rivers,
// caves, trees), a new universe's home world has a dead gate in front of its spawn (what
// wakes it is not decided yet: core.gate_wake is the call), a universe nobody chose a mode
// for is played in survival, and new players are given
// KIT unless the caller names a kit; whether the home world is Earth itself or one made
// from the seed is the caller's (Config.earth), as are the spawn and whether animals
// appear by themselves. A saved world keeps its own generator, gates and kit.
configure :: proc(config: ^core.Config) {
	config.generator = .Earth
	config.home_gate = true
	if config.mode == "" {config.mode = "survival"}
	if config.kit == "" {config.kit = KIT}
}

// terrain_seed: the seed w's land is made from, as the engine makes it: Earth's is its
// address's, the same in every universe; any other world's is its own (World.seed). What the
// sandbox asks of common:worldgen about a world's land (dry_land, land_at) is asked with it.
terrain_seed :: proc(w: ^core.World) -> i64 {
	if w.address == starmap.earth_address() {return i64(starmap.address_hash(w.address))}
	return w.seed
}

#assert(worldgen.Kind.Earth == {}, "the Earth generator is the zero kind (an unset Config's)")

// world_opened: breaking takes time in every sandbox world (the rule break_time: one at 0,
// at once, is set to 1 as it opens; another value stands); a world's interventions log,
// economy file, remains file and outposts are read back.
world_opened :: proc(s: ^core.Server, w: ^core.World) {
	if !(w.rules.break_time > 0) {core.game_rule(s, w, "break_time", "1")}
	interventions_load(w)
	economy_load(w)
	remains_load(s, w)
	settlements_load(s, w)
	outposts_load(w)
	delves_load(s, w)
	beyond_load(s, w)
}

// world_closed: what the sandbox made of a world is freed (its economy's build waited for).
world_closed :: proc(s: ^core.Server, w: ^core.World) {
	sw := world_of(w)
	economy_free(sw)
	interventions_destroy(&sw.interventions)
}

// world_save: a world's files, those that changed, in the save's transaction.
world_save :: proc(s: ^core.Server, w: ^core.World) {
	interventions_write(w)
	economy_write(w)
	remains_write(s, w)
	settlements_write(s, w)
	outposts_write(w)
	delves_write(s, w)
	beyond_write(s, w)
}

// action: the market's asks for it (trader.odin); Use uses what is in the hand
// (survival.odin). The crafting screen's is the client part's alone.
action :: proc(s: ^core.Server, c: ^core.Client, index: int) {
	switch index {
	case sandbox.MARKET_ACTION:
		market_ask(s, c)
	case sandbox.USE_ACTION:
		use_held(s, c)
	}
}

// request: a trade in the town (or camp) the player stands in; a recipe to make
// (survival.odin); an answer in a conversation (talk.odin).
request :: proc(s: ^core.Server, c: ^core.Client, r: core.Request) {
	if t, ok := core.request_value(s, r, sandbox.Trade); ok {market_trade(s, c, t^)}
	if v, ok := core.request_value(s, r, sandbox.Craft); ok {craft_ask(s, c, v^)}
	if v, ok := core.request_value(s, r, sandbox.Say); ok {talk_say(s, c, v^)}
}

// command: `/sheep [lamb] [shorn] [black] [spotted]` sets a sheep of those looks down in
// front of the player (north of it, each further along; the summoning permission);
// `/interventions [radius]` lists the world's interventions (interventions.odin); `/town`
// takes the player to the nearest town with a market (trader.odin); `/showroom <family>`
// sets every material of a family up to look at (showroom.odin); `/settlement` says where
// the camps are or sets one down (settlement.odin); `/places` says where a gate world's places
// are or views one (beyond.odin).
command :: proc(s: ^core.Server, c: ^core.Client, name: string, args: []string) -> bool {
	if name == "interventions" {return interventions_command(s, c, args)}
	if name == "showroom" {return showroom_command(s, c, args)}
	if name == "creatures" {return creatures_command(s, c, args)}
	if name == "town" && len(args) == 0 {return town_command(s, c)}
	if name == "outposts" && len(args) == 0 {return outposts_command(s, c)}
	if name == "settlement" {return settlement_command(s, c, args)}
	if name == "places" {return beyond_command(s, c, args)}
	if name == "delve" {return delve_command(s, c, args)}
	if name != "sheep" {return false}
	if !core.allowed(s, c, "world.summon") {
		core.notice(s, c, "You may not summon here")
		return true
	}
	g := state(s)
	d := Creature{}
	for a in args {
		switch a {
		case "lamb":
			d.grows = sandbox.LAMB_TICKS
		case "shorn":
			d.shorn = true
		case "black":
			d.genes += sandbox.WOOL_BLACK
		case "spotted":
			d.genes += sandbox.COAT_SPOTTED
		case:
			core.notice(s, c, "Usage: sheep [lamb] [shorn] [black] [spotted]")
			return true
		}
	}
	at := c.player.position + {f64(g.placed % 5) * 1.5 - 3, 0, -4}
	g.placed += 1
	h := core.entity_spawn(c.world, g.sheep, at, false)
	if h == 0 {
		core.notice(s, c, "The world is full")
		return true
	}
	sheep(s, c.world, h)^ = d
	show(c.world, h, sheep(s, c.world, h))
	return true
}

// harming: a creature of the roster's shell or sleep (wild.odin); nobody hurts the camps'
// people (folk.odin).
harming :: proc(s: ^core.Server, hm: ^core.Harming) {
	wild_harming(s, hm)
	folk_harming(s, hm)
}
