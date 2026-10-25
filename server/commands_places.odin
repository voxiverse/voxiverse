package server

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"

import "../game"

// Server commands for getting around (after EssentialsX's): homes, warps,
// teleport requests, back, top, tp. Every arrival lands (spawn.odin) and
// remembers where the player was, for back.

// Tpa: a teleport request to a player: from someone, to come (or, here,
// to bring them).
Tpa :: struct {
	from:     [game.MAX_NAME_LENGTH]u8,
	from_len: int,
	here:     bool, // tpahere: the one asked goes to the asker
	at:       u64, // tick (0: none)
}

// TPA_TIMEOUT: ticks a request waits for an answer (2 minutes).
TPA_TIMEOUT :: 120 * game.TICK_RATE

// place_name_valid: a home's or warp's name.
@(private)
place_name_valid :: proc(name: string) -> bool {
	return role_name_valid(name) // (lowercase letters, digits, _ and -)
}

@(private)
place_of :: proc(c: ^Client) -> Place {
	return {c.world.address, c.player.position, c.look}
}

// notice_if tells c why not, if there is a why.
@(private)
notice_if :: proc(s: ^Server, c: ^Client, why: string) {
	if why != "" {notice(s, c, fmt.tprintf("&c%s", why))}
}

@(private)
names_text :: proc(m: map[string]Place) -> string {
	names := make([dynamic]string, context.temp_allocator)
	for k in m {append(&names, k)}
	slice.sort(names[:])
	return strings.join(names[:], ", ", context.temp_allocator)
}

// --- Homes ---

// admin_sethome: a home here (named, default "home"); at most the
// player's max_homes metadata (when set).
@(private)
admin_sethome :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	name := args[0] if len(args) > 0 else "home"
	if !place_name_valid(name) {return false}
	m := member_get(&s.community, client_name(c))
	if name not_in m.homes {
		if most, ok := strconv.parse_int(meta_of(&s.perms, client_name(c), "max_homes"));
		   ok && len(m.homes) >= most {
			notice(s, c, fmt.tprintf("&cYou have %d homes, the most you may (delhome one)", most))
			return true
		}
	}
	place_set(&m.homes, name, place_of(c))
	notice(s, c, fmt.tprintf("Home %s set", name))
	return true
}

@(private)
admin_home :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	m := member_get(&s.community, client_name(c))
	name := "home"
	if len(args) > 0 {
		name = args[0]
	} else if len(m.homes) == 1 {
		for k in m.homes {name = k}
	}
	p, ok := m.homes[name]
	if !ok {
		homes := names_text(m.homes)
		notice(
			s,
			c,
			fmt.tprintf("&cNo home %s (homes: %s)", name, homes if homes != "" else "none"),
		)
		return true
	}
	notice_if(s, c, go_to(s, c, p))
	return true
}

@(private)
admin_delhome :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	m := member_get(&s.community, client_name(c))
	if !place_delete(&m.homes, args[0]) {
		notice(s, c, fmt.tprintf("&cNo home %s", args[0]))
		return true
	}
	notice(s, c, fmt.tprintf("Home %s deleted", args[0]))
	return true
}

@(private)
admin_homes :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	m := member_get(&s.community, client_name(c))
	if len(m.homes) == 0 {
		notice(s, c, "No homes (sethome makes one)")
	} else {
		notice(s, c, fmt.tprintf("Homes: %s", names_text(m.homes)))
	}
	return true
}

// --- Warps ---

@(private)
admin_warp :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	if len(args) == 0 {return admin_warps(s, c, args)}
	p, ok := s.community.warps[args[0]]
	if !ok {
		notice(s, c, fmt.tprintf("&cNo warp %s", args[0]))
		return true
	}
	notice_if(s, c, go_to(s, c, p))
	return true
}

@(private)
admin_warps :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	if len(s.community.warps) == 0 {
		notice(s, c, "No warps")
	} else {
		notice(s, c, fmt.tprintf("Warps: %s", names_text(s.community.warps)))
	}
	return true
}

@(private)
admin_setwarp :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	if !place_name_valid(args[0]) {return false}
	place_set(&s.community.warps, args[0], place_of(c))
	notice(s, c, fmt.tprintf("Warp %s set", args[0]))
	return true
}

@(private)
admin_delwarp :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	if !place_delete(&s.community.warps, args[0]) {
		notice(s, c, fmt.tprintf("&cNo warp %s", args[0]))
		return true
	}
	notice(s, c, fmt.tprintf("Warp %s deleted", args[0]))
	return true
}

// --- Teleport requests ---

@(private)
admin_tpa :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	return tpa_ask(s, c, args[0], false)
}

@(private)
admin_tpahere :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	return tpa_ask(s, c, args[0], true)
}

@(private = "file")
tpa_ask :: proc(s: ^Server, c: ^Client, name: string, here: bool) -> bool {
	other := client_by_name(s, name)
	if other == nil || other == c {
		notice(s, c, fmt.tprintf("&c%s is not here", name))
		return true
	}
	if ignores(s, other, client_name(c)) {
		notice(s, c, fmt.tprintf("Asked %s", name)) // (they will not hear of it)
		return true
	}
	other.tpa = {
		here = here,
		at   = s.tick,
	}
	other.tpa.from_len = copy(other.tpa.from[:], client_name(c))
	who := display_name(s, c)
	what := "asks you to teleport to them" if here else "asks to teleport to you"
	notice(s, other, game.format_join({who, fmt.tprintf("&e %s: /tpaccept or /tpdeny", what)}))
	notice(s, c, fmt.tprintf("Asked %s", name))
	return true
}

// tpa_pending: c's open request, if any (and its asker still here).
@(private = "file")
tpa_pending :: proc(s: ^Server, c: ^Client) -> (from: ^Client, ok: bool) {
	if c.tpa.at == 0 || s.tick - c.tpa.at > TPA_TIMEOUT {
		c.tpa = {}
		return nil, false
	}
	from = client_by_name(s, string(c.tpa.from[:c.tpa.from_len]))
	if from == nil {c.tpa = {}}
	return from, from != nil
}

@(private)
admin_tpaccept :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	from, ok := tpa_pending(s, c)
	if !ok || (len(args) == 1 && args[0] != client_name(from)) {
		notice(s, c, "&cNo request to accept")
		return true
	}
	if c.tpa.here {
		notice_if(s, c, go_to(s, c, {from.world.address, from.player.position, c.look}))
	} else {
		notice_if(s, from, go_to(s, from, {c.world.address, c.player.position, from.look}))
	}
	notice(s, from, fmt.tprintf("%s accepted", client_name(c)))
	c.tpa = {}
	return true
}

@(private)
admin_tpdeny :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	from, ok := tpa_pending(s, c)
	if !ok {
		notice(s, c, "&cNo request to deny")
		return true
	}
	notice(s, from, fmt.tprintf("%s said no", client_name(c)))
	notice(s, c, "Denied")
	c.tpa = {}
	return true
}

// --- Back, top, tp ---

@(private)
admin_back :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	p, ok := c.back.?
	if !ok {
		notice(s, c, "&cNowhere to go back to")
		return true
	}
	notice_if(s, c, go_to(s, c, p)) // (and back again after)
	return true
}

// admin_top: up onto the highest block above.
@(private)
admin_top :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	p := c.player.position
	top := column_top(c.world, i32(math.floor(p.x)), i32(math.floor(p.z)))
	land(s, c, {p.x, f64(top + 1), p.z}, c.look, .Ground)
	return true
}

// admin_tphere: bring a player here (teleport.tp.others).
@(private)
admin_tphere :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	who := players_matching(s, c, args[0])
	if len(who) == 0 {
		notice(s, c, fmt.tprintf("&c%s is not here", args[0]))
		return true
	}
	for w in who {notice_if(s, c, go_to(s, w, {c.world.address, c.player.position, w.look}))}
	return true
}
