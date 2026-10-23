package client

import "core:testing"

import "../game"

// Creative tools only where cheats are allowed; the selection stays on the
// hotbar when it shrinks.
@(test)
test_hotbar_items :: proc(t: ^testing.T) {
	s := new(Session)
	defer free(s)
	s.state = .Playing
	all := len(hotbar_items(s))
	s.welcome.cheats = true
	testing.expect_value(t, len(hotbar_items(s)), len(HOTBAR))
	testing.expect(t, all < len(HOTBAR), "the launcher shown without cheats")
	s.hotbar = len(HOTBAR) - 1
	_, tool := held_item(s).(Tool)
	testing.expect(t, tool)
	s.welcome.cheats = false
	block, is_block := held_item(s).(game.Block)
	testing.expect(t, is_block && game.can_place(block))
	for item in HOTBAR {testing.expect(t, item_name(item) != "")}
}
