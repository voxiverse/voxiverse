package collector

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import "core:unicode/utf8"

import "common:game"
import "common:netcode"
import "common:telemetry"

// Developer chat (docs/telemetry.md, "Developer chat"): admin accounts write
// to the developers and read their replies over the collector's connection.
//
//	<dir>/admins.cfg                                  who is heard
//	<dir>/devchat/<account hex>/in/<ms>-<id hex>.json   a message, written once
//	<dir>/devchat/<account hex>/out/<name>.json         a reply, written by the
//	                                                    developers' program
//
// The account is the one that proved its key (Hello, Challenge, Proof); a
// message from any other account is refused with a reason and stores nothing.

ADMINS_CHECK :: time.Second

// Reply_File: what a reply file holds.
@(private)
Reply_File :: struct {
	id:   string,
	time: i64,
	text: string,
	link: string,
}

// devchat_admins re-reads admins.cfg when it has changed (checked once a second).
@(private)
devchat_admins :: proc(c: ^Collector) {
	if c.admins_checked && time.tick_diff(c.admins_at, c.now) < ADMINS_CHECK {return}
	c.admins_checked, c.admins_at = true, c.now
	data, err := os.read_entire_file_from_path(
		fmt.tprintf("%s/admins.cfg", c.dir),
		context.temp_allocator,
	)
	if err != nil {
		data = nil
	}
	if string(data) == c.admins_text && c.admins_loaded {return}
	delete(c.admins_text)
	c.admins_text = strings.clone(string(data))
	c.admins_loaded = true
	if bad := game.admins_parse(&c.admins, c.admins_text); bad > 0 {
		log.warnf(
			"collector admins.cfg: lines that are not an account key or steam:<id> count=%d",
			bad,
		)
	}
	log.infof("collector admins loaded count=%d", len(c.admins.accounts) + len(c.admins.steam))
}

@(private)
dev_refuse :: proc(c: ^Collector, id: netcode.Peer_Id, m: game.Dev_Message, why: string) {
	sync.mutex_lock(&c.mutex)
	c.stats.dev_refused += 1
	sync.mutex_unlock(&c.mutex)
	log.warnf("collector refused a developer message why=%s", why)
	send(c, id, game.Dev_Ack{m.id, false, why})
}

// take_dev_message stores an admin's message once and acknowledges it.
@(private)
take_dev_message :: proc(
	c: ^Collector,
	id: netcode.Peer_Id,
	p: ^Collector_Peer,
	m: game.Dev_Message,
) {
	devchat_admins(c)
	if !game.is_admin(&c.admins, p.account, p.steam_id) {
		dev_refuse(c, id, m, "this account is not a developer-chat admin")
		return
	}
	if len(m.text) == 0 {
		dev_refuse(c, id, m, "an empty message")
		return
	}
	hex := game.account_text(p.account)
	dir := fmt.tprintf("%s/devchat/%s/in", c.dir, hex)
	os.make_directory_all(dir)
	suffix := fmt.tprintf("-%08x.json", m.id)
	infos, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
	for info in infos {
		if strings.has_suffix(info.name, suffix) {
			sync.mutex_lock(&c.mutex)
			c.stats.dev_duplicates += 1
			sync.mutex_unlock(&c.mutex)
			send(c, id, game.Dev_Ack{m.id, true, ""}) // (it was stored before)
			return
		}
	}
	now := telemetry.now_ms()
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&b,
		`{{"id":"%08x","time":%d,"text":%s,"version":%s`,
		m.id,
		now,
		quote(m.text),
		quote(m.version),
	)
	if m.universe != "" {fmt.sbprintf(&b, `,"universe":%s`, quote(m.universe))}
	if m.world != "" {fmt.sbprintf(&b, `,"world":%s`, quote(m.world))}
	if m.has_pos {fmt.sbprintf(&b, `,"position":[%d,%d,%d]`, m.pos.x, m.pos.y, m.pos.z)}
	if m.has_tick {fmt.sbprintf(&b, `,"tick":%d`, m.tick)}
	strings.write_string(&b, "}\n")
	path := fmt.tprintf("%s/%d-%08x.json", dir, now, m.id)
	if os.write_entire_file(path, transmute([]u8)strings.to_string(b)) != nil {
		dev_refuse(c, id, m, "the message could not be stored")
		return
	}
	sync.mutex_lock(&c.mutex)
	c.stats.dev_stored += 1
	sync.mutex_unlock(&c.mutex)
	send(c, id, game.Dev_Ack{m.id, true, ""})
}

@(private)
quote :: proc(s: string) -> string {
	data, err := json.marshal(s, allocator = context.temp_allocator)
	return string(data) if err == nil else `""`
}

// reply_parse reads one reply file; ok is false for a malformed one.
@(private)
reply_parse :: proc(data: []u8, stem: string) -> (r: game.Dev_Reply, ok: bool) {
	f: Reply_File
	if json.unmarshal(data, &f, allocator = context.temp_allocator) != nil {return}
	if f.id != stem || len(f.id) == 0 || len(f.id) > game.MAX_DEV_FIELD {return}
	if f.time <= 0 || len(f.text) == 0 || len(f.text) > game.MAX_DEV_TEXT {return}
	if len(f.link) > game.MAX_DEV_LINK {return}
	if !utf8.valid_string(f.id) ||
	   !utf8.valid_string(f.text) ||
	   !utf8.valid_string(f.link) {return}
	return {f.id, f.time, f.text, f.link}, true
}

// take_dev_fetch answers with the replies after after_id (name order), at most one message's worth.
@(private)
take_dev_fetch :: proc(c: ^Collector, id: netcode.Peer_Id, p: ^Collector_Peer, m: game.Dev_Fetch) {
	devchat_admins(c)
	out: game.Dev_Replies
	if game.is_admin(&c.admins, p.account, p.steam_id) {
		dir := fmt.tprintf("%s/devchat/%s/out", c.dir, game.account_text(p.account))
		infos, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
		slice.sort_by(infos, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
		for info in infos {
			if info.type == .Directory || !strings.has_suffix(info.name, ".json") {continue}
			stem := info.name[:len(info.name) - len(".json")]
			if m.after_id != "" && stem <= m.after_id {continue}
			data, err := os.read_entire_file_from_path(info.fullpath, context.temp_allocator)
			reply: game.Dev_Reply
			ok := false
			if err == nil {reply, ok = reply_parse(data, stem)}
			if !ok {
				log.warnf("collector skipped a malformed reply file=%s", info.name)
				continue
			}
			out.entries[out.count] = reply
			out.count += 1
			if out.count == game.MAX_DEV_REPLIES {break}
		}
	}
	send(c, id, out)
}
