package server

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import "common:base"
import "common:game"

// Who may do what (common/game/permissions.odin has the rules): roles grant
// nodes and inherit other roles; players have roles and grants of their
// own; both carry metadata (prefix, suffix, ... whatever content wants).
// Everyone has the role "default". Kept in the world's permissions.cfg:
//
//	role mod
//	inherit default
//	grant chat.*
//	grant -chat.format
//	meta prefix &e&lMod
//	player Alice
//	role mod
//
// The owner (the local player of a world played here, or anyone with the
// dedicated server's --cheats) has every node.

PERMISSIONS_FILE :: "permissions.cfg"

Role :: struct {
	inherits: [dynamic]string,
	grants:   [dynamic]string,
	meta:     map[string]string,
}

Perm_Player :: struct {
	roles:  [dynamic]string,
	grants: [dynamic]string,
	meta:   map[string]string,
}

// Permissions: on the heap (it changes while running), strings owned.
Permissions :: struct {
	roles:   map[string]Role,
	players: map[string]Perm_Player,
}

// A new world's roles: everyone may play, chat and travel; moderators
// keep order; admins may do anything.
@(private)
DEFAULT_PERMISSIONS :: `# Voxiverse permissions: roles grant nodes ("chat.*": everything under chat,
# "-chat.format": not that), inherit roles, and carry metadata; players get
# roles and grants. Everyone has the role default. See docs/debugging.md.
role default
grant world.edit
grant chat.send
grant chat.msg
grant chat.me
grant chat.ignore
grant chat.afk
grant teleport.spawn
grant teleport.home
grant teleport.warp
grant teleport.tpa
grant teleport.back
grant info.*
grant -info.stats.others
grant items.wear
meta max_homes 3
role mod
inherit default
grant chat.*
grant moderation.*
grant teleport.tp
meta prefix &e&lMod
role admin
inherit mod
grant *
meta prefix &c&lAdmin
`

permissions_destroy :: proc(p: ^Permissions) {
	for name, &r in p.roles {
		delete(name)
		role_destroy(&r)
	}
	delete(p.roles)
	for name, &pl in p.players {
		delete(name)
		for x in pl.roles {delete(x)}
		delete(pl.roles)
		for x in pl.grants {delete(x)}
		delete(pl.grants)
		meta_destroy(&pl.meta)
	}
	delete(p.players)
	p^ = {}
}

role_free :: proc(r: ^Role) {role_destroy(r)}

map_entry_role :: proc(p: ^Permissions, name: string) -> (key: string, r: Role, ok: bool) {
	for k, v in p.roles {if k == name {return k, v, true}}
	return
}

// list_set adds (present) or removes value in a list of owned strings.
list_set :: proc(list: ^[dynamic]string, value: string, present: bool) {
	for x, i in list {
		if x != value {continue}
		if !present {
			delete(x)
			ordered_remove(list, i)
		}
		return
	}
	if present {append(list, strings.clone(value))}
}

@(private = "file")
role_destroy :: proc(r: ^Role) {
	for x in r.inherits {delete(x)}
	delete(r.inherits)
	for x in r.grants {delete(x)}
	delete(r.grants)
	meta_destroy(&r.meta)
}

@(private = "file")
meta_destroy :: proc(m: ^map[string]string) {
	for k, v in m {
		delete(k)
		delete(v)
	}
	delete(m^)
}

// permissions_parse reads permissions.cfg's text; problems are logged and
// their lines skipped.
permissions_parse :: proc(p: ^Permissions, text: string) {
	rest := text
	role: ^Role
	player: ^Perm_Player
	line_number := 0
	for raw in strings.split_lines_iterator(&rest) {
		line_number += 1
		line := strings.trim_space(raw)
		if line == "" || line[0] == '#' {continue}
		word, _, value := strings.partition(line, " ")
		value = strings.trim_space(value)
		ok := true
		switch word {
		case "role":
			if player != nil {
				ok = short_name_valid(value)
				if ok &&
				   !slice.contains(
						   player.roles[:],
						   value,
					   ) {append(&player.roles, strings.clone(value))}
			} else {
				ok = short_name_valid(value)
				if ok {role = role_get(p, value)}
			}
		case "player":
			ok = game.name_valid(value)
			if ok {
				role = nil
				player = player_perms(p, value)
			}
		case "account":
			a, parsed := game.account_parse(value)
			ok = parsed
			if ok {
				role = nil
				player = player_perms(p, account_key(a))
			}
		case "inherit":
			ok = role != nil && short_name_valid(value)
			if ok {append(&role.inherits, strings.clone(value))}
		case "grant":
			_, ok = game.grant_parse(value, 0)
			if ok &&
			   role !=
				   nil {append(&role.grants, strings.clone(value))} else if ok && player != nil {append(&player.grants, strings.clone(value))} else {ok = false}
		case "meta":
			key, _, v := strings.partition(value, " ")
			ok = key != "" && (role != nil || player != nil)
			if ok {meta_set(&role.meta if role != nil else &player.meta, key, strings.trim_space(v))}
		case:
			ok = false
		}
		if !ok {log.warnf("server permissions line ignored line=%d text=%q", line_number, line)}
	}
}

permissions_text :: proc(p: ^Permissions, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(
		&b,
		"# Voxiverse permissions (written by the server; see docs/debugging.md)\n",
	)
	role_names := sorted_keys(p.roles)
	for name in role_names {
		r := &p.roles[name]
		fmt.sbprintfln(&b, "role %s", name)
		for x in r.inherits {fmt.sbprintfln(&b, "inherit %s", x)}
		for x in r.grants {fmt.sbprintfln(&b, "grant %s", x)}
		for k in sorted_keys(r.meta) {fmt.sbprintfln(&b, "meta %s %s", k, r.meta[k])}
	}
	for name in sorted_keys(p.players) {
		pl := &p.players[name]
		if strings.has_prefix(name, ACCOUNT_PREFIX) {
			fmt.sbprintfln(&b, "account %s", name[len(ACCOUNT_PREFIX):])
		} else {
			fmt.sbprintfln(&b, "player %s", name)
		}
		for x in pl.roles {fmt.sbprintfln(&b, "role %s", x)}
		for x in pl.grants {fmt.sbprintfln(&b, "grant %s", x)}
		for k in sorted_keys(pl.meta) {fmt.sbprintfln(&b, "meta %s %s", k, pl.meta[k])}
	}
	return strings.to_string(b)
}

// sorted_keys: a map's keys in order (temp allocator).
sorted_keys :: proc(m: map[string]$V) -> []string {
	keys := make([dynamic]string, 0, len(m), context.temp_allocator)
	for k in m {append(&keys, k)}
	slice.sort(keys[:])
	return keys[:]
}

// short_name_valid: a role's, a structure's, a home's or a warp's name: 1 to 32
// lowercase letters, digits, _ and -.
short_name_valid :: proc(name: string) -> bool {
	if len(name) == 0 || len(name) > 32 {return false}
	for c in transmute([]u8)name {
		if !((c >= 'a' && c <= 'z') ||
			   (c >= '0' && c <= '9') ||
			   c == '_' ||
			   c == '-') {return false}
	}
	return true
}

role_get :: proc(p: ^Permissions, name: string) -> ^Role {
	if r, ok := &p.roles[name]; ok {return r}
	p.roles[strings.clone(name)] = {}
	return &p.roles[name]
}

player_perms :: proc(p: ^Permissions, name: string) -> ^Perm_Player {
	if pl, ok := &p.players[name]; ok {return pl}
	p.players[strings.clone(name)] = {}
	return &p.players[name]
}

meta_set :: proc(m: ^map[string]string, key, value: string) {
	if old_key, old, ok := map_entry_of(m, key); ok {
		delete(old)
		if value == "" {
			delete_key(m, key)
			delete(old_key)
			return
		}
		m[old_key] = strings.clone(value)
		return
	}
	if value != "" {m[strings.clone(key)] = strings.clone(value)}
}

@(private = "file")
map_entry_of :: proc(m: ^map[string]string, key: string) -> (k, v: string, ok: bool) {
	for mk, mv in m {if mk == key {return mk, mv, true}}
	return
}

// resolve: the grants of player name (the owner: everything), nearest
// first: their own (rank 0), their roles and default (1), what those
// inherit (2, ...). Patterns are cloned with allocator.
resolve :: proc(
	p: ^Permissions,
	name: string,
	account: Maybe(game.Account),
	owner: bool,
	out: ^[dynamic]game.Grant,
	allocator := context.allocator,
	guest_role := "", // the world's rule: a role everyone has besides default
) {
	if owner {append(out, game.Grant{strings.clone("*", allocator), true, 0})}
	add :: proc(out: ^[dynamic]game.Grant, texts: []string, rank: int, allocator: mem.Allocator) {
		for t in texts {
			if g, ok := game.grant_parse(t, rank); ok {
				g.pattern = strings.clone(g.pattern, allocator)
				append(out, g)
			}
		}
	}
	level := make([dynamic]string, context.temp_allocator)
	// The character's own, and their account's (every character of it).
	for key in ([2]string{name, account_key(account)}) {
		if pl, ok := &p.players[key]; ok && key != "" {
			add(out, pl.grants[:], 0, allocator)
			append(&level, ..pl.roles[:])
		}
	}
	append(&level, "default")
	if guest_role != "" {append(&level, guest_role)}
	seen := make(map[string]struct{}, 16, context.temp_allocator)
	for rank := 1; len(level) > 0 && rank < 32; rank += 1 {
		next := make([dynamic]string, context.temp_allocator)
		for role in level {
			if role in seen {continue}
			seen[role] = {}
			r, ok := &p.roles[role]
			if !ok {continue}
			add(out, r.grants[:], rank, allocator)
			append(&next, ..r.inherits[:])
		}
		level = next
	}
}

// Permissions for an account (all its characters) are kept as a player
// called ACCOUNT_PREFIX + its hex (`account <hex>` in permissions.cfg).
ACCOUNT_PREFIX :: "account:"

account_key :: proc(account: Maybe(game.Account)) -> string {
	a, ok := account.?
	if !ok {return ""}
	return strings.concatenate({ACCOUNT_PREFIX, game.account_text(a)}, context.temp_allocator)
}

// meta_of: player name's metadata key: their own, else the nearest role's.
meta_of :: proc(p: ^Permissions, name, key: string) -> string {
	level := make([dynamic]string, context.temp_allocator)
	if pl, ok := &p.players[name]; ok {
		if v, has := pl.meta[key]; has {return v}
		append(&level, ..pl.roles[:])
	}
	append(&level, "default")
	seen := make(map[string]struct{}, 16, context.temp_allocator)
	for len(level) > 0 {
		next := make([dynamic]string, context.temp_allocator)
		for role in level {
			if role in seen {continue}
			seen[role] = {}
			r, ok := &p.roles[role]
			if !ok {continue}
			if v, has := r.meta[key]; has {return v}
			append(&next, ..r.inherits[:])
		}
		level = next
	}
	return ""
}

// permissions_open reads the world's permissions.cfg, or makes the
// default (written with the world's other files).
permissions_open :: proc(s: ^Server) {
	text := DEFAULT_PERMISSIONS
	if s.store.dir != "" {
		path :=
			filepath.join(
				{s.store.dir, PERMISSIONS_FILE},
				context.temp_allocator,
			) or_else PERMISSIONS_FILE
		if data, err := os.read_entire_file_from_path(path, context.temp_allocator); err == nil {
			text = string(data)
		}
	}
	permissions_parse(&s.perms, text)
}

permissions_save :: proc(s: ^Server) -> bool {
	if s.store.dir == "" {return true}
	path :=
		filepath.join(
			{s.store.dir, PERMISSIONS_FILE},
			context.temp_allocator,
		) or_else PERMISSIONS_FILE
	text := permissions_text(&s.perms)
	return store_write(s, path, transmute([]u8)text)
}

// is_owner: c has every node (the local player of a world played here;
// everyone, with everyone_cheats).
is_owner :: proc(s: ^Server, c: ^Client) -> bool {
	_, local := c.link.(Local)
	return (local && s.config.allow_cheats) || s.config.everyone_cheats
}

// refresh_grants resolves c's grants again and tells them.
refresh_grants :: proc(s: ^Server, c: ^Client) {
	for g in c.grants {delete(g.pattern)}
	clear(&c.grants)
	guest := base.var_text(&c.world.rules.guest_role) if c.world != nil else ""
	resolve(&s.perms, client_name(c), c.account, is_owner(s, c), &c.grants, guest_role = guest)
	grants := game.Grants{game.grants_text(c.grants[:]), commands_allowed(s, c)}
	state_put(s, c, .Grants, &grants)
}

// permissions_changed: after an edit, everyone's grants again, and saved.
permissions_changed :: proc(s: ^Server) {
	for &c in s.clients {if c.state == .Playing {refresh_grants(s, &c)}}
	permissions_save(s)
}

// allowed: c may do node.
allowed :: proc(s: ^Server, c: ^Client, node: string) -> bool {
	return game.allowed(c.grants[:], node)
}
