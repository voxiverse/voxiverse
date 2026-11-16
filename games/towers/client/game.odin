package towers_client

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"

import "client:engine"
import "client:ui"
import "common:base"
import "common:game"
import "common:protocol"
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

// View: what the session knows of the run.
View :: struct {
	run:      towers.Run,
	builders: [game.MAX_PLAYERS]Seat, // by player id
	flash:    engine.Flash, // a wave set out or held
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

received :: proc(s: ^engine.Session, r: protocol.Received) {
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
			engine.flash(&v.flash, s, fmt.tprintf("WAVE %d HELD", wave.wave), .Good)
		} else {
			engine.flash(
				&v.flash,
				s,
				fmt.tprintf("WAVE %d: %d CREEPS", wave.wave, wave.size),
				.Warn,
			)
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

hud :: proc(s: ^engine.Session, ctx: ^ui.Context) {
	v := view(s)
	t := &ctx.theme
	rest := ctx.screen
	engine.top_bar(ctx, &rest, status(s))

	// In the world: the creeps' health, the gate and the core, where a piece would go.
	for kind in v.kinds {engine.entity_bars(s, ctx, kind)}
	g := towers.GATE
	engine.world_label(s, ctx, {f64(g.x), 4.6, f64(g.z) + 0.5}, "GATE")
	engine.world_label(s, ctx, {f64(towers.CORE_X) + 1, 3.2, f64(towers.MID_Z)}, "CORE")
	preview(s, ctx)

	// The banner: a wave sets out or is held, the run ends.
	if v.run.phase == .Results {
		// The run's end stands as long as the results do, with your part in it.
		head, color := "THE CORE HAS FALLEN", t.log_warn
		if v.run.outcome == .Won {head, color = "THE CORE STANDS", t.success}
		engine.banner(ctx, -140, head, 1.2, color)
		me := mine(s)
		part := fmt.tprintf(
			"wave %d of %d   your kills %d   coins spent %d",
			v.run.wave,
			v.run.waves,
			me.kills,
			me.spent,
		)
		engine.banner(ctx, -50, part, 0.6, t.text)
		next := fmt.tprintf("a new run in %d   (hold P for the builders)", v.run.left)
		engine.banner(ctx, 60, next, 0.6, t.text)
	} else {
		engine.flash_draw(ctx, &v.flash, s, -140)
	}
	if v.run.phase == .Building && v.run.wave == 0 {
		prices := "walls 2, arrow towers 12, cannons 25: leave the creeps a way"
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
