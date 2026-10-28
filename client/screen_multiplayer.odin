package client

import "core:fmt"
import "core:log"
import "core:net"
import "core:strings"
import "core:time"

import "../base"
import "../common/game"
import "../common/netcode"
import "ui"

// Multiplayer (Minecraft's screen): the servers LAN discovery finds (asked
// about every second while the screen is open), one selected and joined
// (or double-clicked); Direct Connection to an address. The player's name
// lives in Options; the first visit without one asks for it.

Multiplayer_Mode :: enum u8 {
	List,
	Direct, // Direct Connection: an address and a password
	Name, // first time: the name to play under
}

Multiplayer_Screen :: struct {
	discovery:  netcode.Discovery,
	searching:  bool, // discovery is open
	mode:       Multiplayer_Mode,
	selected:   u64, // the selected server's instance (0: none)
	last_click: time.Tick, // (double-clicks)
	address:    [dynamic]u8,
	password:   [dynamic]u8,
	name:       [dynamic]u8,
}

MULTIPLAYER_WIDTH :: 620
SERVER_ROW :: 56 // a server's row: its name, its players

multiplayer_open :: proc(app: ^App) {
	m := &app.multiplayer
	if !m.searching {
		if err := netcode.discovery_open(&m.discovery); err != nil {
			log.warnf("multiplayer cannot look for LAN servers error=%v", err)
		} else {
			m.searching = true
		}
	}
	m.mode, m.selected = .List, 0
	if base.var_text(&app.settings.name) == "" {
		clear(&m.name)
		m.mode = .Name
	}
	app.screen = .Multiplayer
}

// multiplayer_close stops looking for servers (leaving the screen).
multiplayer_close :: proc(m: ^Multiplayer_Screen) {
	if m.searching {netcode.discovery_close(&m.discovery)}
	m.searching = false
}

multiplayer_destroy :: proc(m: ^Multiplayer_Screen) {
	multiplayer_close(m)
	delete(m.address)
	delete(m.password)
	delete(m.name)
}

// multiplayer_back: Escape: Direct Connection back to the list; the list
// (or the name, not given) back to the title.
multiplayer_back :: proc(app: ^App) {
	m := &app.multiplayer
	if m.mode == .Direct {
		m.mode = .List
		return
	}
	multiplayer_close(m)
	app.screen = .Title
}

multiplayer_screen :: proc(app: ^App, ctx: ^ui.Context) {
	ui.push_id(ctx, "multiplayer")
	defer ui.pop_id(ctx)
	m := &app.multiplayer
	if m.searching {netcode.discovery_update(&m.discovery, time.tick_now())}
	switch m.mode {
	case .List:
		servers_list(app, ctx)
	case .Direct:
		direct_connection(app, ctx)
	case .Name:
		name_prompt(app, ctx)
	}
}

@(private = "file")
servers_list :: proc(app: ^App, ctx: ^ui.Context) {
	m := &app.multiplayer
	t := &ctx.theme
	area := ui.rect_center(ctx.screen, MULTIPLAYER_WIDTH, ctx.screen.h - 60)
	ui.title(ctx, "Multiplayer", ui.cut_top(&area, 70))
	buttons := ui.cut_bottom(&area, 2 * t.row_height + t.spacing)
	ui.cut_bottom(&area, 2 * t.spacing)
	if app.message != "" {
		ui.label(ctx, app.message, ui.cut_bottom(&area, t.row_height), .Center, t.text_muted)
		ui.cut_bottom(&area, t.spacing)
	}
	ui.fill_rect(ctx, area, t.list_fill)
	ui.stroke_rect(ctx, area, 1, t.list_border)

	// The servers found, as they answer: one focusable list for a pad or
	// keyboard (Up and Down select, Confirm joins), rows for the mouse.
	chosen: Maybe(Found) = nil
	valid := make([dynamic]int, context.temp_allocator)
	if m.searching {
		for f, i in m.discovery.found {
			info, ok := game.decode_server_info(f.info)
			if ok && info.protocol == game.PROTOCOL_VERSION {append(&valid, i)}
		}
	}
	selected := -1
	for i, k in valid {
		if m.discovery.found[i].instance == m.selected {selected = k}
	}
	visible := max(int(area.h / SERVER_ROW), 1)
	first := 0
	list := ui.list_nav(ctx, "servers", area, len(valid), &selected, &first, visible, SERVER_ROW)
	if selected >= 0 && selected < len(valid) {
		m.selected = m.discovery.found[valid[selected]].instance
	}
	y := area.y
	ui.push_clip_rect(ctx, area)
	for i in valid[min(first, len(valid)):] {
		f := m.discovery.found[i]
		info, _ := game.decode_server_info(f.info)
		row := ui.Rect{area.x, y, area.w, SERVER_ROW}
		y += SERVER_ROW
		ui.push_id(ctx, fmt.tprint(f.instance))
		it := ui.interact(ctx, ui.get_id(ctx, "row"), row, focusable = false, label = info.name)
		ui.pop_id(ctx)
		found := Found{net.endpoint_to_string(f.address), info.password}
		if it.clicked {
			if m.selected == f.instance && time.tick_since(m.last_click) < DOUBLE_CLICK {
				ui.pop_clip_rect(ctx)
				server_join(app, found)
				return
			}
			m.selected, m.last_click = f.instance, time.tick_now()
		}
		if m.selected == f.instance {
			chosen = found
			ui.fill_rect(ctx, row, t.row_hover)
			ui.stroke_rect(ctx, ui.rect_shrink(row, 1), 1, t.text)
		} else if it.hovered {
			ui.fill_rect(ctx, row, t.row_selected)
		}
		text := ui.rect_shrink(row, 10)
		ui.draw_text(ctx, ui.cut_top(&text, t.font_size), info.name, t.font_size, t.text, .Left)
		small := t.font_size * 0.8
		ui.draw_text(
			ctx,
			ui.cut_bottom(&text, small),
			fmt.tprintf(
				"%d of %d players%s",
				info.players,
				info.max_players,
				" - password" if info.password else "",
			),
			small,
			t.text_muted,
			.Left,
		)
	}
	ui.pop_clip_rect(ctx)
	if list.clicked && chosen != nil {
		server_join(app, chosen.?)
		return
	}
	if y == area.y {
		// None yet: still looking, and visibly so (the dots count up).
		text := "Cannot look for servers on your network"
		if m.searching {
			DOTS := [3]string{".  ", ".. ", "..."} // (padded: the line stays still)
			dots := DOTS[int(time.duration_seconds(time.tick_since({})) * 2) % 3]
			text = fmt.tprintf("Looking for servers on your network%s", dots)
		}
		hint := ui.rect_center(area, area.w, t.row_height)
		ui.draw_text(ctx, hint, text, t.font_size, t.text_muted, .Center)
	}

	half := (buttons.w - t.spacing) / 2
	top := ui.cut_top(&buttons, t.row_height)
	ui.cut_top(&buttons, t.spacing)
	if ui.button(ctx, "Join Server", ui.cut_left(&top, half), disabled = chosen == nil) {
		server_join(app, chosen.?)
		return
	}
	ui.cut_left(&top, t.spacing)
	if ui.button(ctx, "Direct Connection", top) {
		clear(&m.address)
		append(&m.address, base.var_text(&app.settings.last_server))
		clear(&m.password)
		m.mode = .Direct
	}
	if ui.button(ctx, "Back", ui.rect_center(buttons, half, t.row_height)) {multiplayer_back(app)}
}

// Found: a server of the list, enough to join it.
@(private = "file")
Found :: struct {
	address:  string,
	password: bool,
}

// server_join: a LAN server joined; one with a password goes by Direct
// Connection, its address filled in.
@(private = "file")
server_join :: proc(app: ^App, f: Found) {
	m := &app.multiplayer
	if f.password {
		clear(&m.address)
		append(&m.address, f.address)
		clear(&m.password)
		m.mode = .Direct
		return
	}
	join_from_screen(app, f.address, "")
}

@(private = "file")
direct_connection :: proc(app: ^App, ctx: ^ui.Context) {
	m := &app.multiplayer
	t := &ctx.theme
	column := ui.rect_center(ctx.screen, 460, 6 * (t.row_height + t.spacing) + 80)
	ui.title(ctx, "Direct Connection", ui.cut_top(&column, 80))
	ui.layout_begin(ctx, column)
	defer ui.layout_end(ctx)
	ui.label(ctx, "Server Address", ui.next(ctx), .Left, t.text_muted)
	submitted := ui.text_input(
		ctx,
		"address",
		&m.address,
		ui.next(ctx),
		placeholder = fmt.tprintf("host or host:port (port %d if left out)", netcode.DEFAULT_PORT),
	)
	submitted ||= ui.text_input(
		ctx,
		"password",
		&m.password,
		ui.next(ctx),
		placeholder = "Password (if the server has one)",
	)
	ui.next(ctx, 10)
	address := strings.trim_space(string(m.address[:]))
	row := ui.next(ctx)
	half := (row.w - t.spacing) / 2
	join := ui.button(ctx, "Join Server", ui.cut_left(&row, half), disabled = address == "")
	if (join || submitted) && address != "" {
		if base.var_text_set(&app.settings.last_server, address) {settings_changed(app)}
		join_from_screen(app, address, string(m.password[:]))
		return
	}
	if ui.button(ctx, "Cancel", ui.cut_right(&row, half)) {m.mode = .List}
}

// name_prompt: the first visit asks for the name others will see (kept in
// Options > Profile).
@(private = "file")
name_prompt :: proc(app: ^App, ctx: ^ui.Context) {
	m := &app.multiplayer
	t := &ctx.theme
	column := ui.rect_center(ctx.screen, 460, 5 * (t.row_height + t.spacing) + 80)
	ui.title(ctx, "Choose a Name", ui.cut_top(&column, 80))
	ui.layout_begin(ctx, column)
	defer ui.layout_end(ctx)
	ui.label(ctx, "The name other players see", ui.next(ctx), .Left, t.text_muted)
	submitted := ui.text_input(ctx, "name", &m.name, ui.next(ctx), placeholder = DEFAULT_NAME)
	name := strings.trim_space(string(m.name[:]))
	valid := game.name_valid(name)
	ui.label(
		ctx,
		"" if valid || name == "" else "Letters, digits, _ and - (16 at most)",
		ui.next(ctx),
		.Left,
		t.text_muted,
	)
	row := ui.next(ctx)
	half := (row.w - t.spacing) / 2
	if (ui.button(ctx, "Done", ui.cut_left(&row, half), disabled = !valid) || submitted) && valid {
		base.var_text_set(&app.settings.name, name)
		settings_changed(app)
		m.mode = .List
	}
	if ui.button(ctx, "Cancel", ui.cut_right(&row, half)) {multiplayer_back(app)}
}

@(private = "file")
join_from_screen :: proc(app: ^App, address, password: string) {
	m := &app.multiplayer
	multiplayer_close(m)
	join_server(app, address, password, choose = true)
	if app.session == nil {multiplayer_open(app)} 	// failed at once: stay (message shown)
}
