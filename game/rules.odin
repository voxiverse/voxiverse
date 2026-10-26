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
	day_length:        f32, // seconds from one midnight to the next (time.odin)
	daylight_cycle:    bool, // time passes (false: it stands still)
	drops:             bool, // a block a player breaks leaves its item
	damage:            bool, // players take damage (falls, explosions) and can die
	death_drops:       bool, // a player who dies drops their inventory where they fell (else keeps it)
	random_tick_speed: i32, // blocks picked in each chunk each tick to change by themselves (0: none)
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
	day_length        = 1200,
	daylight_cycle    = true,
	drops             = true,
	damage            = true,
	random_tick_speed = 3,
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
	{field = "day_length", help = "seconds per day and night", min = 10, max = 86400, step = 60},
	{field = "daylight_cycle", help = "time passes (off: the sun stands still)"},
	{field = "drops", help = "a block a player breaks leaves its item"},
	{field = "damage", help = "players take damage (falls, explosions) and can die"},
	{field = "death_drops", help = "a player who dies drops their inventory where they fell"},
	{
		field = "random_tick_speed",
		help = "blocks picked in each chunk each tick: grass spreads, crops grow (0: none)",
		min = 0,
		max = 100,
		step = 1,
	},
}

rules_table :: proc() -> base.Var_Table {
	return {"rules.", Rules, RULES_VARS[:], &RULES_DEFAULTS}
}

// rules_still: the defaults with nothing changing by itself (random ticks
// off): the world of every test that compares worlds, and of the benchmarks
// and exit checks. One switch here, so a new self-changing thing joins it once.
rules_still :: proc() -> Rules {
	r := RULES_DEFAULTS
	r.random_tick_speed = 0
	return r
}

// rules_valid: every rule within its table range (rules from the wire).
rules_valid :: proc(r: ^Rules) -> bool {
	t := rules_table()
	for &v in t.vars {
		kind, _ := base.var_kind(t, &v)
		if kind == .Bool {continue}
		value := base.var_get_f64(t, r, &v)
		if !(value >= v.min && value <= v.max) {return false}
	}
	return true
}
