package testkit

import "common:game"

// mode: the base pack's game mode of that name (its abilities are what the checks that were
// once grants of items.catalog and items.infinite ask). A test session takes it with
// `s.mode = testkit.mode(s.reg, "survival")`.
mode :: proc(reg: ^game.Registry, name: string) -> int {
	m, ok := game.mode_find(reg, name)
	assert(ok)
	return m
}
