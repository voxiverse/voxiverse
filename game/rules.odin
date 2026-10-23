package game

import "../base"

// Game rules: the tunable numbers of the simulation. The server owns them
// and sends them to clients (Welcome, and on change) so client prediction
// runs on the same numbers; see PLAN.md, "Console and variables". The
// defaults follow Minecraft's feel (blocks, seconds).

Rules :: struct {
	gravity:           f32, // blocks/s²
	terminal_velocity: f32, // blocks/s, falling
	walk_speed:        f32, // blocks/s
	sprint_speed:      f32,
	sneak_speed:       f32,
	jump_height:       f32, // blocks
	fly_speed:         f32,
	fly_sprint_speed:  f32,
	ground_control:    f32, // how fast velocity follows input on the ground (1/s)
	air_control:       f32, // ... in the air
	reach:             f32, // blocks, for breaking and placing
	allow_flying:      bool,
}

@(rodata)
RULES_DEFAULTS := Rules {
	gravity           = 32,
	terminal_velocity = 78.4,
	walk_speed        = 4.317,
	sprint_speed      = 5.612,
	sneak_speed       = 1.31,
	jump_height       = 1.25,
	fly_speed         = 10.92,
	fly_sprint_speed  = 21.6,
	ground_control    = 20,
	air_control       = 3,
	reach             = 5,
	allow_flying      = true,
}

@(rodata)
RULES_VARS := [?]base.Var {
	{field = "gravity", help = "blocks/s²", min = 0, max = 200, step = 0.5},
	{field = "terminal_velocity", help = "fastest fall, blocks/s", min = 1, max = 500, step = 1},
	{field = "walk_speed", help = "blocks/s", min = 0, max = 50, step = 0.1},
	{field = "sprint_speed", help = "blocks/s", min = 0, max = 50, step = 0.1},
	{field = "sneak_speed", help = "blocks/s", min = 0, max = 50, step = 0.1},
	{field = "jump_height", help = "blocks", min = 0, max = 20, step = 0.05},
	{field = "fly_speed", help = "blocks/s", min = 0, max = 200, step = 0.5},
	{field = "fly_sprint_speed", help = "blocks/s", min = 0, max = 400, step = 0.5},
	{
		field = "ground_control",
		help = "how quickly movement follows input on the ground, 1/s",
		min = 0.1,
		max = 100,
		step = 0.5,
	},
	{
		field = "air_control",
		help = "how quickly movement follows input in the air, 1/s",
		min = 0,
		max = 100,
		step = 0.5,
	},
	{
		field = "reach",
		help = "how far blocks can be broken and placed, blocks",
		min = 1,
		max = 64,
		step = 0.5,
	},
	{field = "allow_flying", help = "players may fly (double-tap jump)"},
}

rules_table :: proc() -> base.Var_Table {
	return {"rules.", Rules, RULES_VARS[:], &RULES_DEFAULTS}
}
