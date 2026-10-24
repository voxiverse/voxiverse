package server

import "core:fmt"
import "core:log"
import "core:strings"
import "core:unicode/utf8"

import "../game"

// Chat: what players say, as everyone sees it (their tag, name and words,
// each formatted on its own: game/format.odin), within a rate; numbered,
// so a moderator can take lines back; not shown to those ignoring the
// speaker; logged.

// CHAT_RECENT: lines remembered (who said them), to take back.
CHAT_RECENT :: 256
// A player may say CHAT_BURST lines at once, then one per CHAT_EVERY ticks.
CHAT_BURST :: 5
CHAT_EVERY :: game.TICK_RATE

Chat_State :: struct {
	next_id: u32,
	recent:  [CHAT_RECENT]Said, // ring, by id
}

Said :: struct {
	id:       u32,
	name:     [game.MAX_NAME_LENGTH]u8,
	name_len: int,
}

// chat_say: c says text (a Chat message).
@(private)
chat_say :: proc(s: ^Server, c: ^Client, text: string) {
	name := client_name(c)
	words := words_of(s, c, text)
	if words == "" || !may_speak(s, c) {return}
	line := game.format_join({speaker(s, c), ": ", words})
	log.infof("server chat name=%s text=%q", name, game.format_strip(line))
	id := chat_next(s, name)
	for &other in s.clients {
		if other.state != .Playing || ignores(s, &other, name) {continue}
		send_message(s, &other, game.Chat_Line{id, player_id(s, c), line})
	}
}

// speaker: c's tag (role prefix), name (or nickname) and suffix, as one
// formatted part.
@(private)
speaker :: proc(s: ^Server, c: ^Client) -> string {
	name := client_name(c)
	prefix := meta_of(&s.perms, name, "prefix")
	suffix := meta_of(&s.perms, name, "suffix")
	parts := make([dynamic]string, context.temp_allocator)
	if prefix != "" {append(&parts, prefix, " ")}
	append(&parts, display_name(s, c))
	if suffix != "" {append(&parts, " ", suffix)}
	return game.format_join(parts[:])
}

// chat_clean: text without control characters or broken UTF-8, trimmed.
@(private)
chat_clean :: proc(text: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r in text {
		if r == utf8.RUNE_ERROR || r < 0x20 || r == 0x7f {continue}
		strings.write_rune(&b, r)
	}
	return strings.trim_space(strings.to_string(b))
}

// ignores: c ignores the player called name.
@(private)
ignores :: proc(s: ^Server, c: ^Client, name: string) -> bool {
	e, ok := &s.community.members[client_name(c)]
	if !ok {return false}
	for x in e.ignores {if x == name {return true}}
	return false
}

@(private)
chat_next :: proc(s: ^Server, name: string) -> u32 {
	s.chat.next_id += 1
	id := s.chat.next_id
	said := &s.chat.recent[id % CHAT_RECENT]
	said.id = id
	said.name_len = copy(said.name[:], name)
	return id
}

// chat_system: a line from the server to everyone (who joined, left...).
@(private)
chat_system :: proc(s: ^Server, text: string) {
	log.infof("server chat system text=%q", game.format_strip(text))
	id := chat_next(s, "")
	for &c in s.clients {
		if c.state == .Playing {send_message(s, &c, game.Chat_Line{id, game.NO_PLAYER, text})}
	}
}

// chat_take_back: the newest count lines of name, taken back from
// everyone; how many there were.
@(private)
chat_take_back :: proc(s: ^Server, name: string, count: int) -> int {
	taken := 0
	for back in u32(0) ..< CHAT_RECENT {
		if taken == count || back >= s.chat.next_id {break}
		id := s.chat.next_id - back
		said := &s.chat.recent[id % CHAT_RECENT]
		if said.id != id || string(said.name[:said.name_len]) != name {continue}
		said.id = 0
		for &c in s.clients {
			if c.state == .Playing {send_message(s, &c, game.Chat_Delete{id})}
		}
		taken += 1
	}
	return taken
}

// --- Commands -------------------------------------------------------------

// admin_delmsg: take back a player's newest lines (default one).
@(private)
admin_delmsg :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	if !game.name_valid(args[0]) {return false}
	count := 1
	if len(args) == 2 {
		n, ok := parse_count(args[1])
		if !ok {return false}
		count = n
	}
	taken := chat_take_back(s, args[0], count)
	log.infof("server chat taken back name=%s lines=%d by=%s", args[0], taken, client_name(c))
	notice(s, c, fmt.tprintf("Took back %d line(s) of %s", taken, args[0]))
	return true
}

// admin_mute: mute a player (for a while, or for good).
@(private)
admin_mute :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	if !game.name_valid(args[0]) {return false}
	until := i64(FOREVER)
	if len(args) == 2 {
		seconds, ok := duration_parse(args[1])
		if !ok {return false}
		until = now_unix() + seconds
	}
	member_get(&s.community, args[0]).muted_until = until
	how := "for good" if until == FOREVER else fmt.tprintf("for %s", args[1])
	log.infof("server muted name=%s until=%d by=%s", args[0], until, client_name(c))
	notice(s, c, fmt.tprintf("Muted %s %s", args[0], how))
	if other := client_by_name(s, args[0]); other != nil {
		notice(s, other, fmt.tprintf("&cYou were muted %s", how))
	}
	return true
}

@(private)
admin_unmute :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	if !game.name_valid(args[0]) {return false}
	if e, ok := &s.community.members[args[0]]; ok {e.muted_until = 0}
	notice(s, c, fmt.tprintf("Unmuted %s", args[0]))
	if other := client_by_name(s, args[0]); other != nil {notice(s, other, "You may speak again")}
	return true
}

// admin_ignore: stop (or start again) seeing what a player says.
@(private)
admin_ignore :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	if !game.name_valid(args[0]) || args[0] == client_name(c) {return false}
	e := member_get(&s.community, client_name(c))
	now := !ignores(s, c, args[0])
	list_set(&e.ignores, args[0], now)
	notice(s, c, fmt.tprintf("%s %s", "Ignoring" if now else "No longer ignoring", args[0]))
	return true
}

// client_by_name: the playing client called name, or nil.
@(private)
client_by_name :: proc(s: ^Server, name: string) -> ^Client {
	for &c in s.clients {
		if c.state == .Playing && client_name(&c) == name {return &c}
	}
	return nil
}

@(private)
parse_count :: proc(text: string) -> (int, bool) {
	n := 0
	if len(text) == 0 || len(text) > 4 {return 0, false}
	for ch in transmute([]u8)text {
		if ch < '0' || ch > '9' {return 0, false}
		n = n * 10 + int(ch - '0')
	}
	return n, n > 0
}
