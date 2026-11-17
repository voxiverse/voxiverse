package delve_client

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"

import "client:engine"
import "client:ui"
import "common:game"
import "common:protocol"
import "games:delve"

// Delve's client part (the game: games/delve): it shows the dungeon from above (a
// camera over the head, the world cut above the walls' height, the pointer aiming),
// keeps what the server told it (the dungeon, every delver's progress, the creatures'
// tags) and draws: a line at the top (depth, level, potions, coins, the whirl), the
// experience bar, banners, a health bar over every creature and the name of an elite or
// the warden, the name of each piece of loot lying about, the delvers while the player
// list's key is held, and a line in F3. It makes the fight felt with the feel kit: each
// hit's damage floating up (a critical one bigger, with sparks), chips where a creature is
// struck, red edges and a jolt when the delver is hurt, coins and potions picked up rising
// from it, a level's sparkle and glow, the warden's fall shaking the floor.

GAME :: engine.Game {
	info       = delve.INFO,
	kinds      = delve.KINDS,
	state      = View,
	actions    = delve.ACTIONS,
	camera     = camera,
	started    = started,
	received   = received,
	hud        = hud,
	debug      = debug,
	scoreboard = scoreboard,
	look       = LOOK,
	seen       = seen,
}

// LOOK: a dungeon's air: no sky to speak of, a cold blue dark close round the delver, the
// braziers' and the runes' warm light the only warmth, and the corners dark. Creatures are
// drawn in more light than the dark gives, so they read against the floor.
LOOK :: engine.Look {
	time = 0.5,
	zenith = {0.004, 0.005, 0.009},
	horizon = {0.012, 0.014, 0.024},
	sun_light = {0.13, 0.15, 0.23},
	lamp_light = {1.15, 0.72, 0.38},
	ambient = {0.03, 0.04, 0.07},
	figure_light = {0.55, 0.55, 0.62},
	fog = 30,
	fog_near = 0.3,
	no_clouds = true,
	no_sun = true,
	grade = {tint = {0.95, 0.97, 1.08}, saturation = -0.1, contrast = 0.12, vignette = 0.45},
}

// The camera: over the head, looking down at 60 degrees from 15 blocks; nothing of the
// world from the walls' height up is drawn (a roof, a ceiling).
CAMERA :: engine.Game_Camera {
	kind     = .Top_Down,
	distance = 15,
	angle    = 60,
	heading  = 0,
	cut      = delve.WALL_HEIGHT,
}

// The feel's colours, inside the dungeon's dark: a hit's number, a critical one's, a
// delver's own hurt; the coin's gold, the potion's red, a level's warm glow, the edges' red.
NUMBER :: [4]u8{236, 232, 222, 255}
CRIT :: [4]u8{220, 90, 70, 255}
TAKEN :: [4]u8{255, 200, 80, 255}
COIN :: [4]u8{255, 214, 96, 255}
POTION :: [4]u8{230, 80, 90, 255}
LEVEL :: [4]u8{255, 210, 120, 70}
HARM :: [4]u8{200, 30, 30, 85}

View :: struct {
	dungeon: delve.Delve,
	heroes:  [game.MAX_PLAYERS]Seat, // by player id
	tags:    [delve.MAX_TAGS]Tag,
	flash:   engine.Flash, // a level gained, the warden's fall, a new depth
	purse:   Purse, // the delver's coins and potions as last told
	items:   [delve.Weapon]game.Item,
	coin:    game.Item,
	potion:  game.Item,
	hits:    int, // seen (tests)
}

Seat :: struct {
	known:    bool,
	hero:     delve.Hero,
	name:     [game.MAX_NAME_LENGTH]u8,
	name_len: int,
}

// Tag: a creature's tag, by its entity id (id 0: a free slot).
Tag :: struct {
	id:       u32,
	foe:      delve.Foe,
	elite:    bool,
	level:    u8,
	name:     [16]u8,
	name_len: int,
}

// Purse: the delver's coins and potions as last told, to tell what it picked up.
Purse :: struct {
	told:    bool,
	coins:   u32,
	potions: u16,
}

view :: proc(s: ^engine.Session) -> ^View {return engine.game_state(s, View)}

mine :: proc(s: ^engine.Session) -> ^Seat {
	v := view(s)
	return &v.heroes[min(int(s.welcome.player), len(v.heroes) - 1)]
}

seat_name :: proc(seat: ^Seat) -> string {return string(seat.name[:seat.name_len])}

camera :: proc(s: ^engine.Session) -> engine.Game_Camera {return CAMERA}

started :: proc(s: ^engine.Session) {
	v := view(s)
	for &item, w in v.items {item, _ = game.registry_item(s.reg, delve.WEAPON_ITEMS[w])}
	v.coin, _ = game.registry_item(s.reg, delve.COIN)
	v.potion, _ = game.registry_item(s.reg, delve.POTION)
}

received :: proc(s: ^engine.Session, r: protocol.Received) {
	v := view(s)
	if d, ok := engine.game_value(s, r, delve.Delve); ok && d != nil {v.dungeon = d^}
	if h, ok := engine.game_value(s, r, delve.Hero); ok && int(r.key.a) < len(v.heroes) {
		seat := &v.heroes[r.key.a]
		if h == nil {
			seat^ = {}
		} else {
			seat.known, seat.hero = true, h^
			seat.name_len = copy(seat.name[:], h.name)
			seat.hero.name = ""
			if int(r.key.a) == int(s.welcome.player) {purse_felt(s, &seat.hero)}
		}
	}
	if t, ok := engine.game_value(s, r, delve.Foe_Tag); ok {tag_set(v, u32(r.key.a), t)}
	if hit, ok := engine.game_value(s, r, delve.Hit); ok && hit != nil {
		v.hits += 1
		at := [3]f64{f64(hit.at.x), f64(hit.at.y), f64(hit.at.z)}
		switch {
		case hit.taken:
			engine.float_text(s, at, fmt.tprint(hit.amount), TAKEN)
		case hit.crit:
			engine.float_text(s, at, fmt.tprintf("%d!", hit.amount), CRIT, 1.35)
			engine.burst(s, at, .Sparks, {}, 1.5)
		case:
			engine.float_text(s, at, fmt.tprint(hit.amount), NUMBER)
		}
	}
	if up, ok := engine.game_value(s, r, delve.Level_Up); ok && up != nil {
		engine.flash(&view(s).flash, s, delve.tr(.Level_Up, up.level), .Good)
		engine.burst(s, s.feet + {0, 1, 0}, .Sparkle, {}, 1.8)
		engine.pulse(s, LEVEL)
	}
	if down, ok := engine.game_value(s, r, delve.Warden_Down); ok && down != nil {
		engine.flash(&view(s).flash, s, delve.tr(.Warden_Falls), .Good)
		engine.shake(s, 0.35, 0.7)
	}
	if deeper, ok := engine.game_value(s, r, delve.Descended); ok && deeper != nil {
		engine.flash(&view(s).flash, s, delve.tr(.Deeper, deeper.depth), .Bad)
	}
}

// purse_felt: the delver's progress as now told: coins and potions more than before (loot
// walked over) rise from it, with a sparkle.
purse_felt :: proc(s: ^engine.Session, h: ^delve.Hero) {
	p := &view(s).purse
	defer p^ = {true, h.coins, h.potions}
	if !p.told {return}
	at := s.feet + {0, 1.6, 0}
	if h.coins > p.coins {
		engine.float_text(s, at, delve.tr(.Gained_Coins, h.coins - p.coins), COIN)
		engine.burst(s, s.feet + {0, 0.8, 0}, .Sparkle, COIN)
	}
	if h.potions > p.potions {
		engine.float_text(s, at + {0, 0.4, 0}, delve.tr(.Gained_Potion), POTION)
		engine.burst(s, s.feet + {0, 0.8, 0}, .Sparkle, POTION)
	}
}

// seen: the fight felt: a creature struck throws chips of its colour from the side the
// camera sees; the delver hurt flushes the edges red and jolts the view.
seen :: proc(s: ^engine.Session, e: engine.Seen) {
	#partial switch x in e {
	case engine.Seen_Hurt:
		if tag_of(view(s), x.id) != nil { 	// (bigger: the camera is far above)
			engine.burst(s, facing_side(s, x.at), .Impact, kind_colour(s, x.kind), 1.5)
		}
	case engine.Seen_Harm:
		engine.pulse(s, HARM)
		engine.shake(s, min(0.08 + x.amount * 0.015, 0.25), 0.25)
		engine.kick(s, -0.8)
	}
}

// tag_of: the tag of a creature (nil: not one of the dungeon's).
tag_of :: proc(v: ^View, id: u32) -> ^Tag {
	for &tag in v.tags {if tag.id == id {return &tag}}
	return nil
}

// facing_side: a point of a creature's body on the side the camera sees, half a block out
// from its middle toward it, where a burst from it is not hidden inside it.
facing_side :: proc(s: ^engine.Session, middle: [3]f64) -> [3]f64 {
	d := s.view.position - middle
	d.y = 0
	l := math.sqrt(d.x * d.x + d.z * d.z)
	return middle if l < 0.01 else middle + d / l * 0.45
}

// kind_colour: a creature's colour, its model's first part's (its body's).
kind_colour :: proc(s: ^engine.Session, kind: game.Kind_Id) -> [4]u8 {
	info := game.kind_info(s.reg, kind)
	if info == nil || len(info.parts) == 0 {return {}}
	c := info.parts[0].color
	return {c[0], c[1], c[2], 255}
}

// tag_set: a creature's tag came (t nil: it went).
tag_set :: proc(v: ^View, id: u32, t: ^delve.Foe_Tag) {
	free := -1
	for &tag, i in v.tags {
		if tag.id == id {
			if t == nil {tag = {}} else {tag_fill(&tag, id, t)}
			return
		}
		if tag.id == 0 && free < 0 {free = i}
	}
	if t != nil && free >= 0 {tag_fill(&v.tags[free], id, t)}
}

tag_fill :: proc(tag: ^Tag, id: u32, t: ^delve.Foe_Tag) {
	tag^ = {
		id    = id,
		foe   = t.foe,
		elite = t.elite,
		level = t.level,
	}
	tag.name_len = copy(tag.name[:], t.name)
}

// status: the line at the top of the screen.
status :: proc(s: ^engine.Session) -> string {
	v := view(s)
	h := mine(s).hero
	whirl :=
		delve.tr(.Whirl_Ready) if h.whirl == 0 else delve.tr(.Whirl_In, (int(h.whirl) + game.TICK_RATE - 1) / game.TICK_RATE)
	where_: string
	switch v.dungeon.phase {
	case .Building:
		where_ = delve.tr(.Rising)
	case .Delving:
		where_ = delve.tr(.Creatures, v.dungeon.foes)
	case .Open:
		where_ = delve.tr(.Way_Open)
	}
	return delve.tr(
		.Status,
		v.dungeon.depth,
		where_,
		h.level,
		h.potions,
		engine.game_action_key(s, 1),
		h.coins,
		engine.game_action_key(s, 0),
		whirl,
	)
}

// held_text: the weapon in hand, with its roll.
held_text :: proc(s: ^engine.Session) -> string {
	v := view(s)
	held := game.inventory_held(&s.inventory)
	for item, w in v.items {
		if item != game.NO_ITEM && item == held.item {return delve.loot_text(w, held.data)}
	}
	return ""
}

// loot_label: what a dropped stack is called over it ("" for none of the game's).
loot_label :: proc(v: ^View, stack: game.Stack) -> string {
	switch stack.item {
	case game.NO_ITEM:
		return ""
	case v.coin:
		return delve.tr(.Coins, stack.count)
	case v.potion:
		return delve.tr(.Potion)
	}
	for item, w in v.items {if item == stack.item {return delve.loot_text(w, stack.data)}}
	return ""
}

hud :: proc(s: ^engine.Session, ctx: ^ui.Context) {
	v := view(s)
	t := &ctx.theme
	screen := ctx.screen
	engine.top_bar(ctx, &screen, status(s))
	// The experience bar under it, and the weapon in hand.
	h := mine(s).hero
	bar := ui.cut_top(&screen, 6)
	ui.fill_rect(ctx, bar, t.meter_back)
	if h.next > 0 {
		ui.fill_rect(
			ctx,
			{bar.x, bar.y, bar.w * clamp(f32(h.xp) / f32(h.next), 0, 1), bar.h},
			t.success,
		)
	}
	if text := held_text(s); text != "" {
		// (on a plate of its own, under the line: not a label in the world)
		line := ui.cut_top(&screen, t.row_height)
		width := ui.measure_text(ctx, text, t.font_size) + 2 * t.padding
		plate := ui.Rect{line.x + (line.w - width) / 2, line.y, width, line.h}
		ui.fill_rect(ctx, plate, t.hud_fill)
		ui.draw_text(ctx, plate, text, t.font_size, t.text, .Center)
	}

	// In the world: every creature's health, the names of the elites and the warden.
	for &tag in v.tags {
		if tag.id == 0 {continue}
		engine.entity_bar(s, ctx, tag.id)
		if tag.name_len > 0 {
			name := string(tag.name[:tag.name_len])
			if tag.foe != .Warden {name = delve.tr(.Elite, name, delve.FOES[tag.foe].label)}
			engine.entity_label(s, ctx, tag.id, name, 1)
		}
	}
	// The loot lying about.
	for id, &e in s.entities {
		if text := loot_label(v, e.stack); text != "" {engine.entity_label(s, ctx, id, text)}
	}
	engine.flash_draw(ctx, &v.flash, s, -160)
}

// ranked: the known delvers, the highest level first, then the most kills, then name.
Ranked :: struct {
	id:   int,
	seat: ^Seat,
}

ranked :: proc(v: ^View) -> []Ranked {
	all := make([dynamic]Ranked, context.temp_allocator)
	for &seat, id in v.heroes {if seat.known {append(&all, Ranked{id, &seat})}}
	slice.sort_by(all[:], proc(a, b: Ranked) -> bool {
		if a.seat.hero.level != b.seat.hero.level {return a.seat.hero.level > b.seat.hero.level}
		if a.seat.hero.kills != b.seat.hero.kills {return a.seat.hero.kills > b.seat.hero.kills}
		return strings.compare(seat_name(a.seat), seat_name(b.seat)) < 0
	})
	return all[:]
}

scoreboard :: proc(s: ^engine.Session, board: ^engine.Scoreboard) {
	v := view(s)
	board.title = delve.tr(.Board_Title, v.dungeon.depth)
	engine.scoreboard_columns(
		board,
		delve.tr(.Column_Level),
		delve.tr(.Column_Kills),
		delve.tr(.Column_Deaths),
		delve.tr(.Column_Deepest),
	)
	for r in ranked(v) {
		h := r.seat.hero
		engine.scoreboard_row(
			board,
			seat_name(r.seat),
			fmt.tprint(h.level),
			fmt.tprint(h.kills),
			fmt.tprint(h.deaths),
			fmt.tprint(h.best),
			you = r.id == int(s.welcome.player),
		)
	}
}

debug :: proc(s: ^engine.Session) -> string {
	v := view(s)
	tags := 0
	for tag in v.tags {if tag.id != 0 {tags += 1}}
	h := mine(s).hero
	p, aimed := s.pointer.?
	pointer := fmt.tprintf("%.1f %.1f %.1f", p.x, p.y, p.z) if aimed else "-"
	return fmt.tprintf(
		"depth %d %v seed %d  foes %d tagged %d  level %d xp %d/%d  hits %d  pointer %s",
		v.dungeon.depth,
		v.dungeon.phase,
		v.dungeon.seed,
		v.dungeon.foes,
		tags,
		h.level,
		h.xp,
		h.next,
		v.hits,
		pointer,
	)
}
