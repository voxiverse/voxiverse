package client

import "common:game"
import "server:core"

// Frame_Rig: one session on the harness's simulated network, given a frame
// of the actions the test chooses at every tick (a party of the harness, run
// before the server's tick).
Frame_Rig :: struct {
	h:       core.Harness,
	s:       ^Session,
	input:   Input_State,
	actions: ^Actions,
}

@(private = "file")
IDLE: Actions

rig_party :: proc(data: rawptr) {
	r := (^Frame_Rig)(data)
	session_update(
		r.s,
		&r.input,
		r.actions if r.actions != nil else &IDLE,
		SETTINGS_DEFAULTS,
		{},
		game.TICK_SECONDS,
		true,
	)
}

// rig_add makes s the rig's session and a party of its harness.
rig_add :: proc(r: ^Frame_Rig, s: ^Session) {
	r.s = s
	core.harness_add(&r.h, rig_party, r)
}

// rig_frame: one tick with the actions a.
rig_frame :: proc(r: ^Frame_Rig, a: ^Actions) {
	r.actions = a
	core.harness_step(&r.h)
}
