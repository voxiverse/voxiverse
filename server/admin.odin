package server

import "core:fmt"
import "core:log"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"

import "../common/game"
import "../common/netcode"
import "../common/worldgen"

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
	// Minecraft's names for what we already have.
	{"tell", "<player> <words>", {2, 64}, admin_msg, "chat.msg"},
	{"w", "<player> <words>", {2, 64}, admin_msg, "chat.msg"},
	{"gamerule", "[name] [value]", {0, 2}, admin_rule, "info.rules"},
	{"say", "<words>", {1, 64}, admin_broadcast, "chat.broadcast"},
	{"teleport", "(as tp)", {1, 5}, admin_tp, "teleport.tp"},
	{"save", "", {0, 0}, admin_save, "server.save"},
	{
		"time",
		"set <0..1 | sunrise | day | noon | sunset | night | midnight> | add <hours> | query",
		{1, 2},
		admin_time,
		"world.time",
	},
	{"setblock", "<x y z> <block>", {4, 4}, admin_setblock, "world.edit.bulk"},
	{"rule", "[name] [value]", {0, 2}, admin_rule, "info.rules"},
	{"gamerule", "[name] [value]", {0, 2}, admin_rule, "info.rules"},
	{"kill", "<kind|all> [radius]", {1, 2}, admin_kill, "world.kill"},
	{"seed", "", {0, 0}, admin_seed, "info.seed"},
	{"wear", "", {0, 0}, admin_wear, "items.wear"},
	{"help", "[command]", {0, 1}, admin_help, "info.help"},
	// World editing: on the selection (selection.odin), or coordinates given.
	{
		"pos1",
		"[x y z]",
		{0, 3},
		proc(s: ^Server, c: ^Client, args: []string) -> bool {return admin_corner(s, c, args, 0)},
		"world.edit.bulk",
	},
	{
		"pos2",
		"[x y z]",
		{0, 3},
		proc(s: ^Server, c: ^Client, args: []string) -> bool {return admin_corner(s, c, args, 1)},
		"world.edit.bulk",
	},
	{"sel", "", {0, 0}, admin_sel, "world.edit.bulk"},
	{"fill", "[x1 y1 z1 x2 y2 z2] <block>", {1, 7}, admin_fill, "world.edit.bulk"},
	{"replace", "[x1 y1 z1 x2 y2 z2] <from> <to>", {2, 8}, admin_replace, "world.edit.bulk"},
	{
		"sphere",
		"[x y z] <radius> <block> (no x y z: at pos1)",
		{2, 5},
		admin_sphere,
		"world.edit.bulk",
	},
	{
		"rollback",
		"player <name> <time> [radius <n> | sel | world] | system <system> <time> [...] | area <time> [radius <n> | sel] | status | cancel  (time: 90s, 10m, 2h, 1d)",
		{1, 6},
		admin_rollback,
		"world.rollback",
	},
	{
		"protect",
		"add <name> [x1 y1 z1 x2 y2 z2] | remove <name> | list | member add|remove <name> <character>  (no coordinates: the selection)",
		{1, 8},
		admin_protect,
		"world.protect",
	},
	{"history", "<x y z>", {3, 3}, admin_history, "world.rollback"},
	{"undo", "[n]", {0, 1}, admin_undo, "world.edit.undo"},
	{"redo", "[n]", {0, 1}, admin_redo, "world.edit.undo"},
	{"summon", "[kind] [count]", {0, 2}, admin_summon, "world.summon"},
	{"open_lan", "", {0, 0}, admin_open_lan, "server.open_lan"},
	{"locate", "[biome|structure] <name>", {1, 2}, admin_locate, "teleport.locate"},
	{"spawn", "", {0, 0}, admin_spawn, "teleport.spawn"},
	{"delmsg", "<player> [count]", {1, 2}, admin_delmsg, "chat.delete"},
	{"mute", "<player> [30m|2h|7d]", {1, 2}, admin_mute, "moderation.mute"},
	{"unmute", "<player>", {1, 1}, admin_unmute, "moderation.mute"},
	{"ignore", "<player>", {1, 1}, admin_ignore, "chat.ignore"},
	// Places and teleports (commands_places.odin).
	{"home", "[name]", {0, 1}, admin_home, "teleport.home"},
	{"sethome", "[name]", {0, 1}, admin_sethome, "teleport.home"},
	{"delhome", "<name>", {1, 1}, admin_delhome, "teleport.home"},
	{"homes", "", {0, 0}, admin_homes, "teleport.home"},
	{"warp", "[name]", {0, 1}, admin_warp, "teleport.warp"},
	{"warps", "", {0, 0}, admin_warps, "teleport.warp"},
	{"setwarp", "<name>", {1, 1}, admin_setwarp, "teleport.warp.set"},
	{"delwarp", "<name>", {1, 1}, admin_delwarp, "teleport.warp.set"},
	{"tpa", "<player>", {1, 1}, admin_tpa, "teleport.tpa"},
	{"tpahere", "<player>", {1, 1}, admin_tpahere, "teleport.tpa"},
	{"tpaccept", "[player]", {0, 1}, admin_tpaccept, "teleport.tpa"},
	{"tpdeny", "", {0, 0}, admin_tpdeny, "teleport.tpa"},
	{"back", "", {0, 0}, admin_back, "teleport.back"},
	{"top", "", {0, 0}, admin_top, "teleport.top"},
	{
		"tp",
		"<player> | <who> <player> | <x y z> [yaw pitch]  (~ is relative)",
		{1, 5},
		admin_tp,
		"teleport.tp",
	},
	{"tphere", "<player>", {1, 1}, admin_tphere, "teleport.tp.others"},
	// Messaging, moderation, who and status (commands_people.odin).
	{"msg", "<player> <words>", {2, 64}, admin_msg, "chat.msg"},
	{"tell", "<player> <words>", {2, 64}, admin_msg, "chat.msg"},
	{"w", "<player> <words>", {2, 64}, admin_msg, "chat.msg"},
	{"r", "<words>", {1, 64}, admin_r, "chat.msg"},
	{"me", "<action>", {1, 64}, admin_me, "chat.me"},
	{"broadcast", "<words>", {1, 64}, admin_broadcast, "chat.broadcast"},
	{"say", "<words>", {1, 64}, admin_broadcast, "chat.broadcast"},
	{"nick", "<nickname|off> [player]", {1, 2}, admin_nick, "chat.nick"},
	{"realname", "<nickname>", {1, 1}, admin_realname, "info.realname"},
	{"motd", "[set <words>]", {0, 64}, admin_motd, "info.motd"},
	{"kick", "<player> [reason]", {1, 64}, admin_kick, "moderation.kick"},
	{"ban", "<player> [reason]", {1, 64}, admin_ban, "moderation.ban"},
	{"tempban", "<player> <30m|2h|7d> [reason]", {2, 64}, admin_tempban, "moderation.ban"},
	{"unban", "<player>", {1, 1}, admin_unban, "moderation.ban"},
	{"ban-ip", "<player|address> [reason]", {1, 64}, admin_ban_ip, "moderation.ban_ip"},
	{"unban-ip", "<address>", {1, 1}, admin_unban_ip, "moderation.ban_ip"},
	{"list", "", {0, 0}, admin_list, "info.list"},
	{"whois", "<player>", {1, 1}, admin_whois, "info.whois"},
	{"seen", "<player>", {1, 1}, admin_seen, "info.seen"},
	{"afk", "", {0, 0}, admin_afk, "chat.afk"},
	{"stats", "[player] [filter]", {0, 2}, admin_stats, "info.stats"},
	{"status", "", {0, 0}, admin_status, "info.status"},
	// Items (items.odin).
	{"give", "<player> <item> [count]", {2, 3}, admin_give, "items.give"},
	{"clear", "[player] [item]", {0, 2}, admin_clear, "items.clear"},
	{"item", "", {0, 0}, admin_item, "info.item"},
	{"audit", "", {0, 0}, admin_audit, "admin.audit"},
	// Worlds (worlds.odin).
	{"travel", "<address> [character]", {1, 3}, admin_travel, "world.travel"},
	{"address", "", {0, 0}, admin_address, "info.address"},
	{"worlds", "", {0, 0}, admin_worlds, "info.worlds"},
	{"setworldspawn", "[x y z]", {0, 3}, admin_setworldspawn, "world.spawn"},
	{"regen", "[radius in chunks, 1..8]", {0, 1}, admin_regen, "world.gen"},
	{
		"structure",
		"save <name> [x1 y1 z1 x2 y2 z2] [clear] | paste <name> [x y z] [quarter turns] | list (no coordinates: the selection, pos1)",
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

// command_usage: a command's usage text and the permission it needs.
command_usage :: proc(name: string) -> (usage, node: string, found: bool) {
	for &cmd in ADMIN_COMMANDS {
		if cmd.name == name {return cmd.usage, cmd.node, true}
	}
	return
}

// admin runs a command from c.
admin :: proc(s: ^Server, c: ^Client, command: string) {
	f := strings.fields(command, context.temp_allocator)
	if len(f) == 0 {return}
	for &cmd in ADMIN_COMMANDS {
		if cmd.name != f[0] {continue}
		args := expand_relative(c, f[1:])
		if !allowed(s, c, cmd.node) {
			notice(s, c, fmt.tprintf("You may not use %s here (%s)", cmd.name, cmd.node))
			return
		}
		c.command = command
		ran := len(args) >= cmd.args[0] && len(args) <= cmd.args[1] && cmd.run(s, c, args)
		c.command = ""
		if !ran {
			notice(s, c, fmt.tprintf("Usage: %s %s", cmd.name, cmd.usage))
			return
		}
		record(s, c, .Command, cmd.name)
		switch cmd.name {
		case "tp", "home", "warp", "spawn", "back", "travel":
			record(s, c, .Teleport, cmd.name)
		case "msg", "r":
			record(s, c, .Chat_Whisper)
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

@(private)
admin_fill :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	box, ok, said := edit_box(s, c, args, 1)
	if said {return true}
	if !ok {return false}
	block := parse_block(args[len(args) - 1]) or_return
	bulk_notice(s, c, "fill", {shape = box, op = .Set, block = block})
	return true
}

@(private = "file")
admin_replace :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	box, ok, said := edit_box(s, c, args, 2)
	if said {return true}
	if !ok {return false}
	from := parse_block(args[len(args) - 2]) or_return
	to := parse_block(args[len(args) - 1]) or_return
	bulk_notice(s, c, "replace", {shape = box, op = .Replace, from = from, block = to})
	return true
}

@(private = "file")
admin_sphere :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	center: [3]f64
	radius: f64
	switch len(args) {
	case 2:
		// At pos1.
		p, set := c.selection[0].?
		if !set {
			notice(s, c, "&cSet pos1 first (/pos1)")
			return true
		}
		center = {f64(p.x) + 0.5, f64(p.y) + 0.5, f64(p.z) + 0.5}
		radius = strconv.parse_f64(args[0]) or_return
		if !(radius > 0 && radius <= 32) {return false}
	case 5:
		center, radius = parse_ball(args[:4]) or_return
	case:
		return false
	}
	block := parse_block(args[len(args) - 1]) or_return
	bulk_notice(s, c, "sphere", {shape = Sphere{center, radius}, op = .Set, block = block})
	return true
}

@(private = "file")
admin_summon :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	kind := game.Entity_Kind.Sheep
	if len(args) > 0 {
		found := false
		for k in game.Entity_Kind {
			if game.ENTITY_INFO[k].name == args[0] &&
			   game.ENTITY_INFO[k].summonable {kind, found = k, true}
		}
		if !found {return false}
	}
	count := 1
	if len(args) == 2 {
		n, ok := parse_count(args[1])
		if !ok || n > 20 {return false}
		count = n
	}
	for _ in 0 ..< count {
		if !summon(s, c, kind) {
			notice(s, c, "Nowhere to put it (look at open ground nearby)")
			break
		}
	}
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
admin_locate :: proc(s: ^Server, c: ^Client, args_in: []string) -> bool {
	args := args_in
	if len(args) == 2 && (args[0] == "biome" || args[0] == "structure") {args = args[1:]}
	if len(args) != 1 {return false}
	w := c.world
	p := c.player.position
	gen := &w.chunks.gen
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
		if kind == .Gate {
			// In front of it, on its platform, looking at its ring's foot
			// (right-click dials).
			front, yaw := worldgen.gate_front(st)
			c.player.flying = false
			land(s, c, front, {yaw + math.PI, GATE_LOOK_PITCH}, .Exact)
			notice(
				s,
				c,
				fmt.tprintf(
					"gate at %d %d %d (right-click it to dial)",
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
		// save <name> [x1 y1 z1 x2 y2 z2] [clear]
		if len(args) < 2 || !structure_name_valid(args[1]) {return false}
		rest := args[2:]
		clear := len(rest) > 0 && rest[len(rest) - 1] == "clear"
		if clear {rest = rest[:len(rest) - 1]}
		box, ok, said := edit_box(s, c, rest, 0)
		if said {return true}
		if !ok {return false}
		notice(s, c, structure_save(c.world, args[1], box.lo, box.hi, clear))
	case "paste":
		// paste <name> [x y z] [turns]
		if len(args) < 2 || !structure_name_valid(args[1]) {return false}
		rest := args[2:]
		turns := 0
		if len(rest) == 1 || len(rest) == 4 {
			turns = strconv.parse_int(rest[len(rest) - 1]) or_return
			rest = rest[:len(rest) - 1]
		}
		if turns < 0 || turns > 3 {return false}
		n: [3]i32
		switch len(rest) {
		case 3:
			parse_coords(rest, n[:]) or_return
		case 0:
			p, set := c.selection[0].?
			if !set {
				notice(s, c, "&cSet pos1 first (/pos1), or give where")
				return true
			}
			n = p
		case:
			return false
		}
		act := Act{action_begin(c.world, actor_of(s, c), .Structure, c.command), .Structure}
		notice(s, c, structure_paste(c.world, args[1], n, u8(turns), act))
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
	notice(s, c, fmt.tprintf("regen: %d chunks made again", regen(c.world, c, i32(radius))))
	return true
}

// admin_hash: the chunks this client has, as the server has them (for
// blast_test to compare with its own).
// edit_box: the box a world-editing command acts on: the six coordinates
// before its last `rest` words, or with none, c's selection. said: there
// is none, and c was told (the command is done); else !ok is a usage error.
@(private = "file")
edit_box :: proc(s: ^Server, c: ^Client, args: []string, rest: int) -> (box: Box, ok, said: bool) {
	switch len(args) - rest {
	case 6:
		box, ok = parse_box(args[:6])
		return
	case 0:
		if box, ok = selection_box(c); !ok {
			notice(s, c, "&cSelect a box first (/pos1, /pos2), or give its corners")
			return {}, false, true
		}
		return
	}
	return
}

@(private = "file")
admin_sel :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	selection_set(s, c, {})
	notice(s, c, "Selection cleared")
	return true
}

// bulk_notice applies a bulk edit and tells c how it went.
@(private = "file")
bulk_notice :: proc(s: ^Server, c: ^Client, name: string, e: Bulk_Edit) {
	act := Act{action_begin(c.world, actor_of(s, c), .Command, c.command), .Command}
	changed, result, protected := bulk_edit(c.world, e, act)
	switch result {
	case .Done:
		if protected > 0 {
			notice(
				s,
				c,
				fmt.tprintf("%s: %d blocks changed, %d protected", name, changed, protected),
			)
		} else {
			notice(s, c, fmt.tprintf("%s: %d blocks changed", name, changed))
		}
	case .Too_Big:
		notice(s, c, fmt.tprintf("%s: too big (at most %d blocks)", name, MAX_BULK_VOLUME))
	case .Not_Loaded:
		notice(s, c, fmt.tprintf("%s: part of it is not loaded", name))
	}
}

parse_coords :: proc(words: []string, out: []i32) -> bool {
	for w, i in words {
		n := strconv.parse_int(w) or_return
		if abs(n) >= game.WORLD_LIMIT {return false}
		out[i] = i32(n)
	}
	return true
}

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
	_, wheat := game.wheat_stage(b)
	return b, ok && (b == .Air || game.can_place(b) || game.block_is_farmland(b) || wheat)
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
