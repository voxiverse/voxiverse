package arena_client

import "core:fmt"
import "core:slice"
import "core:strings"

import "client:engine"
import "client:ui"
import "common:game"
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
	scores: [game.MAX_PLAYERS]Seat, // by player id
	feed:   [FEED_LINES]Feed_Line, // a ring, newest at feed_next - 1
	next:   int,
}

// Seat: a fighter's score, as told.
Seat :: struct {
	known:    bool,
	name:     [game.MAX_NAME_LENGTH]u8,
	name_len: int,
	frags:    int,
	deaths:   int,
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

seat_name :: proc(seat: ^Seat) -> string {return string(seat.name[:seat.name_len])}

received :: proc(s: ^engine.Session, r: game.Received) {
	v := view(s)
	if m, ok := engine.game_value(s, r, arena.Match); ok && m != nil {
		v.match = m^
		v.match.winner = string(v.winner[:copy(v.winner[:], m.winner)])
	}
	if score, ok := engine.game_value(s, r, arena.Score); ok && int(r.key.a) < len(v.scores) {
		seat := &v.scores[r.key.a]
		if score == nil {
			seat^ = {}
		} else {
			seat^ = {
				known  = true,
				frags  = int(score.frags),
				deaths = int(score.deaths),
			}
			seat.name_len = copy(seat.name[:], score.name)
		}
	}
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

// Ranked: a known fighter, by its player id.
Ranked :: struct {
	id:   int,
	seat: ^Seat,
}

// ranked: the known fighters, the most frags first, then the fewest deaths, then by
// name (temp memory).
ranked :: proc(v: ^View) -> []Ranked {
	all := make([dynamic]Ranked, context.temp_allocator)
	for &seat, id in v.scores {if seat.known {append(&all, Ranked{id, &seat})}}
	slice.sort_by(all[:], proc(a, b: Ranked) -> bool {
		x, y := a.seat, b.seat
		if x.frags != y.frags {return x.frags > y.frags}
		if x.deaths != y.deaths {return x.deaths < y.deaths}
		return strings.compare(seat_name(x), seat_name(y)) < 0
	})
	return all[:]
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
		mine := &v.scores[min(int(s.welcome.player), len(v.scores) - 1)]
		leader := "-"
		if all := ranked(v); len(all) > 0 {
			leader = fmt.tprintf("%s %d", seat_name(all[0].seat), all[0].seat.frags)
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

// banner: a line of big text across the screen, centred on y, with a shadow.
banner :: proc(ctx: ^ui.Context, y: f32, text: string, size: f32, color: ui.Color) {
	r := ui.Rect{ctx.screen.x, y - size, ctx.screen.w, size * 2}
	ui.draw_text(ctx, {r.x + 3, r.y + 3, r.w, r.h}, text, size, ctx.theme.text_shadow, .Center)
	ui.draw_text(ctx, r, text, size, color, .Center)
}

hud :: proc(s: ^engine.Session, ctx: ^ui.Context) {
	v := view(s)
	m := v.match
	t := &ctx.theme
	screen := ctx.screen
	top := ui.cut_top(&screen, t.row_height + t.padding)
	ui.fill_rect(ctx, top, t.hud_fill)
	ui.draw_text(ctx, top, status(s), t.font_size, t.text, .Center)

	// The kill feed: under the bar on the right, newest last.
	feed := ui.rect_shrink(screen, t.padding)
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

	// The banners are laid out for a 720-high screen and shrink with a smaller one (the
	// engine gives the HUD only the screen below F3 while it is open).
	k := min(1, ctx.screen.h / 720)
	mid := ctx.screen.y + ctx.screen.h / 2
	big := t.title_size * 1.5 * k
	size := t.title_size * k
	#partial switch m.phase {
	case .Countdown:
		banner(ctx, mid - 140 * k, fmt.tprintf("MATCH %d", m.match), big, t.focus_ring)
		banner(ctx, mid - 60 * k, fmt.tprintf("%d", m.left), big, t.text)
		banner(
			ctx,
			mid + 40 * k,
			fmt.tprintf(
				"First to %d frags. Every kill counts; your own death costs one.",
				m.frag_limit,
			),
			size * 0.6,
			t.text,
		)
	case .Results:
		head, color := "DRAW", t.log_warn
		if m.winner != "" {
			head = strings.to_upper(fmt.tprintf("%s wins", m.winner), context.temp_allocator)
			mine := v.scores[min(int(s.welcome.player), len(v.scores) - 1)]
			color = t.success if seat_name(&mine) == m.winner else t.log_warn
		}
		banner(ctx, mid - 160 * k, head, big, color)
		banner(ctx, mid - 80 * k, fmt.tprintf("%d frags", m.top_frags), size * 0.8, t.text)
		banner(
			ctx,
			mid + 100 * k,
			fmt.tprintf("next match in %d   (hold P for the scores)", m.left),
			size * 0.6,
			t.text_muted,
		)
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
	for r in ranked(v) {
		engine.scoreboard_row(
			board,
			seat_name(r.seat),
			fmt.tprint(r.seat.frags),
			fmt.tprint(r.seat.deaths),
			you = r.id == int(s.welcome.player),
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
