package screen

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

import "client:engine"
import "client:platform"
import "client:ui"
import "common:base"
import "common:game"
import "common:starmap"
import "server:store"

// A game's page: its name and its one line, then its saves and only its saves (a save is
// one directory under saves/ in the user data directory, or VX_SAVES, written by the
// server, server/core/save.odin: a universe, universe.cfg, or, an older save, a single
// world, world.cfg). New is at the top (sandbox's opens the creation screen,
// creation.odin; another game's asks for a name), then the saves in a list that
// scrolls, the one played last first: each its name, when it was last played and how
// long it has been played (sandbox's with its galaxy and its game mode). A click selects
// a save, a double-click (or Confirm) plays it; Play, Rename, Delete (asked first) and
// Export act on the selected one, Import brings an exported save in, Back returns to the
// games. A game whose rounds keep nothing (engine.game_keeps) has a page with Play
// alone. Players see "universe" in sandbox; the code says universe for every save. Chosen
// to host (Multiplayer's Host: Singleplayer_Screen.host), the page says so under its line
// and its Play is Host: the world it starts opens to the LAN as soon as it plays.

DOUBLE_CLICK :: 400 * time.Millisecond // (the multiplayer list's)

// saves_override: where the saves are, for the tests (each on its own thread:
// the environment is shared by all of them).
@(thread_local)
saves_override: string

// saves_dir: VX_SAVES, else voxiverse/saves in the user data directory.
saves_dir :: proc() -> string {
	if saves_override != "" {return saves_override}
	if p, set := base.boot_info().env.saves.?; set && p != "" {return p}
	dir := base.boot_info().dirs.data
	if dir == "" {return "saves"}
	return filepath.join({dir, "voxiverse", "saves"}, context.temp_allocator) or_else "saves"
}

universes_destroy :: proc(w: ^engine.Universes_Screen) {
	worlds_clear(w)
	delete(w.entries)
	delete(w.name)
	delete(w.path)
	delete(w.message)
}

@(private = "file")
worlds_clear :: proc(w: ^engine.Universes_Screen) {
	for e in w.entries {
		delete(e.name)
		delete(e.path)
		delete(e.mode)
		delete(e.game_id)
	}
	clear(&w.entries)
}

// universes_refresh lists the saves of every game: directories with a universe.cfg, or a
// world.cfg (from before universes), most recently played first. The page's first save
// is selected.
universes_refresh :: proc(w: ^engine.Universes_Screen) {
	worlds_clear(w)
	w.mode, w.list = .List, {}
	w.last.checked = false // (Continue looks again: a save may have gone)
	message_set(w, "")
	dir := saves_dir()
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {return} 	// no saves yet
	for e in entries {
		if e.type != .Directory {continue}
		for file in ([]string{"universe.cfg", "world.cfg"}) {
			cfg := filepath.join({e.fullpath, file}, context.temp_allocator) or_else ""
			info, stat_err := os.stat(cfg, context.temp_allocator)
			if stat_err != nil {continue}
			entry := engine.Save_Entry {
				name   = strings.clone(e.name),
				path   = strings.clone(e.fullpath),
				played = info.modification_time,
			}
			entry_read_config(&entry, cfg)
			append(&w.entries, entry)
			break
		}
	}
	slice.sort_by(
		w.entries[:],
		proc(a, b: engine.Save_Entry) -> bool {return time.diff(b.played, a.played) > 0},
	)
}

// save_played: the save at path is the one played last (the title's Continue). Kept in
// the settings by its name; one too long for them is not kept, and Continue shows none.
save_played :: proc(app: ^engine.App, path: string) {
	if !base.var_text_set(&app.settings.last_save, filepath.base(path)) {
		base.var_text_set(&app.settings.last_save, "")
	}
	engine.settings_changed(app)
}

// continue_save: the save played last, to continue: the name of the game it plays and
// its own name; not ok when there is none, it is gone or unreadable, or its game is not in
// this build. Read from the disk once, then as the saves change (Last_Save).
continue_save :: proc(app: ^engine.App) -> (game_name, name: string, ok: bool) {
	c := &app.universes.last
	want := base.var_text(&app.settings.last_save)
	if !c.checked || base.var_text(&c.name) != want {
		c.checked, c.name, c.game = true, app.settings.last_save, ""
		cfg :=
			filepath.join({saves_dir(), want, "universe.cfg"}, context.temp_allocator) or_else ""
		if want != "" && save_dir_name(want) == want && os.is_file(cfg) {
			e: engine.Save_Entry
			entry_read_config(&e, cfg)
			id := entry_game(&e)
			if g, known := engine.game_find(app.games, id);
			   known && engine.game_hostable(app, id) {
				c.game = g.name
			}
			delete(e.mode)
			delete(e.game_id)
		}
	}
	return c.game, base.var_text(&c.name), c.game != ""
}

// continue_play enters the save played last (continue_save), alone.
continue_play :: proc(app: ^engine.App) {
	_, name, ok := continue_save(app)
	if !ok {return}
	path := filepath.join({saves_dir(), name}, context.temp_allocator) or_else name
	if universe_enter(app, path) != "" {app.universes.last.checked = false}
}

// page_back: Back from a game's page: to the games, to host one still if it was hosting.
page_back :: proc(app: ^engine.App) {
	singleplayer_open(app, app.singleplayer.host)
}

// universes_open: the page of the game id (constant data), its saves read.
universes_open :: proc(app: ^engine.App, id: string) {
	app.universes.game = id
	universes_refresh(&app.universes)
	app.screen = .Universes
}

// page_game: the game whose page it is ("" before one was opened: the default game's).
page_game :: proc(w: ^engine.Universes_Screen) -> string {
	return w.game if w.game != "" else game.DEFAULT_GAME
}

// page_saves: the page's saves, as places in entries (temp allocator).
page_saves :: proc(w: ^engine.Universes_Screen) -> []int {
	shown := make([dynamic]int, 0, len(w.entries), context.temp_allocator)
	for &e, i in w.entries {if entry_game(&e) == page_game(w) {append(&shown, i)}}
	return shown[:]
}

// page_selected: the selected save's place in entries (-1: none).
page_selected :: proc(w: ^engine.Universes_Screen) -> int {
	shown := page_saves(w)
	s := w.list.selected
	return shown[s] if s >= 0 && s < len(shown) else -1
}

@(private = "file")
message_set :: proc(w: ^engine.Universes_Screen, text: string) {
	delete(w.message)
	w.message = strings.clone(text) if text != "" else ""
}

// entry_read_config takes what a save's row shows from the universe's config file:
// the seed (a thumbnail is its galaxy), the game it plays, the game mode and whether
// it changed, and its age (the time played).
@(private = "file")
entry_read_config :: proc(e: ^engine.Save_Entry, cfg: string) {
	data, err := os.read_entire_file_from_path(cfg, context.temp_allocator)
	if err != nil {return}
	for l in base.config_lines(string(data)) {
		value := l.value
		switch l.key {
		case "":
			log.warnf("universes line ignored path=%s line=%d text=%q", cfg, l.number, l.text)
		case "seed":
			if n, ok := strconv.parse_i64(value); ok {e.seed = u64(n)}
		case "mode":
			e.mode = strings.clone(value)
		case "game":
			e.game_id = strings.clone(value)
		case "mode_changed":
			e.mode_changed = value == "true"
		case "age":
			if n, ok := strconv.parse_i64(value); ok && n > 0 {e.age = n}
		}
	}
	starmap.galaxy_stars(starmap.seed_glyphs(e.seed), e.stars[:])
}

// save_dir_name: a save's name as a directory name (letters, digits,
// spaces, - and _; anything else becomes _), "" if nothing is left.
save_dir_name :: proc(name: string) -> string {
	clean := strings.builder_make(context.temp_allocator)
	for r in strings.trim_space(name) {
		ok :=
			r >= 'a' && r <= 'z' ||
			r >= 'A' && r <= 'Z' ||
			r >= '0' && r <= '9' ||
			r == ' ' ||
			r == '-' ||
			r == '_'
		strings.write_rune(&clean, r if ok else '_')
	}
	return strings.to_string(clean)
}

// free_save_path: the path for a save called name, numbered if taken.
@(private = "file")
free_save_path :: proc(name: string) -> string {
	path := filepath.join({saves_dir(), name}, context.temp_allocator) or_else name
	for i := 2; os.exists(path); i += 1 {
		path =
			filepath.join(
				{saves_dir(), fmt.tprintf("%s (%d)", name, i)},
				context.temp_allocator,
			) or_else name
	}
	return path
}

// Universe_Plan: what Ignite (or a console command) creates.
Universe_Plan :: struct {
	path:  string, // the directory (a free variant of the name)
	seed:  u64,
	mode:  string,
	earth: bool, // the home world is Earth (else made from the seed)
}

// universe_plan: the directory for a universe called name (a free variant
// of it, "New Universe" if nothing is left of it), with its seed and mode.
universe_plan :: proc(name: string, seed: u64, mode: string, earth := false) -> Universe_Plan {
	base_name := save_dir_name(name)
	if base_name == "" {base_name = "New Universe"}
	return {free_save_path(base_name), seed, mode, earth}
}

// world_create makes a directory for a new universe named name (a free
// variant of it) and enters it; seed_text may be a number, any text (hashed)
// or empty (random); earth: its home world is Earth (else one made from the
// seed). The creation screen does the same from its fields.
world_create :: proc(app: ^engine.App, name, seed_text: string, earth := false) {
	seed, typed := starmap.seed_of_text(seed_text)
	if !typed {seed = u64(time.now()._nsec) ~ 0x5eed_5eed}
	plan := universe_plan(name, seed, "creative", earth)
	log.infof(
		"saves creating name=%q seed=%d earth=%v",
		filepath.base(plan.path),
		i64(plan.seed),
		earth,
	)
	engine.enter_world(app, plan.path, i64(plan.seed), mode = plan.mode, earth = plan.earth)
	if app.session != nil {save_played(app, plan.path)}
}

// save_create makes a new save of the game id called name (a free variant of it) and
// enters it: a game other than sandbox, on the world the game is made on (the scratch
// world's seed), as its Play in a scratch world was; open_lan: opened to the LAN.
save_create :: proc(app: ^engine.App, id, name: string, open_lan := false) {
	plan := universe_plan(name, engine.SCRATCH_SEED, "creative")
	log.infof("saves creating name=%q game=%s", filepath.base(plan.path), id)
	engine.enter_world(app, plan.path, i64(plan.seed), game_id = id, open_lan = open_lan)
	if app.session != nil {save_played(app, plan.path)}
}

// last_played: when a save was last played, as people say it.
last_played :: proc(t, now: time.Time) -> string {
	ago := time.duration_seconds(time.diff(t, now))
	switch {
	case ago < 60:
		return engine.tr(.Universes_Last_Just_Now)
	case ago < 3600:
		return engine.tr(.Universes_Last_Minutes, int(ago / 60))
	case ago < 86400:
		return engine.tr(.Universes_Last_Hours, int(ago / 3600))
	case ago < 2 * 86400:
		return engine.tr(.Universes_Last_Yesterday)
	case ago < 30 * 86400:
		return engine.tr(.Universes_Last_Days, int(ago / 86400))
	}
	y, m, d := time.date(t)
	return fmt.tprintf("%d %v %d", d, m, y)
}

// time_played: how long a save has been played (its age in ticks), as people say it.
time_played :: proc(ticks: i64) -> string {
	minutes := ticks / (game.TICK_RATE * 60)
	switch {
	case minutes < 1:
		return engine.tr(.Universes_Time_Under_Minute)
	case minutes < 60:
		return engine.tr(.Universes_Time_Minutes, minutes)
	}
	return engine.tr(.Universes_Time_Hours, minutes / 60, minutes % 60)
}

universes_screen :: proc(app: ^engine.App, ctx: ^ui.Context) {
	ui.push_id(ctx, "saves")
	defer ui.pop_id(ctx)
	w := &app.universes
	if !engine.game_keeps(app, page_game(w)) {
		play_page(app, ctx)
		return
	}
	switch w.mode {
	case .List:
		saves_list(app, ctx)
	case .New:
		saves_list(app, ctx)
		save_new_dialog(app, ctx)
	case .Edit:
		save_edit(app, ctx)
	case .Delete:
		saves_list(app, ctx)
		save_delete_confirm(app, ctx)
	case .Import:
		saves_list(app, ctx)
		save_import_dialog(app, ctx)
	}
}

SAVE_ROW :: 64 // a save's row
SAVES_WIDTH :: 640
THUMB :: 48

// page_heading: the game's name and its one line, cut from the top of area.
@(private = "file")
page_heading :: proc(app: ^engine.App, ctx: ^ui.Context, area: ^ui.Rect) {
	t := &ctx.theme
	w := &app.universes
	name, about := page_game(w), ""
	if g, known := engine.game_find(app.games, page_game(w)); known {
		name, about = g.name, g.description
	}
	ui.title(ctx, name, ui.cut_top(area, 60))
	ui.draw_text(ctx, ui.cut_top(area, 24), about, t.font_size * GAME_ABOUT, t.text_muted, .Center)
	if app.singleplayer.host {
		ui.draw_text(
			ctx,
			ui.cut_top(area, 24),
			engine.tr(.Multiplayer_Host_Note),
			t.font_size * GAME_ABOUT,
			t.text,
			.Center,
		)
	}
	ui.cut_top(area, 2 * t.spacing)
}

// play_text: what the page's Play says: Host while hosting.
@(private = "file")
play_text :: proc(app: ^engine.App) -> string {
	return engine.tr(.Multiplayer_Host if app.singleplayer.host else .Universes_Play)
}

// play_page: the page of a game whose rounds keep nothing: Play, in a world kept
// nowhere, and Back.
@(private = "file")
play_page :: proc(app: ^engine.App, ctx: ^ui.Context) {
	t := &ctx.theme
	w := &app.universes
	area := ui.rect_center(
		ctx.screen,
		SAVES_WIDTH,
		84 + 24 + 2 * t.spacing + 4 * t.row_height + 3 * t.spacing,
	)
	page_heading(app, ctx, &area)
	name := page_game(w)
	if g, known := engine.game_find(app.games, name); known {name = g.name}
	ui.label(
		ctx,
		engine.tr(.Universes_Keeps_Nothing, name),
		ui.cut_top(&area, t.row_height),
		.Center,
		t.text_muted,
	)
	ui.cut_top(&area, t.spacing)
	if w.message !=
	   "" {ui.label(ctx, w.message, ui.cut_top(&area, t.row_height), .Center, t.text_muted)}
	column := ui.rect_center(area, 300, 2 * t.row_height + t.spacing)
	ui.begin_column(ctx, column)
	defer ui.end_column(ctx)
	ui.default_focus(ctx)
	if ui.button(ctx, play_text(app), ui.next(ctx)) {
		if engine.game_hostable(app, page_game(w)) {
			app.launch = page_game(w) // (the frame starts it: play_game)
		} else {
			message_set(w, engine.tr(.Universes_Game_Missing, page_game(w)))
		}
	}
	if ui.button(ctx, engine.tr(.Credits_Back), ui.next(ctx)) {page_back(app)}
}

@(private = "file")
saves_list :: proc(app: ^engine.App, ctx: ^ui.Context) {
	w := &app.universes
	t := &ctx.theme
	sandbox := page_game(w) == game.DEFAULT_GAME
	shown := page_saves(w)
	area := ui.rect_center(ctx.screen, SAVES_WIDTH, ctx.screen.h - 40)
	page_heading(app, ctx, &area)
	// New, first: what a page without saves is for.
	ui.default_focus(ctx)
	new_text := engine.tr(.Universes_New_Universe if sandbox else .Universes_New_Save)
	if ui.button(ctx, new_text, ui.cut_top(&area, t.row_height)) {
		if sandbox {
			creation_open(app)
		} else {
			name, _ := engine.game_find(app.games, page_game(w))
			clear(&w.name)
			append(
				&w.name,
				engine.tr(
					.Universes_Default_Name,
					name.name if name != nil else page_game(w),
					len(shown) + 1,
				),
			)
			w.mode = .New
			message_set(w, "")
		}
		return
	}
	ui.cut_top(&area, t.spacing)
	buttons := ui.cut_bottom(&area, 2 * t.row_height + t.spacing)
	ui.cut_bottom(&area, 2 * t.spacing)
	if w.message !=
	   "" {ui.label(ctx, w.message, ui.cut_bottom(&area, t.row_height), .Center, t.text_muted)}

	view := ui.list_begin(ctx, "saves", area, len(shown), SAVE_ROW, &w.list)
	play := -1
	small := t.font_size * 0.8
	for row in view.first ..< view.last {
		e := &w.entries[shown[row]]
		r, it := ui.list_row(ctx, &view, row, e.name)
		if it.clicked && card_click(w, row, time.tick_now()) {play = shown[row]}
		inner := ui.rect_shrink(r, 8)
		if sandbox {
			draw_galaxy(ctx, ui.cut_left(&inner, THUMB), e.stars[:], 1)
			ui.cut_left(&inner, 12)
		} else {
			ui.cut_left(&inner, 4)
		}
		ui.draw_text(ctx, ui.cut_top(&inner, t.font_size + 8), e.name, t.font_size, t.text, .Left)
		info := engine.tr(.Universes_Played_When, last_played(e.played, engine.app_wall(app)))
		if e.age > 0 {
			info = engine.tr(
				.Universes_Info,
				info,
				engine.tr(.Universes_Played_For, time_played(e.age)),
			)
		}
		if sandbox {
			mode := engine.tr(
				.Universes_Mode_Survival if e.mode == MODE_SURVIVAL else .Universes_Mode_Creative,
			)
			if e.mode_changed {mode = engine.tr(.Universes_Mode_Changed, mode)}
			info = engine.tr(.Universes_Info, mode, info)
		}
		ui.draw_text(ctx, ui.cut_top(&inner, small + 4), info, small, t.text_muted, .Left)
	}
	if ui.list_end(ctx, &view) {play = page_selected(w)}
	if len(shown) == 0 {
		ui.label(
			ctx,
			engine.tr(.Universes_None_Yet if sandbox else .Universes_Saves_None),
			area,
			.Center,
			t.text_muted,
		)
	}
	if play >= 0 && w.mode == .List {
		save_play(app, play)
		return
	}

	// Play, Rename, Delete for the selected save; then Export, Import and Back.
	selected := page_selected(w)
	none := selected < 0
	quarter := (buttons.w - 2 * t.spacing) / 4
	top := ui.cut_top(&buttons, t.row_height)
	ui.cut_top(&buttons, t.spacing)
	if ui.button(ctx, play_text(app), ui.cut_left(&top, 2 * quarter), disabled = none) {
		save_play(app, selected)
		return
	}
	ui.cut_left(&top, t.spacing)
	if ui.button(ctx, engine.tr(.Universes_Rename), ui.cut_left(&top, quarter), disabled = none) {
		clear(&w.name)
		append(&w.name, w.entries[selected].name)
		w.mode = .Edit
		message_set(w, "")
		return
	}
	ui.cut_left(&top, t.spacing)
	if ui.button(ctx, engine.tr(.Universes_Delete), top, disabled = none) {
		w.mode = .Delete
		return
	}
	third := (buttons.w - 2 * t.spacing) / 3
	if ui.button(
		ctx,
		engine.tr(.Universes_Export),
		ui.cut_left(&buttons, third),
		disabled = none,
	) {
		path, why := save_export(w.entries[selected].name, "")
		if why != "" {
			message_set(w, engine.tr(.Universes_Export_Failed, why))
		} else {
			engine.toast(app, .Universes_Exported_To, path)
		}
	}
	ui.cut_left(&buttons, t.spacing)
	if ui.button(ctx, engine.tr(.Universes_Import), ui.cut_left(&buttons, third)) {
		clear(&w.path)
		w.mode = .Import
		message_set(w, "")
	}
	ui.cut_left(&buttons, t.spacing)
	if ui.button(ctx, engine.tr(.Credits_Back), buttons) {page_back(app)}
}

// card_click: a click on save i at now. One click selects it; a second on the same save
// within DOUBLE_CLICK says to play it.
card_click :: proc(w: ^engine.Universes_Screen, i: int, now: time.Tick) -> (play: bool) {
	if w.last_row == i && time.tick_diff(w.last_click, now) < DOUBLE_CLICK {return true}
	w.list.selected, w.last_row, w.last_click = i, i, now
	return false
}

// save_play opens the save at i in entries (universe_enter), hosted when the page is;
// why it could not is said on the page.
save_play :: proc(app: ^engine.App, i: int) {
	w := &app.universes
	if i < 0 || i >= len(w.entries) {return}
	why := universe_enter(app, w.entries[i].path, open_lan = app.singleplayer.host)
	if why != "" {message_set(w, why)}
}

// universe_enter plays the saved universe at path with the game it records (one from
// before games were recorded played the engine's world: the default game, sandbox),
// opened to the LAN as soon as it plays if open_lan; why not (temp allocator) if this
// build lacks that game.
universe_enter :: proc(app: ^engine.App, path: string, open_lan := false) -> (why: string) {
	e: engine.Save_Entry
	defer {
		delete(e.mode)
		delete(e.game_id)
	}
	entry_read_config(&e, filepath.join({path, "universe.cfg"}, context.temp_allocator) or_else "")
	id := entry_game(&e)
	if !engine.game_hostable(app, id) {return engine.tr(.Universes_Game_Missing, id)}
	engine.enter_world(app, path, 0, game_id = id, open_lan = open_lan)
	if app.session != nil {save_played(app, path)}
	return ""
}

// entry_game: the game a universe plays.
entry_game :: proc(e: ^engine.Save_Entry) -> string {
	return e.game_id if e.game_id != "" else game.DEFAULT_GAME
}

// save_new_dialog asks a new save's name (a game other than sandbox) and makes it.
@(private = "file")
save_new_dialog :: proc(app: ^engine.App, ctx: ^ui.Context) {
	w := &app.universes
	t := &ctx.theme
	ui.push_id(ctx, "new dialog")
	defer ui.pop_id(ctx)
	prev := ui.begin_layer(ctx, .Modal)
	defer ui.end_layer(ctx, prev)
	ui.backdrop(ctx)
	box := ui.rect_center(ctx.screen, 460, 4 * t.row_height + 4 * t.spacing + 2 * t.padding)
	ui.panel(ctx, box)
	ui.layout_begin(ctx, ui.rect_shrink(box, t.padding))
	defer ui.layout_end(ctx)
	ui.label(ctx, engine.tr(.Universes_New_Save_Title), ui.next(ctx), .Center)
	ui.label(ctx, engine.tr(.Universes_Name), ui.next(ctx), .Left, t.text_muted)
	ui.default_focus(ctx)
	submitted := ui.text_input(ctx, "name", &w.name, ui.next(ctx))
	row := ui.next(ctx)
	cancel := ui.cut_right(&row, (row.w - t.spacing) / 2)
	ui.cut_right(&row, t.spacing)
	named := save_dir_name(string(w.name[:])) != ""
	if ui.button(ctx, engine.tr(.Universes_Create_Save), row, disabled = !named) ||
	   (submitted && named) {
		if !engine.game_hostable(app, page_game(w)) {
			message_set(w, engine.tr(.Universes_Game_Missing, page_game(w)))
			w.mode = .List
			return
		}
		save_create(app, page_game(w), string(w.name[:]), open_lan = app.singleplayer.host)
		w.mode = .List
		return
	}
	if ui.button(ctx, engine.tr(.Cancel), cancel) {w.mode = .List}
}

// save_import_dialog asks for the exported file's path.
@(private = "file")
save_import_dialog :: proc(app: ^engine.App, ctx: ^ui.Context) {
	w := &app.universes
	t := &ctx.theme
	ui.push_id(ctx, "import dialog")
	defer ui.pop_id(ctx)
	prev := ui.begin_layer(ctx, .Modal)
	defer ui.end_layer(ctx, prev)
	ui.backdrop(ctx)
	box := ui.rect_center(ctx.screen, 520, 3 * t.row_height + 4 * t.spacing + 2 * t.padding)
	ui.panel(ctx, box)
	ui.layout_begin(ctx, ui.rect_shrink(box, t.padding))
	defer ui.layout_end(ctx)
	ui.label(ctx, engine.tr(.Universes_Import_Path), ui.next(ctx), .Left, t.text_muted)
	submitted := ui.text_input(ctx, "path", &w.path, ui.next(ctx))
	row := ui.next(ctx)
	cancel := ui.cut_right(&row, (row.w - t.spacing) / 2)
	ui.cut_right(&row, t.spacing)
	if ui.button(ctx, engine.tr(.Universes_Import_Do), row, disabled = len(w.path) == 0) ||
	   (submitted && len(w.path) > 0) {
		_, why := save_import(strings.trim_space(string(w.path[:])), "")
		universes_refresh(w)
		if why != "" {message_set(w, engine.tr(.Universes_Import_Failed, why))}
		return
	}
	if ui.button(ctx, engine.tr(.Cancel), cancel) {w.mode = .List}
}

@(private = "file")
save_edit :: proc(app: ^engine.App, ctx: ^ui.Context) {
	w := &app.universes
	t := &ctx.theme
	selected := page_selected(w)
	if selected < 0 {
		w.mode = .List
		return
	}
	e := w.entries[selected]
	column := ui.rect_center(ctx.screen, 420, 7 * (t.row_height + t.spacing) + 70)
	ui.title(ctx, engine.tr(.Universes_Rename_Title), ui.cut_top(&column, 70))
	ui.layout_begin(ctx, column)
	defer ui.layout_end(ctx)
	ui.label(ctx, engine.tr(.Universes_Name), ui.next(ctx), .Left, t.text_muted)
	submitted := ui.text_input(ctx, "name", &w.name, ui.next(ctx))
	if ui.button(ctx, engine.tr(.Universes_Open_Folder), ui.next(ctx)) {
		if !platform.open_folder(e.path) {message_set(w, engine.tr(.Universes_Folder_Failed))}
	}
	if w.message != "" {ui.label(ctx, w.message, ui.next(ctx), .Center, t.text_muted)}
	ui.next(ctx, 10)
	row := ui.next(ctx)
	cancel := ui.cut_right(&row, (row.w - t.spacing) / 2)
	ui.cut_right(&row, t.spacing)
	if ui.button(ctx, engine.tr(.Universes_Save), row) || submitted {
		name := save_dir_name(string(w.name[:]))
		if name != "" && name != e.name {
			path := free_save_path(name)
			if err := os.rename(e.path, path); err != nil {
				log.errorf("saves cannot rename from=%s to=%s error=%v", e.path, path, err)
				message_set(w, engine.tr(.Universes_Rename_Failed))
				return
			}
			if base.var_text(&app.settings.last_save) == e.name {save_played(app, path)} 	// (Continue follows it)
		}
		universes_refresh(w)
		return
	}
	if ui.button(ctx, engine.tr(.Cancel), cancel) {w.mode = .List}
}

@(private = "file")
save_delete_confirm :: proc(app: ^engine.App, ctx: ^ui.Context) {
	w := &app.universes
	t := &ctx.theme
	selected := page_selected(w)
	if selected < 0 {
		w.mode = .List
		return
	}
	e := w.entries[selected]
	ui.push_id(ctx, "delete dialog") // (its Delete is not the page's)
	defer ui.pop_id(ctx)
	prev := ui.begin_layer(ctx, .Modal)
	defer ui.end_layer(ctx, prev)
	ui.backdrop(ctx)
	box := ui.rect_center(ctx.screen, 460, 170)
	ui.panel(ctx, box)
	inner := ui.rect_shrink(box, 2 * t.padding)
	ui.label(
		ctx,
		engine.tr(.Universes_Delete_Named, e.name),
		ui.cut_top(&inner, t.row_height),
		.Center,
	)
	ui.label(
		ctx,
		engine.tr(.Universes_It_Will_Be_Lost_Forever),
		ui.cut_top(&inner, t.row_height),
		.Center,
		t.text_muted,
	)
	buttons := ui.cut_bottom(&inner, t.row_height)
	cancel := ui.cut_right(&buttons, (buttons.w - t.spacing) / 2)
	ui.cut_right(&buttons, t.spacing)
	if ui.button(ctx, engine.tr(.Universes_Delete), buttons) {
		if err := os.remove_all(e.path); err != nil {
			log.errorf("saves cannot delete path=%s error=%v", e.path, err)
		}
		universes_refresh(w)
		return
	}
	ui.default_focus(ctx)
	if ui.button(ctx, engine.tr(.Cancel), cancel) {w.mode = .List}
}

// save_export writes the save called name as one file (default <saves>/<name>.vxu)
// and says where; "" and why if it could not (a save being played is open: close it
// first).
save_export :: proc(name, file: string) -> (path, problem: string) {
	dir := filepath.join({saves_dir(), name}, context.temp_allocator) or_else name
	if !os.exists(dir) {return "", fmt.tprintf("there is no save called %s", name)}
	path = file
	if path == "" {
		path =
			filepath.join(
				{saves_dir(), fmt.tprintf("%s.vxu", name)},
				context.temp_allocator,
			) or_else name
	}
	if why := store.universe_export(dir, path, &base.Disk{}); why != "" {return "", why}
	return path, ""
}

// save_import makes a new save from an export file (named name, or after the
// file; numbered if the name is taken) and says where; "" and why if it could not.
save_import :: proc(file, name: string) -> (path, problem: string) {
	name := name
	if name == "" {
		name = save_dir_name(strings.trim_suffix(filepath.base(file), filepath.ext(file)))
		if name == "" {name = "Imported"}
	}
	path = free_save_path(name)
	if why := store.universe_import(file, path, &base.Disk{}); why != "" {return "", why}
	return path, ""
}
