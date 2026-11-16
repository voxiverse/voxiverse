package rally_client

import "core:fmt"
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
// player list's key is held, and a line in F3.

GAME :: engine.Game {
	info       = rally.INFO,
	kinds      = rally.KINDS,
	state      = View,
	received   = received,
	hud        = hud,
	debug      = debug,
	scoreboard = scoreboard,
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
}

// Seat: a racer's progress, as told.
Seat :: struct {
	using racer: rally.Racer,
	known:       bool,
	name_buf:    [game.MAX_NAME_LENGTH]u8,
}

view :: proc(s: ^engine.Session) -> ^View {return engine.game_state(s, View)}

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
		}
	}
	if split, ok := engine.game_value(s, r, rally.Split); ok && split != nil {
		gate :=
			"FINISH" if split.checkpoint == rally.CHECKPOINTS else fmt.tprintf("GATE %d", split.checkpoint)
		if split.compared {
			text := fmt.tprintf(
				"%s  %s  %s",
				gate,
				rally.clock(split.ticks),
				rally.delta(split.delta),
			)
			engine.flash(&v.split, s, text, .Good if split.delta < 0 else .Warn)
		} else {
			engine.flash(
				&v.split,
				s,
				fmt.tprintf("%s  %s", gate, rally.clock(split.ticks)),
				.Plain,
			)
		}
	}
	if f, ok := engine.game_value(s, r, rally.Finish); ok && f != nil {
		mine := f.name == mine(s).name
		switch {
		case f.record:
			engine.flash(
				&v.finish,
				s,
				fmt.tprintf("COURSE RECORD: %s %s", f.name, rally.clock(f.ticks)),
				.Good,
				5,
			)
		case mine && f.personal:
			engine.flash(
				&v.finish,
				s,
				fmt.tprintf("PERSONAL BEST: %s", rally.clock(f.ticks)),
				.Good,
				5,
			)
		case mine:
			engine.flash(
				&v.finish,
				s,
				fmt.tprintf("FINISHED: %s", rally.clock(f.ticks)),
				.Plain,
				5,
			)
		}
	}
}

// best_text: a time, or "-" for none.
best_text :: proc(ticks: u32) -> string {return rally.clock(ticks) if ticks > 0 else "-"}

// status: the line at the top of the screen.
status :: proc(s: ^engine.Session) -> string {
	v := view(s)
	r := v.race
	me := mine(s)
	record := "-"
	if r.record > 0 {record = fmt.tprintf("%s (%s)", rally.clock(r.record), r.record_name)}
	switch r.phase {
	case .Waiting:
		return "RALLY  waiting for racers"
	case .Countdown:
		return fmt.tprintf(
			"RALLY  race %d   starting   best %s   record %s",
			r.race,
			best_text(me.best),
			record,
		)
	case .Racing:
		where_ := fmt.tprintf("gate %d/%d", me.next, rally.CHECKPOINTS)
		switch {
		case !me.racing:
			where_ = "watching"
		case me.time > 0:
			where_ = fmt.tprintf("finished %s", rally.clock(me.time))
		}
		return fmt.tprintf(
			"RALLY  race %d   %s   %s   best %s   record %s",
			r.race,
			where_,
			rally.clock(r.ticks),
			best_text(me.best),
			record,
		)
	case .Results:
		return fmt.tprintf("RALLY  race %d over   next in %ds   record %s", r.race, r.left, record)
	}
	return ""
}

hud :: proc(s: ^engine.Session, ctx: ^ui.Context) {
	v := view(s)
	r := v.race
	if r.race == 0 {return}
	t := &ctx.theme
	rest := ctx.screen
	engine.top_bar(ctx, &rest, status(s))
	marks(s, ctx)

	switch r.phase {
	case .Waiting:
	case .Countdown:
		engine.banner(ctx, -140, fmt.tprintf("RACE %d", r.race), 1.5, t.focus_ring)
		engine.banner(ctx, -60, fmt.tprintf("%d", r.left), 1.5, t.text)
		engine.banner(ctx, 40, "Every gate in order. Hook and rockets allowed.", 0.6, t.text)
	case .Racing:
		engine.flash_draw(ctx, &v.split, s, -200, 0.8)
		engine.flash_draw(ctx, &v.finish, s, -120, 1.1)
	case .Results:
		engine.flash_draw(ctx, &v.finish, s, -250, 0.8)
		engine.banner(ctx, -180, "RACE OVER", 1.5, t.focus_ring)
		at := f32(-90)
		for b, i in ranked(v) {
			if i >= 4 {break}
			line := fmt.tprintf(
				"%d. %s  %s",
				i + 1,
				b.seat.name,
				rally.clock(b.seat.time) if b.seat.time > 0 else "did not finish",
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
		engine.banner(ctx, at + 20, fmt.tprintf("next race in %d", r.left), 0.6, t.text_muted)
	}
}

// marks: each gate's name over it, the next one to make for outlined.
marks :: proc(s: ^engine.Session, ctx: ^ui.Context) {
	v := view(s)
	me := mine(s)
	for k in 1 ..= rally.CHECKPOINTS {
		g := v.course.checkpoints[k]
		label := "FINISH" if k == rally.CHECKPOINTS else fmt.tprintf("GATE %d", k)
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
	board.title = fmt.tprintf("Rally: race %d, record %s", r.race, best_text(r.record))
	engine.scoreboard_columns(board, "Gate", "Time", "Best", "Resets")
	for b in ranked(v) {
		gate := "done" if b.seat.time > 0 else fmt.tprintf("%d/%d", b.seat.next, rally.CHECKPOINTS)
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
