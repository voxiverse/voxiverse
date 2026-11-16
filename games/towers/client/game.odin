package towers_client

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"

import "client:engine"
import "client:ui"
import "common:base"
import "common:game"
import "games:towers"

// Towers' client part (the game: games/towers): it keeps the run and every builder's
// purse as the server told them, and shows them: a line at the top of the HUD (the
// wave, the lives, your coins, the time to the next wave), a banner as a wave sets out
// or is held and at the run's end, a health bar over each hurt creep, the gate's and the
// core's names over them, an outline where the piece in hand would go (lit if it may,
// red if not), each tower's shot as a tracer, the builders while the player list's key
// is held, and a line in F3.

GAME :: engine.Game {
	info       = towers.INFO,
	kinds      = towers.KINDS,
	state      = View,
	started    = started,
	received   = received,
	hud        = hud,
	debug      = debug,
	scoreboard = scoreboard,
}

BANNER_SECONDS :: 3.0

// View: what the session knows of the run.
View :: struct {
	run:      towers.Run,
	builders: [game.MAX_PLAYERS]Seat, // by player id
	banner:   [64]u8,
	banner_n: int,
	until:    f64, // the session's clock (frame_seconds) when the banner goes
	good:     bool, // the banner's news is good (its colour)
	pieces:   [towers.Piece]game.Item, // what each piece's item is in this registry
	kinds:    [towers.Creep]game.Kind_Id,
	shots:    int, // seen (tests)
}

// Seat: a builder's purse, as told.
Seat :: struct {
	known:    bool,
	name:     [game.MAX_NAME_LENGTH]u8,
	name_len: int,
	coins:    int,
	kills:    int,
	spent:    int,
}

view :: proc(s: ^engine.Session) -> ^View {return engine.game_state(s, View)}

seat_name :: proc(seat: ^Seat) -> string {return string(seat.name[:seat.name_len])}

// mine: the player's own purse.
mine :: proc(s: ^engine.Session) -> ^Seat {
	v := view(s)
	return &v.builders[min(int(s.welcome.player), len(v.builders) - 1)]
}

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

received :: proc(s: ^engine.Session, r: game.Received) {
	v := view(s)
	if run, ok := engine.game_value(s, r, towers.Run); ok && run != nil {
		v.run = run^
	}
	if b, ok := engine.game_value(s, r, towers.Builder); ok && int(r.key.a) < len(v.builders) {
		seat := &v.builders[r.key.a]
		if b == nil {
			seat^ = {}
		} else {
			seat^ = {
				known = true,
				coins = int(b.coins),
				kills = int(b.kills),
				spent = int(b.spent),
			}
			seat.name_len = copy(seat.name[:], b.name)
		}
	}
	if wave, ok := engine.game_value(s, r, towers.Wave); ok && wave != nil {
		if wave.done {
			say(s, fmt.tprintf("WAVE %d HELD", wave.wave), true)
		} else {
			say(s, fmt.tprintf("WAVE %d: %d CREEPS", wave.wave, wave.size), false)
		}
	}
	if shot, ok := engine.game_value(s, r, towers.Shot); ok && shot != nil {
		v.shots += 1
		from := [3]f64{f64(shot.from.x), f64(shot.from.y), f64(shot.from.z)}
		to := [3]f64{f64(shot.to.x), f64(shot.to.y), f64(shot.to.z)}
		streak(s, from, to, shot.piece)
		if shot.piece == .Cannon {blast(s, to)}
	}
}

// say: a banner for BANNER_SECONDS.
say :: proc(s: ^engine.Session, text: string, good: bool) {
	v := view(s)
	v.banner_n = copy(v.banner[:], text)
	v.until, v.good = s.frame_seconds + BANNER_SECONDS, good
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

// blast: a cannon's shot lands: a puff of smoke and sparks.
blast :: proc(s: ^engine.Session, at: [3]f64) {
	r := base.cosmetic_rng()
	for i in 0 ..< 12 {
		a := f32(i) * math.TAU / 12
		speed := base.rng_f32_range(r, 1.5, 3.5)
		engine.puff_add(
			s,
			{
				position = at,
				velocity = {
					f32(base.cos(f64(a))) * speed,
					base.rng_f32_range(r, 1, 3),
					f32(base.sin(f64(a))) * speed,
				},
				life = 0.5,
				size = 0.09,
				gravity = 6,
				drag = 2,
				color = {90, 86, 80, 255} if i % 3 != 0 else {255, 170, 60, 255},
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
			return fmt.tprintf(
				"TOWERS  build!  first wave in %ds   lives %d   coins %d",
				r.left,
				r.lives,
				coins,
			)
		}
		return fmt.tprintf(
			"TOWERS  wave %d of %d held   next in %ds   lives %d   coins %d",
			r.wave,
			r.waves,
			r.left,
			r.lives,
			coins,
		)
	case .Wave:
		return fmt.tprintf(
			"TOWERS  wave %d of %d   creeps %d (+%d to come)   lives %d   coins %d",
			r.wave,
			r.waves,
			r.alive,
			r.to_come,
			r.lives,
			coins,
		)
	case .Results:
		return fmt.tprintf("TOWERS  run %d over   next run in %ds", r.run, r.left)
	}
	return ""
}

// banner: a line of big text across the screen, centred on y, with a shadow.
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

	// In the world: the creeps' health, the gate and the core, where a piece would go.
	for kind in v.kinds {engine.entity_bars(s, ctx, kind)}
	g := towers.GATE
	engine.world_label(s, ctx, {f64(g.x), 4.6, f64(g.z) + 0.5}, "GATE")
	engine.world_label(s, ctx, {f64(towers.CORE_X) + 1, 3.2, f64(towers.MID_Z)}, "CORE")
	preview(s, ctx)

	// The banner: a wave sets out or is held, the run ends.
	k := min(1, ctx.screen.h / 720)
	mid := ctx.screen.y + ctx.screen.h / 2
	switch {
	case v.run.phase == .Results:
		// The run's end stands as long as the results do, with your part in it.
		head, good := "THE CORE HAS FALLEN", false
		if v.run.outcome == .Won {head, good = "THE CORE STANDS", true}
		banner(ctx, mid - 140 * k, head, t.title_size * 1.2 * k, t.success if good else t.log_warn)
		me := mine(s)
		banner(
			ctx,
			mid - 50 * k,
			fmt.tprintf(
				"wave %d of %d   your kills %d   coins spent %d",
				v.run.wave,
				v.run.waves,
				me.kills,
				me.spent,
			),
			t.title_size * 0.6 * k,
			t.text,
		)
		banner(
			ctx,
			mid + 60 * k,
			fmt.tprintf("a new run in %d   (hold P for the builders)", v.run.left),
			t.title_size * 0.6 * k,
			t.text,
		)
	case v.banner_n > 0 && s.frame_seconds < v.until:
		color := t.success if v.good else t.log_warn
		banner(ctx, mid - 140 * k, string(v.banner[:v.banner_n]), t.title_size * k, color)
	}
	if v.run.phase == .Building && v.run.wave == 0 {
		banner(
			ctx,
			mid + 200 * k,
			"walls 2, arrow towers 12, cannons 25: leave the creeps a way",
			t.title_size * 0.5 * k,
			t.text,
		)
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
			mine(s).coins >= towers.PIECES[p].price &&
			v.run.phase != .Results
		engine.world_box(s, at, at, {90, 230, 110, 255} if ok else {240, 70, 60, 255})
		label := fmt.tprintf(
			"%s: %s",
			towers.PIECES[p].name,
			towers.coins_text(towers.PIECES[p].price),
		)
		engine.world_label(s, ctx, {f64(at.x) + 0.5, f64(at.y) + 1.6, f64(at.z) + 0.5}, label)
		return
	}
}

// Ranked: a known builder, by its player id.
Ranked :: struct {
	id:   int,
	seat: ^Seat,
}

// ranked: the known builders, the most kills first, then by name (temp memory).
ranked :: proc(v: ^View) -> []Ranked {
	all := make([dynamic]Ranked, context.temp_allocator)
	for &seat, id in v.builders {if seat.known {append(&all, Ranked{id, &seat})}}
	slice.sort_by(all[:], proc(a, b: Ranked) -> bool {
		if a.seat.kills != b.seat.kills {return a.seat.kills > b.seat.kills}
		return strings.compare(seat_name(a.seat), seat_name(b.seat)) < 0
	})
	return all[:]
}

// scoreboard: every builder of the run, the most kills first, with their coins and what
// they spent; yours lit.
scoreboard :: proc(s: ^engine.Session, board: ^engine.Scoreboard) {
	v := view(s)
	r := v.run
	board.title = fmt.tprintf(
		"Towers: run %d, wave %d of %d, %d lives",
		r.run,
		r.wave,
		r.waves,
		r.lives,
	)
	engine.scoreboard_columns(board, "Kills", "Coins", "Spent")
	for b in ranked(v) {
		engine.scoreboard_row(
			board,
			seat_name(b.seat),
			fmt.tprint(b.seat.kills),
			fmt.tprint(b.seat.coins),
			fmt.tprint(b.seat.spent),
			you = b.id == int(s.welcome.player),
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
