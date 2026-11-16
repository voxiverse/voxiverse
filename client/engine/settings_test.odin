package engine

import "core:testing"

import "common:access"
import "common:base"
import "common:game"

// Two players who never chose a name join one server under names of their own: a server
// keeps a name for the account that first played it, so a shared default would send the
// second away. A chosen name is the name everywhere; our own world keeps the default.
@(test)
test_unnamed_players_join_apart :: proc(t: ^testing.T) {
	settings := SETTINGS_DEFAULTS
	alice, bob: access.Account
	alice[0], alice[1] = 0x3f, 0x0a
	bob[0], bob[1] = 0x3f, 0x0b
	testing.expect_value(t, join_name(&settings, alice), "Player-3f0a")
	testing.expect(t, join_name(&settings, alice) != join_name(&settings, bob))
	testing.expect(t, game.name_valid(join_name(&settings, alice)))
	testing.expect_value(t, player_name(&settings), DEFAULT_NAME)

	base.var_text_set(&settings.name, "alice")
	testing.expect_value(t, join_name(&settings, alice), "alice")
	testing.expect_value(t, player_name(&settings), "alice")
}
