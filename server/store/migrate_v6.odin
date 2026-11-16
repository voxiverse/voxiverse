package store

import "core:fmt"
import "core:strings"

// Format 6 to 7: entities.cfg's lines name what each entity has beyond its kind, place,
// yaw, health and whether it came by itself as `name=value` fields (a game's record on
// its entities among them), where format 6 had a dropped stack's item, count, action and
// data, and a sheep's shorn, genes, growth, love and wait, by their places. Every other
// file of format 6 is a file of format 7. The reader of format 6's lines is frozen here.

@(private)
migrate_v6_entities :: proc(m: ^Migrator) -> bool {
	for world in world_dirs(m) {
		rel := fmt.tprintf("%s/entities.cfg", world)
		data, ok := mig_read(m, rel)
		if !ok {continue}
		b := strings.builder_make(context.temp_allocator)
		rest := string(data)
		for line in strings.split_lines_iterator(&rest) {
			fmt.sbprintln(&b, v6_entity_line(line))
		}
		mig_write(m, rel, b.buf[:])
	}
	return true
}

// v6_entity_line: a line of a format 6 entities.cfg as format 7 has it (a comment, or a
// line format 6 did not read either, is kept as it is: format 7 skips it as 6 did).
@(private = "file")
v6_entity_line :: proc(line: string) -> string {
	f := strings.fields(strings.trim_space(line), context.temp_allocator)
	if len(f) < 7 || f[0][0] == '#' {return line}
	kind := f[0]
	b := strings.builder_make(context.temp_allocator)
	switch kind {
	case "critter":
		kind = "voxiverse:sheep" // (before it was a sheep)
	}
	fmt.sbprintf(&b, "%s", kind)
	for v in f[1:7] {fmt.sbprintf(&b, " %s", v)}
	extra := f[7:]
	switch kind {
	case "item", "voxiverse:item":
		// item count [action [data]]
		if len(extra) < 2 || len(extra) > 4 {return line}
		fmt.sbprintf(&b, " item=%s count=%s", extra[0], extra[1])
		if len(extra) >= 3 && extra[2] != "0" {fmt.sbprintf(&b, " action=%s", extra[2])}
		if len(extra) == 4 && extra[3] != "0" {fmt.sbprintf(&b, " stack_data=%s", extra[3])}
	case "sheep", "voxiverse:sheep":
		// shorn [genes growth love wait]
		if len(extra) != 0 && len(extra) != 1 && len(extra) != 5 {return line}
		names := [5]string{"shorn", "genes", "growth", "love", "wait"}
		for v, i in extra {fmt.sbprintf(&b, " %s=%s", names[i], v)}
	case:
		if len(extra) != 0 {return line}
	}
	return strings.to_string(b)
}
