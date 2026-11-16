package store

import "core:fmt"
import "core:strconv"
import "core:strings"

// Format 7 to 8: the sheep left the engine for the sandbox (games/sandbox). A line of a
// world's entities.cfg for the base pack's sheep (`voxiverse:sheep`, or a bare `sheep`)
// becomes one of the sandbox's (`sandbox:sheep`), what the engine kept of it by name
// becoming the sandbox's record on it: `shorn` and `genes` as they were, `love` and
// `wait` as they were, and `growth` (ticks grown, an adult at LAMB_TICKS) as `grows`
// (ticks before it is grown). Every other line and file of format 7 is one of format 8.
// The reader of format 7's sheep is frozen here.

@(private = "file")
LAMB_TICKS_V7 :: 10 * 60 * 30 // format 7's ticks for a lamb to grow up

@(private)
migrate_v7_sheep :: proc(m: ^Migrator) -> bool {
	for world in world_dirs(m) {
		rel := fmt.tprintf("%s/entities.cfg", world)
		data, ok := mig_read(m, rel)
		if !ok {continue}
		b := strings.builder_make(context.temp_allocator)
		rest := string(data)
		for line in strings.split_lines_iterator(&rest) {
			fmt.sbprintln(&b, v7_entity_line(line))
		}
		mig_write(m, rel, b.buf[:])
	}
	return true
}

// v7_entity_line: a line of a format 7 entities.cfg as format 8 has it.
@(private = "file")
v7_entity_line :: proc(line: string) -> string {
	f := strings.fields(strings.trim_space(line), context.temp_allocator)
	if len(f) < 7 || (f[0] != "voxiverse:sheep" && f[0] != "sheep") {return line}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "sandbox:sheep")
	for v in f[1:7] {fmt.sbprintf(&b, " %s", v)}
	for field in f[7:] {
		name, eq, value := strings.partition(field, "=")
		if eq == "" {return line} 	// (not a line format 7 read either: as it was)
		switch name {
		case "shorn", "genes", "love", "wait":
			if value != "0" && value != "false" {fmt.sbprintf(&b, " data.%s=%s", name, value)}
		case "growth":
			growth, parsed := strconv.parse_int(value)
			if !parsed {return line}
			if grows := LAMB_TICKS_V7 - clamp(growth, 0, LAMB_TICKS_V7); grows > 0 {
				fmt.sbprintf(&b, " data.grows=%d", grows)
			}
		case:
			fmt.sbprintf(&b, " %s", field) // (the engine's own: its health, its way)
		}
	}
	return strings.to_string(b)
}
