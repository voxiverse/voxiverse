package main

import "core:testing"

import "client:autopilot"

// A scene line may start with a size (`name: @WxH script`); without one it is
// autopilot.SCENE_SIZE; a malformed size is an error naming the line.
@(test)
test_scene_sized_lines :: proc(t: ^testing.T) {
	text := "# c\nplain: look 0 0\nbig: @1280x720 screen universes create; creation seed 42\nbad: @12x screen x\nzero: @0x5 look\n"
	script, size, found, err := autopilot.scene_find(text, "big")
	testing.expect(t, found && err == "")
	testing.expect_value(t, script, "screen universes create; creation seed 42")
	testing.expect_value(t, size, [2]u32{1280, 720})
	testing.expect(t, autopilot.scene_is_menu(script))
	script, size, found, err = autopilot.scene_find(text, "plain")
	testing.expect(t, found)
	testing.expect_value(t, script, "look 0 0")
	testing.expect_value(t, size, autopilot.SCENE_SIZE)
	testing.expect(t, !autopilot.scene_is_menu(script))
	for name in ([]string{"bad", "zero"}) {
		_, _, found, err = autopilot.scene_find(text, name)
		testing.expect(t, !found && err != "", "a malformed size is an error")
		testing.expect(t, len(err) > 0 && contains(err, name), "naming the line")
	}
	_, _, found, err = autopilot.scene_find(text, "nope")
	testing.expect(t, !found && err == "")
	// Every scene of the real file parses.
	for name in autopilot.scene_names(autopilot.SCENES_TEXT, context.temp_allocator) {
		_, _, ok, e := autopilot.scene_find(autopilot.SCENES_TEXT, name)
		testing.expectf(t, ok && e == "", "scene %s parses", name)
	}
}

@(private = "file")
contains :: proc(s, sub: string) -> bool {
	for i in 0 ..= len(s) - len(sub) {
		if s[i:i + len(sub)] == sub {return true}
	}
	return false
}
