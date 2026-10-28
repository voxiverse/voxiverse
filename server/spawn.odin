package server

import "core:fmt"
import "core:log"
import "core:math"
import "core:strconv"

import "../common/game"
import "../common/worldgen"

// The world spawn and landings: every arrival (joining, a teleport, spawn)
// goes through land, and the player stands where game.landing_spot says
// once the blocks there are loaded (until then they wait there, still).

// World_Spawn: where new players arrive. The generator's (on open ground,
// chosen once with the world) lands on the ground; one set with
// setworldspawn lands exactly there.
World_Spawn :: struct {
	position: [3]f64,
	look:     [2]f32, // yaw, pitch
	exact:    bool, // set by a player (else: on the ground of its column)
	known:    bool, // read from world.cfg or chosen
}

// Landing: a client's arrival waiting for its blocks.
Landing :: struct {
	position: [3]f64,
	mode:     game.Landing_Mode,
	since:    u64, // tick it began
}

// LANDING_TIMEOUT: ticks a landing waits for its blocks before the player is
// let go where they are (10 s; a world that slow has worse problems).
LANDING_TIMEOUT :: 10 * game.TICK_RATE

// spawn_choose: a world without a spawn gets the generator's.
@(private)
spawn_choose :: proc(w: ^World) {
	s := w.server
	if w.spawn.known {return}
	w.spawn = {
		position = s.config.spawn.? or_else worldgen.spawn_point(&w.chunks.gen),
		known    = true,
	}
	log.infof("server world spawn chosen at=%v", w.spawn.position)
}

// land moves c's player to position (looking look) and holds them until
// the blocks there are loaded, then stands them where they fit. Where they
// were is kept for back (not when they arrive in the world).
@(private)
land :: proc(
	s: ^Server,
	c: ^Client,
	position: [3]f64,
	look: [2]f32,
	mode: game.Landing_Mode,
	remember := true,
) {
	if remember {c.back = Place{c.world.address, c.player.position, c.look}}
	c.player = {
		position = position,
		flying   = c.player.flying, // a flyer arrives flying
	}
	c.teleport = look
	c.teleported = true
	disturb(s, c)
	c.landing = Landing{position, mode, s.tick}
	set_position(c, position)
}

// land_at_spawn: land at the world spawn.
@(private)
land_at_spawn :: proc(s: ^Server, c: ^Client, remember := true) {
	w := c.world
	land(s, c, w.spawn.position, w.spawn.look, .Exact if w.spawn.exact else .Ground, remember)
}

// landing_tick: true while c's landing still waits (the player is then held
// still).
@(private)
landing_tick :: proc(s: ^Server, c: ^Client) -> bool {
	w := c.world
	l, waiting := c.landing.?
	if !waiting {return false}
	query := game.Block_Query{&w.chunks, chunks_block, &w.server.registry.blocks}
	from := l.position
	if l.mode == .Ground {
		// From above everything the column has.
		x, z := i32(math.floor(from.x)), i32(math.floor(from.z))
		from.y = max(from.y, f64(column_top(w, x, z) + 1))
	}
	spot, found := game.landing_spot(query, from, l.mode)
	if !found {
		if s.tick - l.since < LANDING_TIMEOUT {return true}
		spot = l.position
		log.warnf("server landing timed out player=%d at=%v", player_id(s, c), spot)
	}
	c.landing = nil
	if spot != c.player.position {
		c.player.position = spot
		c.player.velocity = {}
		c.teleported = true
		disturb(s, c)
		set_position(c, spot)
	}
	return false
}

// admin_spawn: back to the world spawn.
@(private)
admin_spawn :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	land_at_spawn(s, c)
	return true
}

// admin_setworldspawn: the world spawn becomes here (or x y z), looking as
// the player looks.
@(private)
admin_setworldspawn :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	w := c.world
	at := c.player.position
	if len(args) == 3 {
		for a, i in args {
			v, ok := strconv.parse_f64(a)
			if !ok || abs(v) >= game.WORLD_LIMIT {return false}
			at[i] = v
		}
	} else if len(args) != 0 {return false}
	w.spawn = {
		position = at,
		look     = c.look,
		exact    = true,
		known    = true,
	}
	log.infof("server world spawn set at=%v by=%s", at, client_name(c))
	notice(s, c, fmt.tprintf("World spawn set to %.1f %.1f %.1f", at.x, at.y, at.z))
	return true
}
