package rally_client

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"

import "client:engine"
import "client:ui"
import "common:game"
import "common:protocol"
import "games:rally"

// Rally's client part (the game: games/rally): it keeps the race and every racer's
// progress as the server told them, lays the course out from its seed as the server did,
// and shows them: a line at the top of the HUD (the gate to make for, the race's clock,
// your best, the record), the countdown, each split against your best's and each finish
// as banners, the gates marked in the world (the next one outlined), the racers while the
// player list's key is held, and a line in F3. With the feel kit: a hard landing jolts the
// view and kicks up the platform's dust, a gate passed sparkles, a fall sent back shakes
// the view and flushes the edges, a best or a record sparkles round the racer.

GAME :: engine.Game {
	info       = rally.INFO,
	kinds      = rally.KINDS,
	state      = View,
	received   = received,
	hud        = hud,
	debug      = debug,
	scoreboard = scoreboard,
	look       = LOOK,
}

// LOOK: a bright midday for racing: a deep blue sky, strong white light, saturated colour
// and the fog pushed out to the view's edge so the course reads far ahead.
LOOK :: engine.Look {
	time = 0.5,
	zenith = {0.04, 0.18, 0.72},
	horizon = {0.40, 0.64, 0.95},
	sun_light = {1.08, 1.05, 0.98},
	fog_near = 0.85,
	grade = {saturation = 0.25, contrast = 0.1},
}

// View: what the session knows of the race.
View :: struct {
	race:        rally.Race,
	record_name: [game.MAX_NAME_LENGTH]u8, // (race.record_name is a view into it)
	racers:      [game.MAX_PLAYERS]Seat, // by player id
	course:      rally.Course, // laid out from race.seed
	laid:        u32, // the seed it was laid out from (0: none yet)
	split:       engine.Flash, // the last gate passed, against the best
	finish:      engine.Flash, // a finish
	resets:      u16, // yours, as last told (one more: sent back)
	falling:     f32, // the fastest the racer fell since it left the ground (blocks/s, down)
	aloft:       bool, // it was off the ground last frame
}

// The feel's colours, inside the bright midday: a gate's green, a best's gold, the
// edges' flush at a fall.
GATE :: [4]u8{120, 240, 140, 255}
BEST :: [4]u8{255, 214, 96, 255}
FELL :: [4]u8{230, 60, 50, 70}

// HARD_LANDING: blocks a second of fall speed at which a landing is felt (a step down is
// not; a gap's jump is).
HARD_LANDING :: 7.0

// Seat: a racer's progress, as told.
Seat :: struct {
	using racer: rally.Racer,
	known:       bool,
	name_buf:    [game.MAX_NAME_LENGTH]u8,
}

view :: proc(s: ^engine.Session) -> ^View {return engine.game_state(s, View)}

// landing: once a frame, the racer's feet as predicted: coming down hard from a jump jolts
// the view down, as hard as it fell, and kicks up the dust of what it landed on.
landing :: proc(s: ^engine.Session) {
	v := view(s)
	state := s.prediction.state
	if !state.on_ground {
		v.aloft = true
		v.falling = max(v.falling, f32(-state.velocity.y))
		return
	}
	defer v.aloft, v.falling = false, 0
	if !v.aloft || v.falling < HARD_LANDING {return}
	hard := min((v.falling - HARD_LANDING) / 10, 1)
	engine.kick(s, -(1 + 2 * hard))
	x, z := i32(math.floor(s.feet.x)), i32(math.floor(s.feet.z))
	y := i32(math.floor(s.feet.y))
	if block, _, ok := engine.ground_top(s, x, z, y - 2, y); ok {
		engine.burst(s, s.feet + {0, 0.1, 0}, .Impact, engine.block_colour(s, block), 0.8 + hard)
	}
}

// mine: the player's own progress.
mine :: proc(s: ^engine.Session) -> ^Seat {
	v := view(s)
	return &v.racers[min(int(s.welcome.player), len(v.racers) - 1)]
}

received :: proc(s: ^engine.Session, r: protocol.Received) {
	v := view(s)
	if race, ok := engine.game_value(s, r, rally.Race); ok && race != nil {
		v.race = race^
		v.race.record_name = string(v.record_name[:copy(v.record_name[:], race.record_name)])
		if v.laid != race.seed || v.laid == 0 {
			v.course = rally.course_plan(race.seed)
			v.laid = race.seed
		}
	}
	if racer, ok := engine.game_value(s, r, rally.Racer); ok && int(r.key.a) < len(v.racers) {
		seat := &v.racers[r.key.a]
		if racer == nil {
			seat^ = {}
		} else {
			seat.racer, seat.known = racer^, true
			seat.name = string(seat.name_buf[:copy(seat.name_buf[:], racer.name)])
			if int(r.key.a) == int(s.welcome.player) {
				if racer.racing && racer.resets > v.resets {
					engine.shake(s, 0.25, 0.35) // (sent back to the last gate)
					engine.pulse(s, FELL)
				}
				v.resets = racer.resets
			}
		}
	}
	if split, ok := engine.game_value(s, r, rally.Split); ok && split != nil {
		if int(split.checkpoint) < len(v.course.checkpoints) {
			c := v.course.checkpoints[split.checkpoint]
			engine.burst(s, {f64(c.x) + 0.5, f64(c.y) + 1, f64(c.z) + 0.5}, .Sparkle, GATE, 1.5)
		}
		gate :=
			rally.tr(.Finish) if split.checkpoint == rally.CHECKPOINTS else rally.tr(.Gate, split.checkpoint)
		if split.compared {
			text := rally.tr(
				.Split_Compared,
				gate,
				rally.clock(split.ticks),
				rally.delta(split.delta),
			)
			engine.flash(&v.split, s, text, .Good if split.delta < 0 else .Warn)
		} else {
			engine.flash(&v.split, s, rally.tr(.Split, gate, rally.clock(split.ticks)), .Plain)
		}
	}
	if f, ok := engine.game_value(s, r, rally.Finish); ok && f != nil {
		mine := f.name == mine(s).name
		if mine && (f.record || f.personal) {
			engine.burst(s, s.feet + {0, 1, 0}, .Sparkle, BEST, 2)
		}
		switch {
		case f.record:
			engine.flash(
				&v.finish,
				s,
				rally.tr(.Course_Record, f.name, rally.clock(f.ticks)),
				.Good,
				5,
			)
		case mine && f.personal:
			engine.flash(&v.finish, s, rally.tr(.Personal_Best, rally.clock(f.ticks)), .Good, 5)
		case mine:
			engine.flash(&v.finish, s, rally.tr(.Finished, rally.clock(f.ticks)), .Plain, 5)
		}
	}
}

// best_text: a time, or "-" for none.
best_text :: proc(ticks: u32) -> string {return(
		rally.clock(ticks) if ticks > 0 else rally.tr(.None) \
	)}

// status: the line at the top of the screen.
status :: proc(s: ^engine.Session) -> string {
	v := view(s)
	r := v.race
	me := mine(s)
	record := rally.tr(.None)
	if r.record > 0 {record = rally.tr(.Record, rally.clock(r.record), r.record_name)}
	switch r.phase {
	case .Waiting:
		return rally.tr(.Status_Waiting)
	case .Countdown:
		return rally.tr(.Status_Starting, r.race, best_text(me.best), record)
	case .Racing:
		where_ := rally.tr(.At_Gate, me.next, rally.CHECKPOINTS)
		switch {
		case !me.racing:
			where_ = rally.tr(.Watching)
		case me.time > 0:
			where_ = rally.tr(.Finished_At, rally.clock(me.time))
		}
		return rally.tr(
			.Status_Racing,
			r.race,
			where_,
			rally.clock(r.ticks),
			best_text(me.best),
			record,
		)
	case .Results:
		return rally.tr(.Status_Over, r.race, r.left, record)
	}
	return ""
}

hud :: proc(s: ^engine.Session, ctx: ^ui.Context) {
	v := view(s)
	r := v.race
	if r.race == 0 {return}
	landing(s)
	t := &ctx.theme
	rest := ctx.screen
	engine.top_bar(ctx, &rest, status(s))
	marks(s, ctx)

	switch r.phase {
	case .Waiting:
	case .Countdown:
		engine.banner(ctx, -140, rally.tr(.Race_Title, r.race), 1.5, t.focus_ring)
		engine.banner(ctx, -60, fmt.tprintf("%d", r.left), 1.5, t.text)
		engine.banner(ctx, 40, rally.tr(.Rules), 0.6, t.text)
	case .Racing:
		engine.flash_draw(ctx, &v.split, s, -200, 0.8)
		engine.flash_draw(ctx, &v.finish, s, -120, 1.1)
	case .Results:
		engine.flash_draw(ctx, &v.finish, s, -250, 0.8)
		engine.banner(ctx, -180, rally.tr(.Race_Over), 1.5, t.focus_ring)
		at := f32(-90)
		for b, i in ranked(v) {
			if i >= 4 {break}
			line := rally.tr(
				.Placing,
				i + 1,
				b.seat.name,
				rally.clock(b.seat.time) if b.seat.time > 0 else rally.tr(.No_Finish),
			)
			engine.banner(
				ctx,
				at,
				line,
				0.7,
				t.success if b.id == int(s.welcome.player) else t.text,
			)
			at += 60
		}
		engine.banner(ctx, at + 20, rally.tr(.Next_Race, r.left), 0.6, t.text_muted)
	}
}

// marks: each gate's name over it, the next one to make for outlined.
marks :: proc(s: ^engine.Session, ctx: ^ui.Context) {
	v := view(s)
	me := mine(s)
	for k in 1 ..= rally.CHECKPOINTS {
		g := v.course.checkpoints[k]
		label := rally.tr(.Finish) if k == rally.CHECKPOINTS else rally.tr(.Gate, k)
		engine.world_label(s, ctx, {f64(g.x) + 0.5, f64(g.y) + 4.6, f64(g.z) + 0.5}, label)
		if me.racing && int(me.next) == k {
			engine.world_box(s, {g.x, g.y, g.z - 2}, {g.x, g.y + 2, g.z + 2}, {90, 230, 110, 255})
		}
	}
}

// Ranked: a known racer, by its player id.
Ranked :: struct {
	id:   int,
	seat: ^Seat,
}

// ranked: the racers of the race: finished first, fastest first, then the furthest along,
// then by name (temp memory).
ranked :: proc(v: ^View) -> []Ranked {
	all := make([dynamic]Ranked, context.temp_allocator)
	for &seat, id in v.racers {if seat.known && seat.racing {append(&all, Ranked{id, &seat})}}
	slice.sort_by(all[:], proc(a, b: Ranked) -> bool {
		x, y := a.seat, b.seat
		if (x.time > 0) != (y.time > 0) {return x.time > 0}
		if x.time != y.time {return x.time < y.time}
		if x.next != y.next {return x.next > y.next}
		return strings.compare(x.name, y.name) < 0
	})
	return all[:]
}

// scoreboard: every racer of the race, in order; yours lit.
scoreboard :: proc(s: ^engine.Session, board: ^engine.Scoreboard) {
	v := view(s)
	r := v.race
	board.title = rally.tr(.Board_Title, r.race, best_text(r.record))
	engine.scoreboard_columns(
		board,
		rally.tr(.Column_Gate),
		rally.tr(.Column_Time),
		rally.tr(.Column_Best),
		rally.tr(.Column_Resets),
	)
	for b in ranked(v) {
		gate :=
			rally.tr(.Done) if b.seat.time > 0 else rally.tr(.Gate_Of, b.seat.next, rally.CHECKPOINTS)
		engine.scoreboard_row(
			board,
			b.seat.name,
			gate,
			best_text(b.seat.time),
			best_text(b.seat.best),
			fmt.tprint(b.seat.resets),
			you = b.id == int(s.welcome.player),
		)
	}
}

// debug: F3's line.
debug :: proc(s: ^engine.Session) -> string {
	v := view(s)
	r := v.race
	return fmt.tprintf(
		"race %d %v  ticks %d  racers %d finished %d  gate %d  course %d (%d platforms)",
		r.race,
		r.phase,
		r.ticks,
		r.racers,
		r.finished,
		mine(s).next,
		r.seed,
		v.course.count,
	)
}
