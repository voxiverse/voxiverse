package netdump

import "core:flags"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

import "common:access"
import "common:game"
import "common:protocol"
import "common:starmap"
import games "generated:games"

// netdump prints a network trace (build/net.trace, recorded with
// `set debug.net_trace 1` or the net_trace command), decoding every message
// with the game's own decoders.
//
//	build netdump                          every message
//	build netdump -kind:chunk -from:2 -to:3
//	build netdump -summary                 counts and bytes per kind and direction

Options :: struct {
	file:    string `args:"pos=0" usage:"trace file (default build/net.trace)"`,
	summary: bool `usage:"counts and bytes per message kind instead of messages"`,
	stats:   bool `usage:"bandwidth analytics, category breakdown, packet size and jitter stats"`,
	csv:     bool `usage:"export records as CSV (timestamp_sec,direction,kind,bytes)"`,
	kind:    string `usage:"only this kind (-kind:list lists them)"`,
	sender:  string `usage:"only messages from client or server"`,
	from:    f64 `usage:"only from this many seconds into the session"`,
	to:      f64 `usage:"only up to this many seconds into the session"`,
	limit:   int `usage:"stop after this many messages"`,
}

// registry: what block and item numbers in a capture mean: the base pack's, and the
// traced session's game's pack's (trace_registry).
registry: ^game.Registry

main :: proc() {
	registry = game.registry_base()
	opts := Options {
		file = "build/net.trace",
	}
	flags.parse_or_exit(&opts, os.args, .Odin)
	if opts.kind != "" && !kind_known(opts.kind) {
		if opts.kind != "list" {fmt.eprintfln("netdump: no message kind %q", opts.kind)}
		for sender in protocol.Side {
			fmt.printf("%v:", sender)
			for k in 0 ..< 256 {
				if name := protocol.message_kind_name(sender, u8(k));
				   name != "" {fmt.printf(" %s", name)}
			}
			fmt.println()
		}
		os.exit(0 if opts.kind == "list" else 1)
	}
	data, err := os.read_entire_file_from_path(opts.file, context.allocator)
	if err != nil {
		fmt.eprintfln("netdump: cannot read %s: %v", opts.file, err)
		os.exit(1)
	}
	header, records, ok := protocol.trace_read(data)
	registry = trace_registry(records[:])
	fmt.printfln(
		"trace %s: protocol %d, seed %d, view %dx%d, %d messages",
		opts.file,
		header.protocol,
		header.seed,
		header.view_radius,
		header.view_height,
		len(records),
	)
	if header.protocol != protocol.PROTOCOL_VERSION {
		fmt.eprintfln(
			"netdump: recorded with protocol %d, this build speaks %d; decoding may fail",
			header.protocol,
			protocol.PROTOCOL_VERSION,
		)
	}
	if !ok {fmt.eprintln("netdump: the trace is damaged or cut short; showing what precedes it")}

	if opts.csv {
		fmt.println("timestamp_sec,direction,kind,bytes")
		shown := 0
		for r in records {
			secs := time.duration_seconds(r.time)
			if secs < opts.from || (opts.to > 0 && secs > opts.to) {continue}
			if opts.sender != "" &&
			   opts.sender != (r.sender == .Client ? "client" : "server") {continue}
			kind := protocol.message_kind_name(r.sender, r.data[0])
			if opts.kind != "" && kind != opts.kind {continue}
			dir := r.sender == .Client ? "client" : "server"
			fmt.printfln("%.4f,%s,%s,%d", secs, dir, kind if kind != "" else "?", len(r.data))
			shown += 1
			if opts.limit > 0 && shown >= opts.limit {break}
		}
		return
	}

	if opts.stats {
		Category :: enum {
			Chunks,
			State,
			Snapshot,
			Control,
			Gameplay,
		}
		category_name := [Category]string {
			.Chunks   = "Chunks & Terrain",
			.State    = "State Model Deltas",
			.Snapshot = "Snapshot Entities/Motion",
			.Control  = "Session Control",
			.Gameplay = "Gameplay & Actions",
		}
		cat_bytes: [Category]int
		cat_msgs: [Category]int
		client_bytes, server_bytes := 0, 0
		client_msgs, server_msgs := 0, 0
		min_bytes, max_bytes := max(int), 0
		intervals := make([dynamic]f64, context.temp_allocator)
		prev_time: Maybe(time.Duration) = nil
		first_time: Maybe(time.Duration) = nil
		last_time: time.Duration

		for r in records {
			secs := time.duration_seconds(r.time)
			if secs < opts.from || (opts.to > 0 && secs > opts.to) {continue}
			if opts.sender != "" &&
			   opts.sender != (r.sender == .Client ? "client" : "server") {continue}
			kind := protocol.message_kind_name(r.sender, r.data[0])
			if opts.kind != "" && kind != opts.kind {continue}

			sz := len(r.data)
			if sz < min_bytes {min_bytes = sz}
			if sz > max_bytes {max_bytes = sz}

			if first_time == nil {first_time = r.time}
			if prev, prev_ok := prev_time.?; prev_ok {
				interval_ms := time.duration_milliseconds(r.time - prev)
				if interval_ms >= 0 {append(&intervals, interval_ms)}
			}
			prev_time = r.time
			last_time = r.time

			if r.sender == .Client {
				client_msgs += 1
				client_bytes += sz
			} else {
				server_msgs += 1
				server_bytes += sz
			}

			cat: Category = .Gameplay
			switch kind {
			case "chunk", "column", "bulk", "unload":
				cat = .Chunks
			case "state":
				cat = .State
			case "snapshot":
				cat = .Snapshot
			case "hello",
			     "welcome",
			     "reject",
			     "ping",
			     "pong",
			     "challenge",
			     "proof",
			     "choose",
			     "dial",
			     "teleport",
			     "characters",
			     "world_changed",
			     "stats_request",
			     "stats_page",
			     "pack_want",
			     "packs",
			     "pack_part",
			     "packs_ready",
			     "packs_changed":
				cat = .Control
			}
			cat_bytes[cat] += sz
			cat_msgs[cat] += 1
		}

		duration_s := 0.001
		if f, first_ok := first_time.?; first_ok {
			duration_s = max(time.duration_seconds(last_time - f), 0.001)
		}
		total_bytes := client_bytes + server_bytes
		total_msgs := client_msgs + server_msgs
		slice.sort(intervals[:])
		p50_jitter := intervals[len(intervals) / 2] if len(intervals) > 0 else 0
		p99_jitter :=
			intervals[min(len(intervals) - 1, len(intervals) * 99 / 100)] if len(intervals) > 0 else 0
		max_jitter := intervals[len(intervals) - 1] if len(intervals) > 0 else 0

		fmt.println("\nnetwork traffic profile")
		fmt.printfln("  duration:       %.2f s", duration_s)
		fmt.printfln(
			"  total messages: %d (%.1f msgs/s)",
			total_msgs,
			f64(total_msgs) / duration_s,
		)
		fmt.printfln(
			"  total data:     %d B (%.1f KiB, %.2f KiB/s)",
			total_bytes,
			f64(total_bytes) / 1024,
			(f64(total_bytes) / 1024) / duration_s,
		)
		fmt.printfln(
			"  client -> server: %d msgs, %d B (%.1f KiB, %.1f%%)",
			client_msgs,
			client_bytes,
			f64(client_bytes) / 1024,
			100.0 * f64(client_bytes) / max(f64(total_bytes), 1),
		)
		fmt.printfln(
			"  server -> client: %d msgs, %d B (%.1f KiB, %.1f%%)",
			server_msgs,
			server_bytes,
			f64(server_bytes) / 1024,
			100.0 * f64(server_bytes) / max(f64(total_bytes), 1),
		)

		fmt.println("\nmessage categories")
		fmt.printfln("  %-26s %8s %10s %10s %8s", "category", "msgs", "bytes", "KiB/s", "share")
		for cat in Category {
			c_bytes := cat_bytes[cat]
			c_msgs := cat_msgs[cat]
			pct := 100.0 * f64(c_bytes) / max(f64(total_bytes), 1)
			fmt.printfln(
				"  %-26s % 8d % 10d % 10.2f % 7.1f%%",
				category_name[cat],
				c_msgs,
				c_bytes,
				(f64(c_bytes) / 1024) / duration_s,
				pct,
			)
		}

		fmt.println("\nmessage size & timing")
		avg_bytes := f64(total_bytes) / max(f64(total_msgs), 1)
		fmt.printfln(
			"  packet payload sizes: min %d B, avg %.1f B, max %d B",
			min_bytes if min_bytes != max(int) else 0,
			avg_bytes,
			max_bytes,
		)
		fmt.printfln(
			"  inter-packet interval: p50 %.2f ms, p99 %.2f ms, max %.2f ms",
			p50_jitter,
			p99_jitter,
			max_jitter,
		)
		return
	}

	scratch := new(game.Block_Array)
	schema := trace_schema(records[:], scratch)
	Total :: struct {
		messages, bytes: int,
	}
	totals: map[string]Total
	shown := 0
	invalid := 0
	last: time.Duration
	for r in records {
		secs := time.duration_seconds(r.time)
		if secs < opts.from || (opts.to > 0 && secs > opts.to) {continue}
		if opts.sender != "" &&
		   opts.sender != (r.sender == .Client ? "client" : "server") {continue}
		kind := protocol.message_kind_name(r.sender, r.data[0])
		if opts.kind != "" && kind != opts.kind {continue}
		last = r.time
		if opts.summary {
			key := fmt.aprintf(
				"%s %s",
				r.sender == .Client ? "client->server" : "server->client",
				kind if kind != "" else "?",
			)
			t := totals[key]
			totals[key] = {t.messages + 1, t.bytes + len(r.data)}
			if r.sender == .Server && (kind == "state" || kind == "snapshot") {
				// State and Snapshot split by the kinds they carry
				bytes := make([]int, len(schema.kinds), context.temp_allocator)
				entries := make([]int, len(schema.kinds), context.temp_allocator)
				if protocol.scan_state(&schema, r.data, bytes, entries) {
					for k in schema.kinds {
						if entries[k.id] == 0 {continue}
						sub := fmt.aprintf("server->client   %s: %s", kind, k.name)
						st := totals[sub]
						totals[sub] = {st.messages + entries[k.id], st.bytes + bytes[k.id]}
					}
				}
			}
			continue
		}
		text, valid := describe(r, scratch, &schema)
		if !valid {invalid += 1}
		fmt.printfln(
			"% 10.4f  %s  % 6d B  %s",
			secs,
			r.sender == .Client ? "C->S" : "S->C",
			len(r.data),
			text,
		)
		shown += 1
		if opts.limit > 0 && shown >= opts.limit {break}
	}
	if opts.summary {
		keys, _ := slice.map_keys(totals)
		slice.sort(keys)
		secs := max(time.duration_seconds(last), 0.001)
		fmt.printfln("%-40s %9s %12s %12s", "", "messages", "bytes", "bytes/s")
		for k in keys {
			t := totals[k]
			fmt.printfln("%-40s % 9d % 12d % 12.0f", k, t.messages, t.bytes, f64(t.bytes) / secs)
		}
	}
	if invalid > 0 {
		fmt.eprintfln("netdump: %d message(s) did not decode", invalid)
		os.exit(1)
	}
}

// describe_state names the kinds a State or Snapshot message carries and
// their sizes (game.scan_state: no baseline is needed).
describe_state :: proc(schema: ^protocol.Schema, name: string, data: []u8) -> string {
	bytes := make([]int, len(schema.kinds), context.temp_allocator)
	entries := make([]int, len(schema.kinds), context.temp_allocator)
	if !protocol.scan_state(schema, data, bytes, entries) {return fmt.tprintf("INVALID %s", name)}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprint(&b, name)
	for k in schema.kinds {
		if entries[k.id] > 0 {fmt.sbprintf(&b, " %s*%d(%dB)", k.name, entries[k.id], bytes[k.id])}
	}
	return strings.to_string(b)
}

kind_known :: proc(name: string) -> bool {
	for sender in protocol.Side {
		for k in 0 ..< 256 {if protocol.message_kind_name(sender, u8(k)) == name {return true}}
	}
	return false
}

// describe decodes one message into "kind field=value ...".
describe :: proc(
	r: protocol.Trace_Record,
	scratch: ^game.Block_Array,
	schema: ^protocol.Schema,
) -> (
	string,
	bool,
) {
	if r.sender == .Client {
		m, ok := protocol.decode_client(r.data, registry)
		if !ok {return "INVALID client message", false}
		switch v in m {
		case protocol.Hello:
			return fmt.tprintf(
					"hello protocol=%d account=%s character=%q schema=%016x",
					v.protocol,
					access.account_text(v.account)[:16],
					v.character,
					v.schema,
				),
				true
		case protocol.Proof:
			return "proof", true
		case protocol.Pack_Want:
			return fmt.tprintf("pack_want count=%d", v.count), true
		case protocol.Packs_Ready:
			return fmt.tprintf("packs_ready content=%016x", v.content), true
		case protocol.Dial:
			return fmt.tprintf("dial gate=%v address=%s", v.gate, starmap.address_dir(v.address)),
				true
		case protocol.Choose:
			return fmt.tprintf("choose character=%q", v.character), true
		case protocol.Input:
			text := fmt.tprintf(
				"input seq=%d snapshot=%d move=[%.2f, %.2f] yaw=%.3f pitch=%.3f buttons=%v",
				v.sequence,
				v.snapshot,
				v.input.move.x,
				v.input.move.y,
				v.input.yaw,
				v.input.pitch,
				v.input.buttons,
			)
			return text, true
		case protocol.Teleport:
			text := fmt.tprintf(
				"teleport position=[%.2f, %.2f, %.2f]",
				v.position.x,
				v.position.y,
				v.position.z,
			)
			return text, true
		case protocol.Set_Rule:
			return fmt.tprintf("set_rule name=%s value=%s", v.name, v.value), true
		case protocol.Edit:
			return fmt.tprintf(
					"edit id=%d after=%d pos=%v block=%v",
					v.id,
					v.after,
					v.pos,
					v.block,
				),
				true
		case protocol.Command:
			return fmt.tprintf("command command=%q", v.command), true
		case protocol.Chat:
			return fmt.tprintf("chat text=%q", v.text), true
		case protocol.Inventory_Request:
			return fmt.tprintf("inventory_request seq=%d action=%v", v.sequence, v.action), true
		case protocol.Attack:
			return fmt.tprintf("attack entity=%d after=%d", v.entity, v.after), true
		case protocol.Respawn:
			return "respawn", true
		case protocol.Reload:
			return "reload", true
		case protocol.Game_Action:
			return fmt.tprintf("game_action index=%d after=%d", v.index, v.after), true
		case protocol.Game_Request:
			return fmt.tprintf(
					"game_request kind=%d after=%d bytes=%d",
					v.kind,
					v.after,
					len(v.data),
				),
				true
		case protocol.Shoot:
			return fmt.tprintf(
					"shoot after=%d slot=%d press=%v yaw=%.2f pitch=%.2f",
					v.after,
					v.slot,
					v.press,
					v.yaw,
					v.pitch,
				),
				true
		case protocol.Stats_Request:
			return fmt.tprintf("stats_request filter=%q page=%d of=%q", v.filter, v.page, v.of),
				true
		case protocol.Dev_Message:
			return fmt.tprintf(
					"dev_message id=%d bytes=%d version=%q",
					v.id,
					len(v.text),
					v.version,
				),
				true
		case protocol.Dev_Fetch:
			return fmt.tprintf("dev_fetch after=%q", v.after_id), true
		case protocol.Telemetry_Batch:
			return fmt.tprintf(
					"telemetry_batch %v day=%q offset=%d bytes=%d",
					v.kind,
					v.day,
					v.offset,
					len(v.text),
				),
				true
		case protocol.Telemetry_Report:
			return fmt.tprintf("telemetry entries=%d", v.count), true
		case protocol.Use_Entity:
			return fmt.tprintf("use_entity entity=%d after=%d", v.entity, v.after), true
		case protocol.Use_Block:
			return fmt.tprintf("use_block pos=%v after=%d", v.pos, v.after), true
		case protocol.Prediction_Check:
			return fmt.tprintf("prediction_check sequence=%d fields=%v", v.sequence, v.fields),
				true
		case protocol.Fire:
			return fmt.tprintf("fire after=%d yaw=%.2f pitch=%.2f", v.after, v.yaw, v.pitch), true
		case protocol.Ping:
			return fmt.tprintf("ping id=%d", v.id), true
		}
	} else {
		m, ok := protocol.decode_server(r.data, scratch, registry)
		if !ok {return "INVALID server message", false}
		switch v in m {
		case protocol.Welcome:
			return fmt.tprintf(
					"welcome protocol=%d tick_rate=%d spawn=[%.2f, %.2f, %.2f] view=%dx%d",
					v.protocol,
					v.tick_rate,
					v.spawn.x,
					v.spawn.y,
					v.spawn.z,
					v.view_radius,
					v.view_height,
				),
				true
		case protocol.Reject:
			return fmt.tprintf("reject reason=%q", v.reason), true
		case protocol.Chunk_Message:
			if v.is_uniform {return fmt.tprintf("chunk pos=%v uniform=%v", v.pos, v.uniform), true}
			counts: [game.Block]int
			for b in scratch {counts[b] += 1}
			b := strings.builder_make(context.temp_allocator)
			for n, block in counts {
				if n > 0 {fmt.sbprintf(&b, " %v=%d", block, n)}
			}
			return fmt.tprintf("chunk pos=%v blocks:%s", v.pos, strings.to_string(b)), true
		case protocol.Unload_Chunk:
			return fmt.tprintf("unload pos=%v", v.pos), true
		case protocol.Pong:
			return fmt.tprintf("pong id=%d", v.id), true
		case protocol.Edit_Result:
			return fmt.tprintf(
					"edit_result id=%d accepted=%v pos=%v block=%v",
					v.id,
					v.accepted,
					v.pos,
					v.block,
				),
				true
		case protocol.Column:
			lo, hi := max(i32), min(i32)
			for h in v.heights {lo, hi = min(lo, h), max(hi, h)}
			return fmt.tprintf("column pos=%v heights=%d..%d", v.pos, lo, hi), true
		case protocol.Dev_Ack:
			return fmt.tprintf("dev_ack id=%d ok=%v reason=%q", v.id, v.ok, v.reason), true
		case protocol.Dev_Replies:
			return fmt.tprintf("dev_replies count=%d", v.count), true
		case protocol.Telemetry_Ack:
			return fmt.tprintf("telemetry_ack day=%q end=%d", v.day, v.end), true
		case protocol.Stats_Page:
			return fmt.tprintf("stats_page %d of %d bytes=%d", v.page, v.pages, len(v.text)), true
		case protocol.Bulk_Begin:
			return fmt.tprintf("bulk count=%d", v.count), true
		case protocol.Challenge:
			return "challenge", true
		case protocol.World_Changed:
			return fmt.tprintf("world_changed address=%s", starmap.address_dir(v.address)), true
		case protocol.State_Message:
			return describe_state(schema, "state", v.data), true
		case protocol.Snapshot_Message:
			return describe_state(schema, "snapshot", v.data), true
		case protocol.Characters:
			return fmt.tprintf("characters names=%q", v.names), true
		case protocol.Packs:
			return fmt.tprintf("packs content=%016x count=%d", v.content, v.count), true
		case protocol.Packs_Changed:
			return fmt.tprintf("packs_changed content=%016x", v.content), true
		case protocol.Pack_Part:
			return fmt.tprintf(
					"pack_part index=%d offset=%d bytes=%d",
					v.index,
					v.offset,
					len(v.data),
				),
				true
		}
	}
	return "", true
}

// trace_schema: the state kinds of the traced session: the engine's and its game's (the
// game its Welcome named, found among the games this build has: a State message of a game
// the build lacks counts as one that does not decode).
trace_schema :: proc(
	records: []protocol.Trace_Record,
	scratch: ^game.Block_Array,
) -> protocol.Schema {
	played := protocol.trace_game(records, scratch, registry)
	for g in games.SERVER {
		if g.id == played {return protocol.game_schema(g.id, g.kinds)}
	}
	return protocol.game_schema()
}

// trace_registry: the registry the traced session played with, as far as the trace says:
// the base pack and the pack of the game its Welcome named (a game this build has), so a
// game's blocks and items read by their names. The base pack's alone for any other.
trace_registry :: proc(records: []protocol.Trace_Record) -> ^game.Registry {
	scratch := new(game.Block_Array)
	defer free(scratch)
	played := protocol.trace_game(records, scratch, registry)
	for g in games.SERVER {
		if g.id != played || len(g.pack.files) == 0 {continue}
		reg, errs := game.registry_build({game.base_pack_source(context.temp_allocator), g.pack})
		if reg != nil && len(errs) == 0 {return reg}
		fmt.eprintfln(
			"%s: the pack of %s does not build; reading with the base pack's",
			"netdump",
			played,
		)
	}
	return registry
}
