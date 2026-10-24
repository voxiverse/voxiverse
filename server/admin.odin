package server

import "core:fmt"
import "core:log"
import "core:strconv"
import "core:strings"

import "../game"
import "../netcode"
import "../worldgen"

// Admin commands: what a player who may cheat can ask of the server, as
// text (game.Admin; the console's commands send them). Each one checks its
// own arguments; bad ones and unknown commands are answered with a notice.

@(private = "file")
Admin_Command :: struct {
	name:  string,
	usage: string, // its arguments
	args:  [2]int, // how many: at least, at most
	run:   proc(s: ^Server, c: ^Client, args: []string) -> bool, // false: bad arguments
}

@(private = "file", rodata)
ADMIN_COMMANDS := [?]Admin_Command {
	{"save", "", {0, 0}, admin_save},
	{"time", "<0..1 | sunrise | day | noon | sunset | night | midnight>", {1, 1}, admin_time},
	{"fill", "<x1 y1 z1 x2 y2 z2> <block>", {7, 7}, admin_fill},
	{"replace", "<x1 y1 z1 x2 y2 z2> <from> <to>", {8, 8}, admin_replace},
	{"sphere", "<x y z> <radius> <block>", {5, 5}, admin_sphere},
	{"explode", "<x y z> <radius>", {4, 4}, admin_explode},
	{"summon", "[kind]", {0, 1}, admin_summon},
	{"open_lan", "", {0, 0}, admin_open_lan},
	{"hash", "", {0, 0}, admin_hash},
	{"locate", "<biome>", {1, 1}, admin_locate},
}

// admin runs a command from c.
admin :: proc(s: ^Server, c: ^Client, command: string) {
	f := strings.fields(command, context.temp_allocator)
	if len(f) == 0 {return}
	for &cmd in ADMIN_COMMANDS {
		if cmd.name != f[0] {continue}
		args := f[1:]
		if len(args) < cmd.args[0] || len(args) > cmd.args[1] || !cmd.run(s, c, args) {
			notice(s, c, fmt.tprintf("Usage: %s %s", cmd.name, cmd.usage))
		}
		return
	}
	log.warnf("server unknown admin command command=%q by=%s", command, client_name(c))
	notice(s, c, fmt.tprintf("Unknown server command: %s", f[0]))
}

@(private = "file")
admin_save :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	notice(s, c, "Saved" if save(s) else "Could not save (see the server log)")
	return true
}

@(private = "file")
admin_time :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	f := game.parse_time_of_day(args[0]) or_return
	s.clock = game.set_time_of_day(s.clock, f)
	log.infof("server time set time=%.4f by=%s", s.clock, client_name(c))
	broadcast(s, game.Time{s.clock})
	return true
}

@(private = "file")
admin_fill :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	box := parse_box(args[:6]) or_return
	block := parse_block(args[6]) or_return
	bulk_notice(s, c, "fill", {shape = box, op = .Set, block = block})
	return true
}

@(private = "file")
admin_replace :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	box := parse_box(args[:6]) or_return
	from := parse_block(args[6]) or_return
	to := parse_block(args[7]) or_return
	bulk_notice(s, c, "replace", {shape = box, op = .Replace, from = from, block = to})
	return true
}

@(private = "file")
admin_sphere :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	center, radius := parse_ball(args[:4]) or_return
	block := parse_block(args[4]) or_return
	bulk_notice(s, c, "sphere", {shape = Sphere{center, radius}, op = .Set, block = block})
	return true
}

@(private = "file")
admin_explode :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	center, radius := parse_ball(args) or_return
	explode(s, center, radius)
	return true
}

@(private = "file")
admin_summon :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	kind := game.Entity_Kind.Critter
	if len(args) > 0 {
		found := false
		for k in game.Entity_Kind {
			if game.ENTITY_INFO[k].name == args[0] &&
			   game.ENTITY_INFO[k].summonable {kind, found = k, true}
		}
		if !found {return false}
	}
	if !summon(s, c, kind) {notice(s, c, "Nowhere to put it (look at open ground nearby)")}
	return true
}

@(private = "file")
admin_open_lan :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	if s.listening {
		notice(s, c, fmt.tprintf("Already open on port %d", s.host.socket.port))
	} else if listen(s, netcode.DEFAULT_PORT, netcode.DEFAULT_PORT + netcode.DISCOVERY_PORTS - 1) {
		notice(s, c, fmt.tprintf("Open to LAN on port %d", s.host.socket.port))
	} else {
		notice(s, c, "Could not open to LAN: no free port (see the log)")
	}
	return true
}

// admin_locate takes the player to the nearest place of a biome (Earth
// worlds), high above it, flying.
@(private = "file")
admin_locate :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	biome := worldgen.biome_by_name(args[0]) or_return
	p := c.player.position
	at, found := worldgen.locate(&s.world.gen, biome, i32(p.x), i32(p.z))
	if !found {
		notice(s, c, fmt.tprintf("No %s within 4096 blocks (or not an Earth world)", args[0]))
		return true
	}
	top := worldgen.column_top(&s.world.gen, at.x, at.y)
	c.player = {
		position = {
			f64(at.x) + 0.5,
			f64(max(top, s.world.gen.params.sea_level)) + 24,
			f64(at.y) + 0.5,
		},
		flying   = true,
	}
	c.teleport = {c.look[0], -1.25} // looking down at it
	c.teleported = true
	notice(s, c, fmt.tprintf("%s at %d %d", args[0], at.x, at.y))
	return true
}

// admin_hash: the chunks this client has, as the server has them (for
// blast_test to compare with its own).
@(private = "file")
admin_hash :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	sum: u64
	for pos in c.has {
		if chunk := world_get(&s.world, pos); chunk != nil && chunk.state == .Ready {
			game.chunks_hash_add(&sum, pos, &chunk.blocks)
		}
	}
	notice(s, c, fmt.tprintf("hash %d %x", len(c.has), sum))
	return true
}

// bulk_notice applies a bulk edit and tells c how it went.
@(private = "file")
bulk_notice :: proc(s: ^Server, c: ^Client, name: string, e: Bulk_Edit) {
	changed, result := bulk_edit(s, e)
	switch result {
	case .Done:
		notice(s, c, fmt.tprintf("%s: %d blocks changed", name, changed))
	case .Too_Big:
		notice(s, c, fmt.tprintf("%s: too big (at most %d blocks)", name, MAX_BULK_VOLUME))
	case .Not_Loaded:
		notice(s, c, fmt.tprintf("%s: part of it is not loaded", name))
	}
}

@(private = "file")
parse_coords :: proc(words: []string, out: []i32) -> bool {
	for w, i in words {
		n := strconv.parse_int(w) or_return
		if abs(n) >= game.WORLD_LIMIT {return false}
		out[i] = i32(n)
	}
	return true
}

@(private = "file")
parse_box :: proc(words: []string) -> (box: Box, ok: bool) {
	n: [6]i32
	parse_coords(words, n[:]) or_return
	return Box{{n[0], n[1], n[2]}, {n[3], n[4], n[5]}}, true
}

// parse_ball: a block's centre and a radius (up to 32).
@(private = "file")
parse_ball :: proc(words: []string) -> (center: [3]f64, radius: f64, ok: bool) {
	n: [3]i32
	parse_coords(words[:3], n[:]) or_return
	radius = strconv.parse_f64(words[3]) or_return
	if !(radius > 0 && radius <= 32) {return}
	return {f64(n[0]) + 0.5, f64(n[1]) + 0.5, f64(n[2]) + 0.5}, radius, true
}

// parse_block: a block a bulk edit may set (air, or a placeable one).
@(private = "file")
parse_block :: proc(name: string) -> (game.Block, bool) {
	b, ok := game.block_by_name(name)
	return b, ok && (b == .Air || game.can_place(b))
}
