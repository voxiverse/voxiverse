package analytics

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"

import "../../common/game"

// Analysis of a lake of event lines (collector/): each function takes the
// lines (JSON objects, one per line, as the sink wrote them with a "pid"
// added) and answers one of the questions asked most. The tool (main.odin)
// reads the files and prints; DuckDB reads the same files for the rest.

Event :: struct {
	pid:    string,
	kind:   string,
	t:      i64, // ms
	sid:    i64, // the server run
	actor:  i64, // -1: the server
	fields: json.Object,
}

// parse_events reads lines (those that are not objects with a time and a kind are skipped).
parse_events :: proc(text: string, allocator := context.temp_allocator) -> []Event {
	events := make([dynamic]Event, allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if len(line) == 0 {continue}
		value, err := json.parse(transmute([]u8)line, allocator = allocator)
		if err != nil {continue}
		obj, is_obj := value.(json.Object)
		if !is_obj {continue}
		e := Event {
			fields = obj,
			actor  = -1,
		}
		if v, ok := obj["pid"].(json.String); ok {e.pid = v}
		if v, ok := obj["k"].(json.String); ok {e.kind = v}
		e.t = i64(json_number(obj["t"]))
		e.sid = i64(json_number(obj["sid"]))
		if actor, present := obj["actor"]; present {
			if _, null := actor.(json.Null); !null {e.actor = i64(json_number(actor))}
		}
		if e.kind != "" && e.t != 0 {append(&events, e)}
	}
	return events[:]
}

number :: proc(e: Event, name: string) -> f64 {
	return json_number(e.fields[name])
}

@(private)
json_number :: proc(v: json.Value) -> f64 {
	#partial switch n in v {
	case json.Float:
		return f64(n)
	case json.Integer:
		return f64(n)
	}
	return 0
}

text :: proc(e: Event, name: string) -> string {
	if v, ok := e.fields[name].(json.String); ok {return v}
	return ""
}

// summary: events per kind, how many senders, the span.
summary :: proc(events: []Event) -> string {
	counts := make(map[string]int, allocator = context.temp_allocator)
	pids := make(map[string]struct{}, allocator = context.temp_allocator)
	first, last := max(i64), i64(0)
	for e in events {
		counts[e.kind] += 1
		pids[e.pid] = {}
		first, last = min(first, e.t), max(last, e.t)
	}
	kinds := make([dynamic]string, context.temp_allocator)
	for k in counts {append(&kinds, k)}
	slice.sort_by(kinds[:], proc(a, b: string) -> bool {return a < b})
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(
		&b,
		"events %d from %d senders, %.1f hours",
		len(events),
		len(pids),
		f64(last - first) / 3_600_000 if len(events) > 0 else 0,
	)
	for k in kinds {fmt.sbprintfln(&b, "  %-18s %d", k, counts[k])}
	return strings.to_string(b)
}

// Session_Row: one sender's sessions.
Session_Row :: struct {
	pid:      string,
	sessions: int,
	seconds:  int,
}

// sessions: per sender, how many sessions and how long they played (the
// retention picture: how many return on a later day is `returning`).
sessions :: proc(events: []Event) -> (rows: []Session_Row, returning: int) {
	by_pid := make(map[string]Session_Row, allocator = context.temp_allocator)
	days := make(map[string]map[i64]struct{}, allocator = context.temp_allocator)
	for e in events {
		if e.kind != "session_start" && e.kind != "session_end" {continue}
		r := by_pid[e.pid]
		r.pid = e.pid
		if e.kind == "session_start" {
			r.sessions += 1
			d, ok := &days[e.pid]
			if !ok {
				days[e.pid] = make(map[i64]struct{}, allocator = context.temp_allocator)
				d = &days[e.pid]
			}
			d[e.t / 86_400_000] = {}
		} else {
			r.seconds += int(number(e, "seconds"))
		}
		by_pid[e.pid] = r
	}
	out := make([dynamic]Session_Row, context.temp_allocator)
	for _, r in by_pid {append(&out, r)}
	slice.sort_by(out[:], proc(a, b: Session_Row) -> bool {return a.seconds > b.seconds})
	for _, d in days {if len(d) > 1 {returning += 1}}
	return out[:], returning
}

// economy: what entered and left the economy by item: picked up, dropped,
// and what blocks were mined and placed (counts).
economy :: proc(events: []Event) -> string {
	picked := make(map[string]int, allocator = context.temp_allocator)
	dropped := make(map[string]int, allocator = context.temp_allocator)
	mined := make(map[string]int, allocator = context.temp_allocator)
	placed := make(map[string]int, allocator = context.temp_allocator)
	for e in events {
		switch e.kind {
		case "item_picked":
			picked[text(e, "item")] += int(number(e, "count"))
		case "item_dropped":
			dropped[text(e, "item")] += int(number(e, "count"))
		case "block_mined":
			mined[text(e, "block")] += 1
		case "block_placed":
			placed[text(e, "block")] += 1
		}
	}
	b := strings.builder_make(context.temp_allocator)
	table :: proc(b: ^strings.Builder, title: string, m: map[string]int) {
		names := make([dynamic]string, context.temp_allocator)
		for k in m {append(&names, k)}
		slice.sort_by(names[:], proc(a, b: string) -> bool {return a < b})
		fmt.sbprintfln(b, "%s:", title)
		for k in names {fmt.sbprintfln(b, "  %-16s %d", k, m[k])}
	}
	table(&b, "picked up", picked)
	table(&b, "dropped", dropped)
	table(&b, "mined", mined)
	table(&b, "placed", placed)
	return strings.to_string(b)
}

// faucets: per item, what was made and what was unmade, by reason (the
// server's ledger: item_created and item_destroyed).
faucets :: proc(events: []Event) -> string {
	Key :: struct {
		item:   string,
		reason: string,
		made:   bool,
	}
	totals := make(map[Key]int, allocator = context.temp_allocator)
	for e in events {
		if e.kind != "item_created" && e.kind != "item_destroyed" {continue}
		n := int(number(e, "count"))
		why := int(number(e, "reason"))
		name := "?"
		if why >= 0 && why < len(game.Reason) {name = game.reason_name(game.Reason(why))}
		totals[{text(e, "item"), name, e.kind == "item_created"}] += n
	}
	keys := make([dynamic]Key, context.temp_allocator)
	for k in totals {append(&keys, k)}
	slice.sort_by(keys[:], proc(a, b: Key) -> bool {
		if a.item != b.item {return a.item < b.item}
		if a.made != b.made {return a.made}
		return a.reason < b.reason
	})
	b := strings.builder_make(context.temp_allocator)
	for k in keys {
		fmt.sbprintfln(
			&b,
			"%-16s %-9s %-16s %d",
			k.item,
			"created" if k.made else "destroyed",
			k.reason,
			totals[k],
		)
	}
	return strings.to_string(b)
}

// slowest: the five worst server minutes (tick_summary) and client frame p99s.
slowest :: proc(events: []Event) -> string {
	Row :: struct {
		t:     i64,
		pid:   string,
		kind:  string,
		value: f64,
	}
	rows := make([dynamic]Row, context.temp_allocator)
	for e in events {
		switch e.kind {
		case "tick_summary":
			append(&rows, Row{e.t, e.pid, "tick worst us", number(e, "worst_us")})
		case "client_perf":
			append(&rows, Row{e.t, e.pid, "frame p99 us", number(e, "p99_us")})
		}
	}
	slice.sort_by(rows[:], proc(a, b: Row) -> bool {return a.value > b.value})
	b := strings.builder_make(context.temp_allocator)
	for r in rows[:min(5, len(rows))] {fmt.sbprintfln(&b, "  %-14s %8.0f  pid %s  t %d", r.kind, r.value, r.pid, r.t)}
	return strings.to_string(b)
}

// launch_to_playing: the median and worst time from launch to playing, ms (client_info).
launch_to_playing :: proc(events: []Event) -> (median, worst: f64, count: int) {
	values := make([dynamic]f64, context.temp_allocator)
	for e in events {
		if e.kind == "client_info" {append(&values, number(e, "launch_ms"))}
	}
	if len(values) == 0 {return}
	slice.sort(values[:])
	return values[len(values) / 2], values[len(values) - 1], len(values)
}

// heat: position samples binned into size x size cells of `cell` blocks around
// the origin: counts per cell (row major, z down).
heat :: proc(events: []Event, size, cell: int) -> []int {
	grid := make([]int, size * size, context.temp_allocator)
	for e in events {
		if e.kind != "position_sample" {continue}
		pos, ok := e.fields["pos"].(json.Array)
		if !ok || len(pos) != 3 {continue}
		x, z := json_int(pos[0]), json_int(pos[2])
		gx, gz := x / cell + size / 2, z / cell + size / 2
		if gx >= 0 && gx < size && gz >= 0 && gz < size {grid[gz * size + gx] += 1}
	}
	return grid
}

@(private)
json_int :: proc(v: json.Value) -> int {
	return int(json_number(v))
}
