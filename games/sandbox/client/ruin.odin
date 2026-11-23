package sandbox_client

import "client:engine"
import "client:ui"
import "games:sandbox"

// The ruined site's fight (games/sandbox/server/ruin.odin), as the player locked in it is
// told it: a bar across the top with the wave and the creatures left, the countdown or the
// break. Nothing shows while the player fights none.

// ruin_received: the fight the server last put.
ruin_received :: proc(s: ^engine.Session, v: ^sandbox.Ruin_Fight) {view(s).ruin = v^}

// ruin_hud: the fight's bar, while the player fights.
ruin_hud :: proc(s: ^engine.Session, ctx: ^ui.Context) {
	f := view(s).ruin
	rest := ctx.screen
	switch f.phase {
	case .Asleep:
	case .Countdown:
		engine.top_bar(ctx, &rest, sandbox.tr(.Ruin_Countdown, f.left))
	case .Wave:
		engine.top_bar(
			ctx,
			&rest,
			sandbox.tr(.Ruin_Wave, f.wave, f.waves, int(f.alive) + int(f.to_come)),
		)
	case .Break:
		engine.top_bar(ctx, &rest, sandbox.tr(.Ruin_Break, f.wave, f.waves, f.left))
	}
}
