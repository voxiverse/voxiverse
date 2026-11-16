package arena

import "common:game"

// The game's pack (games/arena/pack, docs/games.md): its two game modes, arena:fighter
// (in the match: health, the kit, nothing dropped) and arena:watching (between
// matches: flying, unharmed, changing nothing). Loaded only where Arena is played.
PACK :: game.Pack_Source {
	namespace = "arena",
	files     = {
		{"pack.json", #load("pack/pack.json")},
		{"data/game_modes/modes.json", #load("pack/data/game_modes/modes.json")},
	},
}

FIGHTER_MODE :: "arena:fighter"
WATCHING_MODE :: "arena:watching"
