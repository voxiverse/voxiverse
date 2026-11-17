package horde_client

import "core:fmt"

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
	look       = LOOK,
}

// LOOK: a cold moonlit night that never ends, the fog close and heavy beyond the walls;
// the moon lights enough to aim by, and the creatures are drawn in more light than it gives.
LOOK :: engine.Look {
	time = 0.02,
	zenith = {0.008, 0.012, 0.03},
	horizon = {0.03, 0.045, 0.085},
	sun_light = {0.32, 0.38, 0.58},
	figure_light = {0.42, 0.44, 0.52},
	fog = 64,
	fog_near = 0.15,
	grade = {tint = {0.88, 0.95, 1.10}, saturation = -0.3, contrast = 0.08, vignette = 0.35},
}

// View: what the session knows of the run.
View :: struct {
	run:       horde.Run,
	survivors: engine.Seats(horde.Survivor), // by player id
	flash:     engine.Flash, // a wave set out or held
	kinds:     [horde.Foe]game.Kind_Id,
	round:     game.Item,
}

view :: proc(s: ^engine.Session) -> ^View {return engine.game_state(s, View)}

// mine: the player's own purse.
mine :: proc(s: ^engine.Session) -> ^horde.Survivor {return engine.seat_mine(
		s,
		&view(s).survivors,
	)}

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
	if engine.seats_received(s, &v.survivors, r) {return}
	if news, ok := engine.game_value(s, r, horde.Wave_News); ok && news != nil {
		switch {
		case news.held:
			engine.flash(&v.flash, s, horde.tr(.Wave_Held, news.wave), .Good)
		case news.boss:
			engine.flash(&v.flash, s, horde.tr(.Wave_Boss, news.wave), .Bad)
		case:
			engine.flash(&v.flash, s, horde.tr(.Wave_Sets_Out, news.wave, news.size), .Warn)
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
		return horde.tr(.Status_Waiting)
	case .Countdown:
		return horde.tr(.Status_Countdown, r.run, r.left, me.coins, r.best)
	case .Wave:
		return horde.tr(
			.Status_Wave,
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
		return horde.tr(.Status_Break, r.wave, r.left, me.coins, rounds(s), r.best)
	case .Over:
		return horde.tr(.Status_Over, r.run, r.left, r.best)
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
		horde.tr(.Shop) if r.phase == .Break || r.phase == .Countdown else horde.tr(.Shop_Closed),
	)

	switch r.phase {
	case .Waiting:
	case .Countdown:
		engine.banner(ctx, -140, horde.tr(.Run_Title, r.run), 1.5, t.focus_ring)
		engine.banner(ctx, -60, fmt.tprintf("%d", r.left), 1.5, t.text)
		engine.banner(ctx, 40, horde.tr(.Rules), 0.6, t.text)
		shop_lines(s, ctx)
	case .Wave:
		if mine(s).down {
			engine.banner(ctx, -140, horde.tr(.Down), 1, t.log_error)
		} else {
			engine.flash_draw(ctx, &v.flash, s, -160)
		}
	case .Break:
		engine.flash_draw(ctx, &v.flash, s, -160)
		shop_lines(s, ctx)
	case .Over:
		engine.banner(ctx, -160, horde.tr(.Horde_Wins), 1.5, t.log_error)
		held := max(int(r.wave) - 1, 0)
		engine.banner(ctx, -80, horde.tr(.Held, held, r.best), 0.8, t.text)
		next := horde.tr(.Next_Run, r.left)
		engine.banner(ctx, 40, next, 0.6, t.text)
	}
}

// shop_lines: what the shop sells and asks, while it is open.
shop_lines :: proc(s: ^engine.Session, ctx: ^ui.Context) {
	r := view(s).run
	t := &ctx.theme
	if r.phase == .Break {engine.banner(ctx, 120, horde.tr(.Shop_Open, r.left), 0.8, t.success)}
	wares := horde.tr(
		.Wares,
		engine.game_action_key(s, 0),
		engine.game_action_key(s, 1),
		engine.game_action_key(s, 2),
		r.prices[.Rounds],
		r.prices[.Medkit],
		r.prices[.Gun],
	)
	engine.banner(ctx, 180, wares, 0.5, t.text)
}

// ranked: the known survivors, the most kills first, then by name, as player ids (temp
// memory).
ranked :: proc(v: ^View) -> []int {
	return engine.seats_ranked(
		&v.survivors,
		proc(a, b: ^horde.Survivor) -> bool {return a.kills > b.kills},
	)
}

// scoreboard: every survivor of the run, the most kills first; yours lit.
scoreboard :: proc(s: ^engine.Session, board: ^engine.Scoreboard) {
	v := view(s)
	r := v.run
	board.title = horde.tr(.Board_Title, r.run, r.wave, r.best)
	engine.scoreboard_columns(
		board,
		horde.tr(.Column_Kills),
		horde.tr(.Column_Coins),
		horde.tr(.Column_Downs),
		"",
	)
	for id in ranked(v) {
		sv := &v.survivors.values[id]
		engine.scoreboard_row(
			board,
			sv.name,
			fmt.tprint(sv.kills),
			fmt.tprint(sv.coins),
			fmt.tprint(sv.downs),
			horde.tr(.Is_Down) if sv.down else "",
			you = id == int(s.welcome.player),
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
