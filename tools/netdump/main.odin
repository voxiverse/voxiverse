package netdump

import "core:flags"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

import "../../common/game"

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
	kind:    string `usage:"only this kind (-kind:list lists them)"`,
	sender:  string `usage:"only messages from client or server"`,
	from:    f64 `usage:"only from this many seconds into the session"`,
	to:      f64 `usage:"only up to this many seconds into the session"`,
	limit:   int `usage:"stop after this many messages"`,
}

// base_registry: what block and item numbers in a capture mean (the base pack's).
base_registry: ^game.Registry

main :: proc() {
	base_registry = game.registry_base()
	opts := Options {
		file = "build/net.trace",
	}
	flags.parse_or_exit(&opts, os.args, .Odin)
	if opts.kind != "" && !kind_known(opts.kind) {
		if opts.kind != "list" {fmt.eprintfln("netdump: no message kind %q", opts.kind)}
		for sender in game.Side {
			fmt.printf("%v:", sender)
			for k in 0 ..< 256 {
				if name := game.message_kind_name(sender, u8(k));
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
	header, records, ok := game.trace_read(data)
	fmt.printfln(
		"trace %s: protocol %d, seed %d, view %dx%d, %d messages",
		opts.file,
		header.protocol,
		header.seed,
		header.view_radius,
		header.view_height,
		len(records),
	)
	if header.protocol != game.PROTOCOL_VERSION {
		fmt.eprintfln(
			"netdump: recorded with protocol %d, this build speaks %d; decoding may fail",
			header.protocol,
			game.PROTOCOL_VERSION,
		)
	}
	if !ok {fmt.eprintln("netdump: the trace is damaged or cut short; showing what precedes it")}

	scratch := new(game.Block_Array)
	schema := game.game_schema()
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
		kind := game.message_kind_name(r.sender, r.data[0])
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
				if game.scan_state(&schema, r.data, bytes, entries) {
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
describe_state :: proc(schema: ^game.Schema, name: string, data: []u8) -> string {
	bytes := make([]int, len(schema.kinds), context.temp_allocator)
	entries := make([]int, len(schema.kinds), context.temp_allocator)
	if !game.scan_state(schema, data, bytes, entries) {return fmt.tprintf("INVALID %s", name)}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprint(&b, name)
	for k in schema.kinds {
		if entries[k.id] > 0 {fmt.sbprintf(&b, " %s*%d(%dB)", k.name, entries[k.id], bytes[k.id])}
	}
	return strings.to_string(b)
}

kind_known :: proc(name: string) -> bool {
	for sender in game.Side {
		for k in 0 ..< 256 {if game.message_kind_name(sender, u8(k)) == name {return true}}
	}
	return false
}

// describe decodes one message into "kind field=value ...".
describe :: proc(
	r: game.Trace_Record,
	scratch: ^game.Block_Array,
	schema: ^game.Schema,
) -> (
	string,
	bool,
) {
	if r.sender == .Client {
		m, ok := game.decode_client(r.data, base_registry)
		if !ok {return "INVALID client message", false}
		switch v in m {
		case game.Hello:
			return fmt.tprintf(
					"hello protocol=%d account=%s character=%q schema=%016x",
					v.protocol,
					game.account_text(v.account)[:16],
					v.character,
					v.schema,
				),
				true
		case game.Proof:
			return "proof", true
		case game.Pack_Want:
			return fmt.tprintf("pack_want count=%d", v.count), true
		case game.Packs_Ready:
			return fmt.tprintf("packs_ready content=%016x", v.content), true
		case game.Dial:
			return fmt.tprintf("dial gate=%v address=%s", v.gate, game.address_dir(v.address)),
				true
		case game.Choose:
			return fmt.tprintf("choose character=%q", v.character), true
		case game.Input:
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
		case game.Teleport:
			text := fmt.tprintf(
				"teleport position=[%.2f, %.2f, %.2f]",
				v.position.x,
				v.position.y,
				v.position.z,
			)
			return text, true
		case game.Set_Rule:
			return fmt.tprintf("set_rule name=%s value=%s", v.name, v.value), true
		case game.Edit:
			return fmt.tprintf(
					"edit id=%d after=%d pos=%v block=%v",
					v.id,
					v.after,
					v.pos,
					v.block,
				),
				true
		case game.Command:
			return fmt.tprintf("command command=%q", v.command), true
		case game.Chat:
			return fmt.tprintf("chat text=%q", v.text), true
		case game.Inventory_Request:
			return fmt.tprintf("inventory_request seq=%d action=%v", v.sequence, v.action), true
		case game.Attack:
			return fmt.tprintf("attack entity=%d after=%d", v.entity, v.after), true
		case game.Stats_Request:
			return fmt.tprintf("stats_request filter=%q page=%d of=%q", v.filter, v.page, v.of),
				true
		case game.Telemetry_Batch:
			return fmt.tprintf(
					"telemetry_batch %v day=%q offset=%d bytes=%d",
					v.kind,
					v.day,
					v.offset,
					len(v.text),
				),
				true
		case game.Telemetry_Report:
			return fmt.tprintf("telemetry entries=%d", v.count), true
		case game.Use_Entity:
			return fmt.tprintf("use_entity entity=%d after=%d", v.entity, v.after), true
		case game.Use_Block:
			return fmt.tprintf("use_block pos=%v after=%d", v.pos, v.after), true
		case game.Prediction_Check:
			return fmt.tprintf("prediction_check sequence=%d fields=%v", v.sequence, v.fields),
				true
		case game.Fire:
			return fmt.tprintf("fire after=%d yaw=%.2f pitch=%.2f", v.after, v.yaw, v.pitch), true
		case game.Ping:
			return fmt.tprintf("ping id=%d", v.id), true
		}
	} else {
		m, ok := game.decode_server(r.data, scratch, base_registry)
		if !ok {return "INVALID server message", false}
		switch v in m {
		case game.Welcome:
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
		case game.Reject:
			return fmt.tprintf("reject reason=%q", v.reason), true
		case game.Chunk_Message:
			if v.is_uniform {return fmt.tprintf("chunk pos=%v uniform=%v", v.pos, v.uniform), true}
			counts: [game.Block]int
			for b in scratch {counts[b] += 1}
			b := strings.builder_make(context.temp_allocator)
			for n, block in counts {
				if n > 0 {fmt.sbprintf(&b, " %v=%d", block, n)}
			}
			return fmt.tprintf("chunk pos=%v blocks:%s", v.pos, strings.to_string(b)), true
		case game.Unload_Chunk:
			return fmt.tprintf("unload pos=%v", v.pos), true
		case game.Pong:
			return fmt.tprintf("pong id=%d", v.id), true
		case game.Edit_Result:
			return fmt.tprintf(
					"edit_result id=%d accepted=%v pos=%v block=%v",
					v.id,
					v.accepted,
					v.pos,
					v.block,
				),
				true
		case game.Column:
			lo, hi := max(i32), min(i32)
			for h in v.heights {lo, hi = min(lo, h), max(hi, h)}
			return fmt.tprintf("column pos=%v heights=%d..%d", v.pos, lo, hi), true
		case game.Telemetry_Ack:
			return fmt.tprintf("telemetry_ack day=%q end=%d", v.day, v.end), true
		case game.Stats_Page:
			return fmt.tprintf("stats_page %d of %d bytes=%d", v.page, v.pages, len(v.text)), true
		case game.Bulk_Begin:
			return fmt.tprintf("bulk count=%d", v.count), true
		case game.Challenge:
			return "challenge", true
		case game.World_Changed:
			return fmt.tprintf("world_changed address=%s", game.address_dir(v.address)), true
		case game.State_Message:
			return describe_state(schema, "state", v.data), true
		case game.Snapshot_Message:
			return describe_state(schema, "snapshot", v.data), true
		case game.Characters:
			return fmt.tprintf("characters names=%q", v.names), true
		case game.Packs:
			return fmt.tprintf("packs content=%016x count=%d", v.content, v.count), true
		case game.Packs_Changed:
			return fmt.tprintf("packs_changed content=%016x", v.content), true
		case game.Pack_Part:
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
