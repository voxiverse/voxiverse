package towers_client

import "core:fmt"
import "core:math"

import "client:engine"
import "client:ui"
import "common:game"
import "common:protocol"
import "games:towers"

// Towers' client part (the game: games/towers): it keeps the run and every builder's
// purse as the server told them, and shows them: a line at the top of the HUD (the
// wave, the lives, your coins, the time to the next wave), a banner as a wave sets out
// or is held and at the run's end, a health bar over each hurt creep, the gate's and the
// core's names over them, an outline where the piece in hand would go (lit if it may,
// red if not), each tower's shot as a tracer, the builders while the player list's key
// is held, and a line in F3. With the feel kit: chips where a creep is struck, a
// cannon ball's landing in smoke and sparks, a kill's bounty rising from the creep, and
// a leak at the core sparking there, shaking the view and flushing the edges red.

GAME :: engine.Game {
	info       = towers.INFO,
	kinds      = towers.KINDS,
	state      = View,
	started    = started,
	received   = received,
	hud        = hud,
	debug      = debug,
	scoreboard = scoreboard,
	look       = LOOK,
	seen       = seen,
}

// The feel's colours, inside the morning's: the coin's gold, the core's sparks, the
// edges' red, a cannon ball's smoke and its fire.
COIN :: [4]u8{255, 214, 96, 255}
CORE_SPARKS :: [4]u8{255, 120, 90, 255}
LEAK :: [4]u8{220, 40, 36, 80}
SMOKE :: [4]u8{90, 86, 80, 255}
FIRE :: [4]u8{255, 170, 60, 255}

// LOOK: a fresh morning with a mist on the far fields: a pale sky, the walls and the
// creeps' way sharp nearby, the greens rich and a touch cool.
LOOK :: engine.Look {
	time = 0.35,
	zenith = {0.16, 0.36, 0.74},
	horizon = {0.74, 0.82, 0.90},
	fog = 120,
	fog_near = 0.35,
	grade = {tint = {0.97, 1.02, 1.0}, saturation = 0.15, contrast = 0.05},
}

// View: what the session knows of the run.
View :: struct {
	run:      towers.Run,
	builders: engine.Seats(towers.Builder), // by player id
	flash:    engine.Flash, // a wave set out or held
	pieces:   [towers.Piece]game.Item, // what each piece's item is in this registry
	kinds:    [towers.Creep]game.Kind_Id,
	shots:    int, // seen (tests)
	kills:    u32, // yours, as last told
	pending:  u32, // kills told whose creeps' deaths are not yet felt (seen; the HUD forgets them)
}

view :: proc(s: ^engine.Session) -> ^View {return engine.game_state(s, View)}

// mine: the player's own purse.
mine :: proc(s: ^engine.Session) -> ^towers.Builder {return engine.seat_mine(s, &view(s).builders)}

// started: the pack's names, as this session's registry has them.
started :: proc(s: ^engine.Session) {
	v := view(s)
	for &item, p in v.pieces {
		item, _ = game.registry_item(s.reg, fmt.tprintf("towers:%s", towers.PIECES[p].block))
	}
	for &kind, c in v.kinds {
		kind, _ = game.registry_kind(s.reg, fmt.tprintf("towers:%s", towers.CREEPS[c].kind))
	}
}

received :: proc(s: ^engine.Session, r: protocol.Received) {
	v := view(s)
	if run, ok := engine.game_value(s, r, towers.Run); ok && run != nil {
		before := v.run
		v.run = run^
		if run.run == before.run && run.phase == .Wave && run.lives < before.lives {leaked(s)}
	}
	if engine.seats_received(s, &v.builders, r) {
		me := mine(s)
		if me.kills > v.kills {v.pending += me.kills - v.kills}
		v.kills = me.kills
		return
	}
	if wave, ok := engine.game_value(s, r, towers.Wave); ok && wave != nil {
		if wave.done {
			engine.flash(&v.flash, s, towers.tr(.Wave_Held, wave.wave), .Good)
		} else {
			engine.flash(&v.flash, s, towers.tr(.Wave_Sets_Out, wave.wave, wave.size), .Warn)
		}
	}
	if shot, ok := engine.game_value(s, r, towers.Shot); ok && shot != nil {
		v.shots += 1
		from := [3]f64{f64(shot.from.x), f64(shot.from.y), f64(shot.from.z)}
		to := [3]f64{f64(shot.to.x), f64(shot.to.y), f64(shot.to.z)}
		streak(s, from, to, shot.piece)
		if shot.piece == .Cannon {
			engine.burst(s, to, .Smoke, SMOKE, 0.8)
			engine.burst(s, to, .Sparks, FIRE)
		}
	}
}

// leaked: a creep reached the core: it sparks, the view shakes and the edges flush red.
leaked :: proc(s: ^engine.Session) {
	core := [3]f64{f64(towers.CORE_X) + 1, 3.1, f64(towers.MID_Z)} // (its top)
	engine.burst(s, core, .Sparks, CORE_SPARKS, 1.5)
	engine.shake(s, 0.2, 0.35)
	engine.pulse(s, LEAK)
}

// seen: a creep struck throws chips of its colour; one of the player's kills floats its
// bounty up from it.
seen :: proc(s: ^engine.Session, e: engine.Seen) {
	v := view(s)
	#partial switch x in e {
	case engine.Seen_Hurt:
		if _, ours := creep_of(v, x.kind); ours {
			engine.burst(s, x.at, .Impact, kind_colour(s, x.kind), 0.8)
		}
	case engine.Seen_Death:
		creep, ours := creep_of(v, x.kind)
		if !ours || v.pending == 0 {break}
		v.pending -= 1
		engine.float_text(s, x.at, towers.tr(.Bounty, towers.CREEPS[creep].bounty), COIN)
	}
}

// creep_of: which of the game's creeps a kind is (false: none of them).
creep_of :: proc(v: ^View, kind: game.Kind_Id) -> (towers.Creep, bool) {
	for k, c in v.kinds {if k != 0 && k == kind {return c, true}}
	return {}, false
}

// kind_colour: a creep's colour, its model's first part's (its body's).
kind_colour :: proc(s: ^engine.Session, kind: game.Kind_Id) -> [4]u8 {
	info := game.kind_info(s.reg, kind)
	if info == nil || len(info.parts) == 0 {return {}}
	c := info.parts[0].color
	return {c[0], c[1], c[2], 255}
}

// STREAK_SECONDS: how long a tower's shot hangs in the air (longer than a gun's tracer:
// a tower's are what the players watch).
STREAK_SECONDS :: 0.45

// streak: a tower's shot, a line of bright specks from its top to where it landed: an
// arrow's pale and thin, a cannon ball's dark and heavy.
streak :: proc(s: ^engine.Session, from, to: [3]f64, piece: towers.Piece) {
	d := to - from
	n := clamp(int(math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z) / 0.35), 2, 40)
	color := [4]u8{255, 220, 90, 255} if piece == .Arrow else {40, 38, 36, 255}
	size: f32 = 0.07 if piece == .Arrow else 0.11
	for i in 0 ..< n {
		engine.puff_add(
			s,
			{
				position = from + d * (f64(i) + 0.5) / f64(n),
				life = STREAK_SECONDS,
				size = size,
				color = color,
			},
		)
	}
}

// status: the line at the top of the screen.
status :: proc(s: ^engine.Session) -> string {
	v := view(s)
	r := v.run
	coins := mine(s).coins
	switch r.phase {
	case .Building:
		if r.wave == 0 {
			return towers.tr(.Status_First, r.left, r.lives, coins)
		}
		return towers.tr(.Status_Held, r.wave, r.waves, r.left, r.lives, coins)
	case .Wave:
		return towers.tr(.Status_Wave, r.wave, r.waves, r.alive, r.to_come, r.lives, coins)
	case .Results:
		return towers.tr(.Status_Over, r.run, r.left)
	}
	return ""
}

hud :: proc(s: ^engine.Session, ctx: ^ui.Context) {
	v := view(s)
	v.pending = 0 // (a kill whose creep was not seen dying: out of sight)
	t := &ctx.theme
	rest := ctx.screen
	engine.top_bar(ctx, &rest, status(s))

	// In the world: the creeps' health, the gate and the core, where a piece would go.
	for kind in v.kinds {engine.entity_bars(s, ctx, kind)}
	g := towers.GATE
	engine.world_label(s, ctx, {f64(g.x), 4.6, f64(g.z) + 0.5}, towers.tr(.Gate))
	engine.world_label(s, ctx, {f64(towers.CORE_X) + 1, 3.2, f64(towers.MID_Z)}, towers.tr(.Core))
	preview(s, ctx)

	// The banner: a wave sets out or is held, the run ends.
	if v.run.phase == .Results {
		// The run's end stands as long as the results do, with your part in it.
		head, color := towers.tr(.Core_Fallen), t.log_warn
		if v.run.outcome == .Won {head, color = towers.tr(.Core_Stands), t.success}
		engine.banner(ctx, -140, head, 1.2, color)
		me := mine(s)
		part := towers.tr(.Your_Part, v.run.wave, v.run.waves, me.kills, me.spent)
		engine.banner(ctx, -50, part, 0.6, t.text)
		next := towers.tr(.Next_Run, v.run.left)
		engine.banner(ctx, 60, next, 0.6, t.text)
	} else {
		engine.flash_draw(ctx, &v.flash, s, -140)
	}
	if v.run.phase == .Building && v.run.wave == 0 {
		prices := towers.tr(.Prices)
		engine.banner(ctx, 200, prices, 0.5, t.text)
	}
}

// preview: with a piece in hand, an outline where it would go: lit when it may be built
// there (on the build ground, paid for), red when not. (Whether it would shut the way is
// the server's to say.)
preview :: proc(s: ^engine.Session, ctx: ^ui.Context) {
	v := view(s)
	hit, aimed := s.aim.?
	if !aimed {return}
	held := game.inventory_held(&s.inventory).item
	for item, p in v.pieces {
		if item == game.NO_ITEM || item != held {continue}
		at := hit.block + game.Block_Pos(hit.normal)
		ok :=
			towers.buildable(at) &&
			int(mine(s).coins) >= towers.PIECES[p].price &&
			v.run.phase != .Results
		engine.world_box(s, at, at, {90, 230, 110, 255} if ok else {240, 70, 60, 255})
		label := towers.tr(
			.Piece_Price,
			towers.PIECES[p].name,
			towers.coins_text(towers.PIECES[p].price),
		)
		engine.world_label(s, ctx, {f64(at.x) + 0.5, f64(at.y) + 1.6, f64(at.z) + 0.5}, label)
		return
	}
}

// ranked: the known builders, the most kills first, then by name, as player ids (temp
// memory).
ranked :: proc(v: ^View) -> []int {
	return engine.seats_ranked(
		&v.builders,
		proc(a, b: ^towers.Builder) -> bool {return a.kills > b.kills},
	)
}

// scoreboard: every builder of the run, the most kills first, with their coins and what
// they spent; yours lit.
scoreboard :: proc(s: ^engine.Session, board: ^engine.Scoreboard) {
	v := view(s)
	r := v.run
	board.title = towers.tr(.Board_Title, r.run, r.wave, r.waves, r.lives)
	engine.scoreboard_columns(
		board,
		towers.tr(.Column_Kills),
		towers.tr(.Column_Coins),
		towers.tr(.Column_Spent),
	)
	for id in ranked(v) {
		b := &v.builders.values[id]
		engine.scoreboard_row(
			board,
			b.name,
			fmt.tprint(b.kills),
			fmt.tprint(b.coins),
			fmt.tprint(b.spent),
			you = id == int(s.welcome.player),
		)
	}
}

// debug: F3's line.
debug :: proc(s: ^engine.Session) -> string {
	v := view(s)
	r := v.run
	return fmt.tprintf(
		"run %d %v %v  wave %d/%d  lives %d  creeps %d+%d  left %ds  builders %d  shots %d  seed %d",
		r.run,
		r.phase,
		r.outcome,
		r.wave,
		r.waves,
		r.lives,
		r.alive,
		r.to_come,
		r.left,
		len(ranked(v)),
		v.shots,
		r.seed,
	)
}
