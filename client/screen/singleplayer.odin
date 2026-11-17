package screen

import "client:engine"
import "client:ui"
import "common:game"

// Singleplayer: every game this build has, in a list that scrolls (the default first,
// then by folder), each its name, its one line and how many saves it has. Choosing one
// opens its page (universes.odin): that game's saves, and only that game's. Multiplayer's
// Host opens the same list to host a game (Singleplayer_Screen.host): titled so, its page
// the same, and the world started from it opens to the LAN; Back returns to Multiplayer.

SINGLEPLAYER_WIDTH :: 600 // (a game's one line is at most TITLE_WIDTH: a test holds each to it)
GAME_ROW :: 60
GAME_ABOUT :: 0.8 // a game's one line, of the theme's font size

// TITLE_WIDTH: as wide as a game's one-line description may be in GAME_ABOUT's text.
TITLE_WIDTH :: 520

// singleplayer_games: the games Singleplayer lists: this build's (App.games), the default
// first, then the rest in the list's order (by folder).
singleplayer_games :: proc(app: ^engine.App) -> []^engine.Game {
	list := make([dynamic]^engine.Game, 0, len(app.games), context.temp_allocator)
	for &g in app.games {if g.id == game.DEFAULT_GAME {append(&list, &g)}}
	for &g in app.games {if g.id != game.DEFAULT_GAME {append(&list, &g)}}
	return list[:]
}

// singleplayer_open: the list of the games, the saves read (each game's count); host: to
// host one (Multiplayer's Host).
singleplayer_open :: proc(app: ^engine.App, host := false) {
	universes_refresh(&app.universes)
	app.singleplayer.host = host
	app.screen = .Singleplayer
}

// singleplayer_back: Back from the games: to the title, or to Multiplayer when hosting.
singleplayer_back :: proc(app: ^engine.App) {
	if app.singleplayer.host {
		multiplayer_open(app)
	} else {
		app.screen = .Title
	}
}

singleplayer_screen :: proc(app: ^engine.App, ctx: ^ui.Context) {
	ui.push_id(ctx, "singleplayer")
	defer ui.pop_id(ctx)
	t := &ctx.theme
	games := singleplayer_games(app)
	area := ui.rect_center(ctx.screen, SINGLEPLAYER_WIDTH, ctx.screen.h - 60)
	if app.singleplayer.host {
		ui.title(ctx, engine.tr(.Multiplayer_Host_Title), ui.cut_top(&area, 60))
		note := ui.cut_top(&area, 24)
		ui.draw_text(
			ctx,
			note,
			engine.tr(.Multiplayer_Host_Note),
			t.font_size * GAME_ABOUT,
			t.text_muted,
			.Center,
		)
		ui.cut_top(&area, t.spacing)
	} else {
		ui.title(ctx, engine.tr(.Title_Singleplayer), ui.cut_top(&area, 70))
	}
	back := ui.cut_bottom(&area, t.row_height)
	ui.cut_bottom(&area, 2 * t.spacing)
	// The list as tall as its games, no taller than the room.
	area.h = min(area.h, f32(max(len(games), 1)) * GAME_ROW)
	state := &app.singleplayer.list
	ui.default_focus(ctx)
	view := ui.list_begin(ctx, "games", area, len(games), GAME_ROW, state)
	open := -1
	about := t.font_size * GAME_ABOUT
	for i in view.first ..< view.last {
		g := games[i]
		r, it := ui.list_row(ctx, &view, i, g.name)
		if it.clicked {open = i}
		inner := ui.rect_shrink(r, 10)
		inner.x += 4
		inner.w -= 8
		count := saves_of(&app.universes, g.id)
		if count > 0 && engine.game_keeps(app, g.id) {
			text :=
				engine.tr(.Universes_Saves_One) if count == 1 else engine.tr(.Universes_Saves_Count, count)
			ui.draw_text(ctx, inner, text, about, t.text_muted, .Right)
		}
		ui.draw_text(ctx, ui.cut_top(&inner, t.font_size + 8), g.name, t.font_size, t.text, .Left)
		ui.draw_text(ctx, inner, g.description, about, t.text_muted, .Left)
	}
	if ui.list_end(ctx, &view) {open = state.selected}
	if open >= 0 && open < len(games) {
		universes_open(app, games[open].id)
		return
	}
	if ui.button(
		ctx,
		engine.tr(.Credits_Back),
		ui.rect_center(back, 200, t.row_height),
	) {singleplayer_back(app)}
}

// saves_of: how many saves of the game id are on the disk (as last read).
saves_of :: proc(w: ^engine.Universes_Screen, id: string) -> int {
	n := 0
	for &e in w.entries {if entry_game(&e) == id {n += 1}}
	return n
}
