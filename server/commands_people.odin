package server

import "core:fmt"
import "core:log"
import "core:slice"
import "core:strings"

import "../game"

// Server commands about people (after EssentialsX's): whispering, actions,
// broadcasts, nicknames, the message of the day; kicking and banning (by
// name, for a while, by address); who is here, who someone is, when they
// were last seen, away, how the server is doing.

// may_speak: c may say something now (not muted; within the chat rate);
// else they are told why. Saying something ends being away.
@(private)
may_speak :: proc(s: ^Server, c: ^Client) -> bool {
	if e, ok := &s.community.members[client_name(c)]; ok && e.muted_until != 0 {
		if e.muted_until == FOREVER || e.muted_until > now_unix() {
			left :=
				"" if e.muted_until == FOREVER else fmt.tprintf(" (%s more)", duration_text(e.muted_until - now_unix()))
			notice(s, c, fmt.tprintf("&cYou are muted%s", left))
			return false
		}
		e.muted_until = 0
	}
	// The rate: a bucket of CHAT_BURST lines, refilled one per CHAT_EVERY.
	refill := int((s.tick - c.chat_tick) / CHAT_EVERY)
	if refill > 0 {
		c.chat_tokens = min(CHAT_BURST, c.chat_tokens + refill)
		c.chat_tick += u64(refill) * CHAT_EVERY
	}
	if c.chat_tokens == 0 {
		notice(s, c, "&cSlow down")
		return false
	}
	c.chat_tokens -= 1
	if c.afk {set_afk(s, c, false)}
	return true
}

// words_of: what c wrote, cleaned, with the codes it may not use escaped.
@(private)
words_of :: proc(s: ^Server, c: ^Client, text: string) -> string {
	kinds: game.Format_Kinds
	if allowed(s, c, "chat.format.color") {kinds += {.Color}}
	if allowed(s, c, "chat.format.rgb") {kinds += {.Rgb}}
	if allowed(s, c, "chat.format.style") {kinds += {.Style}}
	return game.format_filter(chat_clean(text), kinds)
}

// --- Messaging ---

// admin_msg: a word to one player only.
@(private)
admin_msg :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	return whisper(s, c, args[0], strings.join(args[1:], " ", context.temp_allocator))
}

// admin_r: answer whoever last whispered with you.
@(private)
admin_r :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	if c.reply_len == 0 {
		notice(s, c, "&cNobody to answer")
		return true
	}
	return whisper(
		s,
		c,
		string(c.reply[:c.reply_len]),
		strings.join(args, " ", context.temp_allocator),
	)
}

@(private = "file")
whisper :: proc(s: ^Server, c: ^Client, name, text: string) -> bool {
	to := client_by_name(s, name)
	if to == nil || to == c {
		notice(s, c, fmt.tprintf("&c%s is not here", name))
		return true
	}
	words := words_of(s, c, text)
	if words == "" || !may_speak(s, c) {return true}
	log.infof(
		"server whisper from=%s to=%s text=%q",
		client_name(c),
		name,
		game.format_strip(words),
	)
	id := chat_next(s, client_name(c))
	sender := player_id(s, c)
	send_message(
		s,
		c,
		game.Chat_Line {
			id,
			sender,
			game.format_join({"&7[me -> ", display_name(s, to), "&7]", " ", words}),
		},
	)
	if !ignores(s, to, client_name(c)) {
		send_message(
			s,
			to,
			game.Chat_Line {
				id,
				sender,
				game.format_join({"&7[", speaker(s, c), "&7 -> me]", " ", words}),
			},
		)
		to.reply_len = copy(to.reply[:], client_name(c))
	}
	c.reply_len = copy(c.reply[:], name)
	return true
}

// admin_me: an action ("* alice waves").
@(private)
admin_me :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	words := words_of(s, c, strings.join(args, " ", context.temp_allocator))
	if words == "" || !may_speak(s, c) {return true}
	line := game.format_join({"* ", speaker(s, c), " ", words})
	log.infof("server chat action name=%s text=%q", client_name(c), game.format_strip(line))
	id := chat_next(s, client_name(c))
	for &other in s.clients {
		if other.state != .Playing || ignores(s, &other, client_name(c)) {continue}
		send_message(s, &other, game.Chat_Line{id, player_id(s, c), line})
	}
	return true
}

@(private)
admin_broadcast :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	chat_system(
		s,
		game.format_join({"&d[Broadcast]", " ", strings.join(args, " ", context.temp_allocator)}),
	)
	return true
}

// admin_nick: a nickname (formatted as the player may format chat; its
// letters a name's, and nobody else's name), or "off"; another's with
// chat.nick.others.
@(private)
admin_nick :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	who := client_name(c)
	if len(args) == 2 {
		if !allowed(s, c, "chat.nick.others") {
			notice(s, c, "You may not name others here (chat.nick.others)")
			return true
		}
		if !game.name_valid(args[1]) {return false}
		who = args[1]
	}
	m := member_get(&s.community, who)
	if args[0] == "off" {
		set_string(&m.nick, "")
		notice(s, c, fmt.tprintf("%s goes by their name again", who))
		return true
	}
	nick := words_of(s, c, args[0])
	plain := game.format_strip(nick)
	if !game.name_valid(plain) {
		notice(s, c, "&cA nickname's letters are a name's: 1 to 16 letters, digits, _ or -")
		return true
	}
	for name in s.community.members {
		if name != who && strings.equal_fold(name, plain) {
			notice(s, c, "&cThat is someone else's name")
			return true
		}
	}
	set_string(&m.nick, nick)
	notice(s, c, game.format_join({fmt.tprintf("%s is now ", who), nick}))
	return true
}

// admin_realname: who goes by a nickname.
@(private)
admin_realname :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	found := make([dynamic]string, context.temp_allocator)
	for name, m in s.community.members {
		if m.nick != "" &&
		   strings.equal_fold(game.format_strip(m.nick), args[0]) {append(&found, name)}
	}
	slice.sort(found[:])
	if len(found) == 0 {
		notice(s, c, fmt.tprintf("Nobody goes by %s", args[0]))
	} else {
		notice(
			s,
			c,
			fmt.tprintf("%s is %s", args[0], strings.join(found[:], ", ", context.temp_allocator)),
		)
	}
	return true
}

// admin_motd: the message of the day; set (server.motd) with set <text>.
@(private)
admin_motd :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	if len(args) == 0 {
		notice(s, c, s.community.motd if s.community.motd != "" else "No message of the day")
		return true
	}
	if args[0] != "set" {return false}
	if !allowed(s, c, "server.motd") {
		notice(s, c, "You may not set it here (server.motd)")
		return true
	}
	set_string(&s.community.motd, strings.join(args[1:], " ", context.temp_allocator))
	notice(s, c, "Message of the day set")
	return true
}

// --- Moderation ---

// exempt: name may not be kicked, banned or muted by others (the owner,
// or with moderation.exempt).
@(private)
exempt :: proc(s: ^Server, name: string) -> bool {
	if c := client_by_name(s, name); c != nil {return allowed(s, c, "moderation.exempt")}
	grants := make([dynamic]game.Grant, context.temp_allocator)
	account, known := s.store.characters[name]
	resolve(&s.perms, name, account if known else nil, false, &grants, context.temp_allocator)
	return game.allowed(grants[:], "moderation.exempt")
}

// kick sends a player away with a reason (not the local player: the
// world runs in their game).
@(private)
kick :: proc(s: ^Server, c, by: ^Client, reason: string) -> bool {
	if _, local := c.link.(Local); local {
		notice(s, by, "&cThe host cannot be sent away")
		return false
	}
	log.infof("server kicked name=%s by=%s reason=%q", client_name(c), client_name(by), reason)
	chat_system(
		s,
		game.format_join({display_name(s, c), fmt.tprintf("&e was sent away: %s", reason)}),
	)
	disconnect(s, c, reason)
	return true
}

@(private)
admin_kick :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	who := client_by_name(s, args[0])
	if who == nil {
		notice(s, c, fmt.tprintf("&c%s is not here", args[0]))
		return true
	}
	if exempt(s, args[0]) {
		notice(s, c, fmt.tprintf("&c%s may not be kicked", args[0]))
		return true
	}
	reason := strings.join(args[1:], " ", context.temp_allocator) if len(args) > 1 else "Kicked"
	kick(s, who, c, reason)
	return true
}

// admin_ban: ban <player> [reason]; tempban <player> <30m|2h|7d> [reason].
@(private)
admin_ban :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	return ban(s, c, args, 0)
}

@(private)
admin_tempban :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	seconds, ok := duration_parse(args[1])
	if !ok {return false}
	return ban(
		s,
		c,
		slice.concatenate([][]string{args[:1], args[2:]}, context.temp_allocator),
		seconds,
	)
}

@(private = "file")
ban :: proc(s: ^Server, c: ^Client, args: []string, seconds: i64) -> bool {
	name := args[0]
	if !game.name_valid(name) {return false}
	if exempt(s, name) {
		notice(s, c, fmt.tprintf("&c%s may not be banned", name))
		return true
	}
	reason := strings.join(args[1:], " ", context.temp_allocator) if len(args) > 1 else "Banned"
	until := now_unix() + seconds if seconds > 0 else 0
	ban_set(&s.community.bans, name, until, client_name(c), reason)
	if account, known := s.store.characters[name]; known {
		// Their account: every character of it, and any made after.
		ban_set(
			&s.community.account_bans,
			game.account_text(account),
			until,
			client_name(c),
			reason,
		)
	}
	how := fmt.tprintf("for %s", duration_text(seconds)) if seconds > 0 else "for good"
	notice(s, c, fmt.tprintf("Banned %s %s", name, how))
	if who := client_by_name(s, name);
	   who != nil {kick(s, who, c, fmt.tprintf("Banned %s: %s", how, reason))}
	return true
}

@(private)
admin_unban :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	ok := ban_delete(&s.community.bans, args[0])
	if account, known := s.store.characters[args[0]]; known {
		ban_delete(&s.community.account_bans, game.account_text(account))
	}
	notice(
		s,
		c,
		fmt.tprintf("Unbanned %s", args[0]) if ok else fmt.tprintf("%s was not banned", args[0]),
	)
	return true
}

// admin_ban_ip: ban an address (or a player's last one), and everyone
// playing from it.
@(private)
admin_ban_ip :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	address := args[0]
	if game.name_valid(args[0]) {
		if exempt(s, args[0]) {
			notice(s, c, fmt.tprintf("&c%s may not be banned", args[0]))
			return true
		}
		m, known := s.community.members[args[0]]
		if !known || m.ip == "" {
			notice(s, c, fmt.tprintf("&cNo address known for %s", args[0]))
			return true
		}
		address = m.ip
	}
	reason := strings.join(args[1:], " ", context.temp_allocator) if len(args) > 1 else "Banned"
	ban_set(&s.community.ip_bans, address, 0, client_name(c), reason)
	notice(s, c, fmt.tprintf("Banned the address %s", address))
	for &other in s.clients {
		if other.state == .Playing && other.address == address && &other != c {
			kick(s, &other, c, fmt.tprintf("Banned: %s", reason))
		}
	}
	return true
}

@(private)
admin_unban_ip :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	ok := ban_delete(&s.community.ip_bans, args[0])
	notice(
		s,
		c,
		fmt.tprintf("Unbanned %s", args[0]) if ok else fmt.tprintf("%s was not banned", args[0]),
	)
	return true
}

// banned: why a character called name, of account, from address, may not
// join.
@(private)
banned :: proc(s: ^Server, name, address: string, account: game.Account) -> (string, bool) {
	b, is := ban_active(&s.community.bans, name)
	if !is {b, is = ban_active(&s.community.account_bans, game.account_text(account))}
	if !is && address != "" {b, is = ban_active(&s.community.ip_bans, address)}
	if !is {return "", false}
	how :=
		fmt.tprintf("for %s more", duration_text(b.until - now_unix())) if b.until != 0 else "for good"
	why := fmt.tprintf("Banned %s: %s", how, b.reason)
	return why[:min(len(why), game.MAX_REASON_LENGTH)], true
}

// --- Who and status ---

@(private)
admin_list :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	names := make([dynamic]string, context.temp_allocator)
	for &other in s.clients {
		if other.state != .Playing {continue}
		entry := speaker(s, &other)
		if other.afk {entry = game.format_join({entry, " &7(away)"})}
		append(&names, entry)
	}
	notice(
		s,
		c,
		game.format_join(
			{
				fmt.tprintf("Here (%d of %d): ", len(names), s.config.max_players),
				strings.join(names[:], "&r, ", context.temp_allocator),
			},
		),
	)
	return true
}

@(private)
admin_whois :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	name := args[0]
	if !game.name_valid(name) {return false}
	lines := make([dynamic]string, context.temp_allocator)
	m, known := s.community.members[name]
	if m.nick != "" {append(&lines, game.format_join({"goes by ", m.nick}))}
	if pl, has := s.perms.players[name]; has && len(pl.roles) > 0 {
		append(
			&lines,
			fmt.tprintf("roles %s", strings.join(pl.roles[:], ", ", context.temp_allocator)),
		)
	}
	if who := client_by_name(s, name); who != nil {
		p := who.player.position
		append(
			&lines,
			fmt.tprintf("here at %.0f %.0f %.0f%s", p.x, p.y, p.z, ", away" if who.afk else ""),
		)
	} else if known && m.seen != 0 {
		append(&lines, fmt.tprintf("last seen %s ago", duration_text(now_unix() - m.seen)))
	} else {
		append(&lines, "never seen")
	}
	if m.muted_until != 0 {append(&lines, "muted")}
	if _, is := s.community.bans[name]; is {append(&lines, "banned")}
	if known &&
	   m.ip != "" &&
	   allowed(s, c, "moderation.address") {append(&lines, fmt.tprintf("from %s", m.ip))}
	if account, has := s.store.characters[name]; has && allowed(s, c, "moderation.address") {
		append(&lines, fmt.tprintf("account %s", game.account_text(account)))
	}
	notice(s, c, fmt.tprintf("%s: %s", name, strings.join(lines[:], "; ", context.temp_allocator)))
	return true
}

@(private)
admin_seen :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	if client_by_name(s, args[0]) != nil {
		notice(s, c, fmt.tprintf("%s is here", args[0]))
		return true
	}
	m, known := s.community.members[args[0]]
	if !known || m.seen == 0 {
		notice(s, c, fmt.tprintf("%s has never been here", args[0]))
	} else {
		notice(
			s,
			c,
			fmt.tprintf("%s was last here %s ago", args[0], duration_text(now_unix() - m.seen)),
		)
	}
	return true
}

// set_afk: c is away (or back); everyone is told.
@(private)
set_afk :: proc(s: ^Server, c: ^Client, on: bool) {
	if c.afk == on {return}
	c.afk = on
	chat_system(
		s,
		game.format_join({"&7* ", display_name(s, c), "&7 is away" if on else "&7 is back"}),
	)
}

@(private)
admin_afk :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	set_afk(s, c, !c.afk)
	return true
}

// admin_status: how the server is doing.
@(private)
admin_status :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	st := stats(s)
	players := 0
	for &other in s.clients {if other.state == .Playing {players += 1}}
	uptime := i64(s.tick / game.TICK_RATE)
	notice(
		s,
		c,
		fmt.tprintf(
			"Up %s; tick %.1f ms (of %.1f); %d chunks loaded, %d generating; %d block updates waiting; memory %.0f MiB; %d of %d players",
			duration_text(uptime) if uptime >= 60 else fmt.tprintf("%ds", uptime),
			st.tick_ms,
			1000.0 / f32(game.TICK_RATE),
			st.chunks_loaded,
			st.chunks_generating,
			st.updates_waiting,
			f64(st.arena_used + uint(st.arrays_bytes)) / (1 << 20),
			players,
			s.config.max_players,
		),
	)
	return true
}
