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

import "../ui"

// Saved worlds: one directory each under saves/ in the user data directory
// (or VX_SAVES), written by the server (server/save.odin). The Worlds
// screen lists them newest first and creates, plays and deletes them.

World_Entry :: struct {
	name:     string, // the directory's name
	path:     string,
	modified: time.Time,
}

Worlds_Screen :: struct {
	entries:  [dynamic]World_Entry,
	name:     [dynamic]u8, // the new world's
	seed:     [dynamic]u8,
	deleting: int, // index of the world awaiting confirmation; -1 none
}

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

// worlds_refresh lists the saved worlds (directories with a world.cfg).
worlds_refresh :: proc(w: ^Worlds_Screen) {
	worlds_clear(w)
	w.deleting = -1
	dir := saves_dir()
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {return} 	// no saves yet
	for e in entries {
		if e.type != .Directory {continue}
		cfg := filepath.join({e.fullpath, "world.cfg"}, context.temp_allocator) or_else ""
		info, stat_err := os.stat(cfg, context.temp_allocator)
		if stat_err != nil {continue}
		append(
			&w.entries,
			World_Entry{strings.clone(e.name), strings.clone(e.fullpath), info.modification_time},
		)
	}
	slice.sort_by(
		w.entries[:],
		proc(a, b: World_Entry) -> bool {return time.diff(b.modified, a.modified) < 0},
	)
}

// world_create makes a directory for a new world named name (a free
// variant of it) and enters it; seed_text may be a number, any text (hashed)
// or empty (random).
world_create :: proc(app: ^App, name, seed_text: string) {
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
	base_name := strings.to_string(clean)
	if base_name == "" {base_name = "World"}
	path := filepath.join({saves_dir(), base_name}, context.temp_allocator) or_else base_name
	for i := 2; os.exists(path); i += 1 {
		path =
			filepath.join(
				{saves_dir(), fmt.tprintf("%s (%d)", base_name, i)},
				context.temp_allocator,
			) or_else base_name
	}
	seed: i64
	text := strings.trim_space(seed_text)
	if n, ok := strconv.parse_i64(text); ok {
		seed = n
	} else if text != "" {
		seed = i64(hash.fnv64a(transmute([]u8)text))
	} else {
		seed = time.now()._nsec ~ 0x5eed_5eed
	}
	log.infof("worlds creating name=%q seed=%d", base_name, seed)
	enter_world(app, path, seed)
}

worlds_screen :: proc(app: ^App, ctx: ^ui.Context) {
	ui.push_id(ctx, "worlds")
	defer ui.pop_id(ctx)
	w := &app.worlds
	t := &ctx.theme
	column := ui.rect_center(ctx.screen, 620, ctx.screen.h - 80)
	ui.title(ctx, "Universes", ui.cut_top(&column, 80))
	ui.layout_begin(ctx, column)
	defer ui.layout_end(ctx)

	ui.label(ctx, "New world", ui.next(ctx), .Left, t.text_muted)
	ui.text_input(ctx, "name", &w.name, ui.next(ctx), placeholder = "Name")
	ui.text_input(ctx, "seed", &w.seed, ui.next(ctx), placeholder = "Seed (optional)")
	if ui.button(ctx, "Create and Play", ui.next(ctx)) {
		world_create(app, string(w.name[:]), string(w.seed[:]))
		clear(&w.name)
		clear(&w.seed)
		return
	}
	ui.next(ctx, 10)
	if len(w.entries) > 0 {ui.label(ctx, "Saved worlds", ui.next(ctx), .Left, t.text_muted)}
	for e, i in w.entries {
		ui.push_id(ctx, e.name)
		row := ui.next(ctx)
		delete_button := ui.cut_right(&row, 110)
		ui.cut_right(&row, t.spacing)
		if w.deleting == i {
			ui.label(ctx, fmt.tprintf("Delete %s for good?", e.name), row, .Left)
			if ui.button(ctx, "Delete", delete_button) {
				if err := os.remove_all(e.path); err != nil {
					log.errorf("worlds cannot delete path=%s error=%v", e.path, err)
				}
				ui.pop_id(ctx)
				worlds_refresh(w)
				return
			}
		} else {
			if ui.button(ctx, e.name, row) {
				enter_world(app, e.path, 0)
				ui.pop_id(ctx)
				return
			}
			if ui.button(ctx, "Delete", delete_button) {w.deleting = i}
		}
		ui.pop_id(ctx)
	}
	ui.next(ctx, 10)
	if ui.button(ctx, "Back", ui.next(ctx)) {app.screen = .Title}
}
