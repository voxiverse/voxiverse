package core

import "core:fmt"
import "core:log"
import "core:math"
import "core:strconv"
import "core:strings"

import "common:base"
import "common:game"
import "common:planet"
import "common:worldgen"

// Server commands about the world and the players in it, after Minecraft's
// most useful ones: selectors (@s @p @a @r) wherever a command takes a
// player, relative coordinates (~ ~5 ~-2), /tp with angles, /setblock, /time
// set|add|query, /rule (gamerule), /kill, /seed, /summon with a count, /wear,
// /help. Everything here is the server's (a slash command, from the chat or
// the console); the console's plain words are the client's own.

// find_player: who text names for c: a player's name, or @s (c), @p (the
// nearest other player in the world, else c), @r (any player). Not @a: that
// is players_matching's.
find_player :: proc(s: ^Server, c: ^Client, text: string) -> ^Client {
	switch text {
	case "@s":
		return c
	case "@p":
		best: ^Client = c
		best_d := max(f64)
		for &other in s.clients {
			if &other == c || other.state != .Playing || other.world != c.world {continue}
			d := other.player.position - c.player.position
			if dd := d.x * d.x + d.y * d.y + d.z * d.z; dd < best_d {best, best_d = &other, dd}
		}
		return best
	case "@r":
		playing := make([dynamic]^Client, context.temp_allocator)
		for &other in s.clients {if other.state == .Playing {append(&playing, &other)}}
		if len(playing) == 0 {return nil}
		return playing[base.rng_int_max(&c.world.command_rng, len(playing))]
	case "@a":
		return nil
	}
	return client_by_name(s, text)
}

// players_matching: every player text names (@a: everyone playing).
players_matching :: proc(s: ^Server, c: ^Client, text: string) -> []^Client {
	out := make([dynamic]^Client, context.temp_allocator)
	if text == "@a" {
		for &other in s.clients {if other.state == .Playing {append(&out, &other)}}
	} else if one := find_player(s, c, text); one != nil {
		append(&out, one)
	}
	return out[:]
}

// is_coordinate: a word that is a number or a ~ (relative) one.
@(private = "file")
is_coordinate :: proc(w: string) -> bool {
	if len(w) == 0 {return false}
	if w[0] == '~' {return true}
	_, ok := strconv.parse_f64(w)
	return ok
}

// expand_relative turns ~ coordinates into numbers: in each run of coordinate
// words the first is x, then y, then z (round again): "~" the player's, "~5"
// that plus 5 (whole blocks unless the offset has a point).
@(private)
expand_relative :: proc(c: ^Client, args: []string) -> []string {
	any_relative := false
	for a in args {if len(a) > 0 && a[0] == '~' {any_relative = true}}
	if !any_relative {return args}
	here := [3]f64{c.player.position.x, c.player.position.y, c.player.position.z}
	out := make([]string, len(args), context.temp_allocator)
	run := 0
	for a, i in args {
		if !is_coordinate(a) {
			run = 0
			out[i] = a
			continue
		}
		axis := run % 3
		run += 1
		if a[0] != '~' {
			out[i] = a
			continue
		}
		offset := 0.0
		if len(a) > 1 {
			v, ok := strconv.parse_f64(a[1:])
			if !ok {
				out[i] = a // (left as it is: the command refuses it)
				continue
			}
			offset = v
		}
		if strings.contains(a, ".") {
			out[i] = fmt.tprintf("%.3f", here[axis] + offset)
		} else {
			out[i] = fmt.tprintf("%d", int(math.floor(here[axis])) + int(offset))
		}
	}
	return out
}

// admin_tp: tp <player> (to them), tp <who> <player>, or tp <x y z> [yaw
// pitch] (degrees; ~ is relative; the angles stay as they are if left out).
@(private)
admin_tp :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	if len(args) >= 3 && is_coordinate(args[0]) {
		at: [3]f64
		for a, i in args[:3] {
			v := strconv.parse_f64(a) or_return
			if abs(v) >= game.WORLD_LIMIT {return false}
			at[i] = v
		}
		look := c.look
		switch len(args) {
		case 3:
		case 5:
			yaw := strconv.parse_f64(args[3]) or_return
			pitch := strconv.parse_f64(args[4]) or_return
			look = {
				f32(yaw) * math.RAD_PER_DEG,
				clamp(f32(pitch) * math.RAD_PER_DEG, -game.PITCH_LIMIT, game.PITCH_LIMIT),
			}
		case:
			return false
		}
		land(s, c, at, look, .Exact)
		return true
	}
	switch len(args) {
	case 1:
		to := find_player(s, c, args[0])
		if to == nil {
			notice(s, c, fmt.tprintf("&c%s is not here", args[0]))
			return true
		}
		notice_if(s, c, go_to(s, c, {to.world.address, to.player.position, c.look}))
	case 2:
		if !allowed(s, c, "teleport.tp.others") {
			notice(s, c, "You may not move others here (teleport.tp.others)")
			return true
		}
		to := find_player(s, c, args[1])
		who := players_matching(s, c, args[0])
		if to == nil || len(who) == 0 {
			notice(s, c, "&cBoth must be here")
			return true
		}
		for w in who {
			notice_if(s, c, go_to(s, w, {to.world.address, to.player.position, w.look}))
		}
		notice(s, c, fmt.tprintf("Moved %d to %s", len(who), client_name(to)))
	case:
		return false
	}
	return true
}

// admin_setblock: setblock <x y z> <block>.
@(private)
admin_setblock :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	if len(args) != 4 {return false}
	for a in args[:3] {
		if _, ok := strconv.parse_int(a); !ok {return false}
	}
	fill := []string{args[0], args[1], args[2], args[0], args[1], args[2], args[3]}
	return admin_fill(s, c, fill)
}

// admin_cell: /cell <x y z> [<channel> [<value>]]: every channel's value at the cell, one
// channel's, or sets one (clamped to its max, said so; a computed channel is read-only).
@(private)
admin_cell :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	if len(args) < 3 || len(args) > 5 {return false}
	p: game.Block_Pos
	for a, i in args[:3] {
		n := strconv.parse_int(a) or_return
		p[i] = i32(n)
	}
	w := c.world
	infos := s.registry.channels
	if len(args) == 3 {
		for info, id in infos {
			v, loaded := chunks_channel(w, p, id)
			if !loaded {notice(s, c, "That cell is not loaded."); return true}
			notice(s, c, fmt.tprintf("%s = %d", info.name, v))
		}
		return true
	}
	id, found := game.registry_channel(s.registry, args[3])
	if !found {
		notice(s, c, fmt.tprintf("There is no channel %s.", args[3]))
		return true
	}
	if len(args) == 4 {
		v, loaded := chunks_channel(w, p, id)
		if !loaded {notice(s, c, "That cell is not loaded."); return true}
		notice(s, c, fmt.tprintf("%s = %d", infos[id].name, v))
		return true
	}
	if infos[id].computed != .None {
		notice(
			s,
			c,
			fmt.tprintf("%s is computed from the blocks: it cannot be set.", infos[id].name),
		)
		return true
	}
	n := strconv.parse_int(args[4]) or_return
	v := u16(clamp(n, 0, int(game.channel_max(infos[id]))))
	if int(v) != n {
		notice(
			s,
			c,
			fmt.tprintf("%d is out of range for %s: set %d instead.", n, infos[id].name, v),
		)
	}
	if !set_channel(w, p, id, v, world_act(w, .Command), c) {
		notice(s, c, "That cell could not be set (not loaded, or protected).")
	}
	return true
}

// admin_time: time set <t>, time add <hours>, time query (t: 0..1 of a day or a
// name; a bare <t> is a set).
@(private)
admin_time :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	w := c.world
	switch args[0] {
	case "query":
		notice(
			s,
			c,
			fmt.tprintf("It is %.3f of a day (day %d)", game.time_of_day(w.clock), int(w.clock)),
		)
		return true
	case "add":
		if len(args) != 2 {return false}
		hours := strconv.parse_f64(args[1]) or_return
		w.clock = min(w.clock + hours / 24, game.MAX_WORLD_TIME) // (the clock counts days)
	case "set":
		if len(args) != 2 {return false}
		f := game.parse_time_of_day(args[1]) or_return
		w.clock = game.set_time_of_day(w.clock, f)
	case:
		if len(args) != 1 {return false}
		f := game.parse_time_of_day(args[0]) or_return
		w.clock = game.set_time_of_day(w.clock, f)
	}
	clock_resend(s, w)
	return true
}

NODE_RULE :: "voxiverse.command.rule"

// rule_set: the one place a world rule changes (the command and the console's
// Set_Rule both come here): set, journalled with who asked, the world told.
rule_set :: proc(s: ^Server, c: ^Client, w: ^World, name, value: string) -> base.Var_Error {
	table := game.rules_table()
	err := base.var_set(table, &w.rules, rule_name(name), value)
	if err == .None || err == .Out_Of_Range {
		if err == .Out_Of_Range {log.warnf("server rule clamped name=%q value=%q", name, value)}
		log.infof("server rule changed name=%s value=%s by=%s", name, value, client_name(c))
		v, _ := base.var_find(table, rule_name(name))
		text := fmt.tprintf("rule %s %s", name, base.var_format(table, &w.rules, v))
		journal_setting(w, Actor{.Character, client_name(c), false}, text)
		if rule_name(name) == "rules.guest_role" {
			for &other in s.clients {
				if other.state == .Playing && other.world == w {refresh_grants(s, &other)}
			}
		}
		clock_resend(s, w) // (day_length and daylight_cycle change what the clock means)
		disturb_world(s, w)
	} else {
		log.warnf("server rule not changed name=%q value=%q problem=%v", name, value, err)
	}
	return err
}

// admin_rule: rule (all, with values), rule <name> (one), rule <name> <value> (set).
@(private)
admin_rule :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	w := c.world
	table := game.rules_table()
	switch len(args) {
	case 0:
		for &v in table.vars {
			name := strings.trim_prefix(base.var_name(table, &v), "rules.")
			notice(s, c, fmt.tprintf("%s = %s", name, base.var_format(table, &w.rules, &v)))
		}
	case 1:
		v, ok := base.var_find(table, rule_name(args[0]))
		if !ok {
			notice(s, c, fmt.tprintf("&cNo rule %s (rule lists them)", args[0]))
			return true
		}
		notice(s, c, fmt.tprintf("%s = %s", args[0], base.var_format(table, &w.rules, v)))
	case 2:
		if !allowed(s, c, NODE_RULE) {
			notice(s, c, "You may not change rules here.")
			return true
		}
		switch err := rule_set(s, c, w, args[0], args[1]); err {
		case .None, .Out_Of_Range:
			v, _ := base.var_find(table, rule_name(args[0]))
			notice(s, c, fmt.tprintf("%s = %s", args[0], base.var_format(table, &w.rules, v)))
		case .Unknown_Name:
			notice(s, c, fmt.tprintf("&cNo rule %s (rule lists them)", args[0]))
		case .Bad_Value:
			notice(s, c, fmt.tprintf("&c%s is not a value for %s", args[1], args[0]))
		}
	case:
		return false
	}
	return true
}

// admin_kill: kill <kind|all> [radius]: entities of a kind within a radius (32).
@(private)
admin_kill :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	radius := 32.0
	if len(args) == 2 {
		radius = strconv.parse_f64(args[1]) or_return
		if !(radius > 0 && radius <= 256) {return false}
	}
	killed := 0
	w := c.world
	// The hittable entities within the radius come from the spatial service;
	// a death removes its row, so each is found again by id.
	found := make([dynamic]game.Entity_Id, context.temp_allocator)
	game.spatial_sphere(
		&w.entity_world.spatial,
		c.player.position,
		radius,
		{all = {.Hittable}},
		&found,
	)
	for id in found {
		e, i := entity_find(w, u32(id))
		if i < 0 {continue}
		info := game.kind_info(s.registry, e.kind)
		if args[0] != "all" && args[0] != game.kind_name(info) {continue}
		entity_died(w, i)
		killed += 1
	}
	notice(s, c, fmt.tprintf("Killed %d", killed))
	return true
}

// admin_tag: tag <kind|all> add|remove <name> [radius]: the entity world's
// entities of a kind within a radius (32), for tests and admins.
@(private)
admin_tag :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	if args[1] != "add" && args[1] != "remove" {return false}
	radius := 32.0
	if len(args) == 4 {
		radius = strconv.parse_f64(args[3]) or_return
		if !(radius > 0 && radius <= 256) {return false}
	}
	kind: game.Kind_Id
	if args[0] != "all" {
		ok: bool
		if kind, ok = game.registry_kind(s.registry, args[0]); !ok {
			notice(s, c, fmt.tprintf("&cNo entity kind %s", args[0]))
			return true
		}
	}
	n, err := entity_tag_near(
		c.world.entity_world,
		kind,
		c.player.position,
		radius,
		args[1] == "add",
		args[2],
	)
	switch err {
	case .None, .Stale:
		notice(s, c, fmt.tprintf("Tagged %d", n))
	case .Bad_Name:
		notice(s, c, "&cA tag is 1 to 32 of a-z 0-9 _ :")
	case .Names_Full:
		notice(s, c, "&cThis world has too many tag names")
	case .Tags_Full:
		notice(s, c, fmt.tprintf("&cAn entity has 4 tags already (%d tagged)", n))
	}
	return true
}

// admin_seed: the world's seed.
@(private)
admin_seed :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	notice(s, c, fmt.tprintf("Seed: %d", c.world.seed))
	return true
}

// admin_packs: the packs the universe runs, in load order.
@(private)
admin_packs :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	for p in s.registry.packs {
		notice(s, c, fmt.tprintf("%s %s: %s", p.namespace, p.version, p.title))
	}
	return true
}

// admin_pack: `pack reload` (development builds): read the packs' files again
// and swap the registry (pack_reload.odin).
@(private)
admin_pack :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	if args[0] != "reload" {return false}
	when !base.DEV {
		notice(s, c, "Reloading packs is for development builds")
		return true
	}
	if !s.config.pack_watch {
		notice(s, c, "Reloading packs is off here; the game turns it on in a development build")
		return true
	}
	packs_reload_request(s)
	notice(s, c, "Reloading the packs")
	return true
}

// admin_wear: put on every piece of armor carried, where its slot is free.
@(private)
admin_wear :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	worn := 0
	for i in 0 ..< game.INVENTORY_SLOTS {
		if info, _ := game.item_info(s.registry, c.inventory.slots[i].item);
		   info.equip == nil {continue}
		if _, ok := game.inventory_apply(s.registry, &c.inventory, {.Quick_Move, i, 0}, false);
		   ok {worn += 1}
	}
	c.inv_changed = true
	notice(s, c, fmt.tprintf("Put on %d", worn))
	return true
}

// admin_help: help (the commands you may use), help <command> (its usage and permission).
@(private)
admin_help :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	if len(args) == 0 {
		notice(s, c, fmt.tprintf("Commands: %s (help <command> for one)", commands_allowed(s, c)))
		return true
	}
	name := strings.trim_prefix(args[0], "/")
	usage, node, found := command_usage(name)
	if !found {
		notice(s, c, fmt.tprintf("&cNo command %s", name))
		return true
	}
	notice(s, c, fmt.tprintf("/%s %s (needs %s)", name, usage, node))
	return true
}

// rule_name: a rule as the table names it ("drops" or "rules.drops").
rule_name :: proc(name: string) -> string {
	if strings.has_prefix(name, "rules.") {return name}
	return strings.concatenate({"rules.", name}, context.temp_allocator)
}

// admin_where: /where: the latitude, longitude and elevation of an Earth
// planet world's surface under the player (and the block position).
@(private)
admin_where :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	p := c.player.position
	x, z := i32(math.floor(p.x)), i32(math.floor(p.z))
	if c.world.params.planet == 0 {
		notice(
			s,
			c,
			fmt.tprintf(
				"At %d %d %d (this world is not built on the planet)",
				x,
				i32(math.floor(p.y)),
				z,
			),
		)
		return true
	}
	lat, lon := worldgen.planet_lat_lon(x, z)
	k, _ := worldgen.planet_climate(x, z)
	notice(
		s,
		c,
		fmt.tprintf(
			"%.2f°%s %.2f°%s, elevation %d m, %s (%s), biome %s, block %d %d %d",
			abs(lat),
			"N" if lat >= 0 else "S",
			abs(lon),
			"E" if lon >= 0 else "W",
			int(worldgen.planet_elevation(x, z)),
			planet.koppen_code(k),
			planet.koppen_name(k),
			worldgen.BIOME_NAMES[worldgen.earth_biome(&c.world.chunks.gen, x, z)],
			x,
			i32(math.floor(p.y)),
			z,
		),
	)
	return true
}

// admin_goto: /goto <lat> <lon> or /goto <place>: to the surface there on an
// Earth planet world.
@(private)
admin_goto :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	lat, lon: f64
	switch len(args) {
	case 1:
		place, found := worldgen.planet_place(strings.to_lower(args[0], context.temp_allocator))
		if !found {
			names := make([dynamic]string, context.temp_allocator)
			for pl in worldgen.PLANET_PLACES {append(&names, pl.name)}
			notice(
				s,
				c,
				fmt.tprintf(
					"&cNo such place. Try: %s",
					strings.join(names[:], " ", context.temp_allocator),
				),
			)
			return true
		}
		lat, lon = place.lat, place.lon
	case 2:
		lat = strconv.parse_f64(args[0]) or_return
		lon = strconv.parse_f64(args[1]) or_return
	case:
		return false
	}
	if c.world.params.planet == 0 {
		notice(s, c, "&cThis world is not built on the planet")
		return true
	}
	if abs(lat) >= 90 || abs(lon) >= 180 {
		notice(s, c, "&cLatitude is within 90 and longitude within 180 degrees")
		return true
	}
	x, z := worldgen.planet_block_of(lat, lon)
	top := column_top(c.world, x, z)
	land(s, c, {f64(x) + 0.5, f64(top + 1), f64(z) + 0.5}, c.look, .Ground)
	return true
}
