package engine

import "core:math"

import "client:platform"
import "common:game"
import "common:worldgen"

// Sharing a place ("Copy place"): a code a friend pastes to land in the same
// spot. On a planet world it names the position on Earth, on any other
// world the address and the absolute position.

// share_code: the place's code, or "" outside a running session.
share_code :: proc(app: ^App) -> string {
	s := app.session
	if s == nil || s.state != .Playing {return ""}
	pos := s.prediction.state.position
	a := s.welcome.address
	if a == game.earth_address() {
		x, z := i32(math.floor(pos.x)), i32(math.floor(pos.z))
		lat, lon := worldgen.planet_latlon_of(x, z)
		return game.share_earth_code(lat, lon, context.temp_allocator)
	}
	return game.share_world_code(a, pos.x, pos.y, pos.z, context.temp_allocator)
}

// share_place: the code on the clipboard and in a toast; false outside a
// running session. Clipboard is best effort (void on every platform today).
share_place :: proc(app: ^App) -> bool {
	code := share_code(app)
	if code == "" {
		console_print(&app.console, "share needs a world", .Warning)
		return false
	}
	console_print(&app.console, code)
	platform.set_clipboard_text(code)
	toast(app, .Share_Copied, code)
	return true
}
