package sandbox_server

import "server:core"
import "server:play"

// Danger: at night the base pack's hostile creatures come out in every world of the
// sandbox, by the spawn rules the sandbox's pack gives them (pack/data/entities/hostile.json:
// which creatures, on what ground, how many and how often, at what hours, and how far from
// a world's spawn point), and go for the players who can be hurt (play.hunt_tick): one in
// creative, or watching, is left alone. A natural one goes when nobody is near. The ruined
// site's creatures are its fight's to steer (ruin.odin), not the night's.

// danger_tick: every open world's hostile creatures hunt, but the ruin's.
danger_tick :: proc(s: ^core.Server) {
	for w in s.worlds {play.hunt_tick(s, w, ruin_hunted)}
}
