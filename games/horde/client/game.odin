package horde_client

import "core:fmt"
import "core:math"

import "client:engine"
import "client:ui"
import "common:game"
import "common:protocol"
import "common:wave"
import "games:horde"

// Horde's client part (the game: games/horde): it keeps the run and every survivor's
// purse as the server told them, and shows them: a line at the top of the HUD (the wave,
// the creatures, your coins and rounds, the best), the countdown and the wave's news as
// banners, the shop's wares and prices while it is open, a health bar over each hurt
// creature and the shop's name over its counter, the survivors while the player list's
// key is held, and a line in F3. It makes the fight felt with the feel kit: chips where a
// creature is hit, a kill's bounty rising from it, a shake for a big one falling and the
// matriarch's coming, red edges and a jolt when hurt, green when healed, a sparkle at the
// counter when something is bought.

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
	seen       = seen,
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
	felt:      Felt,
}

// Felt: the player's purse and kills as last told, to tell a purchase and its own kills:
// a kill counted in a record comes with its creature's death in the same message, so
// what is pending is felt by the death or forgotten by the next frame's HUD.
Felt :: struct {
	run:     u16, // the run they are of (a new run: kills from 0, the purse not yet told)
	coins:   u32,
	told:    bool, // coins was told this run
	kills:   u32,
	pending: u32, // kills counted and not yet felt
}

// The feel's colours, inside the night's: the coin's gold, the edges' red and green.
COIN :: [4]u8{255, 214, 96, 255}
HARM :: [4]u8{210, 30, 30, 80}
HEAL :: [4]u8{70, 210, 110, 70}

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
		kind, _ = game.registry_kind(s.reg, wave.KINDS[f])
	}
	v.round, _ = game.registry_item(s.reg, horde.ROUND_ITEM)
}

received :: proc(s: ^engine.Session, r: protocol.Received) {
	v := view(s)
	if run, ok := engine.game_value(s, r, horde.Run); ok && run != nil {
		v.run = run^
		if v.felt.run != run.run {v.felt = {
				run = run.run,
			}}
	}
	if engine.seats_received(s, &v.survivors, r) {
		purse_felt(s)
		return
	}
	if news, ok := engine.game_value(s, r, horde.Wave_News); ok && news != nil {
		switch {
		case news.held:
			engine.flash(&v.flash, s, horde.tr(.Wave_Held, news.wave), .Good)
		case news.boss:
			engine.flash(&v.flash, s, horde.tr(.Wave_Boss, news.wave), .Bad)
			engine.shake(s, 0.3, 0.8) // (she is coming)
		case:
			engine.flash(&v.flash, s, horde.tr(.Wave_Sets_Out, news.wave, news.size), .Warn)
		}
	}
}

// purse_felt: the player's purse as the server now tells it: coins gone at the counter (a
// purchase: the shop is open) sparkle there, the cost rising; kills counted wait for their
// creatures' deaths (seen).
purse_felt :: proc(s: ^engine.Session) {
	v := view(s)
	me, f := mine(s), &v.felt
	if f.told && me.coins < f.coins && (v.run.phase == .Break || v.run.phase == .Countdown) {
		counter := [3]f64{horde.MID, 2.2, horde.MID}
		engine.burst(s, counter, .Sparkle, COIN)
		engine.float_text(s, counter, horde.tr(.Spent, f.coins - me.coins), COIN, 0.9)
	}
	if me.kills > f.kills {f.pending += me.kills - f.kills}
	f.coins, f.told, f.kills = me.coins, true, me.kills
}

// seen: the fight felt. A creature hit throws chips of its own colour; one of the player's
// kills floats its bounty up, a hulk falling shakes the yard a little and the matriarch's
// fall more; harm taken flushes the edges red and jolts the view, a heal flushes them
// green.
seen :: proc(s: ^engine.Session, e: engine.Seen) {
	v := view(s)
	#partial switch x in e {
	case engine.Seen_Hurt:
		if _, ours := foe_of(v, x.kind); ours {
			engine.burst(s, facing_side(s, x.at), .Impact, kind_colour(s, x.kind))
		}
	case engine.Seen_Death:
		foe, ours := foe_of(v, x.kind)
		if !ours {break}
		if v.felt.pending > 0 {
			v.felt.pending -= 1
			engine.float_text(s, x.at, horde.tr(.Bounty, horde.FOES[foe].bounty), COIN)
		}
		#partial switch foe {
		case .Hulk:
			engine.shake(s, 0.12, 0.3)
		case .Matriarch:
			engine.shake(s, 0.4, 0.9)
		}
	case engine.Seen_Harm:
		engine.pulse(s, HARM)
		engine.shake(s, min(0.08 + x.amount * 0.02, 0.3), 0.25)
		engine.kick(s, -1.2)
	case engine.Seen_Heal:
		engine.pulse(s, HEAL)
	}
}

// facing_side: a point of a creature's body on the side the player sees, half a block out
// from its middle toward the eyes, where a burst from it is not hidden inside it.
facing_side :: proc(s: ^engine.Session, middle: [3]f64) -> [3]f64 {
	d := s.camera.position - middle
	d.y = 0
	l := math.sqrt(d.x * d.x + d.z * d.z)
	return middle if l < 0.01 else middle + d / l * 0.45
}

// foe_of: which of the game's creatures a kind is (false: none of them).
foe_of :: proc(v: ^View, kind: game.Kind_Id) -> (horde.Foe, bool) {
	for k, f in v.kinds {if k != 0 && k == kind {return f, true}}
	return {}, false
}

// kind_colour: a creature's colour, its model's first part's (its body's).
kind_colour :: proc(s: ^engine.Session, kind: game.Kind_Id) -> [4]u8 {
	info := game.kind_info(s.reg, kind)
	if info == nil || len(info.parts) == 0 {return {}}
	c := info.parts[0].color
	return {c[0], c[1], c[2], 255}
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
	v.felt.pending = 0 // (a kill whose death was not seen: out of sight)
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
