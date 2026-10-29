package server

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"

import "../common/game"

// What a world keeps about its people, besides their permissions: each
// player's nickname, mute, ignore list, homes, when they were last seen and
// from where; the world's warps; bans by name and by address. Kept in the
// world's community.cfg:
//
//	warp market 120.5 64 -30.5 1.57 0
//	ban griefer 0 alice wrecked the spawn
//	player bob
//	nick &bBobby
//	ignore carol
//	home base 10.5 70 4.5 0 0
//	seen 1793000000
//
// Times are Unix seconds; 0 as a ban's or mute's end: never.

COMMUNITY_FILE :: "community.cfg"

Place :: struct {
	world:    game.Address,
	position: [3]f64,
	look:     [2]f32, // yaw, pitch
}

Ban :: struct {
	until:  i64, // 0: for good
	by:     string,
	reason: string,
}

Member :: struct {
	nick:        string, // "": their name
	muted_until: i64, // 0: not muted; FOREVER: for good
	ignores:     [dynamic]string,
	homes:       map[string]Place,
	seen:        i64, // when they last left (or joined)
	ip:          string, // their last address
}

// Community: on the heap, strings owned.
Community :: struct {
	motd:         string, // shown to each player joining (formatted)
	members:      map[string]Member,
	warps:        map[string]Place,
	bans:         map[string]Ban, // by character name
	account_bans: map[string]Ban, // by account (hex)
	ip_bans:      map[string]Ban,
}

FOREVER :: max(i64)

now_unix :: proc() -> i64 {
	return time.time_to_unix(time.now())
}

// member_get: name's entry (made if new).
member_get :: proc(m: ^Community, name: string) -> ^Member {
	if e, ok := &m.members[name]; ok {return e}
	m.members[strings.clone(name)] = {}
	return &m.members[name]
}

// set_string replaces an owned string.
set_string :: proc(s: ^string, value: string) {
	delete(s^)
	s^ = strings.clone(value)
}

ban_destroy :: proc(b: ^Ban) {
	delete(b.by)
	delete(b.reason)
}

// place_delete removes key from a map of places (its owned key freed).
place_delete :: proc(m: ^map[string]Place, key: string) -> bool {
	for k in m {
		if k == key {
			delete_key(m, key)
			delete(k)
			return true
		}
	}
	return false
}

// place_set adds or replaces key in a map of places.
place_set :: proc(m: ^map[string]Place, key: string, p: Place) {
	if old, ok := &m[key]; ok {
		old^ = p
		return
	}
	m[strings.clone(key)] = p
}

// ban_delete removes key from a map of bans.
ban_delete :: proc(m: ^map[string]Ban, key: string) -> bool {
	for k, &b in m {
		if k == key {
			ban_destroy(&b)
			delete_key(m, key)
			delete(k)
			return true
		}
	}
	return false
}

// ban_set adds or replaces key in a map of bans.
ban_set :: proc(m: ^map[string]Ban, key: string, until: i64, by, reason: string) {
	ban_delete(m, key)
	m[strings.clone(key)] = {until, strings.clone(by), strings.clone(reason)}
}

// ban_active: key is banned now (an expired ban is forgotten).
ban_active :: proc(m: ^map[string]Ban, key: string) -> (Ban, bool) {
	b, ok := m[key]
	if !ok {return {}, false}
	if b.until != 0 && b.until <= now_unix() {
		ban_delete(m, key)
		return {}, false
	}
	return b, true
}

community_destroy :: proc(m: ^Community) {
	for name, &e in m.members {
		delete(name)
		delete(e.nick)
		delete(e.ip)
		for x in e.ignores {delete(x)}
		delete(e.ignores)
		for k in e.homes {delete(k)}
		delete(e.homes)
	}
	delete(m.members)
	for k in m.warps {delete(k)}
	delete(m.warps)
	for k, &b in m.bans {
		delete(k)
		ban_destroy(&b)
	}
	delete(m.bans)
	for k, &b in m.ip_bans {
		delete(k)
		ban_destroy(&b)
	}
	delete(m.ip_bans)
	for k, &b in m.account_bans {
		delete(k)
		ban_destroy(&b)
	}
	delete(m.account_bans)
	delete(m.motd)
	m^ = {}
}

// place_parse: "x y z yaw pitch [world]" (no world: the home world's,
// from before worlds).
@(private = "file")
place_parse :: proc(f: []string, home: game.Address) -> (p: Place, ok: bool) {
	if len(f) != 5 && len(f) != 6 {return}
	p.world = home
	if len(f) == 6 {p.world = game.address_parse(f[5], {}) or_return}
	for i in 0 ..< 3 {
		p.position[i] = strconv.parse_f64(f[i]) or_return
		if abs(p.position[i]) >= game.WORLD_LIMIT {return}
	}
	p.look[0] = strconv.parse_f32(f[3]) or_return
	p.look[1] = clamp(strconv.parse_f32(f[4]) or_return, -game.PITCH_LIMIT, game.PITCH_LIMIT)
	return p, true
}

// community_parse reads community.cfg's text; problems are logged and the
// line skipped.
community_parse :: proc(m: ^Community, text: string, home: game.Address) {
	rest := text
	member: ^Member
	line_number := 0
	for raw in strings.split_lines_iterator(&rest) {
		line_number += 1
		line := strings.trim_space(raw)
		if line == "" || line[0] == '#' {continue}
		f := strings.fields(line, context.temp_allocator)
		_, _, tail := strings.partition(line, " ")
		ok := true
		switch f[0] {
		case "motd":
			set_string(&m.motd, strings.trim_space(tail))
		case "player":
			ok = len(f) == 2 && game.name_valid(f[1])
			if ok {member = member_get(m, f[1])}
		case "warp":
			ok = len(f) == 7 || len(f) == 8
			if !ok {break}
			p: Place
			p, ok = place_parse(f[2:], home)
			if ok {place_set(&m.warps, f[1], p)}
		case "ban", "ban_ip", "ban_account":
			ok = len(f) >= 4
			if !ok {break}
			until, is_int := strconv.parse_i64(f[2])
			ok = is_int
			if !ok {break}
			reason := ""
			if len(f) > 4 {reason = strings.join(f[4:], " ", context.temp_allocator)}
			bans := &m.bans
			if f[0] == "ban_ip" {bans = &m.ip_bans}
			if f[0] == "ban_account" {bans = &m.account_bans}
			ban_set(bans, f[1], until, f[3], reason)
		case "nick":
			ok = member != nil && len(f) >= 2
			if ok {set_string(&member.nick, strings.trim_space(tail))}
		case "mute":
			ok = member != nil && len(f) == 2
			if ok {member.muted_until, ok = strconv.parse_i64(f[1])}
		case "ignore":
			ok = member != nil && len(f) == 2 && game.name_valid(f[1])
			if ok {list_set(&member.ignores, f[1], true)}
		case "home":
			ok = member != nil && (len(f) == 7 || len(f) == 8)
			if !ok {break}
			p: Place
			p, ok = place_parse(f[2:], home)
			if ok {place_set(&member.homes, f[1], p)}
		case "seen":
			ok = member != nil && len(f) == 2
			if ok {member.seen, ok = strconv.parse_i64(f[1])}
		case "ip":
			ok = member != nil && len(f) == 2
			if ok {set_string(&member.ip, f[1])}
		case:
			ok = false
		}
		if !ok {log.warnf("server community line ignored line=%d text=%q", line_number, line)}
	}
}

community_text :: proc(m: ^Community, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(
		&b,
		"# Voxiverse community (written by the server; see docs/debugging.md)\n",
	)
	if m.motd != "" {fmt.sbprintfln(&b, "motd %s", m.motd)}
	place :: proc(b: ^strings.Builder, p: Place) {
		fmt.sbprintf(
			b,
			"%.3f %.3f %.3f %.4f %.4f %s",
			p.position.x,
			p.position.y,
			p.position.z,
			p.look[0],
			p.look[1],
			game.address_dir(p.world),
		)
	}
	for name in sorted_keys(m.warps) {
		fmt.sbprintf(&b, "warp %s ", name)
		place(&b, m.warps[name])
		strings.write_byte(&b, '\n')
	}
	for name in sorted_keys(m.bans) {
		ban := m.bans[name]
		fmt.sbprintfln(&b, "ban %s %d %s %s", name, ban.until, ban.by, ban.reason)
	}
	for name in sorted_keys(m.ip_bans) {
		ban := m.ip_bans[name]
		fmt.sbprintfln(&b, "ban_ip %s %d %s %s", name, ban.until, ban.by, ban.reason)
	}
	for name in sorted_keys(m.account_bans) {
		ban := m.account_bans[name]
		fmt.sbprintfln(&b, "ban_account %s %d %s %s", name, ban.until, ban.by, ban.reason)
	}
	for name in sorted_keys(m.members) {
		e := &m.members[name]
		fmt.sbprintfln(&b, "player %s", name)
		if e.nick != "" {fmt.sbprintfln(&b, "nick %s", e.nick)}
		if e.muted_until != 0 {fmt.sbprintfln(&b, "mute %d", e.muted_until)}
		for x in e.ignores {fmt.sbprintfln(&b, "ignore %s", x)}
		for h in sorted_keys(e.homes) {
			fmt.sbprintf(&b, "home %s ", h)
			place(&b, e.homes[h])
			strings.write_byte(&b, '\n')
		}
		if e.seen != 0 {fmt.sbprintfln(&b, "seen %d", e.seen)}
		if e.ip != "" {fmt.sbprintfln(&b, "ip %s", e.ip)}
	}
	return strings.to_string(b)
}

// community_open reads the world's community.cfg (none: nobody yet).
community_open :: proc(s: ^Server) {
	if s.store.dir == "" {return}
	path :=
		filepath.join({s.store.dir, COMMUNITY_FILE}, context.temp_allocator) or_else COMMUNITY_FILE
	if data, err := os.read_entire_file_from_path(path, context.temp_allocator); err == nil {
		community_parse(&s.community, string(data), s.home.address)
	}
}

community_save :: proc(s: ^Server) -> bool {
	if s.store.dir == "" {return true}
	path :=
		filepath.join({s.store.dir, COMMUNITY_FILE}, context.temp_allocator) or_else COMMUNITY_FILE
	text := community_text(&s.community)
	return store_write(s, path, transmute([]u8)text)
}

// display_name: how c is shown (their nickname, else name; formatted).
display_name :: proc(s: ^Server, c: ^Client) -> string {
	name := client_name(c)
	if e, ok := &s.community.members[name]; ok && e.nick != "" {return e.nick}
	return name
}

// duration_text: "5m", "2h", "3d" (for mutes and bans; 0: for good).
duration_text :: proc(seconds: i64) -> string {
	switch {
	case seconds <= 0:
		return "for good"
	case seconds < 3600:
		return fmt.tprintf("%dm", (seconds + 59) / 60)
	case seconds < 86400:
		return fmt.tprintf("%dh", (seconds + 3599) / 3600)
	}
	return fmt.tprintf("%dd", (seconds + 86399) / 86400)
}

// duration_parse: "30" (minutes), "30m", "2h", "7d", "1w" -> seconds.
duration_parse :: proc(text: string) -> (seconds: i64, ok: bool) {
	if text == "" {return}
	unit: i64 = 60
	digits := text
	switch text[len(text) - 1] {
	case 's':
		unit = 1
	case 'm':
		unit = 60
	case 'h':
		unit = 3600
	case 'd':
		unit = 86400
	case 'w':
		unit = 7 * 86400
	}
	if text[len(text) - 1] >= 'a' {digits = text[:len(text) - 1]}
	n := strconv.parse_i64(digits) or_return
	if n <= 0 || n > 100 * 365 * 86400 / unit {return}
	return n * unit, true
}
