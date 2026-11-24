package sandbox_client

import "client:engine"
import "client:ui"
import "common:game"
import "games:sandbox"

// The custodian's fight under a delve (games/sandbox/server/delve_boss.odin), as a player in
// its chamber is told it: the foe's bar under the compass (engine.boss_bar) naming it, its
// phase, its health and, under it, whether its casing stands open; the target frame leaves
// the custodian to the bar (engine.hud_boss). Nothing shows while the player fights none.

CUSTODIAN :: "sandbox:custodian"

// delve_received: the fight the server last put.
delve_received :: proc(s: ^engine.Session, v: ^sandbox.Delve_Fight) {
	view(s).delve = v^
	boss: Maybe(game.Kind_Id)
	if kind, known := game.registry_kind(s.reg, CUSTODIAN); known && v.phase != 0 {boss = kind}
	engine.hud_boss(s, boss)
}

// delve_hud: the custodian's bar, while the player fights it.
delve_hud :: proc(s: ^engine.Session, ctx: ^ui.Context) {
	f := view(s).delve
	if f.phase == 0 {return}
	rest := ctx.screen
	engine.boss_bar(
		ctx,
		&rest,
		sandbox.tr(.Delve_Boss),
		sandbox.tr(.Delve_Boss_Phase, f.phase, f.phases),
		int(f.health),
		int(f.most),
		sandbox.tr(.Delve_Boss_Open) if f.open else "",
	)
}
