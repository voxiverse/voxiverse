package client

import "../common/game"

// test_mode puts a test session in the base pack's game mode name (its abilities
// are what the checks that were once grants of items.catalog and items.infinite ask).
test_mode :: proc(s: ^Session, name: string) {
	m, ok := game.mode_find(s.reg, name)
	assert(ok)
	s.mode = m
}
