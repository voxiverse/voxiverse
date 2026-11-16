package store

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

// Format 8 to 9: the towns' markets, the traders and the interventions log left the engine
// for the sandbox (games/sandbox). A world's `economy.vxe` and `interventions.vxi` are the
// sandbox's files of the world, `sandbox.economy.vxe` and `sandbox.interventions.vxi`, their
// bytes as they were (their formats did not change). A character file's `trader` member
// (silver, cargo by good, the prices seen) is the sandbox's record on the character, its
// `game` member a field by its path (`cash`, `cargo.<i>`, `seen.<i>.cell`, `.price`,
// `.month`, `.good` by its name, `count`, and `given`: the starting purse was), in a universe
// the sandbox plays (or one that names no game, which the sandbox opens); in another it is
// dropped. Every other file of format 8 is one of format 9. The reader of format 8's trader
// is frozen here.

// GOODS_V8: format 8's goods, by their number in a trader's `cargo` and `seen.good`.
@(private = "file")
GOODS_V8 :: [8]string{"Grain", "Timber", "Ore", "Salt", "Fish", "Wool", "Tools", "Cloth"}

@(private = "file")
MAX_SEEN_V8 :: 192 // the prices a format 8 trader remembered

@(private)
migrate_v8_markets :: proc(m: ^Migrator) -> bool {
	for world in world_dirs(m) {
		for name in ([]string{"economy.vxe", "interventions.vxi"}) {
			rel := fmt.tprintf("%s/%s", world, name)
			data, ok := mig_read(m, rel)
			if !ok {continue}
			mig_write(m, fmt.tprintf("%s/sandbox.%s", world, name), data)
			append(&m.deletes, rel)
		}
	}
	universe, _ := mig_read(m, UNIVERSE_FILE)
	game, named := text_value(string(universe), "game")
	sandbox := !named || game == "" || game == "sandbox"
	files := make([dynamic]string, context.temp_allocator)
	append(&files, ..mig_list(m, "players", ".json"))
	accounts, _ := os.read_all_directory_by_path(
		full_path(m.dir, "characters"),
		context.temp_allocator,
	)
	for a in accounts {
		if a.type == .Directory {
			append(&files, ..mig_list(m, fmt.tprintf("characters/%s", a.name), ".json"))
		}
	}
	for rel in files {
		data, _ := mig_read(m, rel)
		text, ok := v8_character(data, sandbox)
		if !ok {
			m.why = fmt.tprintf("%s is not a character file this build can read", rel)
			return false
		}
		if text != nil {mig_write(m, rel, text)}
	}
	return true
}

// v8_character: a format 8 character file with its trader as the sandbox's record (nil: it
// has no trader, and stays as it was).
@(private = "file")
v8_character :: proc(data: []u8, sandbox: bool) -> (text: []u8, ok: bool) {
	value, err := json.parse(data, parse_integers = true, allocator = context.temp_allocator)
	if err != .None {return}
	file, is_object := value.(json.Object)
	if !is_object {return}
	trader, has := file["trader"].(json.Object)
	if !has {return nil, true}
	delete_key(&file, "trader")
	if sandbox {
		record := make(json.Object, 16, context.temp_allocator)
		cash := number(trader["cash"])
		record["cash"] = json.Float(cash if cash >= 0 && cash < 1e15 else 20)
		if cargo, is_array := trader["cargo"].(json.Array); is_array {
			for v, i in cargo {
				n := number(v)
				if i < len(GOODS_V8) && n > 0 && n < 1e9 {
					record[fmt.tprintf("cargo.%d", i)] = json.Float(n)
				}
			}
		}
		count := 0
		if seen, is_array := trader["seen"].(json.Array); is_array {
			for v in seen {
				e, is_entry := v.(json.Object)
				if !is_entry || count >= MAX_SEEN_V8 {continue}
				good := int(number(e["good"]))
				price, month := number(e["price"]), number(e["month"])
				if good < 0 || good >= len(GOODS_V8) {continue}
				if !(price >= 0 && price < 1e9) || !(abs(month) < 1e9) {continue}
				goods := GOODS_V8
				record[fmt.tprintf("seen.%d.cell", count)] = json.Integer(number(e["cell"]))
				record[fmt.tprintf("seen.%d.price", count)] = json.Float(price)
				record[fmt.tprintf("seen.%d.month", count)] = json.Float(month)
				record[fmt.tprintf("seen.%d.good", count)] = json.String(goods[good])
				count += 1
			}
		}
		if count > 0 {record["count"] = json.Integer(count)}
		record["given"] = json.Boolean(true)
		file["game"] = record
		file["format"] = json.Integer(5)
	}
	// The counters stay last, as the server writes them (its reader takes them out by hand).
	stats, has_stats := file["stats"]
	delete_key(&file, "stats")
	options := json.Marshal_Options {
		pretty           = true,
		use_spaces       = true,
		spaces           = 2,
		sort_maps_by_key = true,
	}
	out, merr := json.marshal(file, options, context.temp_allocator)
	if merr != nil {return}
	if !has_stats {return out, true}
	counters, serr := json.marshal(stats, options, context.temp_allocator)
	if serr != nil {return}
	head := strings.trim_right_space(string(out))
	head = strings.trim_right_space(head[:len(head) - 1]) // (without the closing brace)
	return transmute([]u8)strings.concatenate(
			{head, ",\n  \"stats\": ", string(counters), "\n}"},
			context.temp_allocator,
		),
		true
}

// number: a JSON number as f64 (0 for anything else).
@(private = "file")
number :: proc(v: json.Value) -> f64 {
	#partial switch n in v {
	case json.Integer:
		return f64(n)
	case json.Float:
		return n
	}
	return 0
}
