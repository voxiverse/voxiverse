package server

import "core:fmt"
import "core:log"
import "core:path/filepath"

import "../base"
import "../common/game"
import "../common/netcode"
import "../common/telemetry"

// The session recording (issue #65, the LAN party): while a server runs (a
// dedicated one, or a game Open to LAN) it writes every event to one file of
// its own, <universe>/analytics/session-<unix time>.jsonl, in the same lines as
// the telemetry's day files, with more kinds (ping, kills with their time to
// kill, damage by weapon, jumps, the hook, frame times and hardware the
// clients report, tick times, desyncs, bandwidth, the warnings and errors of
// the log). Nothing here is uploaded: the kinds with `session_only` never
// reach the day files, and the uploader reads only those. `build analytics
// --session <file>` reads it (tools/analytics/session.odin).

SESSION_FILE_PREFIX :: "session-"
PING_SAMPLE_TICKS :: 10 * game.TICK_RATE

// emit_event: an event to the day sink (unless the kind is the session's own) and the
// session's.
emit_event :: proc(s: ^Server, e: telemetry.Event) {
	if !telemetry.KIND_INFO[e.kind].session_only {telemetry.emit(&s.sink, e)}
	if s.session_on {telemetry.emit(&s.session, e)}
}

// session_open: start the session's file (nothing when the universe has no folder) and listen
// to the log for warnings and errors.
session_open :: proc(s: ^Server) {
	if s.store.dir == "" {return}
	dir := filepath.join({s.store.dir, "analytics"}, context.temp_allocator) or_else ""
	name := fmt.tprintf("%s%d.jsonl", SESSION_FILE_PREFIX, telemetry.now_ms() / 1000)
	telemetry.sink_start(
		&s.session,
		dir,
		u32(telemetry.now_ms()),
		stepped = s.config.stepped,
		file_name = name,
	)
	s.session_on = true
	emit_event(
		s,
		{actor = telemetry.NO_ACTOR, kind = .Server_Start, n = {i64(s.config.max_players), 0, 0}},
	)
	if sink := base.log_sink_of(context.logger); sink != nil {
		s.log_sink = sink
		base.log_set_capture(sink, session_log_line, s)
	}
}

// session_close: the clean end (a file without it ended in a crash) and the file closed.
session_close :: proc(s: ^Server) {
	if !s.session_on {return}
	if s.log_sink != nil {base.log_set_capture(s.log_sink, nil, nil)}
	emit_event(s, {tick = u32(s.tick), actor = telemetry.NO_ACTOR, kind = .Server_Stop})
	s.session_on = false
	telemetry.sink_stop(&s.session)
}

// session_log_line: a warning or an error of the log, kept (called with the log's lock held:
// it must not log).
@(private = "file")
session_log_line :: proc(data: rawptr, level: log.Level, tag: string, text: string) {
	s := (^Server)(data)
	if !s.session_on {return}
	line := fmt.tprintf("%v %s: %s", level, tag, text)
	telemetry.emit(
		&s.session,
		{
			tick = u32(s.tick),
			actor = telemetry.NO_ACTOR,
			kind = .Log_Line,
			note = telemetry.note(line),
		},
	)
}

// session_minute: once a minute, the server's own numbers: tick times (median, 95th
// percentile, worst), the desync counter, and each player's bandwidth that minute.
session_minute :: proc(s: ^Server, samples: []u32) {
	if !s.session_on || len(samples) == 0 {return}
	emit_event(
		s,
		{
			tick = u32(s.tick),
			actor = telemetry.NO_ACTOR,
			kind = .Server_Perf,
			n = {
				i64(samples[len(samples) / 2]),
				i64(samples[len(samples) * 95 / 100]),
				i64(samples[len(samples) - 1]),
			},
		},
	)
	emit_event(
		s,
		{
			tick = u32(s.tick),
			actor = telemetry.NO_ACTOR,
			kind = .Server_Net,
			n = {i64(s.desyncs), i64(s.checks_judged), i64(s.checks_skipped)},
		},
	)
	for &c in s.clients {
		if c.state != .Playing {continue}
		peer, remote := c.link.(netcode.Peer_Id)
		if !remote || !s.listening {continue}
		conn := netcode.host_conn(&s.host, peer)
		if conn == nil {continue}
		st := conn.stats
		record(
			s,
			&c,
			.Bandwidth_Sample,
			n0 = i64(st.bytes_sent - c.net_seen.bytes_sent),
			n1 = i64(st.bytes_received - c.net_seen.bytes_received),
			n2 = i64(st.resent - c.net_seen.resent),
		)
		c.net_seen = st
	}
}

// session_ping: every 10 seconds, a player's round trip (not for the one playing on the
// server's own process: they have none).
session_ping :: proc(s: ^Server, c: ^Client) {
	if !s.session_on {return}
	if (s.tick + u64(player_id(s, c)) * 11) % PING_SAMPLE_TICKS != 0 {return}
	rtt := f32(0)
	if peer, remote := c.link.(netcode.Peer_Id); remote && s.listening {
		if conn := netcode.host_conn(&s.host, peer); conn != nil {rtt = conn.rtt_ms}
	}
	record(s, c, .Ping_Sample, n0 = i64(rtt + 0.5))
}

// Engagement: the first damage of one attacker to one victim, for the time to kill.
Engagement :: struct {
	attacker: u16,
	since:    u64, // the tick
	live:     bool,
}

ENGAGEMENT_TICKS :: 10 * game.TICK_RATE // a pause this long starts a fight anew

// session_damage: attacker's weapon hurt victim by amount (and killed it, if so): the damage dealt
// by weapon, and a kill's time to kill (from the fight's first hit).
session_damage :: proc(
	s: ^Server,
	victim: ^Client,
	amount: f32,
	source: Damage_Source,
	killed: bool,
) {
	id, by_player := source.attacker.?
	if !by_player || int(id) >= len(s.clients) {return}
	attacker := &s.clients[id]
	if attacker.state != .Playing || id == player_id(s, victim) {return}
	what := source.weapon if source.weapon != "" else game.damage_source_name(source.kind)
	slot := -1
	for e, i in victim.fights {
		if e.live && e.attacker == id {slot = i}
	}
	if slot >= 0 && s.tick - victim.fights[slot].since > ENGAGEMENT_TICKS {slot = -1}
	if slot < 0 { 	// a new fight: a free slot, else the oldest
		oldest := 0
		slot = -1
		for e, i in victim.fights {
			if !e.live || (e.live && e.attacker == id) {
				slot = i
				break
			}
			if e.since < victim.fights[oldest].since {oldest = i}
		}
		if slot < 0 {slot = oldest}
		victim.fights[slot] = {id, s.tick, true}
	}
	record(s, attacker, .Damage_Dealt, what, i64(amount * 10 + 0.5), i64(player_id(s, victim)))
	if killed {
		ms := i64(s.tick - victim.fights[slot].since) * 1000 / game.TICK_RATE
		record(s, attacker, .Kill, what, ms, i64(player_id(s, victim)))
		victim.fights = {}
	}
}
