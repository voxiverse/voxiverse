package engine

import "common:game"
import "core:net"

Lan_Dialog :: struct {
	mode:      int, // the guests' game mode: an index into the registry's modes
	commands:  bool, // Allow commands: guests get the mod role (off: default)
	started:   bool, // Open was pressed
	address:   [64]u8, // this machine's LAN address, found when the dialog opened
	address_n: int,
}

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

// close_lan asks our own server to stop taking players from the LAN.
close_lan :: proc(app: ^App) {
	if s := app.session; s != nil && session_hosting(s) && s.state == .Playing {
		send_message(s, game.Command{"close_lan"})
	}
}
