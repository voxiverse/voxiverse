package horde_client

import "core:fmt"
import "core:slice"
import "core:strings"

import "client:engine"
import "client:ui"
import "common:game"
import "common:protocol"
import "games:horde"

// Horde's client part (the game: games/horde): it keeps the run and every survivor's
// purse as the server told them, and shows them: a line at the top of the HUD (the wave,
// the creatures, your coins and rounds, the best), the countdown and the wave's news as
// banners, the shop's wares and prices while it is open, a health bar over each hurt
// creature and the shop's name over its counter, the survivors while the player list's
// key is held, and a line in F3.

GAME :: engine.Game {
	info       = horde.INFO,
	kinds      = horde.KINDS,
	state      = View,
	started    = started,
	received   = received,
	hud        = hud,
	debug      = debug,
	scoreboard = scoreboard,
	actions    = horde.ACTIONS,
}

// View: what the session knows of the run.
View :: struct {
	run:       horde.Run,
	survivors: [game.MAX_PLAYERS]Seat, // by player id
	flash:     engine.Flash, // a wave set out or held
	kinds:     [horde.Foe]game.Kind_Id,
	round:     game.Item,
}

// Seat: a survivor's purse and tally, as told.
Seat :: struct {
	known:    bool,
	name:     [game.MAX_NAME_LENGTH]u8,
	name_len: int,
	coins:    int,
	kills:    int,
	downs:    int,
	down:     bool,
}

view :: proc(s: ^engine.Session) -> ^View {return engine.game_state(s, View)}

seat_name :: proc(seat: ^Seat) -> string {return string(seat.name[:seat.name_len])}

// mine: the player's own purse.
mine :: proc(s: ^engine.Session) -> ^Seat {
	v := view(s)
	return &v.survivors[min(int(s.welcome.player), len(v.survivors) - 1)]
}

// started: the pack's names, as this session's registry has them.
started :: proc(s: ^engine.Session) {
	v := view(s)
	for &kind, f in v.kinds {
		kind, _ = game.registry_kind(s.reg, fmt.tprintf("horde:%s", horde.FOES[f].kind))
	}
	v.round, _ = game.registry_item(s.reg, horde.ROUND_ITEM)
}

received :: proc(s: ^engine.Session, r: protocol.Received) {
	v := view(s)
	if run, ok := engine.game_value(s, r, horde.Run); ok && run != nil {
		v.run = run^
	}
	if sv, ok := engine.game_value(s, r, horde.Survivor); ok && int(r.key.a) < len(v.survivors) {
		seat := &v.survivors[r.key.a]
		if sv == nil {
			seat^ = {}
		} else {
			seat^ = {
				known = true,
				coins = int(sv.coins),
				kills = int(sv.kills),
				downs = int(sv.downs),
				down  = sv.down,
			}
			seat.name_len = copy(seat.name[:], sv.name)
		}
	}
	if news, ok := engine.game_value(s, r, horde.Wave_News); ok && news != nil {
		switch {
		case news.held:
			engine.flash(
				&v.flash,
				s,
				fmt.tprintf("WAVE %d HELD: THE SHOP IS OPEN", news.wave),
				.Good,
			)
		case news.boss:
			engine.flash(&v.flash, s, fmt.tprintf("WAVE %d: THE MATRIARCH COMES", news.wave), .Bad)
		case:
			engine.flash(
				&v.flash,
				s,
				fmt.tprintf("WAVE %d: %d CREATURES", news.wave, news.size),
				.Warn,
			)
		}
	}
}

// rounds: the rounds the player carries.
rounds :: proc(s: ^engine.Session) -> int {
	return game.inventory_count(&s.inventory, view(s).round)
}

// status: the line at the top of the screen.
status :: proc(s: ^engine.Session) -> string {
	r := view(s).run
	me := mine(s)
	switch r.phase {
	case .Waiting:
		return "HORDE  waiting for survivors"
	case .Countdown:
		return fmt.tprintf(
			"HORDE  run %d   the first wave in %ds   coins %d   best %d",
			r.run,
			r.left,
			me.coins,
			r.best,
		)
	case .Wave:
		return fmt.tprintf(
			"HORDE  wave %d   creatures %d (+%d)   standing %d/%d   coins %d   rounds %d   best %d",
			r.wave,
			r.alive,
			r.to_come,
			r.standing,
			r.players,
			me.coins,
			rounds(s),
			r.best,
		)
	case .Break:
		return fmt.tprintf(
			"HORDE  wave %d held   next in %ds   coins %d   rounds %d   best %d",
			r.wave,
			r.left,
			me.coins,
			rounds(s),
			r.best,
		)
	case .Over:
		return fmt.tprintf("HORDE  run %d over   next run in %ds   best %d", r.run, r.left, r.best)
	}
	return ""
}

hud :: proc(s: ^engine.Session, ctx: ^ui.Context) {
	v := view(s)
	r := v.run
	if r.run == 0 {return}
	t := &ctx.theme
	rest := ctx.screen
	engine.top_bar(ctx, &rest, status(s))

	// In the world: the creatures' health, the shop.
	for kind in v.kinds {engine.entity_bars(s, ctx, kind)}
	shop := [3]f64{horde.MID, 2.8, horde.MID}
	engine.world_label(
		s,
		ctx,
		shop,
		"SHOP" if r.phase == .Break || r.phase == .Countdown else "SHOP (closed)",
	)

	switch r.phase {
	case .Waiting:
	case .Countdown:
		engine.banner(ctx, -140, fmt.tprintf("RUN %d", r.run), 1.5, t.focus_ring)
		engine.banner(ctx, -60, fmt.tprintf("%d", r.left), 1.5, t.text)
		engine.banner(ctx, 40, "Hold out. Creatures come from the corners.", 0.6, t.text)
		shop_lines(s, ctx)
	case .Wave:
		if mine(s).down {
			engine.banner(ctx, -140, "DOWN: watching until the wave ends", 1, t.log_error)
		} else {
			engine.flash_draw(ctx, &v.flash, s, -160)
		}
	case .Break:
		engine.flash_draw(ctx, &v.flash, s, -160)
		shop_lines(s, ctx)
	case .Over:
		engine.banner(ctx, -160, "THE HORDE WINS", 1.5, t.log_error)
		held := max(int(r.wave) - 1, 0)
		engine.banner(ctx, -80, fmt.tprintf("%d waves held   best %d", held, r.best), 0.8, t.text)
		next := fmt.tprintf("a new run in %d   (hold P for the survivors)", r.left)
		engine.banner(ctx, 40, next, 0.6, t.text)
	}
}

// shop_lines: what the shop sells and asks, while it is open.
shop_lines :: proc(s: ^engine.Session, ctx: ^ui.Context) {
	r := view(s).run
	t := &ctx.theme
	if r.phase ==
	   .Break {engine.banner(ctx, 120, fmt.tprintf("THE SHOP IS OPEN: %ds", r.left), 0.8, t.success)}
	wares := fmt.tprintf(
		"at the counter:  Z rounds (%d)   X medkit (%d)   B gun (%d)",
		r.prices[.Rounds],
		r.prices[.Medkit],
		r.prices[.Gun],
	)
	engine.banner(ctx, 180, wares, 0.5, t.text)
}

// Ranked: a known survivor, by its player id.
Ranked :: struct {
	id:   int,
	seat: ^Seat,
}

// ranked: the known survivors, the most kills first, then by name (temp memory).
ranked :: proc(v: ^View) -> []Ranked {
	all := make([dynamic]Ranked, context.temp_allocator)
	for &seat, id in v.survivors {if seat.known {append(&all, Ranked{id, &seat})}}
	slice.sort_by(all[:], proc(a, b: Ranked) -> bool {
		if a.seat.kills != b.seat.kills {return a.seat.kills > b.seat.kills}
		return strings.compare(seat_name(a.seat), seat_name(b.seat)) < 0
	})
	return all[:]
}

// scoreboard: every survivor of the run, the most kills first; yours lit.
scoreboard :: proc(s: ^engine.Session, board: ^engine.Scoreboard) {
	v := view(s)
	r := v.run
	board.title = fmt.tprintf("Horde: run %d, wave %d, best %d", r.run, r.wave, r.best)
	engine.scoreboard_columns(board, "Kills", "Coins", "Downs", "")
	for b in ranked(v) {
		engine.scoreboard_row(
			board,
			seat_name(b.seat),
			fmt.tprint(b.seat.kills),
			fmt.tprint(b.seat.coins),
			fmt.tprint(b.seat.downs),
			"down" if b.seat.down else "",
			you = b.id == int(s.welcome.player),
		)
	}
}

// debug: F3's line.
debug :: proc(s: ^engine.Session) -> string {
	v := view(s)
	r := v.run
	return fmt.tprintf(
		"run %d %v  wave %d  creatures %d+%d  standing %d/%d  left %ds  best %d  seed %d",
		r.run,
		r.phase,
		r.wave,
		r.alive,
		r.to_come,
		r.standing,
		r.players,
		r.left,
		r.best,
		r.seed,
	)
}
