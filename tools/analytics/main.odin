package analytics

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

import "../../base"

// Reads a lake (the collector's `lake/` directory, or a server's own
// telemetry directory of day files) and answers the questions asked most:
//
//	build analytics <dir> summary | sessions | economy | slow | launch | heat [out.png]
//
// JSON lines in, text out; for anything else, DuckDB reads the same files:
//
//	select k, count(*) from read_json_auto('lake/**/*.jsonl') group by 1
main :: proc() {
	args := os.args[1:]
	if len(args) < 2 {
		fmt.eprintln(
			"usage: analytics <dir> summary | sessions | economy | slow | launch | heat [out.png]",
		)
		os.exit(2)
	}
	events := parse_events(read_all(args[0]))
	switch args[1] {
	case "summary":
		fmt.print(summary(events))
	case "sessions":
		rows, returning := sessions(events)
		fmt.printfln("%d senders, %d on more than one day", len(rows), returning)
		for r in rows[:min(len(rows), 20)] {fmt.printfln("  %s  %3d sessions  %6d s", r.pid, r.sessions, r.seconds)}
	case "economy":
		fmt.print(economy(events))
	case "slow":
		fmt.print(slowest(events))
	case "launch":
		median, worst, n := launch_to_playing(events)
		fmt.printfln("%d launches: median %.0f ms, worst %.0f ms to playing", n, median, worst)
	case "heat":
		out := args[2] if len(args) > 2 else "build/heat.png"
		size := 256
		grid := heat(events, size, 16)
		most := max(1, slice.max(grid))
		pixels := make([]u8, size * size * 4)
		for n, i in grid {
			v := u8(255 * f32(n) / f32(most))
			pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2], pixels[i * 4 + 3] =
				v, v / 2, 255 - v, 255
		}
		png, _ := base.png_encode(size, size, pixels)
		_ = os.write_entire_file(out, png)
		fmt.printfln("wrote %s (cells of 16 blocks, the busiest has %d samples)", out, most)
	case:
		fmt.eprintfln("unknown question %s", args[1])
		os.exit(2)
	}
}

// read_all: every .jsonl file under dir, joined.
read_all :: proc(dir: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	walk :: proc(dir: string, b: ^strings.Builder) {
		infos, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
		for info in infos {
			if info.type == .Directory {
				walk(info.fullpath, b)
			} else if strings.has_suffix(info.name, ".jsonl") {
				data, _ := os.read_entire_file_from_path(info.fullpath, context.temp_allocator)
				strings.write_string(b, string(data))
			}
		}
	}
	walk(dir, &b)
	return strings.to_string(b)
}
