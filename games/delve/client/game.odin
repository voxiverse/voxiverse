package delve_client

import "core:fmt"
import "core:slice"
import "core:strings"

import "client:engine"
import "client:ui"
import "common:game"
import "games:delve"

// Delve's client part (the game: games/delve): it shows the dungeon from above (a
// camera over the head, the world cut above the walls' height, the pointer aiming),
// keeps what the server told it (the dungeon, every delver's progress, the creatures'
// tags) and draws: a line at the top (depth, level, potions, coins, the whirl), the
// experience bar, banners, a health bar over every creature and the name of an elite or
// the warden, the damage of each hit floating up, the name of each piece of loot lying
// about, the delvers while the player list's key is held, and a line in F3.

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
}

// The camera: over the head, looking down at 60 degrees from 15 blocks; the world from
// three blocks over the feet is not drawn (the walls are four high).
CAMERA :: engine.Game_Camera {
	kind     = .Top_Down,
	distance = 15,
	angle    = 60,
	heading  = 0,
	cut      = 3,
}

BANNER_SECONDS :: 3.0
NUMBER_SECONDS :: 1.0 // a hit's number floats this long
MAX_NUMBERS :: 48

View :: struct {
	dungeon:  delve.Delve,
	heroes:   [game.MAX_PLAYERS]Seat, // by player id
	tags:     [delve.MAX_TAGS]Tag,
	numbers:  [MAX_NUMBERS]Number,
	next:     int, // the number slot to use next
	banner:   [64]u8,
	banner_n: int,
	until:    f64, // when the banner goes (the session's frame_seconds)
	good:     bool,
	items:    [delve.Weapon]game.Item,
	coin:     game.Item,
	potion:   game.Item,
	hits:     int, // seen (tests)
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

// Number: a hit's damage floating up.
Number :: struct {
	at:     [3]f64,
	amount: int,
	crit:   bool,
	taken:  bool,
	since:  f64, // frame_seconds when it came (0: none)
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

received :: proc(s: ^engine.Session, r: game.Received) {
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
		}
	}
	if t, ok := engine.game_value(s, r, delve.Foe_Tag); ok {tag_set(v, u32(r.key.a), t)}
	if hit, ok := engine.game_value(s, r, delve.Hit); ok && hit != nil {
		v.hits += 1
		v.numbers[v.next] = {
			at     = {f64(hit.at.x), f64(hit.at.y), f64(hit.at.z)},
			amount = int(hit.amount),
			crit   = hit.crit,
			taken  = hit.taken,
			since  = s.frame_seconds,
		}
		v.next = (v.next + 1) % MAX_NUMBERS
	}
	if up, ok := engine.game_value(s, r, delve.Level_Up); ok && up != nil {
		say(s, fmt.tprintf("LEVEL %d", up.level), true)
	}
	if down, ok := engine.game_value(s, r, delve.Warden_Down); ok && down != nil {
		say(s, "THE WARDEN FALLS: THE WAY DOWN IS OPEN", true)
	}
	if deeper, ok := engine.game_value(s, r, delve.Descended); ok && deeper != nil {
		say(s, fmt.tprintf("DEPTH %d", deeper.depth), false)
	}
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

say :: proc(s: ^engine.Session, text: string, good: bool) {
	v := view(s)
	v.banner_n = copy(v.banner[:], text)
	v.until, v.good = s.frame_seconds + BANNER_SECONDS, good
}

// status: the line at the top of the screen.
status :: proc(s: ^engine.Session) -> string {
	v := view(s)
	h := mine(s).hero
	whirl :=
		"ready" if h.whirl == 0 else fmt.tprintf("%ds", (int(h.whirl) + game.TICK_RATE - 1) / game.TICK_RATE)
	where_: string
	switch v.dungeon.phase {
	case .Building:
		where_ = "the dungeon rises"
	case .Delving:
		where_ = fmt.tprintf("%d creatures", v.dungeon.foes)
	case .Open:
		where_ = "the way down is open"
	}
	return fmt.tprintf(
		"DELVE  depth %d   %s   level %d   potions %d (X)   coins %d   whirl (Z) %s",
		v.dungeon.depth,
		where_,
		h.level,
		h.potions,
		h.coins,
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
		return fmt.tprintf("%d coins", stack.count)
	case v.potion:
		return "potion"
	}
	for item, w in v.items {if item == stack.item {return delve.loot_text(w, stack.data)}}
	return ""
}

banner :: proc(ctx: ^ui.Context, y: f32, text: string, size: f32, color: ui.Color) {
	r := ui.Rect{ctx.screen.x, y - size, ctx.screen.w, size * 2}
	ui.draw_text(ctx, {r.x + 3, r.y + 3, r.w, r.h}, text, size, ctx.theme.text_shadow, .Center)
	ui.draw_text(ctx, r, text, size, color, .Center)
}

hud :: proc(s: ^engine.Session, ctx: ^ui.Context) {
	v := view(s)
	t := &ctx.theme
	screen := ctx.screen
	top := ui.cut_top(&screen, t.row_height + t.padding)
	ui.fill_rect(ctx, top, t.hud_fill)
	ui.draw_text(ctx, top, status(s), t.font_size, t.text, .Center)
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
		line := ui.cut_top(&screen, t.row_height)
		ui.draw_text(ctx, line, text, t.font_size, t.text, .Center)
	}

	// In the world: every creature's health, the names of the elites and the warden.
	for &tag in v.tags {
		if tag.id == 0 {continue}
		engine.entity_bar(s, ctx, tag.id)
		if tag.name_len > 0 {
			name := string(tag.name[:tag.name_len])
			if tag.foe != .Warden {name = fmt.tprintf("%s, %s", name, delve.FOES[tag.foe].label)}
			engine.entity_label(s, ctx, tag.id, name, 1)
		}
	}
	// The loot lying about.
	for id, &e in s.entities {
		if text := loot_label(v, e.stack); text != "" {engine.entity_label(s, ctx, id, text)}
	}
	// The hits' numbers, rising and fading.
	for n in v.numbers {
		if n.since == 0 {continue}
		age := s.frame_seconds - n.since
		if age > NUMBER_SECONDS {continue}
		at, shown := engine.world_point(s, ctx, n.at + {0, age * 1.2, 0})
		if !shown {continue}
		color := t.log_warn if n.taken else (t.warning if n.crit else t.text)
		size := t.font_size * (1.5 if n.crit else 1.1)
		text := fmt.tprintf("%d!", n.amount) if n.crit else fmt.tprint(n.amount)
		r := ui.Rect{at.x - 40, at.y - size, 80, size * 2}
		ui.draw_text(ctx, {r.x + 2, r.y + 2, r.w, r.h}, text, size, t.text_shadow, .Center)
		ui.draw_text(ctx, r, text, size, color, .Center)
	}

	k := min(1, ctx.screen.h / 720)
	mid := ctx.screen.y + ctx.screen.h / 2
	if v.banner_n > 0 && s.frame_seconds < v.until {
		color := t.success if v.good else t.warning
		banner(ctx, mid - 160 * k, string(v.banner[:v.banner_n]), t.title_size * k, color)
	}
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
	board.title = fmt.tprintf("Delve: depth %d", v.dungeon.depth)
	engine.scoreboard_columns(board, "Level", "Kills", "Deaths", "Deepest")
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
