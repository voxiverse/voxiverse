package server

import "core:log"
import "core:math"
import "core:strings"

import "../common/game"

// The desync detector (docs/determinism.md): the client hashes the state it
// predicted every DESYNC_CHECK_INPUTS inputs (a Prediction_Check); the server
// hashes its own after the same input and names the fields that differ. A
// check is judged only if the player has been quiet: nothing but its own
// inputs could have changed its movement for DESYNC_QUIET_TICKS (a round trip
// is shorter). A check never changes state.

// disturb marks that something besides c's own inputs changed, or may have
// changed, its movement just now: a teleport, a landing, a knockback, a rules
// change, an input refused, a block moved beside it.
@(private)
disturb :: proc(s: ^Server, c: ^Client) {
	c.disturbed = s.tick
}

@(private)
disturb_world :: proc(s: ^Server, w: ^World) {
	for &c in s.clients {
		if c.state == .Playing && c.world == w {disturb(s, &c)}
	}
}

// DESYNC_NEAR: how far (blocks) from a player's box a changed block disturbs it.
DESYNC_NEAR :: 4

// disturb_near_changes: c is disturbed by a block changed within DESYNC_NEAR of
// its box (water, a rocket's crater, another player's edit), or a bulk edit of
// a chunk that reaches it.
@(private)
disturb_near_changes :: proc(
	s: ^Server,
	c: ^Client,
	edits: []game.Block_Pos,
	bulk: []game.Chunk_Pos,
) {
	p := c.player.position
	lo := game.Block_Pos {
		i32(math.floor(p.x - game.PLAYER_WIDTH / 2)) - DESYNC_NEAR,
		i32(math.floor(p.y)) - DESYNC_NEAR,
		i32(math.floor(p.z - game.PLAYER_WIDTH / 2)) - DESYNC_NEAR,
	}
	hi := game.Block_Pos {
		i32(math.floor(p.x + game.PLAYER_WIDTH / 2)) + DESYNC_NEAR,
		i32(math.floor(p.y + game.PLAYER_HEIGHT)) + DESYNC_NEAR,
		i32(math.floor(p.z + game.PLAYER_WIDTH / 2)) + DESYNC_NEAR,
	}
	for e in edits {
		if e.x >= lo.x && e.x <= hi.x && e.y >= lo.y && e.y <= hi.y && e.z >= lo.z && e.z <= hi.z {
			disturb(s, c)
			return
		}
	}
	for pos in bulk {
		origin := game.chunk_origin(pos)
		far := origin + game.CHUNK_SIZE - 1
		if far.x >= lo.x &&
		   origin.x <= hi.x &&
		   far.y >= lo.y &&
		   origin.y <= hi.y &&
		   far.z >= lo.z &&
		   origin.z <= hi.z {
			disturb(s, c)
			return
		}
	}
}

// check_judge compares c's check, when the input it follows has just been
// applied (sequence), with the server's own state.
@(private)
check_judge :: proc(s: ^Server, c: ^Client, sequence: u32) {
	check, has := c.check.?
	if !has || check.sequence != sequence {return}
	c.check = nil
	if s.tick - c.disturbed < game.DESYNC_QUIET_TICKS {
		s.checks_skipped += 1
		return
	}
	s.checks_judged += 1
	mine := game.player_fields(c.player)
	if mine == check.fields {return}
	s.desyncs += 1
	for f in game.Player_Field {
		if mine[f] != check.fields[f] {s.desync_fields[f] += 1}
	}
	names := make([dynamic]string, context.temp_allocator)
	for f in game.Player_Field {
		if mine[f] !=
		   check.fields[f] {append(&names, strings.to_lower(game.PLAYER_FIELD_NAMES[f], context.temp_allocator))}
	}
	log.warnf(
		"server desync player=%s sequence=%d fields=%s",
		client_name(c),
		sequence,
		strings.join(names[:], ",", context.temp_allocator),
	)
}
