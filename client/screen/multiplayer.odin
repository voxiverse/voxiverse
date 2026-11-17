package screen

import "core:fmt"
import "core:log"
import "core:net"
import "core:strings"
import "core:time"

import "client:engine"
import "client:ui"
import "common:base"
import "common:game"
import "common:netcode"
import "common:protocol"

// Multiplayer (Minecraft's screen): one list of servers, the player's saved ones first (in
// the order added), then those LAN discovery finds, each asked about every second while
// the screen is open (common/netcode: a saved server is asked at its address, the same
// Discover). A row says the server's name (a saved one not answering: its address), the
// game it plays as this build names it, its players and whether it answers; a server
// that runs another version, or a game this build does not have, is listed and cannot be
// joined, the row saying why. One selected is joined (or double-clicked); Direct
// Connection joins an address; Add Server keeps one, Remove Server forgets the selected;
// Host opens the games to host one (singleplayer.odin). The player's name lives in
// Options; the first visit without one asks for it.

MULTIPLAYER_WIDTH :: 640
SERVER_ROW :: 56 // a server's row: its name and its game, its players or why not
SERVER_ASKING :: 2 * time.Second // a saved server not answering yet is still being asked

multiplayer_open :: proc(app: ^engine.App) {
	m := &app.multiplayer
	engine.saved_servers_load(app)
	if !m.searching {
		if err := netcode.discovery_open(&m.discovery); err != nil {
			log.warnf("multiplayer cannot look for LAN servers error=%v", err)
		} else {
			m.searching = true
			m.opened = time.tick_now()
			for s in m.saved {if s.endpoint != {} {netcode.discovery_ask(&m.discovery, s.endpoint)}}
		}
	}
	m.mode, m.list = .List, {}
	if base.var_text(&app.settings.name) == "" {
		clear(&m.name)
		m.mode = .Name
	}
	app.screen = .Multiplayer
}

// multiplayer_close stops looking for servers (leaving the screen).
multiplayer_close :: proc(m: ^engine.Multiplayer_Screen) {
	if m.searching {netcode.discovery_close(&m.discovery)}
	m.searching = false
}

multiplayer_destroy :: proc(m: ^engine.Multiplayer_Screen) {
	multiplayer_close(m)
	engine.saved_servers_destroy(m)
	delete(m.address)
	delete(m.password)
	delete(m.name)
}

// multiplayer_back: Escape: Direct Connection or Add Server back to the list; the list
// (or the name, not given) back to the title.
multiplayer_back :: proc(app: ^engine.App) {
	m := &app.multiplayer
	if m.mode == .Direct || m.mode == .Add {
		m.mode = .List
		return
	}
	multiplayer_close(m)
	app.screen = .Title
}

// host_open: Host: the games, to host one (the same list and pages as Singleplayer).
host_open :: proc(app: ^engine.App) {
	multiplayer_close(&app.multiplayer)
	singleplayer_open(app, host = true)
}

multiplayer_screen :: proc(app: ^engine.App, ctx: ^ui.Context) {
	ui.push_id(ctx, "multiplayer")
	defer ui.pop_id(ctx)
	m := &app.multiplayer
	if m.searching {netcode.discovery_update(&m.discovery, time.tick_now())}
	switch m.mode {
	case .List:
		servers_list(app, ctx)
	case .Direct, .Add:
		address_form(app, ctx)
	case .Name:
		name_prompt(app, ctx)
	}
}

// Server_Row: a row of the servers list.
Server_Row :: struct {
	name:        string, // the server's name; a saved one that has not answered: its address
	address:     string, // where to join it (host or host:port)
	saved:       int, // its place among the saved servers (-1: found on the network)
	answered:    bool, // it answers (it can be reached)
	found:       bool, // its host was found (a saved server's name may not resolve)
	players:     int,
	max_players: int,
	password:    bool,
	game:        string, // the game it plays, as this build names it (else the server's name or id of it)
	why_not:     string, // why it cannot be joined ("": it can be, or tried while it does not answer)
}

// server_rows: the list's rows (temp allocator): the saved servers, in their order, each
// with what answered at its address, then the servers found on the network that are not
// one of them.
server_rows :: proc(
	saved: []engine.Saved_Server,
	d: ^netcode.Discovery,
	games: []engine.Game,
) -> []Server_Row {
	rows := make([dynamic]Server_Row, 0, len(saved) + len(d.found), context.temp_allocator)
	claimed := make([]bool, len(d.found), context.temp_allocator)
	for s, i in saved {
		row := Server_Row {
			name    = s.address,
			address = s.address,
			saved   = i,
			found   = s.endpoint != {},
		}
		if at := netcode.discovery_asked(d, s.endpoint); s.endpoint != {} && at >= 0 {
			claimed[at] = true
			row_take_info(&row, d.found[at].info, games)
		}
		append(&rows, row)
	}
	for f, i in d.found {
		if claimed[i] {continue}
		row := Server_Row {
			address = net.endpoint_to_string(f.address, context.temp_allocator),
			saved   = -1,
			found   = true,
		}
		if !row_take_info(&row, f.info, games) {continue} 	// (not a server's: no row)
		append(&rows, row)
	}
	return rows[:]
}

// row_take_info fills row from what the server said (false: it says nothing that decodes).
@(private = "file")
row_take_info :: proc(row: ^Server_Row, info_bytes: []u8, games: []engine.Game) -> bool {
	info, ok := protocol.decode_server_info(info_bytes)
	if !ok {
		row.answered = true
		row.why_not = engine.tr(.Multiplayer_Other_Version)
		return false
	}
	row.answered = true
	if info.name != "" {row.name = strings.clone(info.name, context.temp_allocator)}
	row.players, row.max_players, row.password = info.players, info.max_players, info.password
	row.game = strings.clone(
		info.game_name if info.game_name != "" else info.game,
		context.temp_allocator,
	)
	switch {
	case info.protocol != protocol.PROTOCOL_VERSION:
		row.why_not = engine.tr(.Multiplayer_Other_Version)
	case:
		if g, known := engine.game_find(games, info.game); known {
			row.game = g.name
		} else {
			row.why_not = engine.tr(.Multiplayer_No_Game, info.game)
		}
	}
	return true
}

// row_status: a row's second line: its players (and a password), or why it cannot be
// joined, or that it does not answer; its address after, for a saved one.
@(private = "file")
row_status :: proc(row: Server_Row, asking: bool) -> string {
	status: string
	switch {
	case !row.found:
		status = engine.tr(.Multiplayer_Cannot_Find, row.address)
	case !row.answered:
		status = engine.tr(.Multiplayer_Asking if asking else .Multiplayer_No_Answer)
	case row.why_not != "":
		status = row.why_not
	case:
		status = engine.tr(.Multiplayer_Players, row.players, row.max_players)
		if row.password {status = engine.tr(.Universes_Info, status, engine.tr(.Multiplayer_Password))}
	}
	if row.saved >= 0 && row.found && row.name != row.address {
		status = engine.tr(.Universes_Info, status, row.address)
	}
	return status
}

@(private = "file")
servers_list :: proc(app: ^engine.App, ctx: ^ui.Context) {
	m := &app.multiplayer
	t := &ctx.theme
	area := ui.rect_center(ctx.screen, MULTIPLAYER_WIDTH, ctx.screen.h - 60)
	ui.title(ctx, engine.tr(.Title_Multiplayer), ui.cut_top(&area, 70))
	buttons := ui.cut_bottom(&area, 2 * t.row_height + t.spacing)
	ui.cut_bottom(&area, 2 * t.spacing)
	if app.message != "" {
		ui.label(ctx, app.message, ui.cut_bottom(&area, t.row_height), .Center, t.text_muted)
		ui.cut_bottom(&area, t.spacing)
	}

	rows := server_rows(m.saved[:], &m.discovery, app.games)
	asking := m.searching && time.tick_since(m.opened) < SERVER_ASKING
	ui.default_focus(ctx)
	view := ui.list_begin(ctx, "servers", area, len(rows), SERVER_ROW, &m.list)
	join := -1
	small := t.font_size * 0.8
	for i in view.first ..< view.last {
		row := rows[i]
		r, it := ui.list_row(ctx, &view, i, row.name)
		if it.clicked {
			if m.last_row == i && time.tick_since(m.last_click) < DOUBLE_CLICK {join = i}
			m.last_row, m.last_click = i, time.tick_now()
		}
		inner := ui.rect_shrink(r, 10)
		inner.x += 4
		inner.w -= 8
		top := ui.cut_top(&inner, t.font_size + 8)
		if row.game != "" {ui.draw_text(ctx, top, row.game, t.font_size, t.text, .Right)}
		ui.draw_text(ctx, top, row.name, t.font_size, t.text, .Left)
		ui.draw_text(ctx, inner, row_status(row, asking), small, t.text_muted, .Left)
	}
	if ui.list_end(ctx, &view) {join = m.list.selected}
	if len(rows) == 0 {
		// None yet: still looking, and visibly so (the dots count up).
		text := engine.tr(.Multiplayer_Cannot_Look)
		if m.searching {
			DOTS := [3]string{".  ", ".. ", "..."} // (padded: the line stays still)
			dots := DOTS[int(time.duration_seconds(time.tick_since({})) * 2) % 3]
			text = engine.tr(.Multiplayer_Looking, dots)
		}
		ui.label(ctx, text, area, .Center, t.text_muted)
	}
	chosen := Server_Row {
		saved = -1,
	}
	if s := m.list.selected; s >= 0 && s < len(rows) {chosen = rows[s]}
	can_join := chosen.address != "" && chosen.why_not == ""
	if join >= 0 && join < len(rows) && rows[join].why_not == "" {
		server_join(app, rows[join])
		return
	}

	third := (buttons.w - 2 * t.spacing) / 3
	top := ui.cut_top(&buttons, t.row_height)
	ui.cut_top(&buttons, t.spacing)
	if ui.button(
		ctx,
		engine.tr(.Multiplayer_Join_Server),
		ui.cut_left(&top, third),
		disabled = !can_join,
	) {
		server_join(app, chosen)
		return
	}
	ui.cut_left(&top, t.spacing)
	if ui.button(ctx, engine.tr(.Multiplayer_Direct_Connection), ui.cut_left(&top, third)) {
		form_open(app, .Direct, base.var_text(&app.settings.last_server))
	}
	ui.cut_left(&top, t.spacing)
	if ui.button(ctx, engine.tr(.Multiplayer_Host), top) {
		host_open(app)
		return
	}
	if ui.button(ctx, engine.tr(.Multiplayer_Add_Server), ui.cut_left(&buttons, third)) {
		form_open(app, .Add, "")
	}
	ui.cut_left(&buttons, t.spacing)
	if ui.button(
		ctx,
		engine.tr(.Multiplayer_Remove_Server),
		ui.cut_left(&buttons, third),
		disabled = chosen.saved < 0,
	) {
		saved_remove(app, chosen.saved)
	}
	ui.cut_left(&buttons, t.spacing)
	if ui.button(ctx, engine.tr(.Credits_Back), buttons) {multiplayer_back(app)}
}

// saved_remove forgets the saved server at i, on the disk too, and stops asking it.
@(private = "file")
saved_remove :: proc(app: ^engine.App, i: int) {
	m := &app.multiplayer
	if i < 0 || i >= len(m.saved) {return}
	if m.searching {netcode.discovery_unask(&m.discovery, m.saved[i].endpoint)}
	engine.saved_server_remove(m, i)
	engine.saved_servers_save(app)
}

// form_open: Direct Connection or Add Server, its address filled in.
@(private = "file")
form_open :: proc(app: ^engine.App, mode: engine.Multiplayer_Mode, address: string) {
	m := &app.multiplayer
	clear(&m.address)
	append(&m.address, address)
	clear(&m.password)
	m.mode = mode
}

// server_join: a server of the list joined; one with a password goes by Direct
// Connection, its address filled in.
@(private = "file")
server_join :: proc(app: ^engine.App, row: Server_Row) {
	if row.password {
		form_open(app, .Direct, row.address)
		return
	}
	join_from_screen(app, row.address, "")
}

// address_form: Direct Connection (an address and a password, joined) or Add Server (an
// address, kept in the list).
@(private = "file")
address_form :: proc(app: ^engine.App, ctx: ^ui.Context) {
	m := &app.multiplayer
	t := &ctx.theme
	adding := m.mode == .Add
	title := engine.tr(.Multiplayer_Add_Server if adding else .Multiplayer_Direct_Connection)
	column := ui.rect_center(ctx.screen, 460, 6 * (t.row_height + t.spacing) + 80)
	ui.title(ctx, title, ui.cut_top(&column, 80))
	ui.layout_begin(ctx, column)
	defer ui.layout_end(ctx)
	ui.label(ctx, engine.tr(.Multiplayer_Server_Address), ui.next(ctx), .Left, t.text_muted)
	// The address takes what is typed from the start (nothing else focused: the form just
	// opened), for the mouse as for the keyboard.
	if ctx.focused == 0 && !ui.osk_is_open(ctx) {ctx.focused = ui.get_id(ctx, "address")}
	submitted := ui.text_input(
		ctx,
		"address",
		&m.address,
		ui.next(ctx),
		placeholder = fmt.tprintf("host or host:port (port %d if left out)", netcode.DEFAULT_PORT),
	)
	if !adding {
		submitted ||= ui.text_input(
			ctx,
			"password",
			&m.password,
			ui.next(ctx),
			placeholder = "Password (if the server has one)",
		)
	}
	ui.next(ctx, 10)
	address := strings.trim_space(string(m.address[:]))
	row := ui.next(ctx)
	half := (row.w - t.spacing) / 2
	done := ui.button(
		ctx,
		engine.tr(.Multiplayer_Save if adding else .Multiplayer_Join_Server),
		ui.cut_left(&row, half),
		disabled = address == "",
	)
	if (done || submitted) && address != "" {
		if adding {
			server_save(app, address)
			return
		}
		if base.var_text_set(&app.settings.last_server, address) {engine.settings_changed(app)}
		join_from_screen(app, address, string(m.password[:]))
		return
	}
	if ui.button(ctx, engine.tr(.Dial_Cancel), ui.cut_right(&row, half)) {m.mode = .List}
}

// server_save keeps address in the list (on the disk too) and asks it, and selects it.
@(private = "file")
server_save :: proc(app: ^engine.App, address: string) {
	m := &app.multiplayer
	m.mode = .List
	if !engine.saved_server_add(m, address) {return}
	engine.saved_servers_save(app)
	added := m.saved[len(m.saved) - 1]
	if m.searching && added.endpoint != {} {netcode.discovery_ask(&m.discovery, added.endpoint)}
	m.list.selected = len(m.saved) - 1
}

// name_prompt: the first visit asks for the name others will see (kept in
// Options > Profile).
@(private = "file")
name_prompt :: proc(app: ^engine.App, ctx: ^ui.Context) {
	m := &app.multiplayer
	t := &ctx.theme
	column := ui.rect_center(ctx.screen, 460, 5 * (t.row_height + t.spacing) + 80)
	ui.title(ctx, engine.tr(.Multiplayer_Choose_A_Name), ui.cut_top(&column, 80))
	ui.layout_begin(ctx, column)
	defer ui.layout_end(ctx)
	ui.label(
		ctx,
		engine.tr(.Multiplayer_The_Name_Other_Players_See),
		ui.next(ctx),
		.Left,
		t.text_muted,
	)
	submitted := ui.text_input(
		ctx,
		"name",
		&m.name,
		ui.next(ctx),
		placeholder = engine.DEFAULT_NAME,
	)
	name := strings.trim_space(string(m.name[:]))
	valid := game.name_valid(name)
	ui.label(
		ctx,
		"" if valid || name == "" else engine.tr(.Multiplayer_Letters_Digits_And_16_At),
		ui.next(ctx),
		.Left,
		t.text_muted,
	)
	row := ui.next(ctx)
	half := (row.w - t.spacing) / 2
	if (ui.button(ctx, engine.tr(.Multiplayer_Done), ui.cut_left(&row, half), disabled = !valid) ||
		   submitted) &&
	   valid {
		base.var_text_set(&app.settings.name, name)
		engine.settings_changed(app)
		m.mode = .List
	}
	if ui.button(ctx, engine.tr(.Dial_Cancel), ui.cut_right(&row, half)) {multiplayer_back(app)}
}

@(private = "file")
join_from_screen :: proc(app: ^engine.App, address, password: string) {
	m := &app.multiplayer
	multiplayer_close(m)
	engine.join_server(app, address, password, choose = true)
	if app.session == nil {multiplayer_open(app)} 	// failed at once: stay (message shown)
}
