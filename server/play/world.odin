package play

import "core:fmt"

import "server:core"

// configure_flat: a game played on ground of its own: a flat world with nothing
// wandering into it, arriving at spawn, in mode unless the universe asks for another
// (the game's configure hook calls it, then changes what it wants otherwise).
configure_flat :: proc(config: ^core.Config, spawn: [3]f64, mode: string) {
	config.generator = .Flat
	config.no_natural_spawns = true
	config.spawn = spawn
	if config.mode == "" {config.mode = mode}
}

// world_still: a world a game stages its rounds in, from its start hook: the time stands
// at clock (0.5: noon), nothing grows or changes by itself and nothing broken drops (no
// pillaring up with what a blast throws).
world_still :: proc(s: ^core.Server, w: ^core.World, clock := 0.5) {
	core.game_rule(s, w, "daylight_cycle", "false")
	core.game_rule(s, w, "drops", "false")
	core.game_rule(s, w, "random_tick_speed", "0")
	w.clock = clock
}

// world_rule: a world's rule set to a value of any type, as text (core.game_rule).
world_rule :: proc(s: ^core.Server, w: ^core.World, name: string, value: any) {
	core.game_rule(s, w, name, fmt.tprint(value))
}

// here: c is playing in the session's home world, where a game stages its rounds.
here :: proc(s: ^core.Server, c: ^core.Client) -> bool {
	return c.state == .Playing && c.world == s.home
}

// present: the players here.
present :: proc(s: ^core.Server) -> (n: int) {
	for &c in s.clients {if here(s, &c) {n += 1}}
	return
}
