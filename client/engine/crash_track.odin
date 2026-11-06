package engine

import "core:fmt"

import "common:base"
import "server:core"

// Crash_Track is what the crash bundle was last told, so a change is recorded once.
Crash_Track :: struct {
	state:    [24]u8, // the last state text
	state_n:  int,
	screen:   Screen,
	overlays: bit_set[Overlay],
	started:  bool, // (the first call records no change: it only learns where we are)
	in_world: bool,
}

// crash_state: what the player is doing, in words that hold no address or name.
crash_state :: proc(app: ^App) -> string {
	s := app.session
	if s == nil {return "title"}
	if s.loading != nil {return "loading"}
	if s.remote {return "world remote"}
	if core.stats(&s.server).port != 0 {return "world LAN"}
	return "world singleplayer"
}

// crash_track tells the crash bundle the state, and the screens, overlays and worlds that
// opened or closed since the last call. Once a frame, from the loop.
crash_track :: proc(app: ^App) {
	t := &app.crash_track
	state := crash_state(app)
	if string(t.state[:t.state_n]) != state {
		t.state_n = copy(t.state[:], state)
		base.crash_bundle_set_state(state)
	}
	in_world := app.session != nil
	open: bit_set[Overlay]
	for i in 0 ..< app.overlays.count {open += {app.overlays.stack[i]}}
	if t.started {
		if in_world !=
		   t.in_world {base.crash_bundle_action("world", "join" if in_world else "leave")}
		if app.screen != t.screen {base.crash_bundle_action("screen", fmt.tprint(app.screen))}
		for o in Overlay {
			switch {
			case o in open && o not_in t.overlays:
				base.crash_bundle_action("screen", fmt.tprintf("%v open", o))
			case o not_in open && o in t.overlays:
				base.crash_bundle_action("screen", fmt.tprintf("%v close", o))
			}
		}
	}
	t.overlays, t.in_world, t.screen, t.started = open, in_world, app.screen, true
}
