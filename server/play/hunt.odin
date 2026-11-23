package play

import "core:math"

import "common:game"
import "server:core"

// Hunting: a creature that fights (its kind's attack: a blow, a shot) going for a player.
// Whom it goes for and when is its game's; how it closes in and attacks is its kind's data
// (the attack's keep, shoot and notice: docs/packs.md), the same in every game and every
// world. Horde picks each creature's prey and calls hunt; the sandbox lets every fighting
// creature of a world go for the players near it (hunt_tick).

// hunt: creature h of w goes for prey: it keeps its kind's band of distances from the
// player's feet and, as its attack allows, strikes it or shoots at its chest. A shooter
// shoots between its shoot distances when it sees the player and strikes when nearer;
// any other strikes.
hunt :: proc(s: ^core.Server, w: ^core.World, h: game.Entity_Handle, prey: ^core.Client) {
	a, fights := game.kind_info(s.registry, core.entity_kind(w, h)).attack.?
	if !fights {return}
	feet := prey.player.position
	chest := feet + {0, 1.1, 0}
	d := core.entity_pos(w, h) - feet
	distance := math.sqrt(d.x * d.x + d.z * d.z)
	core.entity_keep(w, h, feet, a.keep[0], a.keep[1])
	switch {
	case a.shot == 0 || distance < f64(a.shoot[0]):
		core.entity_strike(w, h, prey)
	case distance <= f64(a.shoot[1]) && core.entity_sees(w, h, chest):
		core.entity_shoot(w, h, chest)
	}
}

// prey_nearest: the player in w nearest p (horizontally) within radius blocks that may
// says a creature goes for (nil: none); of two as near, the first seat's.
prey_nearest :: proc(
	s: ^core.Server,
	w: ^core.World,
	p: [3]f64,
	radius: f64,
	may: proc(s: ^core.Server, c: ^core.Client) -> bool,
) -> ^core.Client {
	best: ^core.Client
	best_d := radius * radius
	for &c in s.clients {
		if c.world != w || !may(s, &c) {continue}
		d := c.player.position - p
		dist := d.x * d.x + d.z * d.z
		if dist < best_d {best, best_d = &c, dist}
	}
	return best
}

// prey_fair: c plays, alive, in a mode that can be hurt (it has health and is neither
// invulnerable nor bodiless: not creative, not a spectator), so an open world's creature
// goes for it.
prey_fair :: proc(s: ^core.Server, c: ^core.Client) -> bool {
	if c.state != .Playing || c.dead {return false}
	abilities := game.derive_abilities(s.registry, c.mode, &c.inventory)
	return .Health in abilities && .Invulnerable not_in abilities && .Bodiless not_in abilities
}

// hunt_tick: every creature of w that fights and that its game steers (`"brain":
// "steered"` with an attack) goes for the fair player nearest it within its attack's
// notice (prey_fair), or stands where it is when none is: an open world's hostile
// creatures, each tick. A world nobody plays in is left as it is. leave (optional) says
// which creatures the game hunts with otherwise (a crowd's: crowd_tick); they are skipped.
hunt_tick :: proc(
	s: ^core.Server,
	w: ^core.World,
	leave: proc(s: ^core.Server, w: ^core.World, h: game.Entity_Handle) -> bool = nil,
) {
	players, fair := 0, 0
	for &c in s.clients {
		if c.state != .Playing || c.world != w {continue}
		players += 1
		if prey_fair(s, &c) {fair += 1}
	}
	if players == 0 {return}
	it := core.entities_each(w)
	for h in core.entities_next(&it) {
		info := game.kind_info(s.registry, core.entity_kind(w, h))
		a, fights := info.attack.?
		if !fights || info.brain != .Steered || (leave != nil && leave(s, w, h)) {continue}
		prey: ^core.Client
		if fair > 0 {prey = prey_nearest(s, w, core.entity_pos(w, h), f64(a.notice), prey_fair)}
		if prey == nil {core.entity_stand(w, h)} else {hunt(s, w, h, prey)}
	}
}
