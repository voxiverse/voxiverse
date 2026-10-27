package client

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

import "../common/game"
import "ui"

// The statistics overlay: the counters the server keeps for the character
// (server/stats.odin) as a tree by their dotted names, a parent being the
// sum of what is below it; a search narrows it (the server filters, a page
// at a time) and a click opens or closes a group. Numbers are shown by
// unit: distances in metres, times as hours and minutes.

// Stats_Data: the page of counters the server last sent.
Stats_Data :: struct {
	lines: [dynamic]string, // "name value" (heap)
	page:  int,
	pages: int,
}

stats_data_clear :: proc(d: ^Stats_Data) {
	for l in d.lines {delete(l)}
	clear(&d.lines)
}

// stats_data_take keeps a Stats_Page.
stats_data_take :: proc(d: ^Stats_Data, p: game.Stats_Page) {
	stats_data_clear(d)
	d.page, d.pages = int(p.page), int(p.pages)
	rest := p.text
	for line in strings.split_lines_iterator(&rest) {
		if len(line) > 0 {append(&d.lines, strings.clone(line))}
	}
}

Stats_View :: struct {
	filter:   [dynamic]u8,
	asked:    string, // the filter last asked for (heap)
	asked_at: time.Tick,
	page:     int,
	scroll:   f32, // rows
	expanded: map[string]bool, // heap, keys owned
	fresh:    bool, // opened this frame: its own key press is not a tab step
}

stats_view_destroy :: proc(v: ^Stats_View) {
	delete(v.filter)
	delete(v.asked)
	for k in v.expanded {delete(k)}
	delete(v.expanded)
}

// stats_keys: the key opens the overlay (and closes it), asking for the counters.
stats_keys :: proc(app: ^App) {
	s := app.session
	if s == nil || s.state != .Playing {return}
	if app.settings.keys.stats not_in app.input.pressed {return}
	if overlay_is_open(&app.overlays, .Stats) {
		if top, _ := overlay_top(&app.overlays);
		   top == .Stats && !app.ui.edit.active {overlay_close(&app.overlays, .Stats)}
	} else if game_controls(app) {
		stats_open(app)
	}
}

stats_open :: proc(app: ^App) {
	overlay_open(&app.overlays, .Stats)
	v := &app.stats_view
	clear(&v.filter)
	v.page, v.scroll = 0, 0
	v.fresh = true
	delete(v.asked)
	v.asked = ""
	stats_ask(app)
}

// stats_ask asks the server for the page of the counters matching the filter.
@(private = "file")
stats_ask :: proc(app: ^App) {
	v := &app.stats_view
	delete(v.asked)
	v.asked = strings.clone(string(v.filter[:]))
	v.asked_at = time.tick_now()
	send_message(app.session, game.Stats_Request{filter = v.asked, page = u16(v.page)})
}

// Stats_Row: a line of the tree.
Stats_Row :: struct {
	path:  string,
	depth: int,
	leaf:  bool,
	total: u64,
}

// stats_rows: the tree of lines "name value" as rows in order: every group
// (a prefix with something below it) with its total, shown if the groups
// above it are open (all open when searching).
stats_rows :: proc(
	lines: []string,
	expanded: map[string]bool,
	searching: bool,
	allocator := context.temp_allocator,
) -> []Stats_Row {
	totals := make(map[string]u64, allocator = context.temp_allocator)
	leaves := make(map[string]bool, allocator = context.temp_allocator)
	for line in lines {
		name, _, value_text := strings.partition(line, " ")
		value, _ := strconv.parse_u64(value_text)
		leaves[name] = true
		path := name
		for {
			totals[path] += value
			dot := strings.last_index_byte(path, '.')
			if dot < 0 {break}
			path = path[:dot]
		}
	}
	paths := make([dynamic]string, context.temp_allocator)
	for p in totals {append(&paths, p)}
	slice.sort(paths[:])
	rows := make([dynamic]Stats_Row, allocator)
	for p in paths {
		visible := true
		ancestor := p
		for {
			dot := strings.last_index_byte(ancestor, '.')
			if dot < 0 {break}
			ancestor = ancestor[:dot]
			if !searching && !expanded[ancestor] {visible = false}
		}
		if !visible {continue}
		is_leaf := true
		for q in paths {
			if len(q) > len(p) && strings.has_prefix(q, p) && q[len(p)] == '.' {
				is_leaf = false
				break
			}
		}
		append(&rows, Stats_Row{p, strings.count(p, "."), is_leaf, totals[p]})
	}
	return rows[:]
}

// stats_format: a counter's number by what it measures (distances are
// centimetres, times seconds).
stats_format :: proc(path: string, value: u64) -> string {
	switch {
	case strings.has_prefix(path, "distance"):
		if value >= 100_000 {return fmt.tprintf("%.2f km", f64(value) / 100_000)}
		return fmt.tprintf("%.1f m", f64(value) / 100)
	case strings.has_prefix(path, "time"):
		h, m, sec := value / 3600, value / 60 % 60, value % 60
		if h > 0 {return fmt.tprintf("%dh %02dm", h, m)}
		if m > 0 {return fmt.tprintf("%dm %02ds", m, sec)}
		return fmt.tprintf("%ds", sec)
	}
	return thousands(value)
}

@(private = "file")
thousands :: proc(n: u64) -> string {
	s := fmt.tprintf("%d", n)
	if len(s) <= 3 {return s}
	b := strings.builder_make(context.temp_allocator)
	for c, i in s {
		if i > 0 && (len(s) - i) % 3 == 0 {strings.write_byte(&b, ',')}
		strings.write_rune(&b, c)
	}
	return strings.to_string(b)
}

// stats_ui: the overlay.
stats_ui :: proc(app: ^App, ctx: ^ui.Context, top: bool) {
	s := app.session
	if s == nil {return}
	v := &app.stats_view
	t := &ctx.theme
	prev := ui.begin_layer(ctx, .Modal)
	defer ui.end_layer(ctx, prev)
	ui.backdrop(ctx)
	panel := ui.rect_center(ctx.screen, 560, 520)
	ui.panel(ctx, panel)
	inner := ui.rect_shrink(panel, t.padding)
	fresh := v.fresh
	v.fresh = false
	if to, picked := ring_tabs(app, ctx, ui.cut_top(&inner, t.row_height), .Statistics); picked {
		ring_go(app, to)
		return
	}
	if step := menu_tab_step(app); top && !fresh && step != 0 {
		ring_go(app, ring_step(app, .Statistics, step))
		return
	}
	ui.cut_top(&inner, t.spacing)
	search := ui.cut_top(&inner, t.row_height)
	ui.text_input(ctx, "stats search", &v.filter, search, "search")
	ui.cut_top(&inner, t.spacing)
	// Asked again when the search changed (not more than four times a second).
	if string(v.filter[:]) != v.asked &&
	   time.duration_milliseconds(time.tick_since(v.asked_at)) > 250 {
		v.page, v.scroll = 0, 0
		stats_ask(app)
	}
	footer := ui.cut_bottom(&inner, t.row_height)
	data := &s.player_stats
	if data.pages > 1 {
		half := footer.w / 3
		if ui.button(ctx, "Previous", ui.cut_left(&footer, half), v.page == 0) {
			v.page -= 1
			stats_ask(app)
		}
		ui.draw_text(
			ctx,
			ui.cut_left(&footer, half),
			fmt.tprintf("Page %d of %d", data.page + 1, data.pages),
			t.font_size,
			t.text_muted,
			.Center,
		)
		if ui.button(ctx, "Next", footer, v.page + 1 >= data.pages) {
			v.page += 1
			stats_ask(app)
		}
	} else if len(data.lines) == 0 {
		ui.draw_text(
			ctx,
			footer,
			"Nothing counted yet" if len(v.filter) == 0 else "Nothing matches",
			t.font_size,
			t.text_muted,
			.Center,
		)
	}
	rows := stats_rows(data.lines[:], v.expanded, len(v.filter) > 0)
	step := t.row_height
	visible := int(inner.h / step)
	if ui.rect_contains(inner, ctx.input.mouse) {v.scroll -= ctx.input.wheel.y * 2}
	v.scroll = clamp(v.scroll, 0, f32(max(len(rows) - visible, 0)))
	ui.push_clip_rect(ctx, inner)
	defer ui.pop_clip_rect(ctx)
	first := int(v.scroll)
	for row, i in rows[min(first, len(rows)):] {
		if i >= visible {break}
		r := ui.Rect{inner.x, inner.y + f32(i) * step, inner.w, step}
		indent := f32(row.depth) * 16
		label := row.path[strings.last_index_byte(row.path, '.') + 1:]
		over := ui.rect_contains(r, ctx.input.mouse)
		if over {ui.fill_rect(ctx, r, t.hover)}
		marker := ""
		if !row.leaf {marker = "- " if v.expanded[row.path] || len(v.filter) > 0 else "+ "}
		ink := t.hover_text if over else t.text
		ui.draw_text(
			ctx,
			{r.x + indent, r.y, r.w - indent, r.h},
			fmt.tprintf("%s%s", marker, label),
			t.font_size,
			ink,
		)
		ui.draw_text(ctx, r, stats_format(row.path, row.total), t.font_size, ink, .Right)
		if top && over && !row.leaf && .Left in ctx.input.mouse_pressed {
			if v.expanded[row.path] {
				key, _ := delete_key(&v.expanded, row.path)
				delete(key)
			} else {
				v.expanded[strings.clone(row.path)] = true
			}
		}
	}
}
