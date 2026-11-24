package sandbox_server

import "common:game"
import "server:play"

// The gate worlds' own creatures (the pack's data/entities/natives.json, which says what
// each is, where and when it comes and what it leaves): of the roster (wild.odin), their
// minds its pieces, each living on one world class alone (games/sandbox/worlds.odin,
// CLASS_NATIVES, which the spawned hook enforces). The temperate world's thistlebuck grazes
// with its herd as a loper does; the canyon's sailback, the frozen world's rimeclaw, the
// ocean's surfclaw and the jungle's striper guard their ground as a hacklebird does, each
// warning first; the volcanic world's cinderhounds circle and dart in as duskrunners do; the
// fungal world's sporemaw lies hidden as a pitmaw does; the ocean's driftray swims as a
// glassfin, and the fungal lanternmoth and the jungle's leafwing fly as a wheelwing.

// NATIVES: the roster's gate-world creatures.
NATIVES :: bit_set[Wild] {
	.Thistlebuck,
	.Sailback,
	.Rimeclaw,
	.Surfclaw,
	.Driftray,
	.Cinderhound,
	.Sporemaw,
	.Lanternmoth,
	.Striper,
	.Leafwing,
}

SAIL_TEMPER :: play.Temper {
	notice   = 10,
	near     = 5,
	warn     = game.TICK_RATE * 2,
	leash    = 18,
	patience = game.TICK_RATE * 6,
	wind     = 12,
	may      = wild_prey,
}
RIME_TEMPER :: play.Temper {
	notice   = 14,
	near     = 7,
	warn     = game.TICK_RATE,
	leash    = 28,
	patience = game.TICK_RATE * 8,
	wind     = 15,
	may      = wild_prey,
}
SURF_TEMPER :: play.Temper {
	notice   = 8,
	near     = 4,
	warn     = game.TICK_RATE * 3 / 2,
	leash    = 12,
	patience = game.TICK_RATE * 6,
	wind     = 14,
	may      = wild_prey,
}
SPORE_TEMPER :: play.Temper {
	notice   = 5,
	warn     = game.TICK_RATE,
	leash    = 12,
	patience = game.TICK_RATE * 5,
	wind     = 12,
	may      = wild_prey,
}
STRIPE_TEMPER :: play.Temper {
	notice   = 12,
	near     = 6,
	warn     = game.TICK_RATE * 3 / 2,
	leash    = 24,
	patience = game.TICK_RATE * 8,
	wind     = 12,
	may      = wild_prey,
}

SURF_SHELL :: 0.5 // of any harm that gets through a surfclaw's shell while it is not fighting
