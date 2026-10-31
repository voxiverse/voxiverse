package client

import "core:fmt"
import "core:net"

import "client:ui"
import "common:game"
import "server:."

// The Open to LAN dialog: the guests' game mode, whether
// guests may use commands, and Open; once the world is open it shows where to
// join. The choices are two rules of the world (`default_game_mode`,
// `guest_role`), changed through the commands, so they are journalled like any
// `/rule`; opening is the `open_lan` command. The transport is not touched.

Lan_Dialog :: struct {
	mode:      int, // the guests' game mode: an index into the registry's modes
	commands:  bool, // Allow commands: guests get the mod role (off: default)
	started:   bool, // Open was pressed
	address:   [64]u8, // this machine's LAN address, found when the dialog opened
	address_n: int,
}

// GUESTS_ROLE: what Allow commands gives (the role of permissions.cfg that
// has the commands nodes; off gives only the default role everyone has).
GUESTS_ROLE :: "mod"

// lan_dialog_open: the dialog, set to the world's default mode.
lan_dialog_open :: proc(app: ^App) {
	s := app.session
	d := &app.lan
	d^ = {}
	if s != nil {
		d.mode = lan_default_mode(s)
		text := lan_address()
		d.address_n = copy(d.address[:], text)
	}
	overlay_open(&app.overlays, .Open_To_LAN)
}

// lan_default_mode: the mode new characters get here: the world's rule, else
// the universe's, else the registry's first.
lan_default_mode :: proc(s: ^Session) -> int {
	for text in ([]string{string(s.rules.default_game_mode.buf[:s.rules.default_game_mode.len]), s.config.mode}) {
		if text == "" {continue}
		if m, ok := game.mode_find(s.reg, text); ok {return m}
	}
	if m, ok := game.mode_find(s.reg, "creative"); ok {return m}
	return 0
}

// lan_commands: what Open sends, in order.
lan_commands :: proc(s: ^Session, d: Lan_Dialog) -> [3]string {
	role := GUESTS_ROLE if d.commands else "default"
	return {
		fmt.tprintf("rule default_game_mode %s", s.reg.game_modes[d.mode].id),
		fmt.tprintf("rule guest_role %s", role),
		"open_lan",
	}
}

// lan_address: this machine's address on its local network (the first
// up, non-loopback IPv4 one, not a link-local), or "" if there is none.
lan_address :: proc() -> string {
	interfaces, err := net.enumerate_interfaces(context.temp_allocator)
	if err != nil {return ""}
	for i in interfaces {
		if .Up not_in i.link.state || .Loopback in i.link.state {continue}
		for lease in i.unicast {
			a, is4 := lease.address.(net.IP4_Address)
			if !is4 || a[0] == 127 || (a[0] == 169 && a[1] == 254) {continue}
			return net.address_to_string(a, context.temp_allocator)
		}
	}
	return ""
}

lan_dialog_ui :: proc(app: ^App, ctx: ^ui.Context) {
	s := app.session
	if s == nil || len(s.reg.game_modes) == 0 {return}
	d := &app.lan
	ui.push_id(ctx, "lan dialog")
	defer ui.pop_id(ctx)
	t := &ctx.theme
	prev := ui.begin_layer(ctx, .Modal)
	defer ui.end_layer(ctx, prev)
	ui.backdrop(ctx)
	port := server.stats(&s.server).port
	rows: f32 = 4 if port == 0 else 5
	box := ui.rect_center(ctx.screen, 440, rows * t.row_height + (rows + 1) * t.spacing + 80)
	ui.panel(ctx, box)
	inner := ui.rect_shrink(box, t.padding)
	ui.title(ctx, tr(.Lan_Title), ui.cut_top(&inner, 60))
	ui.layout_begin(ctx, inner)
	defer ui.layout_end(ctx)
	if port == 0 {
		names := make([]string, len(s.reg.game_modes), context.temp_allocator)
		for _, i in s.reg.game_modes {names[i] = game.mode_label(s.reg, i)}
		ui.default_focus(ctx)
		ui.choice(ctx, tr(.Lan_Guest_Mode), &d.mode, names, ui.next(ctx))
		ui.checkbox(ctx, tr(.Lan_Allow_Commands), &d.commands, ui.next(ctx))
		if ui.button(ctx, tr(.Lan_Open), ui.next(ctx), disabled = d.started) {
			d.started = true
			for command in lan_commands(s, d^) {send_message(s, game.Command{command})}
		}
		if d.started {ui.label(ctx, tr(.Lan_Opening), ui.next(ctx), .Center, t.text_muted)}
		if ui.button(
			ctx,
			tr(.Dial_Cancel),
			ui.next(ctx),
		) {overlay_close(&app.overlays, .Open_To_LAN)}
	} else {
		ui.label(ctx, tr(.Lan_Open_On), ui.next(ctx), .Center)
		ui.label(ctx, lan_join_text(d^, port), ui.next(ctx), .Center)
		ui.label(
			ctx,
			tr(.Lan_Mode_Is, game.mode_label(s.reg, d.mode)),
			ui.next(ctx),
			.Center,
			t.text_muted,
		)
		ui.default_focus(ctx)
		if ui.button(ctx, tr(.Lan_Done), ui.next(ctx)) {overlay_close(&app.overlays, .Open_To_LAN)}
		if ui.button(ctx, tr(.Game_Menu_Close_LAN), ui.next(ctx)) {
			close_lan(app)
			overlay_close(&app.overlays, .Open_To_LAN)
		}
	}
}

// lan_join_text: "address:port" (or the port alone when no address was found).
lan_join_text :: proc(d: Lan_Dialog, port: int) -> string {
	if d.address_n == 0 {return tr(.Lan_Port, port)}
	dd := d
	return fmt.tprintf("%s:%d", string(dd.address[:dd.address_n]), port)
}

// close_lan asks our own server to stop taking players from the LAN.
close_lan :: proc(app: ^App) {
	if s := app.session; s != nil && session_hosting(s) && s.state == .Playing {
		send_message(s, game.Command{"close_lan"})
	}
}
