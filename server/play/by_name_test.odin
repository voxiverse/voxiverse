package play

import "core:strconv"
import "core:strings"
import "core:testing"

// What a game keeps by name: rows found or made by a player's name, written as lines and
// read back the same; a full table makes no more, a line of another key or with a number
// out of bounds is refused.

@(private = "file")
Hero :: struct {
	level: int,
	best:  int,
}

@(test)
test_by_name_keeps_rows_and_reads_them_back :: proc(t: ^testing.T) {
	kept: By_Name(Hero, 2)
	ana := by_name(&kept, "ana", make_it = true)
	ana.level, ana.best = 3, 140
	by_name(&kept, "bo", make_it = true).level = 1
	testing.expect(t, by_name(&kept, "cy", make_it = true) == nil, "a row past the table's size")
	testing.expect(t, by_name(&kept, "ana") == ana)
	out := strings.builder_make(context.temp_allocator)
	write :: proc(b: ^strings.Builder, v: ^Hero) -> bool {
		strings.write_int(b, v.level)
		strings.write_byte(b, ' ')
		strings.write_int(b, v.best)
		return v.level > 0
	}
	by_name_save(&kept, "hero", &out, write)
	text := strings.to_string(out)
	testing.expect_value(t, text, "hero = 3 140 ana\nhero = 1 0 bo\n")

	read :: proc(f: []string, v: ^Hero) -> bool {
		if len(f) != 2 {return false}
		level, ok1 := strconv.parse_int(f[0])
		best, ok2 := strconv.parse_int(f[1])
		if !ok1 || !ok2 || level < 1 || best < 0 {return false}
		v.level, v.best = level, best
		return true
	}
	back: By_Name(Hero, 4)
	for line in saved_lines(text) {testing.expect(t, by_name_read(&back, "hero", line, read))}
	testing.expect_value(t, len(by_name_rows(&back)), 2)
	testing.expect_value(t, by_name(&back, "ana").best, 140)
	bad := Saved_Line{"hero", "0 5 dee"}
	testing.expect(t, !by_name_read(&back, "hero", bad, read), "a level out of bounds")
	testing.expect(t, !by_name_read(&back, "hero", {"best", "1 2 ana"}, read), "another key")
}
