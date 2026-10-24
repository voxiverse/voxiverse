package client

import "core:fmt"
import "core:log"
import "core:net"
import "core:strings"
import "core:time"

import "../base"
import "../game"
import "../netcode"
import "../ui"

// The Multiplayer screen: your name, the servers LAN discovery finds (asked
// about every second while the screen is open), and an address to type.

Multiplayer_Screen :: struct {
	discovery: netcode.Discovery,
	searching: bool, // discovery is open
	address:   [dynamic]u8,
	password:  [dynamic]u8,
	name:      [dynamic]u8, // edits settings.name
}

multiplayer_open :: proc(app: ^App) {
	m := &app.multiplayer
	if !m.searching {
		if err := netcode.discovery_open(&m.discovery); err != nil {
			log.warnf("multiplayer cannot look for LAN servers error=%v", err)
		} else {
			m.searching = true
		}
	}
	clear(&m.name)
	append(&m.name, base.var_text(&app.settings.name))
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

multiplayer_screen :: proc(app: ^App, ctx: ^ui.Context) {
	ui.push_id(ctx, "multiplayer")
	defer ui.pop_id(ctx)
	m := &app.multiplayer
	t := &ctx.theme
	if m.searching {netcode.discovery_update(&m.discovery, time.tick_now())}
	column := ui.rect_center(ctx.screen, 620, ctx.screen.h - 80)
	ui.title(ctx, "Multiplayer", ui.cut_top(&column, 80))
	ui.layout_begin(ctx, column)
	defer ui.layout_end(ctx)

	// The name: kept as long as it is valid (or empty: the default).
	row := ui.next(ctx)
	ui.label(ctx, "Your name", ui.cut_left(&row, 160), .Left, t.text_muted)
	ui.text_input(ctx, "name", &m.name, row, placeholder = DEFAULT_NAME)
	typed := string(m.name[:])
	if typed != base.var_text(&app.settings.name) && (typed == "" || game.name_valid(typed)) {
		base.var_text_set(&app.settings.name, typed)
		settings_changed(app)
	}
	if typed != "" && !game.name_valid(typed) {
		ui.label(
			ctx,
			"Names are letters, digits, _ and - (16 at most)",
			ui.next(ctx),
			.Left,
			t.text_muted,
		)
	}

	ui.next(ctx, 10)
	ui.label(ctx, "On your network", ui.next(ctx), .Left, t.text_muted)
	found := 0
	if m.searching {
		for f in m.discovery.found {
			info, ok := game.decode_server_info(f.info)
			if !ok || info.protocol != game.PROTOCOL_VERSION {continue}
			found += 1
			ui.push_id(ctx, fmt.tprint(f.instance))
			text := fmt.tprintf(
				"%s    %d/%d players%s",
				info.name,
				info.players,
				info.max_players,
				", password" if info.password else "",
			)
			if ui.button(ctx, text, ui.next(ctx)) {
				address := net.endpoint_to_string(f.address)
				ui.pop_id(ctx)
				join_from_screen(app, address)
				return
			}
			ui.pop_id(ctx)
		}
	}
	if found == 0 {
		ui.label(
			ctx,
			"Looking for servers..." if m.searching else "Cannot look for servers (see the log)",
			ui.next(ctx),
			.Left,
			t.text_muted,
		)
	}

	ui.next(ctx, 10)
	ui.label(ctx, "Join by address", ui.next(ctx), .Left, t.text_muted)
	submitted := ui.text_input(
		ctx,
		"address",
		&m.address,
		ui.next(ctx),
		placeholder = fmt.tprintf("host or host:port (port %d if left out)", netcode.DEFAULT_PORT),
	)
	ui.text_input(
		ctx,
		"password",
		&m.password,
		ui.next(ctx),
		placeholder = "Password (if it has one)",
	)
	address := strings.trim_space(string(m.address[:]))
	if (ui.button(ctx, "Join", ui.next(ctx), disabled = address == "") || submitted) &&
	   address != "" {
		join_from_screen(app, address)
		return
	}
	if app.message != "" {ui.label(ctx, app.message, ui.next(ctx), .Left, t.text_muted)}
	ui.next(ctx, 10)
	if ui.button(ctx, "Back", ui.next(ctx)) {
		multiplayer_close(m)
		app.screen = .Title
	}
}

@(private = "file")
join_from_screen :: proc(app: ^App, address: string) {
	m := &app.multiplayer
	multiplayer_close(m)
	join_server(app, address, string(m.password[:]), choose = true)
	if app.session == nil {multiplayer_open(app)} 	// failed at once: stay (message shown)
}
