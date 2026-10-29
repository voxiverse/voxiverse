package client

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

import "../base"
import "../common/game"
import "../server"
import "platform"
import "ui"

// Singleplayer's saves (docs/plan.md M20, M48e): one
// directory each under saves/ in the user data directory (or VX_SAVES),
// written by the server (server/save.odin): a universe (universe.cfg) or,
// from before M17, a single world (world.cfg). The screen shows them as
// cards, the one played last first: a galaxy thumbnail drawn from the seed,
// the name, the game mode and when it was played. A click enters the
// universe (the server puts the character where it last stood); a card's
// "..." menu has Rename, Export and Delete (confirmed); New Universe opens
// the creation screen (screen_creation.odin) and Import brings an exported
// universe in from a file. Players see "universe"; the code says universe.

DOUBLE_CLICK :: 400 * time.Millisecond // (the multiplayer list's)

THUMB_STARS :: 400 // stars a card's thumbnail draws

Save_Entry :: struct {
	name:         string, // the directory's name (what players see)
	path:         string,
	played:       time.Time, // its config file's last change: when it was last saved
	seed:         u64, // the universe's seed (its home world's address, its galaxy)
	mode:         string, // the universe's default game mode, as universe.cfg says it
	mode_changed: bool, // /gamemode changed it since it was made
	stars:        [THUMB_STARS]game.Star, // its galaxy
}

Saves_Mode :: enum u8 {
	List,
	Menu, // a card's menu: Rename, Export, Delete
	Edit, // rename (and open the folder)
	Delete, // confirming
	Import, // asking for the file
}

Universes_Screen :: struct {
	entries:  [dynamic]Save_Entry,
	mode:     Saves_Mode,
	selected: int, // -1: none (the card the menu, rename or delete is about)
	scroll:   f32, // cards scrolled
	name:     [dynamic]u8, // Edit's name
	path:     [dynamic]u8, // Import's file
	message:  string, // why the last action failed (shown on the list)
}

// saves_override: where the saves are, for the tests (each on its own thread:
// the environment is shared by all of them).
@(thread_local)
saves_override: string

// saves_dir: VX_SAVES, else voxiverse/saves in the user data directory.
saves_dir :: proc() -> string {
	if saves_override != "" {return saves_override}
	if p, set := os.lookup_env("VX_SAVES", context.temp_allocator); set && p != "" {return p}
	dir, err := os.user_data_dir(context.temp_allocator)
	if err != nil {return "saves"}
	return filepath.join({dir, "voxiverse", "saves"}, context.temp_allocator) or_else "saves"
}

universes_destroy :: proc(w: ^Universes_Screen) {
	worlds_clear(w)
	delete(w.entries)
	delete(w.name)
	delete(w.path)
	delete(w.message)
}

@(private = "file")
worlds_clear :: proc(w: ^Universes_Screen) {
	for e in w.entries {
		delete(e.name)
		delete(e.path)
		delete(e.mode)
	}
	clear(&w.entries)
}

// universes_refresh lists the saves: directories with a universe.cfg, or a
// world.cfg (from before universes), most recently played first.
universes_refresh :: proc(w: ^Universes_Screen) {
	worlds_clear(w)
	w.selected, w.mode, w.scroll = -1, .List, 0
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
			entry := Save_Entry {
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
		proc(a, b: Save_Entry) -> bool {return time.diff(b.played, a.played) > 0},
	)
}

@(private = "file")
message_set :: proc(w: ^Universes_Screen, text: string) {
	delete(w.message)
	w.message = strings.clone(text) if text != "" else ""
}

// entry_read_config takes what a card shows from the universe's config file:
// the seed (a thumbnail is its galaxy), the game mode and whether it changed.
@(private = "file")
entry_read_config :: proc(e: ^Save_Entry, cfg: string) {
	data, err := os.read_entire_file_from_path(cfg, context.temp_allocator)
	if err != nil {return}
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		eq := strings.index_byte(line, '=')
		if eq < 0 || strings.has_prefix(line, "#") {continue}
		key, value := strings.trim_space(line[:eq]), strings.trim_space(line[eq + 1:])
		switch key {
		case "seed":
			if n, ok := strconv.parse_i64(value); ok {e.seed = u64(n)}
		case "mode":
			e.mode = strings.clone(value)
		case "mode_changed":
			e.mode_changed = value == "true"
		}
	}
	game.galaxy_stars(game.seed_glyphs(e.seed), e.stars[:])
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
	path: string, // the directory (a free variant of the name)
	seed: u64,
	mode: string,
}

// universe_plan: the directory for a universe called name (a free variant
// of it, "New Universe" if nothing is left of it), with its seed and mode.
universe_plan :: proc(name: string, seed: u64, mode: string) -> Universe_Plan {
	base_name := save_dir_name(name)
	if base_name == "" {base_name = "New Universe"}
	return {free_save_path(base_name), seed, mode}
}

// world_create makes a directory for a new universe named name (a free
// variant of it) and enters it; seed_text may be a number, any text (hashed)
// or empty (random). The creation screen does the same from its fields.
world_create :: proc(app: ^App, name, seed_text: string) {
	seed, typed := game.seed_of_text(seed_text)
	if !typed {seed = u64(time.now()._nsec) ~ 0x5eed_5eed}
	plan := universe_plan(name, seed, "creative")
	log.infof("saves creating name=%q seed=%d", filepath.base(plan.path), i64(plan.seed))
	enter_world(app, plan.path, i64(plan.seed), mode = plan.mode)
}

// last_played: when a save was last played, as people say it.
last_played :: proc(t: time.Time) -> string {
	ago := time.duration_seconds(time.diff(t, time.now()))
	switch {
	case ago < 60:
		return tr(.Universes_Last_Just_Now)
	case ago < 3600:
		return tr(.Universes_Last_Minutes, int(ago / 60))
	case ago < 86400:
		return tr(.Universes_Last_Hours, int(ago / 3600))
	case ago < 2 * 86400:
		return tr(.Universes_Last_Yesterday)
	case ago < 30 * 86400:
		return tr(.Universes_Last_Days, int(ago / 86400))
	}
	y, m, d := time.date(t)
	return fmt.tprintf("%d %v %d", d, m, y)
}

universes_screen :: proc(app: ^App, ctx: ^ui.Context) {
	ui.push_id(ctx, "saves")
	defer ui.pop_id(ctx)
	w := &app.universes
	switch w.mode {
	case .List:
		saves_list(app, ctx)
	case .Menu:
		saves_list(app, ctx)
		save_menu(app, ctx)
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

SAVE_ROW :: 104 // a universe's card
SAVES_WIDTH :: 640
THUMB :: 88

@(private = "file")
saves_list :: proc(app: ^App, ctx: ^ui.Context) {
	w := &app.universes
	t := &ctx.theme
	area := ui.rect_center(ctx.screen, SAVES_WIDTH, ctx.screen.h - 60)
	ui.title(ctx, tr(.Universes_Title), ui.cut_top(&area, 70))
	buttons := ui.cut_bottom(&area, 2 * t.row_height + t.spacing)
	ui.cut_bottom(&area, 2 * t.spacing)
	if w.message !=
	   "" {ui.label(ctx, w.message, ui.cut_top(&area, t.row_height), .Center, t.text_muted)}
	ui.fill_rect(ctx, area, t.list_fill)
	ui.stroke_rect(ctx, area, 1, t.list_border)
	if len(w.entries) == 0 {
		ui.label(ctx, tr(.Universes_None_Yet), area, .Center, t.text_muted)
	}
	visible := int(area.h / SAVE_ROW)
	first := int(w.scroll)
	enter := -1
	// One focusable widget for a pad or keyboard: Up and Down move the
	// selection, Confirm enters it; the cards below are for the mouse.
	list := ui.list_nav(ctx, "saves", area, len(w.entries), &w.selected, &first, visible, SAVE_ROW)
	w.scroll = f32(first)
	if list.clicked && w.selected >= 0 {enter = w.selected}
	ui.push_clip_rect(ctx, area)
	for i in first ..< min(len(w.entries), first + visible + 1) {
		e := &w.entries[i]
		card := ui.Rect{area.x, area.y + f32(i - first) * SAVE_ROW, area.w, SAVE_ROW}
		ui.push_id_int(ctx, i)
		it := ui.interact(ctx, ui.get_id(ctx, "card"), card, focusable = false, label = e.name)
		if it.hovered {ui.fill_rect(ctx, card, t.row_selected)}
		if w.selected == i {
			ui.fill_rect(ctx, card, t.row_hover)
			ui.stroke_rect(ctx, ui.rect_shrink(card, 1), 1, t.text)
		}
		inner := ui.rect_shrink(card, 8)
		thumb := ui.cut_left(&inner, THUMB)
		draw_galaxy(ctx, thumb, e.stars[:], 1)
		ui.cut_left(&inner, 12)
		// Its menu, on top of the card: a click here is not a click on the card.
		menu := ui.cut_right(&inner, 44)
		menu.h = t.row_height
		menu_clicked := ui.button(ctx, tr(.Universes_Card_Menu), menu)
		ui.pop_id(ctx)
		mode_text := tr(
			.Universes_Mode_Survival if e.mode == MODE_SURVIVAL else .Universes_Mode_Creative,
		)
		if e.mode_changed {mode_text = tr(.Universes_Mode_Changed, mode_text)}
		ui.draw_text(ctx, ui.cut_top(&inner, t.font_size + 8), e.name, t.font_size, t.text, .Left)
		small := t.font_size * 0.8
		ui.draw_text(
			ctx,
			ui.cut_top(&inner, small + 4),
			tr(.Universes_Card_Info, mode_text, last_played(e.played)),
			small,
			t.text_muted,
			.Left,
		)
		if menu_clicked {
			w.selected, w.mode = i, .Menu
		} else if it.clicked {
			enter = i
		}
	}
	ui.pop_clip_rect(ctx)
	if enter >= 0 && w.mode == .List {
		save_play(app, enter)
		return
	}

	half := (buttons.w - 2 * t.spacing) / 3
	top := ui.cut_top(&buttons, t.row_height)
	ui.cut_top(&buttons, t.spacing)
	if ui.button(ctx, tr(.Universes_New_Universe), ui.cut_left(&top, 2 * half + t.spacing)) {
		creation_open(app)
		return
	}
	ui.cut_left(&top, t.spacing)
	if ui.button(ctx, tr(.Universes_Import), top) {
		clear(&w.path)
		w.mode = .Import
		message_set(w, "")
	}
	if ui.button(ctx, tr(.Credits_Back), buttons) {app.screen = .Title}
}

@(private = "file")
save_play :: proc(app: ^App, i: int) {
	w := &app.universes
	if i < 0 || i >= len(w.entries) {return}
	enter_world(app, w.entries[i].path, 0)
}

// save_menu: a card's menu, over the list.
@(private = "file")
save_menu :: proc(app: ^App, ctx: ^ui.Context) {
	w := &app.universes
	t := &ctx.theme
	if w.selected < 0 || w.selected >= len(w.entries) {
		w.mode = .List
		return
	}
	e := w.entries[w.selected]
	ui.push_id(ctx, "card menu")
	defer ui.pop_id(ctx)
	prev := ui.begin_layer(ctx, .Modal)
	defer ui.end_layer(ctx, prev)
	ui.backdrop(ctx)
	box := ui.rect_center(ctx.screen, 360, 5 * t.row_height + 5 * t.spacing + 2 * t.padding)
	ui.panel(ctx, box)
	ui.layout_begin(ctx, ui.rect_shrink(box, t.padding))
	defer ui.layout_end(ctx)
	ui.label(ctx, e.name, ui.next(ctx), .Center)
	if ui.button(ctx, tr(.Universes_Rename), ui.next(ctx)) {
		clear(&w.name)
		append(&w.name, e.name)
		w.mode = .Edit
		message_set(w, "")
		return
	}
	if ui.button(ctx, tr(.Universes_Export), ui.next(ctx)) {
		path, why := save_export(e.name, "")
		w.mode = .List
		if why != "" {
			message_set(w, tr(.Universes_Export_Failed, why))
		} else {
			toast(app, .Universes_Exported_To, path)
		}
		return
	}
	if ui.button(ctx, tr(.Universes_Delete), ui.next(ctx)) {
		w.mode = .Delete
		return
	}
	ui.default_focus(ctx)
	if ui.button(ctx, tr(.Dial_Cancel), ui.next(ctx)) {w.mode = .List}
}

// save_import_dialog asks for the exported file's path.
@(private = "file")
save_import_dialog :: proc(app: ^App, ctx: ^ui.Context) {
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
	ui.label(ctx, tr(.Universes_Import_Path), ui.next(ctx), .Left, t.text_muted)
	submitted := ui.text_input(ctx, "path", &w.path, ui.next(ctx))
	row := ui.next(ctx)
	cancel := ui.cut_right(&row, (row.w - t.spacing) / 2)
	ui.cut_right(&row, t.spacing)
	if ui.button(ctx, tr(.Universes_Import_Do), row, disabled = len(w.path) == 0) ||
	   (submitted && len(w.path) > 0) {
		_, why := save_import(strings.trim_space(string(w.path[:])), "")
		universes_refresh(w)
		if why != "" {message_set(w, tr(.Universes_Import_Failed, why))}
		return
	}
	if ui.button(ctx, tr(.Dial_Cancel), cancel) {w.mode = .List}
}

@(private = "file")
save_edit :: proc(app: ^App, ctx: ^ui.Context) {
	w := &app.universes
	t := &ctx.theme
	if w.selected < 0 || w.selected >= len(w.entries) {
		w.mode = .List
		return
	}
	e := w.entries[w.selected]
	column := ui.rect_center(ctx.screen, 420, 7 * (t.row_height + t.spacing) + 70)
	ui.title(ctx, tr(.Universes_Rename_Title), ui.cut_top(&column, 70))
	ui.layout_begin(ctx, column)
	defer ui.layout_end(ctx)
	ui.label(ctx, tr(.Universes_Name), ui.next(ctx), .Left, t.text_muted)
	submitted := ui.text_input(ctx, "name", &w.name, ui.next(ctx))
	if ui.button(ctx, tr(.Universes_Open_Folder), ui.next(ctx)) {
		if !platform.open_folder(e.path) {message_set(w, tr(.Universes_Folder_Failed))}
	}
	if w.message != "" {ui.label(ctx, w.message, ui.next(ctx), .Center, t.text_muted)}
	ui.next(ctx, 10)
	row := ui.next(ctx)
	cancel := ui.cut_right(&row, (row.w - t.spacing) / 2)
	ui.cut_right(&row, t.spacing)
	if ui.button(ctx, tr(.Universes_Save), row) || submitted {
		name := save_dir_name(string(w.name[:]))
		if name != "" && name != e.name {
			path := free_save_path(name)
			if err := os.rename(e.path, path); err != nil {
				log.errorf("saves cannot rename from=%s to=%s error=%v", e.path, path, err)
				message_set(w, tr(.Universes_Rename_Failed))
				return
			}
		}
		universes_refresh(w)
		return
	}
	if ui.button(ctx, tr(.Dial_Cancel), cancel) {w.mode = .List}
}

@(private = "file")
save_delete_confirm :: proc(app: ^App, ctx: ^ui.Context) {
	w := &app.universes
	t := &ctx.theme
	if w.selected < 0 || w.selected >= len(w.entries) {
		w.mode = .List
		return
	}
	e := w.entries[w.selected]
	ui.push_id(ctx, "delete dialog") // (its Delete is not the card menu's)
	defer ui.pop_id(ctx)
	prev := ui.begin_layer(ctx, .Modal)
	defer ui.end_layer(ctx, prev)
	ui.backdrop(ctx)
	box := ui.rect_center(ctx.screen, 460, 170)
	ui.panel(ctx, box)
	inner := ui.rect_shrink(box, 2 * t.padding)
	ui.label(ctx, tr(.Universes_Delete_Named, e.name), ui.cut_top(&inner, t.row_height), .Center)
	ui.label(
		ctx,
		tr(.Universes_It_Will_Be_Lost_Forever),
		ui.cut_top(&inner, t.row_height),
		.Center,
		t.text_muted,
	)
	buttons := ui.cut_bottom(&inner, t.row_height)
	cancel := ui.cut_right(&buttons, (buttons.w - t.spacing) / 2)
	ui.cut_right(&buttons, t.spacing)
	if ui.button(ctx, tr(.Universes_Delete), buttons) {
		if err := os.remove_all(e.path); err != nil {
			log.errorf("saves cannot delete path=%s error=%v", e.path, err)
		}
		universes_refresh(w)
		return
	}
	ui.default_focus(ctx)
	if ui.button(ctx, tr(.Dial_Cancel), cancel) {w.mode = .List}
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
	if why := server.universe_export(dir, path, &base.Disk{}); why != "" {return "", why}
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
	if why := server.universe_import(file, path, &base.Disk{}); why != "" {return "", why}
	return path, ""
}
