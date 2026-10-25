package server

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import "../game"
import "../telemetry"

// Statistics and events: everything the server counts or measures goes
// through record (a player did something) or record_world (the world did): it
// emits a telemetry event (the log, M27's upload) and adds to the counters
// the kind names (telemetry.KIND_INFO), the player's and the world's. Hot
// paths that cannot afford an event a tick (movement) call stat_add with the
// amount they accumulated. Counters are dotted names, a parent's total being
// the sum of its children (stats_total, asked, not stored); they live with
// the character (player_data.odin) and the world (<world>/stats.json).

TICK_SUMMARY_TICKS :: 60 * game.TICK_RATE // a Tick_Summary event a minute

Counters :: map[string]u64

// counter_add adds amount to the counter name (its key cloned on first use).
counter_add :: proc(m: ^Counters, name: string, amount: u64) {
	if amount == 0 {return}
	if v, ok := &m[name]; ok {
		v^ += amount
	} else {
		m[strings.clone(name)] = amount
	}
}

counters_free :: proc(m: ^Counters) {
	for k in m {delete(k)}
	delete(m^)
	m^ = nil
}

// counters_clone copies m (heap, keys owned).
counters_clone :: proc(m: Counters) -> (out: Counters) {
	for k, v in m {out[strings.clone(k)] = v}
	return
}

// stats_total: the sum of every counter at name or below it ("blocks.mined" adds
// "blocks.mined.stone" and "blocks.mined.sand"; name "" is everything).
stats_total :: proc(m: Counters, name: string) -> (total: u64) {
	for k, v in m {
		if name == "" ||
		   k == name ||
		   (strings.has_prefix(k, name) && len(k) > len(name) && k[len(name)] == '.') {
			total += v
		}
	}
	return
}

// counter_name: the counter an event of kind adds to, with %t the text.
@(private)
counter_name :: proc(kind: telemetry.Kind, text: string) -> string {
	pattern := telemetry.KIND_INFO[kind].counter
	if pattern == "" {return ""}
	if strings.contains(pattern, "%t") {
		clean, _ := strings.replace_all(text, ".", "_", context.temp_allocator)
		return strings.concatenate(
			{pattern[:len(pattern) - 2], clean if clean != "" else "none"},
			context.temp_allocator,
		)
	}
	return pattern
}

// stat_add adds to a player's and their world's counter.
stat_add :: proc(c: ^Client, name: string, amount: u64) {
	counter_add(&c.stats, name, amount)
	if c.world != nil {counter_add(&c.world.stats, name, amount)}
}

@(private)
event_for :: proc(
	s: ^Server,
	w: ^World,
	kind: telemetry.Kind,
	actor: u16,
	text: string,
	n: [3]i64,
) -> telemetry.Event {
	e := telemetry.Event {
		tick  = u32(s.tick),
		actor = actor,
		kind  = kind,
		text  = telemetry.short(text),
		n     = n,
	}
	if w != nil {e.world = telemetry.short(game.address_dir(w.address))}
	return e
}

// record: player c did something (kind, with its text and numbers): an event
// at their position (or at); and the counters.
record :: proc(
	s: ^Server,
	c: ^Client,
	kind: telemetry.Kind,
	text := "",
	n0 := i64(0),
	n1 := i64(0),
	n2 := i64(0),
	at: Maybe(game.Block_Pos) = nil,
) {
	e := event_for(s, c.world, kind, player_id(s, c), text, {n0, n1, n2})
	p, has := at.?
	if !has {
		p = {i32(c.position.x), i32(c.position.y), i32(c.position.z)}
	}
	e.has_pos, e.pos = true, {p.x, p.y, p.z}
	telemetry.emit(&s.sink, e)
	count_event(c, kind, text, n0)
}

// record_world: something happened in w with no player to credit.
record_world :: proc(
	s: ^Server,
	w: ^World,
	kind: telemetry.Kind,
	text := "",
	n0 := i64(0),
	n1 := i64(0),
	n2 := i64(0),
) {
	telemetry.emit(&s.sink, event_for(s, w, kind, telemetry.NO_ACTOR, text, {n0, n1, n2}))
	if name := counter_name(kind, text); name != "" && w != nil {counter_add(&w.stats, name, 1)}
}

@(private)
count_event :: proc(c: ^Client, kind: telemetry.Kind, text: string, n0: i64) {
	name := counter_name(kind, text)
	if name == "" {return}
	amount := u64(1)
	if telemetry.KIND_INFO[kind].amount {amount = u64(max(n0, 0))}
	stat_add(c, name, amount)
}

// stats_lines: a player's counters whose names contain filter, sorted, as
// "name value" lines; with the totals of the first two levels when no filter.
stats_lines :: proc(m: Counters, filter: string, allocator := context.temp_allocator) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	for k in m {
		if filter == "" || strings.contains(k, filter) {append(&names, k)}
	}
	slice.sort(names[:])
	lines := make([dynamic]string, allocator)
	for k in names {append(&lines, fmt.aprintf("%s %d", k, m[k], allocator = allocator))}
	return lines[:]
}

STATS_FILE :: "stats.json"

// write_stats keeps the world's totals (written atomically, with the rest of the save).
write_stats :: proc(w: ^World) -> bool {
	if w.dir == "" {return true}
	data, err := json.marshal(
		w.stats,
		{pretty = true, use_spaces = true, spaces = 2, sort_maps_by_key = true},
		context.temp_allocator,
	)
	if err != nil {return false}
	return write_atomically(
		filepath.join({w.dir, STATS_FILE}, context.temp_allocator) or_else STATS_FILE,
		data,
	)
}

// load_stats brings back a saved world's totals.
load_stats :: proc(w: ^World) {
	if w.dir == "" {return}
	path := filepath.join({w.dir, STATS_FILE}, context.temp_allocator) or_else STATS_FILE
	data, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
	if read_err != nil {return}
	loaded: map[string]u64
	if err := json.unmarshal(data, &loaded, allocator = context.temp_allocator); err != nil {
		log.warnf("server world stats not understood path=%s", path)
		return
	}
	w.stats = counters_clone(loaded)
}

// stats_tick: what a player's tick adds up to: distance (centimetres,
// flown, walked, fallen), jumps, seconds played, a position sample every 10 s.
stats_tick :: proc(s: ^Server, c: ^Client) {
	p := c.player
	d := p.position - c.last_position
	first := c.last_position == {}
	c.last_position = p.position
	horizontal := math.sqrt(d.x * d.x + d.z * d.z)
	if !first && horizontal < 20 && abs(d.y) < 20 { 	// (more is a teleport)
		if p.flying {
			c.dist_acc[1] += math.sqrt(horizontal * horizontal + d.y * d.y) * 100
		} else {
			c.dist_acc[0] += horizontal * 100
			if !p.on_ground && d.y < 0 {c.dist_acc[2] += -d.y * 100}
		}
	}
	names := [3]string{"distance.walked", "distance.flown", "distance.fallen"}
	for &acc, i in c.dist_acc {
		if whole := math.floor(acc); whole >= 1 {
			stat_add(c, names[i], u64(whole))
			acc -= whole
		}
	}
	if c.was_grounded && !p.on_ground && p.velocity.y > 0 && !p.flying {stat_add(c, "jumps", 1)}
	c.was_grounded = p.on_ground
	if s.tick % game.TICK_RATE == 0 {
		stat_add(c, "time.away" if c.afk else "time.played", 1)
		if p.flying {stat_add(c, "time.flying", 1)}
	}
	if (s.tick + u64(player_id(s, c)) * 7) % (10 * game.TICK_RATE) == 0 {
		state := "walking"
		switch {
		case p.flying:
			state = "flying"
		case !p.on_ground:
			state = "falling"
		}
		record(s, c, .Position_Sample, state)
	}
}

// tick_summary: once a minute, how the server is doing.
tick_summary :: proc(s: ^Server) {
	samples := make([]u32, len(s.tick_us), context.temp_allocator)
	copy(samples, s.tick_us[:])
	slice.sort(samples)
	online := 0
	for &c in s.clients {if c.state == .Playing {online += 1}}
	telemetry.emit(
		&s.sink,
		{
			tick = u32(s.tick),
			actor = telemetry.NO_ACTOR,
			kind = .Tick_Summary,
			n = {i64(online), i64(samples[len(samples) / 2]), i64(samples[len(samples) - 1])},
		},
	)
}

// stats_target: whose counters c may see by name ("": their own).
@(private)
stats_target :: proc(s: ^Server, c: ^Client, of: string) -> ^Client {
	if of == "" || of == client_name(c) || of == "@s" {return c}
	if !allowed(s, c, "info.stats.others") {return nil}
	return find_player(s, c, of)
}

// stats_request answers a Stats_Request with a page of the counters.
@(private)
stats_request :: proc(s: ^Server, c: ^Client, q: game.Stats_Request) {
	text, pages := "", 1
	if target := stats_target(s, c, q.of); target != nil {
		lines := stats_lines(target.stats, q.filter)
		pages = max(1, (len(lines) + game.STATS_PAGE_LINES - 1) / game.STATS_PAGE_LINES)
		first := min(int(q.page) * game.STATS_PAGE_LINES, len(lines))
		last := min(first + game.STATS_PAGE_LINES, len(lines))
		text = strings.join(lines[first:last], "\n", context.temp_allocator)
	}
	if len(text) > game.MAX_STATS_TEXT {text = text[:game.MAX_STATS_TEXT]}
	send_message(s, c, game.Stats_Page{q.page, u16(pages), text})
}

// admin_stats: stats [player] [filter]: counters in chat (the first 30 lines).
@(private)
admin_stats :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	who, filter := "", ""
	switch len(args) {
	case 1:
		// A name of a player here, else a filter.
		if find_player(s, c, args[0]) != nil {who = args[0]} else {filter = args[0]}
	case 2:
		who, filter = args[0], args[1]
	}
	target := stats_target(s, c, who)
	if target == nil {
		notice(s, c, "&cYou may not see that player's stats, or they are not here")
		return true
	}
	lines := stats_lines(target.stats, filter)
	if len(lines) == 0 {notice(s, c, "No counters yet" if filter == "" else "No counter matches")}
	for line, i in lines {
		if i == 30 {
			notice(
				s,
				c,
				fmt.tprintf("&7... %d more (the stats screen shows all)", len(lines) - 30),
			)
			break
		}
		notice(s, c, line)
	}
	return true
}

REPORTS_PER_WINDOW :: 6 // a client's Telemetry_Reports in each window of REPORT_WINDOW_TICKS
REPORT_WINDOW_TICKS :: 60 * game.TICK_RATE
MAX_REPORT_NUMBER :: 1 << 30

// telemetry_report takes what a client reports (info, overlays, frame
// times): at most a few reports a minute, each entry of a kind a client may
// report, with printable text and sane numbers; anything else is refused and
// counted (telemetry.refused, in the world's totals).
@(private)
telemetry_report :: proc(s: ^Server, c: ^Client, report: game.Telemetry_Report) {
	r := report
	if s.tick - c.report_window >=
	   REPORT_WINDOW_TICKS {c.report_window, c.report_count = s.tick, 0}
	if c.report_count >= REPORTS_PER_WINDOW {
		counter_add(&c.world.stats, "telemetry.refused", 1)
		return
	}
	c.report_count += 1
	for e in r.entries[:r.count] {
		valid :=
			int(e.kind) < len(telemetry.Kind) && telemetry.KIND_INFO[telemetry.Kind(e.kind)].client
		for ch in transmute([]u8)e.text {valid &&= ch >= 0x20 && ch < 0x7f}
		for n in e.n {valid &&= n < MAX_REPORT_NUMBER}
		if !valid {
			counter_add(&c.world.stats, "telemetry.refused", 1)
			continue
		}
		event := event_for(
			s,
			c.world,
			telemetry.Kind(e.kind),
			player_id(s, c),
			e.text,
			{i64(e.n[0]), i64(e.n[1]), i64(e.n[2])},
		)
		telemetry.emit(&s.sink, event)
	}
}
