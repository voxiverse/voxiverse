package playtest_server

import "core:testing"

import "server:core"

// A notice the game sends from a test's own call reaches the player a step later: told
// waits for it rather than say it never came; a notice never sent is still not told.
@(test)
test_told_waits_for_a_notice_on_its_way :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !start(t, rig, core.HARNESS_GAME, {guests = 1}) {return}
	defer stop(rig)
	core.notice(srv(rig), host(rig), "on its way")
	core.notice(srv(rig), guest(rig), "to the guest")
	testing.expect(t, told(rig, "on its way"))
	testing.expect(t, guest_told(rig, "to the guest"))
	testing.expect(t, !told(rig, "never sent"))
}
