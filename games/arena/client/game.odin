package arena_client

import "core:fmt"
import "core:strings"

import "client:engine"
import "client:ui"
import "common:game"
import "common:protocol"
import "games:arena"

// Arena's client part (the game: games/arena): it keeps the match, every fighter's
// score and the last kills as the server told them, and shows them: a line at the top
// of the HUD (the time left, your frags, the leader), the kill feed under it on the
// right, the countdown and the results big in the middle, the scoreboard while the
// player list's key is held, and a line in F3.

GAME :: engine.Game {
	info       = arena.INFO,
	kinds      = arena.KINDS,
	state      = View,
	received   = received,
	hud        = hud,
	debug      = debug,
	scoreboard = scoreboard,
}

FEED_LINES :: 5

// View: what the session knows of the match.
View :: struct {
	match:  arena.Match, // the server's last word (its winner is a view into winner)
	winner: [game.MAX_NAME_LENGTH]u8,
	scores: engine.Seats(arena.Score), // by player id
	feed:   [FEED_LINES]Feed_Line, // a ring, newest at feed_next - 1
	next:   int,
}

// Feed_Line: a kill as the feed says it, and when it came (the match's phase and its
// seconds: it goes FEED_SECONDS later, or with the phase).
Feed_Line :: struct {
	text:  [64]u8,
	len:   int,
	match: u16,
	phase: arena.Phase,
	at:    u16,
}

view :: proc(s: ^engine.Session) -> ^View {return engine.game_state(s, View)}

received :: proc(s: ^engine.Session, r: protocol.Received) {
	v := view(s)
	if m, ok := engine.game_value(s, r, arena.Match); ok && m != nil {
		v.match = m^
		v.match.winner = string(v.winner[:copy(v.winner[:], m.winner)])
	}
	if engine.seats_received(s, &v.scores, r) {return}
	if kill, ok := engine.game_value(s, r, arena.Kill); ok && kill != nil {
		line := &v.feed[v.next % FEED_LINES]
		v.next += 1
		text := feed_text(kill^)
		line^ = {
			match = v.match.match,
			phase = v.match.phase,
			at    = v.match.seconds,
		}
		line.len = copy(line.text[:], text)
	}
}

// feed_text: a kill as the feed says it: "killer [how] victim", or "[how] victim" for
// a death by one's own hand or the world's.
feed_text :: proc(k: arena.Kill) -> string {
	if k.by == "" {return fmt.tprintf("[%s] %s", arena.how(k), k.victim)}
	return fmt.tprintf("%s [%s] %s", k.by, arena.how(k), k.victim)
}

// ranked: the known fighters, the most frags first, then the fewest deaths, then by
// name, as player ids (temp memory).
ranked :: proc(v: ^View) -> []int {
	return engine.seats_ranked(&v.scores, proc(a, b: ^arena.Score) -> bool {
		if a.frags != b.frags {return a.frags > b.frags}
		return a.deaths < b.deaths
	})
}

// status: the line at the top of the screen.
status :: proc(s: ^engine.Session) -> string {
	v := view(s)
	m := v.match
	switch m.phase {
	case .Warmup:
		if m.players < m.needed {
			return fmt.tprintf(
				"ARENA  warm-up: waiting for players (%d of %d)",
				m.players,
				m.needed,
			)
		}
		return "ARENA  warm-up"
	case .Countdown:
		return fmt.tprintf("ARENA  match %d  starting", m.match)
	case .Playing:
		mine := engine.seat_mine(s, &v.scores)
		leader := "-"
		if all := ranked(v); len(all) > 0 {
			leader = fmt.tprintf(
				"%s %d",
				v.scores.values[all[0]].name,
				v.scores.values[all[0]].frags,
			)
		}
		return fmt.tprintf(
			"ARENA  match %d   %d:%02d left   you %d   leader %s   first to %d",
			m.match,
			m.left / 60,
			m.left % 60,
			mine.frags,
			leader,
			m.frag_limit,
		)
	case .Results:
		return fmt.tprintf("ARENA  match %d over", m.match)
	}
	return ""
}

hud :: proc(s: ^engine.Session, ctx: ^ui.Context) {
	v := view(s)
	m := v.match
	t := &ctx.theme
	rest := ctx.screen
	engine.top_bar(ctx, &rest, status(s))

	// The kill feed: under the bar on the right, newest last.
	feed := ui.rect_shrink(rest, t.padding)
	for k in 0 ..< FEED_LINES {
		line := &v.feed[(v.next + k) % FEED_LINES]
		if line.len == 0 || line.match != m.match || line.phase != m.phase {continue}
		if m.seconds - line.at >= arena.FEED_SECONDS || m.seconds < line.at {continue}
		row := ui.cut_top(&feed, t.row_height)
		text := string(line.text[:line.len])
		width := ui.measure_text(ctx, text, t.font_size) + 2 * t.padding
		ui.fill_rect(ctx, {row.x + row.w - width, row.y, width, row.h}, t.hud_fill)
		ui.draw_text(
			ctx,
			{row.x, row.y, row.w - t.padding, row.h},
			text,
			t.font_size,
			t.text,
			.Right,
		)
	}

	#partial switch m.phase {
	case .Countdown:
		engine.banner(ctx, -140, fmt.tprintf("MATCH %d", m.match), 1.5, t.focus_ring)
		engine.banner(ctx, -60, fmt.tprintf("%d", m.left), 1.5, t.text)
		rules := fmt.tprintf(
			"First to %d frags. Every kill counts; your own death costs one.",
			m.frag_limit,
		)
		engine.banner(ctx, 40, rules, 0.6, t.text)
	case .Results:
		head, color := "DRAW", t.log_warn
		if m.winner != "" {
			head = strings.to_upper(fmt.tprintf("%s wins", m.winner), context.temp_allocator)
			color = t.success if engine.seat_mine(s, &v.scores).name == m.winner else t.log_warn
		}
		engine.banner(ctx, -160, head, 1.5, color)
		engine.banner(ctx, -80, arena.frags_text(int(m.top_frags)), 0.8, t.text)
		next := fmt.tprintf("next match in %d   (hold P for the scores)", m.left)
		engine.banner(ctx, 100, next, 0.6, t.text)
	}
}

// scoreboard: every fighter of the match, ranked, with frags and deaths; yours lit.
scoreboard :: proc(s: ^engine.Session, board: ^engine.Scoreboard) {
	v := view(s)
	m := v.match
	switch m.phase {
	case .Warmup:
		board.title = "Arena: warm-up (nothing counts)"
	case .Countdown, .Playing:
		board.title = fmt.tprintf(
			"Arena: match %d, first to %d, %d:%02d left",
			m.match,
			m.frag_limit,
			m.left / 60,
			m.left % 60,
		)
	case .Results:
		board.title = fmt.tprintf("Arena: match %d is over", m.match)
	}
	engine.scoreboard_columns(board, "Frags", "Deaths")
	for id in ranked(v) {
		score := &v.scores.values[id]
		engine.scoreboard_row(
			board,
			score.name,
			fmt.tprint(score.frags),
			fmt.tprint(score.deaths),
			you = id == int(s.welcome.player),
		)
	}
}

// debug: F3's line.
debug :: proc(s: ^engine.Session) -> string {
	v := view(s)
	m := v.match
	return fmt.tprintf(
		"match %d %v  t=%ds left=%ds  frags to %d  players %d/%d  fighters %d  seed %d",
		m.match,
		m.phase,
		m.seconds,
		m.left,
		m.frag_limit,
		m.players,
		m.needed,
		len(ranked(v)),
		m.seed,
	)
}
