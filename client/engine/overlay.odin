package engine

Overlay :: enum u8 {
	Game_Menu, // Resume, Options, Open to LAN, Leave
	Options, // Options over the game (above the game menu)
	Tuning, // F4: the tuning panel
	Chat,
	Player_Menu, // the player menu: the inventory and the statistics (menu_player.odin)
	Console,
	Quit_Dialog,
	Dial, // a gate's symbols (overlay_dial.odin)
	Audio_Inspector, // F8, dev builds: the audio freeze and solo (dev_audio_inspector.odin)
	Consent, // the one-time question about sharing play data (telemetry.odin)
	Open_To_LAN, // the game menu's dialog (overlay_lan.odin)
	Death, // dead: how, and the Respawn button (overlay_death.odin)
}

Overlay_Take :: enum u8 {
	Keyboard,
	Mouse,
	World,
}

Overlay_Takes :: bit_set[Overlay_Take]

Overlay_Info :: struct {
	takes:   Overlay_Takes,
	in_game: bool, // only over a world (closed when it is left)
}

@(rodata)
OVERLAY_INFO := [Overlay]Overlay_Info {
	.Game_Menu = {takes = {.Keyboard, .Mouse, .World}, in_game = true},
	.Options = {takes = {.Keyboard, .Mouse, .World}, in_game = true},
	.Tuning = {takes = {.Mouse}, in_game = true}, // watching the game respond: it runs on
	.Chat = {takes = {.Keyboard, .Mouse}, in_game = true},
	.Player_Menu = {takes = {.Keyboard, .Mouse}, in_game = true},
	.Console = {takes = {.Keyboard, .Mouse}},
	.Quit_Dialog = {takes = {.Keyboard, .Mouse}},
	.Dial = {takes = {.Keyboard, .Mouse}, in_game = true},
	.Audio_Inspector = {takes = {.Mouse}, in_game = true}, // the game runs on
	.Consent = {takes = {.Keyboard, .Mouse}},
	.Open_To_LAN = {takes = {.Keyboard, .Mouse, .World}, in_game = true},
	.Death = {takes = {.Keyboard, .Mouse}, in_game = true},
}

Overlays :: struct {
	stack: [len(Overlay)]Overlay, // bottom first
	count: int,
}

// overlay_open puts o on top (moving it there if it is open).
overlay_open :: proc(o: ^Overlays, which: Overlay) {
	overlay_close(o, which)
	o.stack[o.count] = which
	o.count += 1
}

// overlay_close removes o (wherever it is in the stack).
overlay_close :: proc(o: ^Overlays, which: Overlay) {
	for i in 0 ..< o.count {
		if o.stack[i] != which {continue}
		copy(o.stack[i:o.count - 1], o.stack[i + 1:o.count])
		o.count -= 1
		return
	}
}

overlay_toggle :: proc(o: ^Overlays, which: Overlay) {
	if overlay_is_open(o, which) {overlay_close(o, which)} else {overlay_open(o, which)}
}

overlay_is_open :: proc(o: ^Overlays, which: Overlay) -> bool {
	for i in 0 ..< o.count {if o.stack[i] == which {return true}}
	return false
}

overlay_top :: proc(o: ^Overlays) -> (Overlay, bool) {
	if o.count == 0 {return {}, false}
	return o.stack[o.count - 1], true
}

// overlays_take: some open overlay takes this.
overlays_take :: proc(o: ^Overlays, what: Overlay_Take) -> bool {
	for i in 0 ..< o.count {if what in OVERLAY_INFO[o.stack[i]].takes {return true}}
	return false
}

// overlays_leave_game closes the overlays that belong to a world.
overlays_leave_game :: proc(o: ^Overlays) {
	for i := o.count - 1; i >= 0; i -= 1 {
		if OVERLAY_INFO[o.stack[i]].in_game {overlay_close(o, o.stack[i])}
	}
}

// world_paused: an overlay pauses the world (the game menu or Options).
world_paused :: proc(app: ^App) -> bool {
	return overlays_take(&app.overlays, .World)
}

// game_controls: the player moves, looks and uses items (nothing over the
// world takes the keyboard or mouse).
game_controls :: proc(app: ^App) -> bool {
	return(
		app.screen == .Game &&
		(app.session == nil ||
				(app.session.loading == nil &&
						app.session.state != .Connecting &&
						app.session.state != .Choosing)) &&
		!overlays_take(&app.overlays, .Keyboard) &&
		!overlays_take(&app.overlays, .Mouse) \
	)
}
