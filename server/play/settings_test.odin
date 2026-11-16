package play

import "core:strings"
import "core:testing"

import "common:base"
import "server:core"

Test_Settings :: struct {
	frags:   int,
	respawn: f32,
}

@(rodata)
TEST_DEFAULTS := Test_Settings{15, 2}

@(rodata)
TEST_VARS := [?]base.Var {
	{field = "frags", help = "the first to this many wins", min = 1, max = 200},
	{field = "respawn", help = "seconds from a death to coming back", min = 0, max = 30},
}

test_table :: proc() -> base.Var_Table {
	return {"", Test_Settings, TEST_VARS[:], &TEST_DEFAULTS}
}

// The settings' text, their usage, and the universe's copy: written and read back; a
// line that names none, or a value out of bounds, refuses the whole and changes nothing.
@(test)
test_settings_kept :: proc(t: ^testing.T) {
	testing.expect(t, base.var_table_check(test_table()))
	r := Test_Settings{7, 3.5}
	testing.expect_value(t, settings_text(test_table(), &r), "frags 7, respawn 3.5")
	testing.expect_value(
		t,
		settings_usage(test_table()),
		"set frags <1..200> | set respawn <0..30>",
	)
	b := strings.builder_make(context.temp_allocator)
	settings_save(test_table(), &r, &b)
	back := TEST_DEFAULTS
	testing.expect(t, settings_load(test_table(), &back, strings.to_string(b)))
	testing.expect_value(t, back, r)
	testing.expect(t, !settings_load(test_table(), &back, "frags = 9\nrespawn = 99\n"))
	testing.expect(t, !settings_load(test_table(), &back, "frags = 9\nlives = 3\n"))
	testing.expect_value(t, back, r)
}

// A game's saved text carries its settings and its own lines through one reading: the
// settings' lines are read, the rest come back to the game in order, as keys and values.
@(test)
test_settings_read_leaves_the_games_lines :: proc(t: ^testing.T) {
	back := TEST_DEFAULTS
	own, ok := settings_read(
		test_table(),
		&back,
		"# the first to this many wins\nfrags = 9\nbest = 12\nhero 3 140 7 ana\n\nrespawn=4\n",
	)
	testing.expect(t, ok)
	testing.expect_value(t, back, Test_Settings{9, 4})
	testing.expect_value(t, len(own), 2)
	if len(own) == 2 {
		testing.expect_value(t, own[0], Saved_Line{"best", "12"})
		testing.expect_value(t, own[1], Saved_Line{"hero", "3 140 7 ana"})
	}
	_, ok = settings_read(test_table(), &back, "frags = 900\nbest = 1\n")
	testing.expect(t, !ok)
	testing.expect_value(t, back, Test_Settings{9, 4})
}

// A game whose command is its settings': /kit set <name> <value>.
@(private = "file")
Kit_State :: struct {
	settings: Test_Settings,
	changed:  int,
}

@(private = "file")
KIT_GAME :: core.Game {
	info = {id = "kit", name = "Kit", description = "server/play's tests' game"},
	server_state = Kit_State,
	start = proc(s: ^core.Server) -> bool {
		core.game_state(s, Kit_State).settings = TEST_DEFAULTS
		return true
	},
	command = proc(s: ^core.Server, c: ^core.Client, name: string, args: []string) -> bool {
		if name != "kit" {return false}
		k := core.game_state(s, Kit_State)
		handled, changed := settings_command(s, c, test_table(), &k.settings, "kit.admin", args)
		if changed {k.changed += 1}
		if !handled {core.notice(s, c, "Kit: not a setting")}
		return true
	},
}

// The command sets a setting in its bounds and says so; out of them it is refused, with
// the setting's usage; a name that is no setting is the game's own; a player without
// the node may not.
@(test)
test_settings_command :: proc(t: ^testing.T) {
	sess := new(core.Session)
	defer free(sess)
	config := core.harness_world()
	config.game = KIT_GAME
	if !testing.expect(t, core.session_start(sess, {}, false, with = config)) {return}
	defer core.session_stop(sess)
	welcomed :: proc(data: rawptr) -> bool {return (^core.Session)(data).mirror.welcomed}
	_, ok := core.harness_step_until(&sess.h, welcomed, sess, 600)
	if !testing.expect(t, ok) {return}
	s := &sess.h.srv
	k := core.game_state(s, Kit_State)
	say :: proc(sess: ^core.Session, text: string) -> string {
		core.command(&sess.mirror, text)
		core.harness_step(&sess.h, 2)
		n := sess.mirror.notices
		return n[len(n) - 1] if len(n) > 0 else ""
	}
	testing.expect_value(
		t,
		say(sess, "kit set frags 9"),
		"Kit: frags = 9 (the first to this many wins)",
	)
	testing.expect_value(t, k.settings.frags, 9)
	testing.expect_value(t, say(sess, "kit set respawn 31"), "Kit: respawn <0..30>")
	testing.expect_value(t, say(sess, "kit set frags many"), "Kit: frags <1..200>")
	testing.expect_value(t, k.settings, Test_Settings{9, 2})
	testing.expect_value(t, k.changed, 1)
	testing.expect_value(t, say(sess, "kit lives 3"), "Kit: not a setting")
	// The namespace: `set` and a setting's name; the game's own command may share a name.
	testing.expect_value(
		t,
		say(sess, "kit set respawn 4"),
		"Kit: respawn = 4 (seconds from a death to coming back)",
	)
	testing.expect_value(t, k.settings.respawn, 4)
	testing.expect_value(
		t,
		say(sess, "kit set lives 3"),
		"Kit: no setting lives (set frags <1..200> | set respawn <0..30>)",
	)
	testing.expect_value(
		t,
		say(sess, "kit set"),
		"Kit: frags 9, respawn 4 (set frags <1..200> | set respawn <0..30>)",
	)
	testing.expect_value(t, say(sess, "kit frags"), "Kit: not a setting")
	// Without the node (the host holds every one; here they are taken away a while).
	owned := s.clients[0].grants
	s.clients[0].grants = {}
	testing.expect_value(
		t,
		say(sess, "kit set frags 3"),
		"You may not change Kit's settings (kit.admin)",
	)
	s.clients[0].grants = owned
	testing.expect_value(t, k.settings.frags, 9)
}
