package server

import "core:fmt"
import "core:log"
import "core:slice"
import "core:strconv"
import "core:strings"

import "../game"
import "../netcode"
import "../worldgen"

// Admin commands: what a player who may cheat can ask of the server, as
// text (game.Command; the console's commands send them). Each one checks its
// own arguments; bad ones and unknown commands are answered with a notice.

@(private = "file")
Admin_Command :: struct {
	name:  string,
	usage: string, // its arguments
	args:  [2]int, // how many: at least, at most
	run:   proc(s: ^Server, c: ^Client, args: []string) -> bool, // false: bad arguments
	node:  string, // the permission it needs
}

@(private = "file", rodata)
ADMIN_COMMANDS := [?]Admin_Command {
	{"save", "", {0, 0}, admin_save, "server.save"},
	{
		"time",
		"<0..1 | sunrise | day | noon | sunset | night | midnight>",
		{1, 1},
		admin_time,
		"world.time",
	},
	{"fill", "<x1 y1 z1 x2 y2 z2> <block>", {7, 7}, admin_fill, "world.edit.bulk"},
	{"replace", "<x1 y1 z1 x2 y2 z2> <from> <to>", {8, 8}, admin_replace, "world.edit.bulk"},
	{"sphere", "<x y z> <radius> <block>", {5, 5}, admin_sphere, "world.edit.bulk"},
	{"explode", "<x y z> <radius>", {4, 4}, admin_explode, "world.explode"},
	{"summon", "[kind]", {0, 1}, admin_summon, "world.summon"},
	{"open_lan", "", {0, 0}, admin_open_lan, "server.open_lan"},
	{"hash", "", {0, 0}, admin_hash, "debug.hash"},
	{"locate", "<biome or structure>", {1, 1}, admin_locate, "teleport.locate"},
	{"spawn", "", {0, 0}, admin_spawn, "teleport.spawn"},
	{"delmsg", "<player> [count]", {1, 2}, admin_delmsg, "chat.delete"},
	{"mute", "<player> [30m|2h|7d]", {1, 2}, admin_mute, "moderation.mute"},
	{"unmute", "<player>", {1, 1}, admin_unmute, "moderation.mute"},
	{"ignore", "<player>", {1, 1}, admin_ignore, "chat.ignore"},
	{"setworldspawn", "[x y z]", {0, 3}, admin_setworldspawn, "world.spawn"},
	{"regen", "[radius in chunks, 1..8]", {0, 1}, admin_regen, "world.gen"},
	{
		"structure",
		"save <name> <x1 y1 z1 x2 y2 z2> [clear] | paste <name> <x y z> [quarter turns] | list",
		{1, 9},
		admin_structure,
		"world.structure",
	},
	{
		"role",
		"list | info <role> | grant|revoke <role> <node> | inherit|uninherit <role> <role> | meta <role> <key> [value] | delete <role>",
		{1, 64}, // (a meta value has spaces)
		admin_role,
		"permissions.edit",
	},
	{
		"user",
		"info <player> | role add|remove <player> <role> | grant|revoke <player> <node> | meta <player> <key> [value]",
		{2, 64},
		admin_user,
		"permissions.edit",
	},
}

// admin runs a command from c.
admin :: proc(s: ^Server, c: ^Client, command: string) {
	f := strings.fields(command, context.temp_allocator)
	if len(f) == 0 {return}
	for &cmd in ADMIN_COMMANDS {
		if cmd.name != f[0] {continue}
		args := f[1:]
		if !allowed(s, c, cmd.node) {
			notice(s, c, fmt.tprintf("You may not use %s here (%s)", cmd.name, cmd.node))
			return
		}
		if len(args) < cmd.args[0] || len(args) > cmd.args[1] || !cmd.run(s, c, args) {
			notice(s, c, fmt.tprintf("Usage: %s %s", cmd.name, cmd.usage))
		}
		return
	}
	log.warnf("server unknown admin command command=%q by=%s", command, client_name(c))
	notice(s, c, fmt.tprintf("Unknown server command: %s", f[0]))
}

// commands_allowed: the names of the commands c may use, space apart.
@(private)
commands_allowed :: proc(s: ^Server, c: ^Client) -> string {
	b := strings.builder_make(context.temp_allocator)
	for &cmd in ADMIN_COMMANDS {
		if !allowed(s, c, cmd.node) {continue}
		if strings.builder_len(b) > 0 {strings.write_byte(&b, ' ')}
		strings.write_string(&b, cmd.name)
	}
	return strings.to_string(b)
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
	p := c.player.position
	gen := &s.world.gen
	if kind, structure := worldgen.structure_by_name(args[0]); structure {
		st, found := worldgen.locate_structure(gen, kind, i32(p.x), i32(p.z))
		if !found {
			notice(s, c, fmt.tprintf("No %s within 4096 blocks (or not an Earth world)", args[0]))
			return true
		}
		if kind == .Dungeon {
			// Its way in, on the land: south of the stair shaft, looking on.
			at := st.lo + {2, 0, 2}
			c.player.flying = true // looking on from above
			land(s, c, {f64(at.x) + 0.5, f64(st.top) + 5, f64(at.z) + 7.5}, {0, -0.55}, .Exact)
			notice(
				s,
				c,
				fmt.tprintf(
					"%s at %d %d %d (its stairs down are in front of you)",
					args[0],
					st.lo.x,
					st.lo.y,
					st.lo.z,
				),
			)
			return true
		}
		// South of it and above, facing north, looking down on it.
		middle := (st.lo + st.hi) / 2
		top := max(st.hi.y, worldgen.column_top(gen, middle.x, middle.z))
		size := st.hi - st.lo + 1
		back := f64(max(size.x, size.z)) + 8
		c.player.flying = true // looking on from above
		land(
			s,
			c,
			{f64(middle.x) + 0.5, f64(top) + back * 0.8, f64(middle.z) + 0.5 + back},
			{0, -0.65},
			.Exact,
		)
		notice(s, c, fmt.tprintf("%s at %d %d %d", args[0], st.lo.x, st.lo.y, st.lo.z))
		return true
	}
	biome := worldgen.biome_by_name(args[0]) or_return
	at, found := worldgen.locate(gen, biome, i32(p.x), i32(p.z))
	if !found {
		notice(s, c, fmt.tprintf("No %s within 4096 blocks (or not an Earth world)", args[0]))
		return true
	}
	top := worldgen.column_top(gen, at.x, at.y)
	c.player.flying = true // looking on from above
	land(
		s,
		c,
		{f64(at.x) + 0.5, f64(max(top, gen.params.sea_level)) + 24, f64(at.y) + 0.5},
		{c.look[0], -1.25},
		.Exact,
	) // looking down at it
	notice(s, c, fmt.tprintf("%s at %d %d", args[0], at.x, at.y))
	return true
}

@(private = "file")
admin_structure :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	switch args[0] {
	case "list":
		notice(s, c, structure_list(s))
	case "save":
		if len(args) != 8 && len(args) != 9 {return false}
		if !structure_name_valid(args[1]) {return false}
		box := parse_box(args[2:8]) or_return
		clear := len(args) == 9 && args[8] == "clear"
		if len(args) == 9 && !clear {return false}
		notice(s, c, structure_save(s, args[1], box.lo, box.hi, clear))
	case "paste":
		if len(args) != 5 && len(args) != 6 {return false}
		if !structure_name_valid(args[1]) {return false}
		n: [3]i32
		parse_coords(args[2:5], n[:]) or_return
		turns := 0
		if len(args) == 6 {turns = strconv.parse_int(args[5]) or_return}
		if turns < 0 || turns > 3 {return false}
		notice(s, c, structure_paste(s, args[1], n, u8(turns)))
	case:
		return false
	}
	return true
}

@(private = "file")
admin_regen :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	radius := 4
	if len(args) > 0 {radius = strconv.parse_int(args[0]) or_return}
	if radius < 1 || radius > 8 {return false}
	notice(s, c, fmt.tprintf("regen: %d chunks made again", regen(s, c, i32(radius))))
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

// admin_role edits a role (it is made by its first grant, inherit or meta).
@(private = "file")
admin_role :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	p := &s.perms
	switch args[0] {
	case "list":
		names := make([dynamic]string, context.temp_allocator)
		for name in p.roles {append(&names, name)}
		slice.sort(names[:])
		notice(
			s,
			c,
			fmt.tprintf("Roles: %s", strings.join(names[:], ", ", context.temp_allocator)),
		)
		return true
	case "info":
		if len(args) != 2 {return false}
		r, ok := &p.roles[args[1]]
		if !ok {
			notice(s, c, fmt.tprintf("No role %s", args[1]))
			return true
		}
		meta := make([dynamic]string, context.temp_allocator)
		for k, v in r.meta {append(&meta, fmt.tprintf("%s=%q", k, v))}
		notice(
			s,
			c,
			fmt.tprintf(
				"%s: inherits %v; grants %v; meta %v",
				args[1],
				r.inherits[:],
				r.grants[:],
				meta[:],
			),
		)
		return true
	}
	if len(args) < 2 || !role_name_valid(args[1]) {return false}
	switch args[0] {
	case "delete":
		if len(args) != 2 {return false}
		if key, r, ok := map_entry_role(p, args[1]); ok {
			role_free(&r)
			delete_key(&p.roles, args[1])
			delete(key)
		}
	case "grant", "revoke":
		if len(args) != 3 {return false}
		game.grant_parse(args[2], 0) or_return
		r := role_get(p, args[1])
		list_set(&r.grants, args[2], args[0] == "grant")
	case "inherit", "uninherit":
		if len(args) != 3 || !role_name_valid(args[2]) || args[1] == args[2] {return false}
		r := role_get(p, args[1])
		list_set(&r.inherits, args[2], args[0] == "inherit")
	case "meta":
		if len(args) < 3 {return false}
		r := role_get(p, args[1])
		meta_set(&r.meta, args[2], strings.join(args[3:], " ", context.temp_allocator))
	case:
		return false
	}
	permissions_changed(s)
	notice(s, c, fmt.tprintf("role %s: done", args[1]))
	return true
}

// admin_user edits a player's roles, grants and metadata.
@(private = "file")
admin_user :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	p := &s.perms
	switch args[0] {
	case "info":
		if len(args) != 2 || !game.name_valid(args[1]) {return false}
		pl, ok := &p.players[args[1]]
		if !ok {
			notice(s, c, fmt.tprintf("%s: the role default only", args[1]))
			return true
		}
		notice(s, c, fmt.tprintf("%s: roles %v; grants %v", args[1], pl.roles[:], pl.grants[:]))
	case "role":
		if len(args) != 4 || !game.name_valid(args[2]) || !role_name_valid(args[3]) {return false}
		if args[1] != "add" && args[1] != "remove" {return false}
		list_set(&player_perms(p, args[2]).roles, args[3], args[1] == "add")
	case "grant", "revoke":
		if len(args) != 3 || !game.name_valid(args[1]) {return false}
		game.grant_parse(args[2], 0) or_return
		list_set(&player_perms(p, args[1]).grants, args[2], args[0] == "grant")
	case "meta":
		if len(args) < 3 || !game.name_valid(args[1]) {return false}
		meta_set(
			&player_perms(p, args[1]).meta,
			args[2],
			strings.join(args[3:], " ", context.temp_allocator),
		)
	case:
		return false
	}
	if args[0] != "info" {
		permissions_changed(s)
		notice(s, c, "user: done")
	}
	return true
}
