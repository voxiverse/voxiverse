package client

import "core:fmt"
import "core:hash"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

import "platform"
import "ui"

// Singleplayer's saves (PLAN.md M20; Minecraft's Select World): one
// directory each under saves/ in the user data directory (or VX_SAVES),
// written by the server (server/save.odin): a universe (universe.cfg) or,
// from before M17, a single world (world.cfg). The screen lists them, most
// recently played first; a save is selected with a click and played with a
// double-click or Play; Create New Save, Edit (rename, open its folder) and
// Delete (confirmed) are screens of their own. Players see "save"; the code
// says universe.

Save_Entry :: struct {
	name:   string, // the directory's name (what players see)
	path:   string,
	played: time.Time, // its config file's last change: when it was last saved
}

Saves_Mode :: enum u8 {
	List,
	Create,
	Edit,
	Delete, // confirming
}

Worlds_Screen :: struct {
	entries:    [dynamic]Save_Entry,
	mode:       Saves_Mode,
	selected:   int, // -1: none
	last_click: time.Tick, // for double-clicks
	last_row:   int,
	scroll:     f32, // rows scrolled
	name:       [dynamic]u8, // Create's or Edit's name
	seed:       [dynamic]u8,
	more:       bool, // Create's "More options" open
	message:    string, // why the last action failed (a constant)
}

DOUBLE_CLICK :: 400 * time.Millisecond

// saves_dir: VX_SAVES, else voxiverse/saves in the user data directory.
saves_dir :: proc() -> string {
	if p, set := os.lookup_env("VX_SAVES", context.temp_allocator); set && p != "" {return p}
	dir, err := os.user_data_dir(context.temp_allocator)
	if err != nil {return "saves"}
	return filepath.join({dir, "voxiverse", "saves"}, context.temp_allocator) or_else "saves"
}

worlds_destroy :: proc(w: ^Worlds_Screen) {
	worlds_clear(w)
	delete(w.entries)
	delete(w.name)
	delete(w.seed)
}

@(private = "file")
worlds_clear :: proc(w: ^Worlds_Screen) {
	for e in w.entries {
		delete(e.name)
		delete(e.path)
	}
	clear(&w.entries)
}

// worlds_refresh lists the saves: directories with a universe.cfg, or a
// world.cfg (from before universes), most recently played first.
worlds_refresh :: proc(w: ^Worlds_Screen) {
	worlds_clear(w)
	w.selected, w.mode, w.scroll, w.message = -1, .List, 0, ""
	dir := saves_dir()
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {return} 	// no saves yet
	for e in entries {
		if e.type != .Directory {continue}
		for file in ([]string{"universe.cfg", "world.cfg"}) {
			cfg := filepath.join({e.fullpath, file}, context.temp_allocator) or_else ""
			info, stat_err := os.stat(cfg, context.temp_allocator)
			if stat_err != nil {continue}
			append(
				&w.entries,
				Save_Entry {
					strings.clone(e.name),
					strings.clone(e.fullpath),
					info.modification_time,
				},
			)
			break
		}
	}
	slice.sort_by(
		w.entries[:],
		proc(a, b: Save_Entry) -> bool {return time.diff(b.played, a.played) < 0},
	)
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

// world_create makes a directory for a new world named name (a free
// variant of it) and enters it; seed_text may be a number, any text (hashed)
// or empty (random).
world_create :: proc(app: ^App, name, seed_text: string) {
	base_name := save_dir_name(name)
	if base_name == "" {base_name = "New Save"}
	path := free_save_path(base_name)
	seed: i64
	text := strings.trim_space(seed_text)
	if n, ok := strconv.parse_i64(text); ok {
		seed = n
	} else if text != "" {
		seed = i64(hash.fnv64a(transmute([]u8)text))
	} else {
		seed = time.now()._nsec ~ 0x5eed_5eed
	}
	log.infof("saves creating name=%q seed=%d", filepath.base(path), seed)
	enter_world(app, path, seed)
}

// last_played: when a save was last played, as people say it.
last_played :: proc(t: time.Time) -> string {
	ago := time.duration_seconds(time.diff(t, time.now()))
	switch {
	case ago < 60:
		return "just now"
	case ago < 3600:
		n := int(ago / 60)
		return fmt.tprintf("%d minute%s ago", n, "" if n == 1 else "s")
	case ago < 86400:
		n := int(ago / 3600)
		return fmt.tprintf("%d hour%s ago", n, "" if n == 1 else "s")
	case ago < 2 * 86400:
		return "yesterday"
	case ago < 30 * 86400:
		return fmt.tprintf("%d days ago", int(ago / 86400))
	}
	y, m, d := time.date(t)
	return fmt.tprintf("%d %v %d", d, m, y)
}

worlds_screen :: proc(app: ^App, ctx: ^ui.Context) {
	ui.push_id(ctx, "saves")
	defer ui.pop_id(ctx)
	w := &app.worlds
	switch w.mode {
	case .List:
		saves_list(app, ctx)
	case .Create:
		save_create(app, ctx)
	case .Edit:
		save_edit(app, ctx)
	case .Delete:
		saves_list(app, ctx)
		save_delete_confirm(app, ctx)
	}
}

SAVE_ROW :: 56 // a save's row: its name, and when it was last played
SAVES_WIDTH :: 620

@(private = "file")
saves_list :: proc(app: ^App, ctx: ^ui.Context) {
	w := &app.worlds
	t := &ctx.theme
	area := ui.rect_center(ctx.screen, SAVES_WIDTH, ctx.screen.h - 60)
	ui.title(ctx, "Singleplayer", ui.cut_top(&area, 70))
	buttons := ui.cut_bottom(&area, 2 * t.row_height + t.spacing)
	ui.cut_bottom(&area, 2 * t.spacing)
	// The list, scrolled by the wheel.
	ui.fill_rect(ctx, area, {0, 0, 0, 140})
	ui.stroke_rect(ctx, area, 1, {255, 255, 255, 50})
	if len(w.entries) == 0 {
		ui.label(ctx, "No saves yet: Create New Save to start one", area, .Center, t.text_muted)
	}
	visible := int(area.h / SAVE_ROW)
	if ui.rect_contains(area, ctx.input.mouse) && ctx.input.wheel.y != 0 {
		w.scroll -= ctx.input.wheel.y
	}
	w.scroll = clamp(w.scroll, 0, f32(max(0, len(w.entries) - visible)))
	ui.push_clip_rect(ctx, area)
	first := int(w.scroll)
	for i in first ..< min(len(w.entries), first + visible + 1) {
		e := w.entries[i]
		row := ui.Rect{area.x, area.y + f32(i - first) * SAVE_ROW, area.w, SAVE_ROW}
		ui.push_id_int(ctx, i)
		it := ui.interact(ctx, ui.get_id(ctx, "row"), row, label = e.name)
		ui.pop_id(ctx)
		if it.clicked {
			if w.last_row == i && time.tick_since(w.last_click) < DOUBLE_CLICK {
				ui.pop_clip_rect(ctx)
				save_play(app, i)
				return
			}
			w.selected, w.last_row, w.last_click = i, i, time.tick_now()
		}
		if w.selected == i {
			ui.fill_rect(ctx, row, {255, 255, 255, 40})
			ui.stroke_rect(ctx, ui.rect_shrink(row, 1), 1, t.text)
		} else if it.hovered {
			ui.fill_rect(ctx, row, {255, 255, 255, 18})
		}
		text := ui.rect_shrink(row, 10)
		ui.draw_text(ctx, ui.cut_top(&text, t.font_size), e.name, t.font_size, t.text, .Left)
		small := t.font_size * 0.8
		ui.draw_text(
			ctx,
			ui.cut_bottom(&text, small),
			fmt.tprintf("Last played %s", last_played(e.played)),
			small,
			t.text_muted,
			.Left,
		)
	}
	ui.pop_clip_rect(ctx)

	// Minecraft's two rows: Play and Create; Edit, Delete and Back.
	half := (buttons.w - t.spacing) / 2
	top := ui.cut_top(&buttons, t.row_height)
	ui.cut_top(&buttons, t.spacing)
	chosen := w.selected >= 0 && w.selected < len(w.entries)
	if ui.button(ctx, "Play Selected Save", ui.cut_left(&top, half), disabled = !chosen) {
		save_play(app, w.selected)
		return
	}
	ui.cut_left(&top, t.spacing)
	if ui.button(ctx, "Create New Save", top) {
		clear(&w.name)
		append(&w.name, "New Save")
		clear(&w.seed)
		w.more, w.mode, w.message = false, .Create, ""
	}
	third := (buttons.w - 2 * t.spacing) / 3
	if ui.button(ctx, "Edit", ui.cut_left(&buttons, third), disabled = !chosen) {
		clear(&w.name)
		append(&w.name, w.entries[w.selected].name)
		w.mode, w.message = .Edit, ""
	}
	ui.cut_left(&buttons, t.spacing)
	if ui.button(
		ctx,
		"Delete",
		ui.cut_left(&buttons, third),
		disabled = !chosen,
	) {w.mode = .Delete}
	ui.cut_left(&buttons, t.spacing)
	if ui.button(ctx, "Back", buttons) {app.screen = .Title}
}

@(private = "file")
save_play :: proc(app: ^App, i: int) {
	w := &app.worlds
	if i < 0 || i >= len(w.entries) {return}
	enter_world(app, w.entries[i].path, 0)
}

@(private = "file")
save_create :: proc(app: ^App, ctx: ^ui.Context) {
	w := &app.worlds
	t := &ctx.theme
	column := ui.rect_center(ctx.screen, 420, 8 * (t.row_height + t.spacing) + 70)
	ui.title(ctx, "Create New Save", ui.cut_top(&column, 70))
	ui.layout_begin(ctx, column)
	defer ui.layout_end(ctx)
	ui.label(ctx, "Name", ui.next(ctx), .Left, t.text_muted)
	submitted := ui.text_input(ctx, "name", &w.name, ui.next(ctx), placeholder = "New Save")
	if ui.button(
		ctx,
		"Fewer options" if w.more else "More options",
		ui.next(ctx),
	) {w.more = !w.more}
	if w.more {
		ui.label(ctx, "Seed (leave empty for a random world)", ui.next(ctx), .Left, t.text_muted)
		submitted ||= ui.text_input(ctx, "seed", &w.seed, ui.next(ctx), placeholder = "Random")
	}
	ui.next(ctx, 10)
	row := ui.next(ctx)
	cancel := ui.cut_right(&row, (row.w - t.spacing) / 2)
	ui.cut_right(&row, t.spacing)
	if ui.button(ctx, "Create Save", row) || submitted {
		world_create(app, string(w.name[:]), string(w.seed[:]))
		w.mode = .List
		return
	}
	if ui.button(ctx, "Cancel", cancel) {w.mode = .List}
}

@(private = "file")
save_edit :: proc(app: ^App, ctx: ^ui.Context) {
	w := &app.worlds
	t := &ctx.theme
	if w.selected < 0 || w.selected >= len(w.entries) {
		w.mode = .List
		return
	}
	e := w.entries[w.selected]
	column := ui.rect_center(ctx.screen, 420, 7 * (t.row_height + t.spacing) + 70)
	ui.title(ctx, "Edit Save", ui.cut_top(&column, 70))
	ui.layout_begin(ctx, column)
	defer ui.layout_end(ctx)
	ui.label(ctx, "Name", ui.next(ctx), .Left, t.text_muted)
	submitted := ui.text_input(ctx, "name", &w.name, ui.next(ctx))
	if ui.button(ctx, "Open Folder", ui.next(ctx)) {
		if !platform.open_folder(e.path) {w.message = "The folder could not be opened"}
	}
	if w.message != "" {ui.label(ctx, w.message, ui.next(ctx), .Center, t.text_muted)}
	ui.next(ctx, 10)
	row := ui.next(ctx)
	cancel := ui.cut_right(&row, (row.w - t.spacing) / 2)
	ui.cut_right(&row, t.spacing)
	if ui.button(ctx, "Save", row) || submitted {
		name := save_dir_name(string(w.name[:]))
		if name != "" && name != e.name {
			path := free_save_path(name)
			if err := os.rename(e.path, path); err != nil {
				log.errorf("saves cannot rename from=%s to=%s error=%v", e.path, path, err)
				w.message = "The save could not be renamed"
				return
			}
		}
		worlds_refresh(w)
		return
	}
	if ui.button(ctx, "Cancel", cancel) {w.mode, w.message = .List, ""}
}

@(private = "file")
save_delete_confirm :: proc(app: ^App, ctx: ^ui.Context) {
	w := &app.worlds
	t := &ctx.theme
	if w.selected < 0 || w.selected >= len(w.entries) {
		w.mode = .List
		return
	}
	e := w.entries[w.selected]
	ui.push_id(ctx, "delete dialog") // (its Delete is not the list's below)
	defer ui.pop_id(ctx)
	prev := ui.begin_layer(ctx, .Modal)
	defer ui.end_layer(ctx, prev)
	ui.backdrop(ctx)
	box := ui.rect_center(ctx.screen, 460, 170)
	ui.panel(ctx, box)
	inner := ui.rect_shrink(box, 2 * t.padding)
	ui.label(ctx, fmt.tprintf("Delete \"%s\"?", e.name), ui.cut_top(&inner, t.row_height), .Center)
	ui.label(
		ctx,
		"It will be lost forever.",
		ui.cut_top(&inner, t.row_height),
		.Center,
		t.text_muted,
	)
	buttons := ui.cut_bottom(&inner, t.row_height)
	cancel := ui.cut_right(&buttons, (buttons.w - t.spacing) / 2)
	ui.cut_right(&buttons, t.spacing)
	if ui.button(ctx, "Delete", buttons) {
		if err := os.remove_all(e.path); err != nil {
			log.errorf("saves cannot delete path=%s error=%v", e.path, err)
		}
		worlds_refresh(w)
		return
	}
	if ui.button(ctx, "Cancel", cancel) {w.mode = .List}
}
