package server

import "core:testing"

import "common:base"
import "common:game"

// rules.show_coordinates: on by default, a variable like the others
// (world.cfg, the console), and sent to the clients with the rest of the
// rules; it is the client's F3 that hides the position when it is off, for
// a player without the permission debug.coordinates (client/camera_test.odin).
@(test)
test_show_coordinates_rule :: proc(t: ^testing.T) {
	rules := game.RULES_DEFAULTS
	testing.expect(t, rules.show_coordinates)
	table := game.rules_table()
	testing.expect(t, base.var_table_check(table))
	testing.expect_value(
		t,
		base.var_set(table, &rules, "rules.show_coordinates", "false"),
		base.Var_Error.None,
	)
	testing.expect(t, !rules.show_coordinates)
	// Over the wire.
	w: game.Writer
	game.writer_init(&w)
	defer game.writer_destroy(&w)
	game.encode_server(&w, game.World_Changed{game.address_derive(1), rules}, nil)
	got, ok := game.decode_server(w.buf[:], nil)
	testing.expect(t, ok)
	testing.expect(t, !got.(game.World_Changed).rules.show_coordinates)
}
