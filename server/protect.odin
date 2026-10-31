package server

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

import "common:game"

// Region protection (docs/journal.md): boxes of a world that only their
// members, the world itself and actors with world.protect.bypass may change.
// admit (journal.odin) asks here; the commands are /protect.

MAX_PROTECTIONS :: 256
MAX_PROTECTION_NAME :: 32
PROTECTIONS_FILE :: "protections.cfg"
PROTECT_NOTICE_TICKS :: game.TICK_RATE // a player is told at most once a second

Protection :: struct {
	name:    string, // owned
	box:     Box, // lo <= hi
	members: [dynamic]string, // character names (owned)
}

protection_name_valid :: proc(name: string) -> bool {
	if len(name) < 1 || len(name) > MAX_PROTECTION_NAME {return false}
	for ch in name {
		if !(ch >= 'a' && ch <= 'z' ||
			   ch >= '0' && ch <= '9' ||
			   ch == '_' ||
			   ch == '-') {return false}
	}
	return true
}

box_has :: proc(b: Box, p: game.Block_Pos) -> bool {
	return(
		p.x >= b.lo.x &&
		p.x <= b.hi.x &&
		p.y >= b.lo.y &&
		p.y <= b.hi.y &&
		p.z >= b.lo.z &&
		p.z <= b.hi.z \
	)
}

@(private = "file")
box_overlaps :: proc(b: Box, lo, hi: game.Block_Pos) -> bool {
	return(
		lo.x <= b.hi.x &&
		hi.x >= b.lo.x &&
		lo.y <= b.hi.y &&
		hi.y >= b.lo.y &&
		lo.z <= b.hi.z &&
		hi.z >= b.lo.z \
	)
}

@(private = "file")
box_normal :: proc(b: Box) -> Box {
	lo, hi := shape_box(b)
	return {lo, hi}
}

// protection_may: whether the actor of act may change blocks inside pr.
@(private = "file")
protection_may :: proc(w: ^World, act: Act, pr: ^Protection) -> bool {
	j := &w.journal
	a := action_live(j, act.action)
	if a == nil || a.actor == 0 || a.bypass {return true}
	who := j.actors[a.actor]
	if who.kind != .Character {return false}
	for m in pr.members {if strings.equal_fold(m, who.name) {return true}}
	return false
}

// protection_refusing: a protection that holds p and that act may not edit (nil: none).
protection_refusing :: proc(w: ^World, act: Act, p: game.Block_Pos) -> ^Protection {
	for &pr in w.protections {
		if box_has(pr.box, p) && !protection_may(w, act, &pr) {return &pr}
	}
	return nil
}

// admit_box: the boxes of protections overlapping lo..hi that the actor of
// act may not edit (temp allocator; none: every block of it is admitted).
admit_box :: proc(w: ^World, act: Act, lo, hi: game.Block_Pos) -> []Box {
	if len(w.protections) == 0 {return nil}
	found := make([dynamic]Box, context.temp_allocator)
	for &pr in w.protections {
		if box_overlaps(pr.box, lo, hi) && !protection_may(w, act, &pr) {append(&found, pr.box)}
	}
	return found[:]
}

// protect_notice tells c that the block at p, which act was refused, is
// protected (at most once a second).
protect_notice :: proc(s: ^Server, c: ^Client, act: Act, p: game.Block_Pos) {
	if c.protect_told != 0 && s.tick < c.protect_told + PROTECT_NOTICE_TICKS {return}
	pr := protection_refusing(c.world, act, p)
	if pr == nil {return}
	c.protect_told = max(s.tick, 1)
	notice(s, c, fmt.tprintf("&cThis place is protected (%s)", pr.name))
}

// ---- the list ----

protection_find :: proc(w: ^World, name: string) -> int {
	for pr, i in w.protections {if pr.name == name {return i}}
	return -1
}

protection_free :: proc(pr: ^Protection) {
	delete(pr.name)
	for m in pr.members {delete(m)}
	delete(pr.members)
}

protections_free :: proc(w: ^World) {
	for &pr in w.protections {protection_free(&pr)}
	delete(w.protections)
	w.protections = nil
}

protections_path :: proc(w: ^World) -> string {
	return(
		filepath.join({w.dir, PROTECTIONS_FILE}, context.temp_allocator) or_else PROTECTIONS_FILE \
	)
}

// protections_write saves the list (a world with a directory only).
protections_write :: proc(w: ^World) -> bool {
	if w.dir == "" {return true}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "# Voxiverse region protections (written by the server)")
	for pr in w.protections {
		fmt.sbprintf(
			&b,
			"protect %s %d %d %d %d %d %d",
			pr.name,
			pr.box.lo.x,
			pr.box.lo.y,
			pr.box.lo.z,
			pr.box.hi.x,
			pr.box.hi.y,
			pr.box.hi.z,
		)
		for m in pr.members {fmt.sbprintf(&b, " %s", m)}
		fmt.sbprintln(&b)
	}
	ok := store_write(w.server, protections_path(w), b.buf[:])
	w.protections_dirty = !ok
	return ok
}

// protections_load reads the list of a world's directory.
protections_load :: proc(w: ^World) {
	if w.dir == "" {return}
	data, err := os.read_entire_file_from_path(protections_path(w), context.temp_allocator)
	if err != nil {return}
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) < 8 || f[0] != "protect" || !protection_name_valid(f[1]) {continue}
		if len(w.protections) >= MAX_PROTECTIONS || protection_find(w, f[1]) >= 0 {continue}
		n: [6]i32
		good := true
		for i in 0 ..< 6 {
			v, ok := strconv.parse_int(f[2 + i])
			if !ok || abs(v) > game.WORLD_LIMIT {good = false}
			n[i] = i32(v)
		}
		if !good {continue}
		pr := Protection {
			name = strings.clone(f[1]),
			box  = box_normal(Box{{n[0], n[1], n[2]}, {n[3], n[4], n[5]}}),
		}
		for m in f[8:] {if len(m) <= game.MAX_NAME_LENGTH {append(&pr.members, strings.clone(m))}}
		append(&w.protections, pr)
	}
	if len(w.protections) > 0 {
		log.infof("server loaded protections count=%d", len(w.protections))
	}
}

// protections_hash folds the list, by name, into h (the Journal section).
protections_hash :: proc(w: ^World, h: ^game.Hasher) {
	names := make([dynamic]string, context.temp_allocator)
	for pr in w.protections {append(&names, pr.name)}
	slice.sort(names[:])
	for name in names {
		pr := w.protections[protection_find(w, name)]
		game.hasher_bytes(h, transmute([]u8)pr.name)
		game.hasher_mix(h, u64(u32(pr.box.lo.x)) | u64(u32(pr.box.lo.y)) << 32)
		game.hasher_mix(h, u64(u32(pr.box.lo.z)) | u64(u32(pr.box.hi.x)) << 32)
		game.hasher_mix(h, u64(u32(pr.box.hi.y)) | u64(u32(pr.box.hi.z)) << 32)
		members := slice.clone(pr.members[:], context.temp_allocator)
		slice.sort(members)
		for m in members {game.hasher_bytes(h, transmute([]u8)m)}
	}
}

// ---- /protect ----

// admin_protect: /protect add <name> [x1 y1 z1 x2 y2 z2] | remove <name> |
// list | member add|remove <name> <character>.
admin_protect :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	w := c.world
	switch args[0] {
	case "add":
		if len(args) != 2 && len(args) != 8 {return false}
		if !protection_name_valid(args[1]) {
			notice(s, c, "&cA protection's name is 1 to 32 of a-z, 0-9, _ and -")
			return true
		}
		box: Box
		if len(args) == 8 {
			parsed, ok := parse_box(args[2:8])
			if !ok {return false}
			box = parsed
		} else {
			selected, ok := selection_box(c)
			if !ok {
				notice(s, c, "&cSelect a box first (/pos1, /pos2), or give its corners")
				return true
			}
			box = selected
		}
		if protection_find(w, args[1]) >= 0 {
			notice(s, c, fmt.tprintf("&cThere is a protection named %s already", args[1]))
			return true
		}
		if len(w.protections) >= MAX_PROTECTIONS {
			notice(s, c, fmt.tprintf("&cAt most %d protections", MAX_PROTECTIONS))
			return true
		}
		append(&w.protections, Protection{name = strings.clone(args[1]), box = box_normal(box)})
		protections_write(w)
		notice(s, c, fmt.tprintf("Protected %s", args[1]))
	case "remove":
		if len(args) != 2 {return false}
		i := protection_find(w, args[1])
		if i < 0 {
			notice(s, c, fmt.tprintf("&cNo protection named %s", args[1]))
			return true
		}
		protection_free(&w.protections[i])
		ordered_remove(&w.protections, i)
		protections_write(w)
		notice(s, c, fmt.tprintf("Removed %s", args[1]))
	case "list":
		if len(args) != 1 {return false}
		if len(w.protections) == 0 {
			notice(s, c, "No protections")
			return true
		}
		for pr in w.protections {
			b := pr.box
			notice(
				s,
				c,
				fmt.tprintf(
					"%s: %d %d %d to %d %d %d, members: %s",
					pr.name,
					b.lo.x,
					b.lo.y,
					b.lo.z,
					b.hi.x,
					b.hi.y,
					b.hi.z,
					strings.join(pr.members[:], " ", context.temp_allocator) if len(pr.members) > 0 else "none",
				),
			)
		}
	case "member":
		if len(args) != 4 || (args[1] != "add" && args[1] != "remove") {return false}
		i := protection_find(w, args[2])
		if i < 0 {
			notice(s, c, fmt.tprintf("&cNo protection named %s", args[2]))
			return true
		}
		if len(args[3]) > game.MAX_NAME_LENGTH {return false}
		pr := &w.protections[i]
		at := -1
		for m, k in pr.members {if strings.equal_fold(m, args[3]) {at = k}}
		if args[1] == "add" {
			if at < 0 {append(&pr.members, strings.clone(args[3]))}
		} else {
			if at < 0 {
				notice(s, c, fmt.tprintf("&c%s is not a member of %s", args[3], pr.name))
				return true
			}
			delete(pr.members[at])
			ordered_remove(&pr.members, at)
		}
		protections_write(w)
		notice(s, c, fmt.tprintf("%s: %s %s", pr.name, args[1], args[3]))
	case:
		return false
	}
	return true
}
